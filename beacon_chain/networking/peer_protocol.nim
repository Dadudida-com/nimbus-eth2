# beacon_chain
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  chronicles,
  ../spec/network,
  ".."/[beacon_clock],
  ../networking/eth2_network,
  ../consensus_object_pools/blockchain_dag,
  ../rpc/rest_constants

logScope:
  topics = "peer_proto"

type
  StatusMsg* = object
    forkDigest*: ForkDigest
    finalizedRoot*: Eth2Digest
    finalizedEpoch*: Epoch
    headRoot*: Eth2Digest
    headSlot*: Slot

  PeerSyncNetworkState* {.final.} = ref object of RootObj
    dag: ChainDAGRef
    cfg: RuntimeConfig
    forkDigests: ref ForkDigests
    genesisBlockRoot: Eth2Digest
    getBeaconTime: GetBeaconTimeFn

  PeerSyncPeerState* {.final.} = ref object of RootObj
    statusLastTime: chronos.Moment
    statusMsg: StatusMsg

func shortLog*(s: StatusMsg): auto =
  (
    forkDigest: s.forkDigest,
    finalizedRoot: shortLog(s.finalizedRoot),
    finalizedEpoch: shortLog(s.finalizedEpoch),
    headRoot: shortLog(s.headRoot),
    headSlot: shortLog(s.headSlot)
  )
chronicles.formatIt(StatusMsg): shortLog(it)

func disconnectReasonName(reason: uint64): string =
  # haha, nim doesn't support uint64 in `case`!
  if reason == uint64(ClientShutDown): "Client shutdown"
  elif reason == uint64(IrrelevantNetwork): "Irrelevant network"
  elif reason == uint64(FaultOrError): "Fault or error"
  else: "Disconnected (" & $reason & ")"

func forkDigestAtEpoch(state: PeerSyncNetworkState,
                       epoch: Epoch): ForkDigest =
  state.forkDigests[].atEpoch(epoch, state.cfg)

proc getCurrentStatus(state: PeerSyncNetworkState): StatusMsg =
  let
    dag = state.dag
    wallSlot = state.getBeaconTime().slotOrZero

  if dag != nil:
    StatusMsg(
      forkDigest: state.forkDigestAtEpoch(wallSlot.epoch),
      finalizedRoot: dag.finalizedHead.blck.root,
      finalizedEpoch: dag.finalizedHead.slot.epoch,
      headRoot: dag.head.root,
      headSlot: dag.head.slot)
  else:
    StatusMsg(
      forkDigest: state.forkDigestAtEpoch(wallSlot.epoch),
      finalizedRoot: state.genesisBlockRoot,
      finalizedEpoch: GENESIS_EPOCH,
      headRoot: state.genesisBlockRoot,
      headSlot: GENESIS_SLOT)

proc checkStatusMsg(state: PeerSyncNetworkState, status: StatusMsg):
    Result[void, cstring] =
  let
    dag = state.dag
    wallSlot = (state.getBeaconTime() + MAXIMUM_GOSSIP_CLOCK_DISPARITY).slotOrZero

  if status.finalizedEpoch > status.headSlot.epoch:
    # Can be equal during genesis or checkpoint start
    return err("finalized epoch newer than head")

  if status.headSlot > wallSlot:
    return err("head more recent than wall clock")

  if state.forkDigestAtEpoch(wallSlot.epoch) != status.forkDigest:
    return err("fork digests differ")

  if dag != nil:
    if status.finalizedEpoch <= dag.finalizedHead.slot.epoch:
      let blockId = dag.getBlockIdAtSlot(status.finalizedEpoch.start_slot())
      if blockId.isSome and
          (not status.finalizedRoot.isZero) and
          status.finalizedRoot != blockId.get().bid.root:
        return err("peer following different finality")
  else:
    if status.finalizedEpoch == GENESIS_EPOCH:
      if status.finalizedRoot != state.genesisBlockRoot:
        return err("peer following different finality")

  ok()

proc handleStatus(peer: Peer,
                  state: PeerSyncNetworkState,
                  theirStatus: StatusMsg): Future[bool] {.async: (raises: [CancelledError]).}

{.pop.} # TODO fix p2p macro for raises

