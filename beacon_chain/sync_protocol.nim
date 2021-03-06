import
  options, tables, sets, macros,
  chronicles, chronos, stew/ranges/bitranges, libp2p/switch,
  spec/[datatypes, crypto, digest],
  beacon_node_types, eth2_network,
  block_pools/chain_dag

logScope:
  topics = "sync"

const
  MAX_REQUESTED_BLOCKS = SLOTS_PER_EPOCH  * 4
    # A boundary on the number of blocks we'll allow in any single block
    # request - typically clients will ask for an epoch or so at a time, but we
    # allow a little bit more in case they want to stream blocks faster

type
  StatusMsg* = object
    forkDigest*: ForkDigest
    finalizedRoot*: Eth2Digest
    finalizedEpoch*: Epoch
    headRoot*: Eth2Digest
    headSlot*: Slot

  ValidatorSetDeltaFlags {.pure.} = enum
    Activation = 0
    Exit = 1

  ValidatorChangeLogEntry* = object
    case kind*: ValidatorSetDeltaFlags
    of Activation:
      pubkey: ValidatorPubKey
    else:
      index: uint32

  BeaconBlockCallback* = proc(signedBlock: SignedBeaconBlock) {.gcsafe.}

  BeaconSyncNetworkState* = ref object
    chainDag*: ChainDAGRef
    forkDigest*: ForkDigest

  BeaconSyncPeerState* = ref object
    initialStatusReceived*: bool
    statusMsg*: StatusMsg

  BlockRootSlot* = object
    blockRoot: Eth2Digest
    slot: Slot

  BlockRootsList* = List[Eth2Digest, Limit MAX_REQUESTED_BLOCKS]

proc shortLog*(s: StatusMsg): auto =
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

proc getCurrentStatus*(state: BeaconSyncNetworkState): StatusMsg {.gcsafe.} =
  let
    chainDag = state.chainDag
    headBlock = chainDag.head

  StatusMsg(
    forkDigest: state.forkDigest,
    finalizedRoot: chainDag.headState.data.data.finalized_checkpoint.root,
    finalizedEpoch: chainDag.headState.data.data.finalized_checkpoint.epoch,
    headRoot: headBlock.root,
    headSlot: headBlock.slot)

proc handleStatus(peer: Peer,
                  state: BeaconSyncNetworkState,
                  ourStatus: StatusMsg,
                  theirStatus: StatusMsg): Future[void] {.gcsafe.}

proc setStatusMsg(peer: Peer, statusMsg: StatusMsg) {.gcsafe.}

