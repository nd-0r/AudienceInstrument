//
//  DistanceManager.swift
//  AudienceInstrument
//
//  Created by Andrew Orals on 4/4/24.
//

import Foundation
import MultipeerConnectivity

protocol DistanceManagerSendDelegate {
    func sendInit(to: [DistanceManager.PeerID]) -> Void
    func sendInitAck(to: [DistanceManager.PeerID]) -> Void
    func sendSpeak(to: [DistanceManager.PeerID]) -> Void
    func sendSpoke(to: [DistanceManager.PeerID]) -> Void
    func sendDone(to: [DistanceManager.PeerID], withCalcDist: [DistanceManager.DistInMeters]) -> Void
}

protocol DistanceManagerUpdateDelegate {
    func didUpdate(distancesByPeer: [DistanceManager.PeerID:DistanceManager.PeerDist])
}

enum DistanceManagerError: Error {
    case unknownMessageType
    case unknownPeer(String)
    case unimplemented
}

struct DistanceManager {
    typealias PeerID = MCPeerID
    typealias DistInMeters = Float

    public enum PeerDist {
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

    public static func addPeers(peers: [PeerID]) {
        Self.dispatchQueue.async {
            for peer in peers {
                Self.peersToAdd.insert(peer)
            }
        }
    }

    public static func removePeers(peers: [PeerID]) {
        Self.dispatchQueue.async {
            uncalculatedPeers =
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
            case .initiator(.`init`(let numAckedPeers)):
                if numAckedPeers == Self.distByPeer.count {
                    return
                }
            default:
                return
            }

            actualSendDelegate.sendInit(to: Array(Self.distByPeer.keys))
            if retries > 0 {
                Self.scheduleTimeout(
                    expectedStateByDeadline: .initiator(.speak),
                    timeoutTargetState: .done,
                    actionOnUnreachedTarget: { Self.initiate(retries: retries - 1) },
                )
            }
        }
    }

    public static func receiveMessage(message: DistanceProtocolWrapper, from: PeerID) throws {
        Self.dispatchQueue.async {
            switch message.type {
            case .init_p:
                throw DistanceManagerError.unimplemented
            case .initAck:
                throw DistanceManagerError.unimplemented
            case .speak:
                throw DistanceManagerError.unimplemented
            case .spoke(let spoke):
                throw DistanceManagerError.unimplemented
            case .done(let done):
                throw DistanceManagerError.unimplemented
            case .none:
                throw DistanceManagerError.unknownMessageType
            }
        }
    }

// MARK: Private interface
    private init() { }

    private static func scheduleTimeout(
        expectedStateByDeadline: Self.State,
        timeoutTargetState: Self.State,
        deadlineFromNow: DispatchTimeInterval = .seconds(1),
        actionOnUnreachedTarget: () -> Void = {},
    ) {
        Self.dispatchQueue.asyncAfter(deadline: DispatchTime.now().advanced(by: deadlineFromNow)) {
            switch DistanceManager.dmState {
            case expectedStateByDeadline:
                return
            default:
                actionOnUnreachedTarget()
                Self.dmState = timeoutTargetState
            }
        }
    }

    private static func didReceiveInit(fromPeer: PeerID) throws {
        switch Self.dmState {
        case .done:
            break
        case .speaker(.initAcked(let initPeer)):
            guard initPeer == fromPeer else {
                return
            }
            // Initiator might not have received the acknowledgement
            break
        case .speaker(.spoke(let initPeer)):
            if initPeer == fromPeer {
                fatalError("Received init from initiator (\(initPeer)) who already sent `speak` command: This should not be possible.")
            }
            return
        default:
            return
        }

        guard let dist = Self.distByPeer[fromPeer] else {
            throw DistanceManagerError.unknownPeer("Received init from peer not added through `addPeer(peer:)`")
        }

        switch dist {
        case .someCalculated(let calculatedDist):
            // Already calculated this distance: Resend it to the peer bc they must have missed the done message
            Self.sendDelegate?.sendDone(to: fromPeer, withCalcDist: calculatedDist)
        case .noneCalculated:
            Self.sendDelegate?.sendInitAck(to: [fromPeer])
            Self.dmState = .speaker(fromPeer, .initAcked)
            Self.scheduleTimeout(
                expectedStateByDeadline: .speaker(.spoke(fromPeer)),
                timeoutTargetState: .done
            )
        }
    }