p2pProtocol PeerSync(version = 1,
                       networkState = PeerSyncNetworkState,
                       peerState = PeerSyncPeerState):

  onPeerConnected do (peer: Peer, incoming: bool) {.async: (raises: [CancelledError]).}:
    debug "Peer connected",
      peer, peerId = shortLog(peer.peerId), incoming
    # Per the eth2 protocol, whoever dials must send a status message when
    # connected for the first time, but because of how libp2p works, there may
    # be a race between incoming and outgoing connections and disconnects that
    # makes the incoming flag unreliable / obsolete by the time we get to
    # this point - instead of making assumptions, we'll just send a status
    # message redundantly.
    # TODO(zah)
    #      the spec does not prohibit sending the extra status message on
    #      incoming connections, but it should not be necessary - this would
    #      need a dedicated flow in libp2p that resolves the race conditions -
    #      this needs more thinking around the ordering of events and the
    #      given incoming flag
    let
      ourStatus = peer.networkState.getCurrentStatus()
      theirStatus = await peer.status(ourStatus, timeout = RESP_TIMEOUT_DUR)

    if theirStatus.isOk:
      discard await peer.handleStatus(peer.networkState, theirStatus.get())
    else:
      debug "Status response not received in time",
            peer, errorKind = theirStatus.error.kind
      await peer.disconnect(FaultOrError)

  proc status(peer: Peer,
              theirStatus: StatusMsg,
              response: SingleChunkResponse[StatusMsg])
    {.async, libp2pProtocol("status", 1).} =
    let ourStatus = peer.networkState.getCurrentStatus()
    trace "Sending status message", peer = peer, status = ourStatus
    await response.send(ourStatus)
    discard await peer.handleStatus(peer.networkState, theirStatus)

  proc ping(peer: Peer, value: uint64): uint64
    {.libp2pProtocol("ping", 1).} =
    peer.network.metadata.seq_number

  # https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.6/specs/altair/p2p-interface.md#transitioning-from-v1-to-v2
  proc getMetaData(peer: Peer): uint64
    {.libp2pProtocol("metadata", 1).} =
    raise newException(InvalidInputsError, "GetMetaData v1 unsupported")

  proc getMetadata_v2(peer: Peer): altair.MetaData
    {.libp2pProtocol("metadata", 2).} =
    peer.network.metadata

  proc goodbye(peer: Peer, reason: uint64)
    {.async, libp2pProtocol("goodbye", 1).} =
    debug "Received Goodbye message", reason = disconnectReasonName(reason), peer

proc setStatusMsg(peer: Peer, statusMsg: StatusMsg) =
  debug "Peer status", peer, statusMsg
  peer.state(PeerSync).statusMsg = statusMsg
  peer.state(PeerSync).statusLastTime = Moment.now()

proc handleStatus(peer: Peer,
                  state: PeerSyncNetworkState,
                  theirStatus: StatusMsg): Future[bool]
                  {.async: (raises: [CancelledError]).} =
  let
    res = checkStatusMsg(state, theirStatus)

  return if res.isErr():
    debug "Irrelevant peer", peer, theirStatus, err = res.error()
    await peer.disconnect(IrrelevantNetwork)
    false
  else:
    peer.setStatusMsg(theirStatus)

    if peer.connectionState == Connecting:
      # As soon as we get here it means that we passed handshake succesfully. So
      # we can add this peer to PeerPool.
      await peer.handlePeer()
    true

proc updateStatus*(peer: Peer): Future[bool] {.async: (raises: [CancelledError]).} =
  ## Request `status` of remote peer ``peer``.
  let
    nstate = peer.networkState(PeerSync)
    ourStatus = getCurrentStatus(nstate)
    theirStatus =
      (await peer.status(ourStatus, timeout = RESP_TIMEOUT_DUR)).valueOr:
        return false

  await peer.handleStatus(nstate, theirStatus)

proc getHeadSlot*(peer: Peer): Slot =
  ## Returns head slot for specific peer ``peer``.
  peer.state(PeerSync).statusMsg.headSlot

proc getFinalizedEpoch*(peer: Peer): Epoch =
  ## Returns head slot for specific peer ``peer``.
  peer.state(PeerSync).statusMsg.finalizedEpoch

proc getStatusLastTime*(peer: Peer): chronos.Moment =
  ## Returns head slot for specific peer ``peer``.
  peer.state(PeerSync).statusLastTime

proc init*(T: type PeerSync.NetworkState,
    dag: ChainDAGRef, getBeaconTime: GetBeaconTimeFn): T =
  T(
    dag: dag,
    cfg: dag.cfg,
    forkDigests: dag.forkDigests,
    genesisBlockRoot: dag.genesisBlockRoot,
    getBeaconTime: getBeaconTime,
  )

proc init*(T: type PeerSync.NetworkState,
                     cfg: RuntimeConfig,
                     forkDigests: ref ForkDigests,
                     genesisBlockRoot: Eth2Digest,
                     getBeaconTime: GetBeaconTimeFn): T =
  T(
    dag: nil,
    cfg: cfg,
    forkDigests: forkDigests,
    genesisBlockRoot: genesisBlockRoot,
    getBeaconTime: getBeaconTime,
  )
