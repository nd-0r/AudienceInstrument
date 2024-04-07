//
//  DistanceManager.swift
//  AudienceInstrument
//
//  Created by Andrew Orals on 4/4/24.
//

import Foundation
import MultipeerConnectivity

protocol DistanceCalculatorProtocol{
    func registerPeer(peer: DistanceManager.PeerID) -> Void
    func deregisterPeer(peer: DistanceManager.PeerID) -> Void
    func speak() throws -> UInt64
    func listen() throws -> Void
    func heardPeerSpeak(reportedSpeakingDelay: UInt64) -> Void
    func calculateDistances() -> ([DistanceManager.PeerID], [DistanceManager.DistInMeters])
    func reset() -> Void
}

protocol DistanceManagerSendDelegate {
    func send(toPeers: [DistanceManager.PeerID], withMessages: [DistanceProtocolWrapper])
    func send(toPeers: [DistanceManager.PeerID], withMessage: DistanceProtocolWrapper)
}

protocol DistanceManagerUpdateDelegate {
    func didUpdate(distancesByPeer: [DistanceManager.PeerID:DistanceManager.PeerDist])
}

enum DistanceManagerError: Error {
    case unknownMessageType
    case unknownPeer(String)
    case unimplemented
}

/// NOT thread-safe
struct DistanceManager {
    typealias PeerID = MCPeerID
    typealias DistInMeters = Float

    public enum PeerDist: Hashable {
        case noneCalculated
        case someCalculated(DistInMeters)
    }

    public static func registerSendDelegate(delegate: any DistanceManagerSendDelegate) {
        Self.dispatchQueue.async {
            DistanceManager.sendDelegate = delegate
        }
    }

    public static func registerUpdateDelegate(delegate: any DistanceManagerUpdateDelegate) {
        Self.dispatchQueue.async {
            DistanceManager.updateDelegate = delegate
        }
    }

    public static func setup(distanceCalculator: any DistanceCalculatorProtocol) {
        Self.distanceCalculator = distanceCalculator
    }

    public static func addPeers(peers: [PeerID]) {
        Self.dispatchQueue.async {
            for peer in peers {
                Self.peersToAdd.insert(PeerToAdd(peerToAdd: peer, peerDist: nil))
            }
        }
    }

    public static func addPeers(peersWithDist: [(PeerID, PeerDist)]) {
        Self.dispatchQueue.async {
            for (peer, peerDist) in peersWithDist {
                Self.peersToAdd.insert(PeerToAdd(peerToAdd: peer, peerDist: peerDist))
            }
        }
    }

    public static func removePeers(peers: [PeerID]) {
        Self.dispatchQueue.async {
            for peer in peers {
                Self.peersToRemove.insert(peer)
            }
        }
    }

    public static func initiate(retries: UInt = 3) {
        Self.dispatchQueue.async {
            updateDistByPeer()

            guard let actualSendDelegate = DistanceManager.sendDelegate else {
                fatalError("Cannot possibly initiate distance measurement protocol without a send delegate.")
            }

            switch Self.dmState {
            case .done:
                break
            case .initiator(.`init`(.certain(let numAckedPeers))):
                if numAckedPeers == Self.distByPeer.count {
                    return
                }
            default:
                return
            }

            actualSendDelegate.send(
                toPeers: Array(Self.distByPeer.keys),
                withMessages: [DistanceProtocolWrapper.with {
                    $0.type = .init_p(Init())
                }]
            )

            if retries > 0 {
                Self.scheduleTimeout(
                    expectedStateByDeadline: .initiator(.speak(.any)),
                    timeoutTargetState: .done,
                    actionOnUnreachedTarget: { Self.initiate(retries: retries - 1) }
                )
            }
        }
    }

    public static func receiveMessage(message: DistanceProtocolWrapper, from: PeerID) throws {
        switch message.type {
        case .init_p:
            Self.dispatchQueue.async { Self.didReceiveInit(fromPeer: from) }
        case .initAck:
            Self.dispatchQueue.async { Self.didReceiveInitAck(from: from) }
        case .speak:
            Self.dispatchQueue.async { Self.didReceiveSpeak(from: from) }
        case .spoke(let spoke):
            Self.dispatchQueue.async { Self.didReceiveSpoke(from: from, delayInNs: spoke.delayInNs) }
        case .done(let done):
            Self.dispatchQueue.async { Self.didReceiveDone(from: from, withCalcDist: done.distanceInM) }
        case .none:
            throw DistanceManagerError.unknownMessageType
        }
    }

    public static func reset() {
        Self.dispatchQueue.sync {
            for timeoutWorkItem in Self.timeouts {
                timeoutWorkItem.cancel()
            }
            Self.timeouts = []

            Self.peersToAdd.removeAll()
            Self.peersToRemove = Set(Self.distByPeer.keys)

            Self.updateDistByPeer()

            Self.dmState = .done
        }
    }

// MARK: Private interface
    private init() { }