    private static func didReceiveInitAck(from: PeerID) {
        guard let actualSendDelegate = Self.sendDelegate else {
            fatalError("Received InitAck with no send delegate registered: This should not be possible.")
        }

        switch Self.dmState {
        case .initiator(.`init`(let numAckedPeers)):
            guard Self.distByPeer[from] != nil else {
                fatalError("Received InitAck from peer not added through `addPeer(peer:)` before `initiate()` was called. This should not be possible.")
            }

            if numAckedPeers == distByPeer.count {
                actualSendDelegate.sendSpeak(to: Array(Self.distByPeer.keys))
                Self.dmState = .initiator(.speak)
                Self.scheduleTimeout(
                    expectedStateByDeadline: .done,
                    timeoutTargetState: .done,
                    actionOnUnreachedTarget: { Self.calculateDistances() }
                )
            } else {
                Self.dmState = .initiator(.`init`(numAckedPeers + 1))
            }
        case .initiator(.speak(*)):
            fatalError("Received InitAck from peer \(from) while in speak phase: This should not be possible because speak commands are only sent after InitAcks from all peers have been received.")
        default:
            return
        }
    }

    private static func didReceiveSpeak(from: PeerID) {
        switch Self.dmState {
        case .speaker(.initAcked(let initPeer)):
            if from != initPeer {
                fatalError("Received speak from peer (\(from)) which is not the initiator (\(initPeer)): This should not be possible.")
            }
            break
        case .speaker(.spoke(let initPeer)):
            fatalError("Received speak from peer (\(from)) while in `spoke` state with initiator (\(initPeer)): This should not be possible")
        default:
            return
        }

        // FIXME
        // Speak here using some audio class

        Self.dmState = .speaker(.spoke)
        scheduleTimeout(
            expectedStateByDeadline: .done,
            timeoutTargetState: .done
        )
    }

    private static func didReceiveSpoke(from: PeerID) {
        switch Self.dmState {
        case .initiator(.speak(let numSpokenPeers)):
            guard let peerDist = Self.distByPeer[from] else {
                fatalError("Received `Spoke` from peer not added through `addPeer(peer:)` before `initiate()` was called. This should not be possible.")
            }

            if peerDist == DistanceManager.PeerDist.someCalculated(*) {
                fatalError("Received `Spoke` from peer whose distance is already calculated: This should not be possible.")
            }

            // FIXME tell distance calculator that received a `Spoke` message
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
        case .speaker(.spoke(let initPeer)):
            if initPeer != from {
                fatalError("Received done from peer (\(from)) which is not the initiator (\(initPeer)): This should not be possible.")
            }
            break
        default:
            return
        }

        Self.distByPeer[from] = .someCalculated(withCalcDist)
        Self.dmState = .done
    }

    private static func calculateDistances() {
        switch Self.dmState {
        case .initiator(.speak(*)):
            break
        default:
            return
        }

        // calculate distance to each peer and send results to each peer
        let (peerIDs, calcDists): ([PeerID], [DistInMeters]) = [] // FIXME
        for (peerID, calcDist) in zip(peerIDs, calcDists) {
            Self.distByPeer[peerID] = .someCalculated(calcDist)
        }

        Self.sendDelegate?.sendDone(to: peerIDs, calculatedDistanceInM: calcDists)

        Self.dmState = .done

        Self.updateDelegate?.didUpdate(distancesByPeer: Self.distByPeer)
    }

    private static func updateDistByPeer() {
        for peerToAdd in peersToAdd {
            if self.distByPeer[peerToAdd] != nil {
                continue
            }
            self.distByPeer[peerToAdd] = .noneCalculated
        }

        for peerToRemove in peersToRemove {
            self.distByPeer[peerToRemove] = nil
        }
    }

    private static var sendDelegate: (any DistanceManagerSendDelegate)?
    private static var updateDelegate: (any DistanceManagerUpdateDelegate)?
    private static var dmState = State.done
    // A custom serial queue
    private static var dispatchQueue = DispatchQueue(
        label: "com.andreworals.DistanceManager",
        qos: .userInitiated
    )

    private static var peersToAdd: Set<PeerID> = []
    private static var peersToRemove: Set<PeerID> = []
    private static var distByPeer: [PeerID:PeerDist] = [:]

    private enum InitiatorState {
        case `init`(UInt)
        case speak(UInt)
    }

    private enum SpeakerState {
        case initAcked(PeerID)
        case spoke(PeerID)
    }

    private enum State {
        case initiator(InitiatorState)
        case speaker(SpeakerState)
        case done
    }
}