p2pProtocol BeaconSync(version = 1,
                       networkState = BeaconSyncNetworkState,
                       peerState = BeaconSyncPeerState):

  onPeerConnected do (peer: Peer) {.async.}:
    debug "Peer connected",
      peer, peerInfo = shortLog(peer.info), wasDialed = peer.wasDialed
    if peer.wasDialed:
      let
        ourStatus = peer.networkState.getCurrentStatus()
        # TODO: The timeout here is so high only because we fail to
        # respond in time due to high CPU load in our single thread.
        theirStatus = await peer.status(ourStatus, timeout = 60.seconds)

      if theirStatus.isOk:
        await peer.handleStatus(peer.networkState,
                                ourStatus, theirStatus.get())
      else:
        warn "Status response not received in time", peer

  proc status(peer: Peer,
              theirStatus: StatusMsg,
              response: SingleChunkResponse[StatusMsg])
    {.async, libp2pProtocol("status", 1).} =
    let ourStatus = peer.networkState.getCurrentStatus()
    trace "Sending status message", peer = peer, status = ourStatus
    await response.send(ourStatus)
    await peer.handleStatus(peer.networkState, ourStatus, theirStatus)

  proc ping(peer: Peer, value: uint64): uint64
    {.libp2pProtocol("ping", 1).} =
    return peer.network.metadata.seq_number

  proc getMetadata(peer: Peer): Eth2Metadata
    {.libp2pProtocol("metadata", 1).} =
    return peer.network.metadata

  proc beaconBlocksByRange(
      peer: Peer,
      startSlot: Slot,
      count: uint64,
      step: uint64,
      response: MultipleChunksResponse[SignedBeaconBlock])
      {.async, libp2pProtocol("beacon_blocks_by_range", 1).} =
    trace "got range request", peer, startSlot, count, step

    if count > 0'u64:
      var blocks: array[MAX_REQUESTED_BLOCKS, BlockRef]
      let
        chainDag = peer.networkState.chainDag
        # Limit number of blocks in response
        count = min(count.Natural, blocks.len)

      let
        endIndex = count - 1
        startIndex =
          chainDag.getBlockRange(startSlot, step, blocks.toOpenArray(0, endIndex))

      for b in blocks[startIndex..endIndex]:
        doAssert not b.isNil, "getBlockRange should return non-nil blocks only"
        trace "wrote response block", slot = b.slot, roor = shortLog(b.root)
        await response.write(chainDag.get(b).data)

      debug "Block range request done",
        peer, startSlot, count, step, found = count - startIndex

  proc beaconBlocksByRoot(
      peer: Peer,
      blockRoots: BlockRootsList,
      response: MultipleChunksResponse[SignedBeaconBlock])
      {.async, libp2pProtocol("beacon_blocks_by_root", 1).} =
    let
      chainDag = peer.networkState.chainDag
      count = blockRoots.len

    var found = 0

    for root in blockRoots[0..<count]:
      let blockRef = chainDag.getRef(root)
      if not isNil(blockRef):
        await response.write(chainDag.get(blockRef).data)
        inc found

    debug "Block root request done",
      peer, roots = blockRoots.len, count, found

  proc goodbye(peer: Peer,
               reason: uint64)
    {.async, libp2pProtocol("goodbye", 1).} =
    debug "Received Goodbye message", reason = disconnectReasonName(reason), peer

proc setStatusMsg(peer: Peer, statusMsg: StatusMsg) =
  debug "Peer status", peer, statusMsg
  peer.state(BeaconSync).initialStatusReceived = true
  peer.state(BeaconSync).statusMsg = statusMsg

proc updateStatus*(peer: Peer): Future[bool] {.async.} =
  ## Request `status` of remote peer ``peer``.
  let
    nstate = peer.networkState(BeaconSync)
    ourStatus = getCurrentStatus(nstate)

  let theirFut = awaitne peer.status(ourStatus,
                                     timeout = chronos.seconds(60))
  if theirFut.failed():
    result = false
  else:
    let theirStatus = theirFut.read()
    if theirStatus.isOk:
      peer.setStatusMsg(theirStatus.get)
      result = true

proc hasInitialStatus*(peer: Peer): bool {.inline.} =
  ## Returns head slot for specific peer ``peer``.
  peer.state(BeaconSync).initialStatusReceived

proc getHeadSlot*(peer: Peer): Slot {.inline.} =
  ## Returns head slot for specific peer ``peer``.
  result = peer.state(BeaconSync).statusMsg.headSlot

proc handleStatus(peer: Peer,
                  state: BeaconSyncNetworkState,
                  ourStatus: StatusMsg,
                  theirStatus: StatusMsg) {.async, gcsafe.} =
  if theirStatus.forkDigest != state.forkDigest:
    notice "Irrelevant peer", peer, theirStatus, ourStatus
    await peer.disconnect(IrrelevantNetwork)
  else:
    if not peer.state(BeaconSync).initialStatusReceived:
      # Initial/handshake status message handling
      peer.state(BeaconSync).initialStatusReceived = true
      debug "Peer connected", peer, ourStatus = shortLog(ourStatus),
                              theirStatus = shortLog(theirStatus)
      var res: bool
      if peer.wasDialed:
        res = await handleOutgoingPeer(peer)
      else:
        res = await handleIncomingPeer(peer)

      if not res:
        debug "Peer is dead or already in pool", peer
        # TODO: DON NOT DROP THE PEER!
        # await peer.disconnect(ClientShutDown)

    peer.setStatusMsg(theirStatus)

proc initBeaconSync*(network: Eth2Node, chainDag: ChainDAGRef,
                     forkDigest: ForkDigest) =
  var networkState = network.protocolState(BeaconSync)
  networkState.chainDag = chainDag
  networkState.forkDigest = forkDigest