    private static func scheduleTimeout(
        expectedStateByDeadline: Self.State,
        timeoutTargetState: Self.State,
        deadlineFromNow: DispatchTimeInterval = .milliseconds(10), // TODO use network latency
        actionOnUnreachedTarget: @escaping () -> Void = {}
    ) {
        let workItem = DispatchWorkItem {
            switch DistanceManager.dmState {
            case expectedStateByDeadline:
                return
            default:
                actionOnUnreachedTarget()
                Self.dmState = timeoutTargetState
            }
        }
        Self.timeouts.append(workItem)

        Self.dispatchQueue.asyncAfter(
            deadline: DispatchTime.now().advanced(by: deadlineFromNow),
            execute: workItem
        )
    }

    private static func didReceiveInit(fromPeer: PeerID) {
        switch Self.dmState {
        case .done:
            break
        case .speaker(.initAcked(.certain(let initPeer))):
            guard initPeer == fromPeer else {
                return
            }
            // Initiator might not have received the acknowledgement
            break
        case .speaker(.spoke(.certain(let initPeer))):
            if initPeer == fromPeer {
                fatalError("Received init from initiator (\(initPeer)) who already sent `speak` command: This should not be possible.")
            }
            return
        default:
            return
        }

        Self.updateDistByPeer()

        guard let dist = Self.distByPeer[fromPeer] else {
            // throw DistanceManagerError.unknownPeer("Received init from peer not added through `addPeer(peer:)`")
            // TODO log something here
            return
        }

        switch dist {
        case .someCalculated(let calculatedDist):
            // Already calculated this distance: Resend it to the peer bc they must have missed the done message
            Self.sendDelegate?.send(
                toPeers: [fromPeer],
                withMessage: DistanceProtocolWrapper.with {
                    $0.type = .done(Done.with {
                        $0.distanceInM = calculatedDist
                    }
                )}
            )
        case .noneCalculated:
            Self.sendDelegate?.send(
                toPeers: [fromPeer],
                withMessage: DistanceProtocolWrapper.with {
                    $0.type = .initAck(InitAck())
                }
            )
            Self.dmState = .speaker(.initAcked(.certain(fromPeer)))
            Self.scheduleTimeout(
                expectedStateByDeadline: .speaker(.spoke(.any)),
                timeoutTargetState: .done
            )
        }
    }

    private static func didReceiveInitAck(from: PeerID) {
        guard let actualSendDelegate = Self.sendDelegate else {
            fatalError("Received InitAck with no send delegate registered: This should not be possible.")
        }

        switch Self.dmState {
        case .initiator(.`init`(.certain(let numAckedPeers))):
            guard Self.distByPeer[from] != nil else {
                fatalError("Received InitAck from peer not added through `addPeer(peer:)` before `initiate()` was called. This should not be possible.")
            }

            if numAckedPeers == distByPeer.count {
                actualSendDelegate.send(
                    toPeers: Array(Self.distByPeer.keys),
                    withMessage: DistanceProtocolWrapper.with {
                        $0.type = .speak(Speak())
                    }
                )
                try? Self.distanceCalculator!.listen() // TODO catch errors
                Self.dmState = .initiator(.speak(.certain(0)))
                Self.scheduleTimeout(
                    expectedStateByDeadline: .done,
                    timeoutTargetState: .done,
                    actionOnUnreachedTarget: { Self.calculateDistances() }
                )
            } else {
                Self.dmState = .initiator(.`init`(.certain(numAckedPeers + 1)))
            }
        case .initiator(.speak(_)):
            fatalError("Received InitAck from peer \(from) while in speak phase: This should not be possible because speak commands are only sent after InitAcks from all peers have been received.")
        default:
            return
        }
    }

    private static func didReceiveSpeak(from: PeerID) {
        guard let actualSendDelegate = Self.sendDelegate else {
            fatalError("Received Speak with no send delegate registered: This should not be possible.")
        }

        switch Self.dmState {
        case .speaker(.initAcked(.certain(let initPeer))):
            if from != initPeer {
                fatalError("Received speak from peer (\(from)) which is not the initiator (\(initPeer)): This should not be possible.")
            }

            guard let delay = try? Self.distanceCalculator!.speak() else {
                // TODO: Might want to change this
                return // let initiator time out
            }

            actualSendDelegate.send(
                toPeers: [initPeer],
                withMessage: DistanceProtocolWrapper.with {
                    $0.type = .spoke(Spoke.with {
                        $0.delayInNs = delay
                    })
                }
            )

            Self.dmState = .speaker(.spoke(.certain(from)))
            scheduleTimeout(
                expectedStateByDeadline: .done,
                timeoutTargetState: .done
            )
            break
        case .speaker(.spoke(let initPeer)):
            fatalError("Received speak from peer (\(from)) while in `spoke` state with initiator (\(initPeer)): This should not be possible")
        default:
            return
        }
    }

