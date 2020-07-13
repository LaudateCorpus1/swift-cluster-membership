//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Cluster Membership open source project
//
// Copyright (c) 2018-2020 Apple Inc. and the Swift Cluster Membership project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Cluster Membership project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import ClusterMembership
import NIO
import Logging

extension SWIM {
    public enum Message: Codable {
        case remote(RemoteMessage)
        case local(LocalMessage)
    }
    
    public enum RemoteMessage: Codable {
        case ping(replyTo: Peer<PingResponse>, payload: GossipPayload)
        
        /// "Ping Request" requests a SWIM probe.
        case pingReq(target: Peer<Message>, replyTo: Peer<PingResponse>, payload: GossipPayload)
    }
    
}

/// The SWIM shell is responsible for driving all interactions of the `SWIM.Instance` with the outside world.
///
/// - SeeAlso: `SWIM.Instance` for detailed documentation about the SWIM protocol implementation.
public struct NIOSWIMShell {
    var swim: SWIM.Instance

    let context: NIOSWIMContext
    var eventLoop: EventLoop {
        self.context.eventLoop
    }

    var peerConnections: [Node: Peer<SWIM.Message>]

    var settings: SWIM.Settings {
        self.swim.settings
    }

    internal init(_ swim: SWIM.Instance, context: NIOSWIMContext) {
        self.swim = swim
        self.context = context

        self.peerConnections = [:]

        let probeInterval = settings.probeInterval
        timers.startSingle(key: SWIM.Shell.periodicPingKey, message: .local(.pingRandomMember), delay: probeInterval)
    }

    // ==== ------------------------------------------------------------------------------------------------------------

    func receiveRemoteMessage(_ message: SWIM.RemoteMessage) {

    }

    public func receiveLocalMessage(_ message: SWIM.LocalMessage) {

    }