    private static func didReceiveSpoke(from: PeerID, delayInNs: UInt64) {
        switch Self.dmState {
        case .initiator(.speak(.certain(let numSpokenPeers))):
            guard let peerDist = Self.distByPeer[from] else {
                fatalError("Received `Spoke` from peer not added through `addPeer(peer:)` before `initiate()` was called. This should not be possible.")
            }

            switch peerDist {
            case .someCalculated(_):
                fatalError("Received `Spoke` from peer whose distance is already calculated: This should not be possible.")
            default:
                break
            }

            Self.distanceCalculator!.heardPeerSpeak(reportedSpeakingDelay: delayInNs)
            guard numSpokenPeers == Self.distByPeer.count else {
                return
            }

            Self.calculateDistances()
        default:
            return
        }
    }

    private static func didReceiveDone(from: PeerID, withCalcDist: DistInMeters) {
        switch Self.dmState {
        case .speaker(.spoke(.certain(let initPeer))):
            if initPeer != from {
                fatalError("Received done from peer (\(from)) which is not the initiator (\(initPeer)): This should not be possible.")
            }
            break
        default:
            return
        }

        Self.distByPeer[from] = .someCalculated(withCalcDist)
        Self.updateDelegate!.didUpdate(distancesByPeer: Self.distByPeer)
        Self.dmState = .done
    }

    private static func calculateDistances() {
        switch Self.dmState {
        case .initiator(.speak(_)):
            break
        default:
            return
        }

        let (peerIDs, calcDists): ([PeerID], [DistInMeters]) = Self.distanceCalculator!.calculateDistances()
        for (peerID, calcDist) in zip(peerIDs, calcDists) {
            Self.distByPeer[peerID] = .someCalculated(calcDist)
        }

        let messages = calcDists.map({ calcDist in
            DistanceProtocolWrapper.with {
                $0.type = .done(Done.with {
                    $0.distanceInM = calcDist
                })
            }
        })

        Self.sendDelegate?.send(toPeers: peerIDs, withMessages: messages)

        Self.dmState = .done
        Self.distanceCalculator!.reset()
        Self.updateDelegate?.didUpdate(distancesByPeer: Self.distByPeer)
    }

    private static func updateDistByPeer() {
        for peerAndDistToAdd in peersToAdd {
            let peerToAdd = peerAndDistToAdd.peerToAdd
            let peerDist = peerAndDistToAdd.peerDist

            switch (peerDist == nil, Self.distByPeer[peerToAdd] != nil) {
            case (true, true):
                // Peer was already registered and no distance given
                continue
            case (true, false):
                // Peer not already registered and no distance given
                Self.distByPeer[peerToAdd] = .noneCalculated
                Self.distanceCalculator!.registerPeer(peer: peerToAdd)
            case (false, true):
                // Peer was already registered but prioritize given distance
                Self.distByPeer[peerToAdd] =  peerDist
            case (false, false):
                // Peer not registered and user given distance
                Self.distByPeer[peerToAdd] = peerDist
                Self.distanceCalculator!.registerPeer(peer: peerToAdd)
            }
        }

        for peerToRemove in peersToRemove {
            Self.distByPeer[peerToRemove] = nil
            Self.distanceCalculator!.deregisterPeer(peer: peerToRemove)
        }

        peersToAdd.removeAll()
        peersToRemove.removeAll()
    }

    private static var sendDelegate: (any DistanceManagerSendDelegate)?
    private static var updateDelegate: (any DistanceManagerUpdateDelegate)?
    private static var distanceCalculator: (any DistanceCalculatorProtocol)?
    private static var dmState = State.done
    // A custom serial queue
    private static var dispatchQueue = DispatchQueue(
        label: "com.andreworals.DistanceManager",
        qos: .userInitiated
    )
    private static var timeouts: [DispatchWorkItem] = []

    private struct PeerToAdd: Hashable {
        let peerToAdd: PeerID
        let peerDist: PeerDist?

        static func == (lhs: DistanceManager.PeerToAdd, rhs: DistanceManager.PeerToAdd) -> Bool {
            lhs.peerToAdd == rhs.peerToAdd && lhs.peerDist == rhs.peerDist
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(peerToAdd)
            hasher.combine(peerDist)
        }
    }

    private static var peersToAdd: Set<PeerToAdd> = []
    private static var peersToRemove: Set<PeerID> = []
    private static var distByPeer: [PeerID:PeerDist] = [:]

    private enum Anyable<T>: Equatable where T: Equatable {
        case certain(T)
        case any

        static func ==(lhs: Anyable<T>, rhs: Anyable<T>) -> Bool {
            switch (lhs, rhs) {
            case (.certain(let lval), .certain(let rval)):
                return lval == rval
            default:
                return true
            }
        }
    }

    private enum InitiatorState: Equatable {
        case `init`(Anyable<UInt>)
        case speak(Anyable<UInt>)
    }

    private enum SpeakerState: Equatable {
        case initAcked(Anyable<PeerID>)
        case spoke(Anyable<PeerID>)
    }

    private enum State: Equatable {
        case initiator(InitiatorState)
        case speaker(SpeakerState)
        case done
    }
}