    internal func receiveTestingMessage(_ message: SWIM.TestingMessage) {
        switch message {
        case .getMembershipState(let replyTo):
            context.log.trace("getMembershipState from \(replyTo), state: \(shell.swim._allMembersDict)")
            replyTo.tell(SWIM.MembershipState(membershipState: shell.swim._allMembersDict))
            return .same
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Receiving messages

    func receiveRemoteMessage(context: SWIM.Context, message: SWIM.RemoteMessage) {
        switch message {
        case .ping(let replyTo, let payload):
            self.tracelog(context, .receive, message: message)
            self.handlePing(context: context, replyTo: replyTo, payload: payload)

        case .pingReq(let target, let replyTo, let payload):
            self.tracelog(context, .receive, message: message)
            self.handlePingReq(context: context, target: target, replyTo: replyTo, payload: payload)
        }
    }

    private func handlePing(context: SWIM.Context, replyTo: Peer<SWIM.PingResponse>, payload: SWIM.GossipPayload) {
        self.processGossipPayload(context: context, payload: payload)

        switch self.swim.onPing() {
        case .reply(let ack):
            self.tracelog(context, .reply(to: replyTo), message: ack)
            replyTo.sendMessage(ack)

            // TODO: push the process gossip into SWIM as well?
            // TODO: the payloadToProcess is the same as `payload` here... but showcasing
            self.processGossipPayload(context: context, payload: payload)
        }
    }

    private func handlePingReq(context: SWIM.Context, target: Peer<SWIM.Message>, replyTo: Peer<SWIM.PingResponse>, payload: SWIM.GossipPayload) {
        context.log.trace("Received request to ping [\(target)] from [\(replyTo)] with payload [\(payload)]")
        self.processGossipPayload(context: context, payload: payload)

        if !self.swim.isMember(target) {
            self.withEnsuredAssociation(context, remoteNode: target.node.node) { result in
                switch result {
                case .success:
                    // The case when member is a suspect is already handled in `processGossipPayload`, since
                    // payload will always contain suspicion about target member
                    self.swim.addMember(target, status: .alive(incarnation: 0)) // TODO: push into SWIM?
                    self.sendPing(context: context, to: target, pingReqOrigin: replyTo)
                case .failure(let error):
                    context.log.warning("Unable to obtain association for remote \(target.node)... Maybe it was tombstoned? Error: \(error)")
                }
            }
        } else {
            self.sendPing(context: context, to: target, pingReqOrigin: replyTo)
        }
    }

    func receiveLocalMessage(context: SWIM.Context, message: SWIM.LocalMessage) {
        switch message {
        case .pingRandomMember:
            self.handleNewProtocolPeriod(context)

        case .monitor(let node):
            self.handleMonitor(context, node: node)

        case .confirmDead(let node):
            self.handleConfirmDead(context, deadNode: node)
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Sending ping, ping-req and friends

    /// - parameter pingReqOrigin: is set only when the ping that this is a reply to was originated as a `pingReq`.
    func sendPing(
        context: SWIM.Context,
        to target: Peer<SWIM.Message>,
        pingReqOrigin: Peer<SWIM.PingResponse>?
    ) {
        let payload = self.swim.makeGossipPayload(to: target)

        context.log.trace("Sending ping to [\(target)] with payload [\(payload)]")

        // let startPing = metrics.uptimeNanoseconds() // FIXME: metrics
        target.ping(from: context.peer, timeout: self.swim.dynamicLHMProtocolInterval) { (result: Result<Reply, Error>) in  }
//        let response = target.ask(for: SWIM.PingResponse.self, timeout: self.swim.dynamicLHMPingTimeout) {
//            let ping = SWIM.RemoteMessage.ping(replyTo: $0, payload: payload)
//            self.tracelog(context, .ask(target), message: ping)
//            return SWIM.Message.remote(ping)
//        }
        // response._onComplete { _ in metrics.recordSWIMPingPingResponseTime(since: startPing) } // FIXME metrics

        // timeout is already handled by the ask, so we can set it to infinite here to not have two timeouts
        context.onResultAsync(of: response, timeout: .effectivelyInfinite) { res in
            self.handlePingResponse(context: context, result: res, pingedMember: target, pingReqOrigin: pingReqOrigin)
            return .same
        }
    }

    func sendPingRequests(context: SWIM.Context, toPing: Peer<SWIM.Message>) {
        guard let lastKnownStatus = self.swim.status(of: toPing) else {
            context.log.info("Skipping ping requests after failed ping to [\(toPing)] because node has been removed from member list")
            return
        }

        // TODO: also push much of this down into SWIM.Instance

        // select random members to send ping requests to
        let membersToPingRequest = self.swim.membersToPingRequest(target: toPing)

        guard !membersToPingRequest.isEmpty else {
            // no nodes available to ping, so we have to assume the node suspect right away
            if let lastIncarnation = lastKnownStatus.incarnation {
                switch self.swim.mark(toPing, as: self.swim.makeSuspicion(incarnation: lastIncarnation)) {
                case .applied(_, let currentStatus):
                    context.log.info("No members to ping-req through, marked [\(toPing)] immediately as [\(currentStatus)].")
                    return
                case .ignoredDueToOlderStatus(let currentStatus):
                    context.log.info("No members to ping-req through to [\(toPing)], was already [\(currentStatus)].")
                    return
                }
            } else {
                context.log.trace("Not marking .suspect, as [\(toPing)] is already dead.") // "You are already dead!"
                return
            }
        }

        // We are only interested in successful pings, as a single success tells us the node is
        // still alive. Therefore we propagate only the first success, but no failures.
        // The failure case is handled through the timeout of the whole operation.
        let firstSuccessPromise = self.eventLoopGroup.next().makePromise(of: SWIM.PingResponse.self)
        let pingTimeout = self.swim.dynamicLHMPingTimeout
        for member: SWIM.Member in membersToPingRequest {
            let payload = self.swim.makeGossipPayload(to: toPing)

            context.log.trace("Sending ping request for [\(toPing)] to [\(member)] with payload: \(payload)")

//            guard let channel = self.peerConnections[member.node] else {
//                fatalError("// FIXME: we need to connect there") // FIXME: we need to connect there
//            }

            member.peer.request(<#T##message: Message##SWIM.SWIM.Message#>, replyType: <#T##Reply.Type##Reply.Type#>, onComplete: <#T##@escaping (Result<Reply, Error>) -> ()##@escaping (Swift.Result<Reply, Swift.Error>) -> ()#>)
            // let startPingReq = metrics.uptimeNanoseconds() // FIXME: metrics
//            let answer = member.peer.request(SWIM.PingResponse.self, timeout: pingTimeout) {
//                let pingReq = SWIM.RemoteMessage.pingReq(target: toPing, replyTo: $0, payload: payload)
//                self.tracelog(context, .ask(member.peer), message: pingReq)
//                return SWIM.Message.remote(pingReq)
//            }
//
//
//            answer._onComplete { result in
//                // metrics.recordSWIMPingPingResponseTime(since: startPingReq) // FIXME: metrics
//
//                // We choose to cascade only successes;
//                // While this has a slight timing implication on time timeout of the pings -- the node that is last
//                // in the list that we ping, has slightly less time to fulfil the "total ping timeout"; as we set a total timeout on the entire `firstSuccess`.
//                // In practice those timeouts will be relatively large (seconds) and the few millis here should not have a large impact on correctness.
//                if case .success(let response) = result {
//                    firstSuccessPromise.succeed(response)
//                }
//            }
        }

        context.onResultAsync(of: firstSuccessPromise.futureResult, timeout: pingTimeout) { result in
            self.handlePingRequestResult(context: context, result: result, pingedMember: toPing)
            return .same
        }
    }

    /// - parameter pingReqOrigin: is set only when the ping that this is a reply to was originated as a `pingReq`.
    func handlePingResponse(
        context: SWIM.Context,
        result: Result<SWIM.PingResponse, Error>,
        pingedMember: Peer<SWIM.Message>,
        pingReqOrigin: Peer<SWIM.PingResponse>?
    ) {
        self.tracelog(context, .receive(pinged: pingedMember), message: result)

        switch result {
        case .failure(let err):
            if let timeoutError = err as? TimeoutError {
                context.log.debug(
                    """
                    Did not receive ack from \(reflecting: pingedMember.node) within [\(timeoutError.timeout.prettyDescription)]. \
                    Sending ping requests to other members.
                    """,
                    metadata: [
                        "swim/target": "\(self.swim.member(for: pingedMember), orElse: "nil")",
                    ]
                )
            } else {
                context.log.debug(
                    """
                    Did not receive ack from \(reflecting: pingedMember.node) within configured timeout. \
                    Sending ping requests to other members. Error: \(err)
                    """)
            }
            if let pingReqOrigin = pingReqOrigin {
                self.swim.adjustLHMultiplier(.probeWithMissedNack)
                pingReqOrigin.tell(.nack(target: pingedMember))
            } else {
                self.swim.adjustLHMultiplier(.failedProbe)
                self.sendPingRequests(context: context, toPing: pingedMember)
            }

        case .success(.ack(let pinged, let incarnation, let payload)):
            // We're proxying an ack payload from ping target back to ping source.
            // If ping target was a suspect, there'll be a refutation in a payload
            // and we probably want to process it asap. And since the data is already here,
            // processing this payload will just make gossip convergence faster.
            self.processGossipPayload(context: context, payload: payload)
            context.log.debug("Received ack from [\(pinged)] with incarnation [\(incarnation)] and payload [\(payload)]", metadata: self.swim.metadata)
            self.markMember(context, latest: SWIM.Member(peer: pinged, status: .alive(incarnation: incarnation), protocolPeriod: self.swim.protocolPeriod))
            if let pingReqOrigin = pingReqOrigin {
                pingReqOrigin.tell(.ack(target: pinged, incarnation: incarnation, payload: payload))
            } else {
                // LHA-probe multiplier for pingReq responses is hanled separately `handlePingRequestResult`
                self.swim.adjustLHMultiplier(.successfulProbe)
            }
        case .success(.nack):
            break
        }
    }

    func handlePingRequestResult(context: SWIM.Context, result: Result<SWIM.PingResponse, Error>, pingedMember: Peer<SWIM.Message>) {
        self.tracelog(context, .receive(pinged: pingedMember), message: result)
        // TODO: do we know here WHO replied to us actually? We know who they told us about (with the ping-req), could be useful to know

        switch self.swim.onPingRequestResponse(result, pingedMember: pingedMember) {
        case .alive(_, let payloadToProcess):
            self.processGossipPayload(context: context, payload: payloadToProcess)
        case .newlySuspect:
            context.log.debug("Member [\(pingedMember)] marked as suspect")
        case .nackReceived:
            context.log.debug("Received `nack` from indirect probing of [\(pingedMember)]")
        default:
            () // TODO: revisit logging more details here
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Handling local messages

    /// Scheduling a new protocol period and performing the actions for the current protocol period
    func handleNewProtocolPeriod(_ context: SWIM.Context) {
        self.pingRandomMember(context)

        context.startTimer(key: SWIM.Shell.periodicPingKey, delay: self.swim.dynamicLHMProtocolInterval) {
            self.pingRandomMember(context)
        }
    }

    func pingRandomMember(_ context: SWIM.Context) {
        context.log.trace("Periodic ping random member, among: \(self.swim._allMembersDict.count)", metadata: self.swim.metadata)

        // needs to be done first, so we can gossip out the most up to date state
        self.checkSuspicionTimeouts(context: context)

        if let toPing = swim.nextMemberToPing() {
            self.sendPing(context: context, to: toPing, pingReqOrigin: nil)
        }
        self.swim.incrementProtocolPeriod()
    }

    func handleMonitor(_ context: SWIM.Context, node: Node) {
        guard context.node != node else { // FIXME: compare while ignoring the UUID
            return // no need to monitor ourselves, nor a replacement of us (if node is our replacement, we should have been dead already)
        }

        self.sendFirstRemotePing(context, on: node)
    }

    // TODO: test in isolation
    func handleConfirmDead(_ context: SWIM.Context, deadNode node: Node) {
        if let member = self.swim.member(for: node) {
            // It is important to not infinitely loop cluster.down + confirmDead messages;
            // See: `.confirmDead` for more rationale
            if member.isDead {
                return // member is already dead, nothing else to do here.
            }

            context.log.trace("Confirming .dead member \(reflecting: member.node)")

            // We are diverging from the SWIM paper here in that we store the `.dead` state, instead
            // of removing the node from the member list. We do that in order to prevent dead nodes
            // from being re-added to the cluster.
            // TODO: add time of death to the status
            // TODO: GC tombstones after a day

            switch self.swim.mark(member.peer, as: .dead) {
            case .applied(let .some(previousState), _):
                if previousState.isSuspect || previousState.isUnreachable {
                    context.log.warning(
                        "Marked [\(member)] as [.dead]. Was marked \(previousState) in protocol period [\(member.protocolPeriod)]",
                        metadata: [
                            "swim/protocolPeriod": "\(self.swim.protocolPeriod)",
                            "swim/member": "\(member)", // TODO: make sure it is the latest status of it in here
                        ]
                    )
                } else {
                    context.log.warning(
                        "Marked [\(member)] as [.dead]. Node was previously [.alive], and now forced [.dead].",
                        metadata: [
                            "swim/protocolPeriod": "\(self.swim.protocolPeriod)",
                            "swim/member": "\(member)", // TODO: make sure it is the latest status of it in here
                        ]
                    )
                }
            case .applied(nil, _):
                // TODO: marking is more about "marking a node as dead" should we rather log addresses and not peer paths?
                context.log.warning("Marked [\(member)] as [.dead]. Node was not previously known to SWIM.")
                // TODO: should we not issue a escalateUnreachable here? depends how we learnt about that node...

            case .ignoredDueToOlderStatus:
                // TODO: make sure a fatal error in SWIM.Shell causes a system shutdown?
                fatalError("Marking [\(member)] as [.dead] failed! This should never happen, dead is the terminal status. SWIM instance: \(self.swim)")
            }
        } else {
            // TODO: would want to see if this happens when we fail these tests
            context.log.warning("Attempted to .confirmDead(\(node)), yet no such member known to \(self)!")
        }
    }

    func checkSuspicionTimeouts(context: SWIM.Context) {
        context.log.trace(
            "Checking suspicion timeouts...",
            metadata: [
                "swim/suspects": "\(self.swim.suspects)",
                "swim/all": "\(self.swim._allMembersDict)",
                "swim/protocolPeriod": "\(self.swim.protocolPeriod)",
            ]
        )

        for suspect in self.swim.suspects {
            if case .suspect(_, let suspectedBy) = suspect.status {
                let suspicionTimeout = self.swim.suspicionTimeout(suspectedByCount: suspectedBy.count)
                context.log.trace(
                    "Checking suspicion timeout for: \(suspect)...",
                    metadata: [
                        "swim/suspect": "\(suspect)",
                        "swim/suspectedBy": "\(suspectedBy.count)",
                        "swim/suspicionTimeout": "\(suspicionTimeout)",
                    ]
                )

                // proceed with suspicion escalation to .unreachable if the timeout period has been exceeded
                // We don't use Deadline because tests can override TimeSource
                guard let startTime = suspect.suspicionStartedAt,
                    self.swim.isExpired(deadline: startTime + suspicionTimeout.nanoseconds) else {
                    continue // skip, this suspect is not timed-out yet
                }

                guard let incarnation = suspect.status.incarnation else {
                    // suspect had no incarnation number? that means it is .dead already and should be recycled soon
                    return
                }

                var unreachableSuspect = suspect
                unreachableSuspect.status = .unreachable(incarnation: incarnation)
                self.markMember(context, latest: unreachableSuspect)
            }
        }

        // metrics.recordSWIM.Members(self.swim.allMembers) // FIXME metrics
    }

    private func markMember(_ context: SWIM.Context, latest: SWIM.Member) {
        switch self.swim.mark(latest.peer, as: latest.status) {
        case .applied(let previousStatus, _):
            context.log.trace(
                "Marked \(latest.node) as \(latest.status), announcing reachability change",
                metadata: [
                    "swim/member": "\(latest)",
                    "swim/previousStatus": "\(previousStatus, orElse: "nil")",
                ]
            )
            let statusChange = SWIM.Instance.MemberStatusChange(fromStatus: previousStatus, member: latest)
            self.tryAnnounceMemberReachability(context, change: statusChange)
        case .ignoredDueToOlderStatus:
            () // context.log.trace("No change \(latest), currentStatus remains [\(currentStatus)]. No reachability change to announce")
        }
    }

    // TODO: since this is applying payload to SWIM... can we do this in SWIM itself rather?
    func processGossipPayload(context: SWIM.Context, payload: SWIM.GossipPayload) {
        switch payload {
        case .membership(let members):
            self.processGossipedMembership(members: members, context: context)

        case .none:
            return // ok
        }
    }

    func processGossipedMembership(members: SWIM.Members, context: SWIM.Context) {
        for member in members {
            switch self.swim.onGossipPayload(about: member) {
            case .connect(let node, let continueAddingMember):
                // ensuring a connection is asynchronous, but executes callback in context
                self.withEnsuredAssociation(context, remoteNode: node) { uniqueAddressResult in
                    switch uniqueAddressResult {
                    case .success(let uniqueAddress):
                        continueAddingMember(.success(uniqueAddress))
                    case .failure(let error):
                        continueAddingMember(.failure(error))
                        context.log.warning("Unable ensure association with \(node), could it have been tombstoned? Error: \(error)")
                    }
                }

            case .ignored(let level, let message):
                if let level = level, let message = message {
                    context.log.log(level: level, message, metadata: self.swim.metadata)
                }

            case .applied(let change, _, _):
                self.tryAnnounceMemberReachability(context, change: change)
            }
        }
    }

    /// Announce to the `ClusterShell` a change in reachability of a member.
    private func tryAnnounceMemberReachability(_ context: SWIM.Context, change: SWIM.Instance.MemberStatusChange?) {
        guard let change = change else {
            // this means it likely was a change to the same status or it was about us, so we do not need to announce anything
            return
        }

        guard change.isReachabilityChange else {
            // the change is from a reachable to another reachable (or an unreachable to another unreachable-like (e.g. dead) state),
            // and thus we must not act on it, as the shell was already notified before about the change into the current status.
            return
        }

        // Log the transition
        switch change.toStatus {
        case .unreachable:
            context.log.info(
                """
                Node \(change.member.node) determined [.unreachable]! \
                The node is not yet marked [.down], a downing strategy or other Cluster.Event subscriber may act upon this information.
                """, metadata: [
                    "swim/member": "\(change.member)",
                ]
            )
        default:
            context.log.info(
                "Node \(change.member.node) determined [.\(change.toStatus)] (was [\(change.fromStatus, orElse: "nil")].",
                metadata: [
                    "swim/member": "\(change.member)",
                ]
            )
        }

        let reachability: Cluster.MemberReachability
        switch change.toStatus {
        case .alive, .suspect:
            reachability = .reachable
        case .unreachable, .dead:
            reachability = .unreachable
        }

        self.clusterRef.tell(.command(.failureDetectorReachabilityChanged(change.member.node, reachability)))
    }

    // TODO: remove or simplify; SWIM/Associations: Simplify/remove withEnsuredAssociation #601
    /// Use to ensure an association to given remote node exists.
    func withEnsuredAssociation(_ context: SWIM.Context, remoteNode: Node?, continueWithAssociation: @escaping (Result<Node, Error>) -> Void) {
        // this is a local node, so we don't need to connect first
        guard let remoteNode = remoteNode else {
            continueWithAssociation(.success(context.node))
            return
        }

        // handle kicking off associations automatically when attempting to send to them; so we do nothing here (!!!)
        continueWithAssociation(.success(remoteNode))
    }

    struct EnsureAssociationError: Error {
        let message: String

        init(_ message: String) {
            self.message = message
        }
    }

    /// This is effectively joining the SWIM membership of the other member.
    func sendFirstRemotePing(_ context: SWIM.Context, on node: Node) {
        let remotePeer = context.peer(on: node)

        // We need to include the member immediately, rather than when we have ensured the association.
        // This is because if we're not able to establish the association, we still want to re-try soon (in the next ping round),
        // and perhaps then the other node would accept the association (perhaps some transient network issues occurred OR the node was
        // already dead when we first try to ping it). In those situations, we need to continue the protocol until we're certain it is
        // suspect and unreachable, as without signalling unreachable the high-level membership would not have a chance to notice and
        // call the node [Cluster.MemberStatus.down].
        self.swim.addMember(remotePeer, status: .alive(incarnation: 0))

        // TODO: we are sending the ping here to initiate cluster membership. Once available this should do a state sync instead
        self.sendPing(context: context, to: remotePeer, pingReqOrigin: nil)
    }
}

extension NIOSWIMShell {
    static let name: String = "swim"

    static let periodicPingKey = "\(NIOSWIMShell.name)/periodic-ping"
}

// FIXME: do we need to expose reachability in SWIM like this?
/// Reachability indicates a failure detectors assessment of the member node's reachability,
/// i.e. whether or not the node is responding to health check messages.
///
/// Unlike `MemberStatus` (which may only move "forward"), reachability may flip back and forth between `.reachable`
/// and `.unreachable` states multiple times during the lifetime of a member.
///
/// - SeeAlso: `SWIM` for a distributed failure detector implementation which may issue unreachable events.
public enum MemberReachability: String, Equatable {
    /// The member is reachable and responding to failure detector probing properly.
    case reachable
    /// Failure detector has determined this node as not reachable.
    /// It may be a candidate to be downed.
    case unreachable
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Internal "trace-logging" for debugging purposes

internal enum TraceLogType: CustomStringConvertible {
    case reply(to: Peer<SWIM.PingResponse>)
    case receive(pinged: Peer<SWIM.Message>?)

    static var receive: TraceLogType {
        .receive(pinged: nil)
    }

    var description: String {
        switch self {
        case .receive(nil):
            return "RECV"
        case .receive(let .some(pinged)):
            return "RECV(pinged:\(pinged.node))"
        case .reply(let to):
            return "REPL(to:\(to.node))"
        }
    }
}