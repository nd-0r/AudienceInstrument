//
//  DistanceManager.swift
//  AudienceInstrument
//
//  Created by Andrew Orals on 4/4/24.
//

import Foundation
import MultipeerConnectivity

enum DistanceCalculatorMode: CustomStringConvertible, Equatable {
    var description: String {
        switch self {
        case .speaker(let freq):
            "Speaker[\(freq)Hz]"
        case .listener:
            "Listener"
        }
    }

    static func ==(lhs: DistanceCalculatorMode, rhs: DistanceCalculatorMode) -> Bool {
        switch (lhs, rhs) {
        case (.speaker(_), .speaker(_)):
            return true
        case (.listener, .listener):
            return true
        default:
            return false
        }
    }

    case speaker(freq: DistanceListener.Freq)
    case listener
}

protocol DistanceCalculatorProtocol: AnyObject {
    func setupForMode(mode: DistanceCalculatorMode) throws
    func registerPeer(peer: DistanceManager.PeerID) -> Void
    func calcFreqsForPeers() -> [DistanceListener.Freq]?
    func deregisterPeer(peer: DistanceManager.PeerID) -> Void
    func speak(receivedAt: UInt64) throws -> UInt64
    func listen() throws -> Void
    func heardPeerSpeak(
        peer: DistanceManager.PeerID,
        recvTimeInNS: UInt64,
        reportedSpeakingDelay: UInt64,
        withOneWayLatency: UInt64?
    ) throws -> Void
    func calculateDistances() -> ([DistanceManager.PeerID], [DistanceManager.DistInMeters])
    func reset() -> Void
}

// Goal is for DistanceManager to do nothing involving time
protocol SpeakTimerDelegateUpdateDelegate: AnyObject {
    func shouldConnectToPeer(
        peer: DistanceManager.PeerID,
        completion: @escaping (Bool) -> Void
    )
    func receivedSpokeMessage(from: DistanceManager.PeerID) -> Void
    func done() -> Void
    func error(message: String) -> Void
}

protocol SpeakTimerDelegate {
    init(selfID: DistanceManager.PeerID)
    func registerDistanceCalculator(distanceCalculator: any DistanceCalculatorProtocol) -> Void
    func registerUpdateDelegate(updateDelegate: any SpeakTimerDelegateUpdateDelegate) -> Void
    func setup(
        expectedNumPingRoundsPerPeripheral: UInt,
        expectedNumConnections: UInt,
        maxConnectionTries: UInt
    ) -> Void
    func startProtocol()
    func resetProtocol()
}

protocol SpokeDelegateUpdateDelegate: AnyObject {
    func receivedSpeakMessage(from: DistanceManager.PeerID) -> Void
    func error(message: String) -> Void
}

protocol SpokeDelegate {
    init(selfID: DistanceManager.PeerID)
    func registerDistanceCalculator(distanceCalculator: any DistanceCalculatorProtocol)
    func registerUpdateDelegate(updateDelegate: any SpokeDelegateUpdateDelegate)
    func startProtocol(numPingRounds: UInt)
    func resetProtocol()
}

enum DistanceManagerError: Error {
    case unknownMessageType
    case unknownPeer(String)
    case unimplemented
}

protocol DistanceManagerUpdateDelegate {
    func didUpdate(distancesByPeer: [DistanceManager.PeerID:DistanceManager.PeerDist])
}

class DistanceManagerNetworkModule: NeighborMessageSender, NeighborMessageReceiver, DistanceManagerUpdateDelegate {
    init() {
        DistanceManager.registerUpdateDelegate(delegate: self)
    }

    func addPeers(peers: [DistanceManager.PeerID]) async {
        DistanceManager.addPeers(peers: peers)
    }

    func removePeers(peers: [DistanceManager.PeerID]) async {
        DistanceManager.removePeers(peers: peers)
    }
    
    func registerSendDelegate(
        delegate: any NeighborMessageSendDelegate,
        selfID _: DistanceManager.PeerID
    ) async {
        DistanceManager.registerSendDelegate(delegate: delegate)
    }

    func receiveMessage(
        message: NeighborAppMessage,
        from: DistanceManager.PeerID,
        receivedAt: UInt64
    ) async throws {
        switch message.data {
        case .distanceProtocolMessage(let distanceProtocolWrapper):
            // speak timeout not used
            try DistanceManager.receiveMessage(
                message: distanceProtocolWrapper,
                from: from,
                receivedAt: receivedAt,
                withInitTimeout: self.speakerInitTimeout,
                withSpeakTimeout: self.speakerSpeakTimeout
            )
        default:
            return
        }
    }

    func didUpdate(distancesByPeer: [DistanceManager.PeerID : DistanceManager.PeerDist]) {
        guard self.connectionManagerModel != nil else {
            return
        }

        Task { @MainActor in
            self.connectionManagerModel!.estimatedDistanceByPeerInM = distancesByPeer
        }
    }

    var speakerInitTimeout: DispatchTimeInterval = .seconds(60)
    // Speaker speak timeout is overridden by the bluetooth stuff
    var speakerSpeakTimeout: DispatchTimeInterval = .seconds(60)
    var connectionManagerModel: ConnectionManagerModel? = nil
}

/// NOT thread-safe
struct DistanceManager  {
    typealias PeerID = UInt64
    typealias DistInMeters = Float

    public enum PeerDist: Hashable {
        case noneCalculated
        case someCalculated(DistInMeters)
    }

    public static func registerSendDelegate(delegate: any NeighborMessageSendDelegate) {
        Self.dispatchQueue.async {
            DistanceManager.sendDelegate = delegate
        }
    }

    public static func registerUpdateDelegate(delegate: any DistanceManagerUpdateDelegate) {
        Self.dispatchQueue.async {
            DistanceManager.updateDelegate = delegate
        }
    }

    public static func setup(
        speakTimerDelegate: (any SpeakTimerDelegate)?,
        spokeDelegate: (any SpokeDelegate)?,
        distanceCalculator: any DistanceCalculatorProtocol
    ) {
        Self.speakTimerDelegate = speakTimerDelegate
        Self.spokeDelegate = spokeDelegate
        Self.distanceCalculator = distanceCalculator

        if speakTimerDelegate != nil {
            speakTimerDelegate!.registerUpdateDelegate(
                updateDelegate: self.speakTimerDelegateUpdateDelegate
            )
            speakTimerDelegate!.registerDistanceCalculator(
                distanceCalculator: self.distanceCalculator!
            )
        }

        if spokeDelegate != nil {
            spokeDelegate!.registerUpdateDelegate(
                updateDelegate: self.spokeDelegateUpdateDelegateClass
            )
            spokeDelegate!.registerDistanceCalculator(
                distanceCalculator: self.distanceCalculator!
            )
        }
    }

    public static func addPeers(peers: [PeerID]) {
        Self.dispatchQueue.async {
            #if DEBUG
            print("DistanceManager: Adding peers: \(peers)")
            #endif
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
            #if DEBUG
            print("DistanceManager: Removing peers: \(peers)")
            #endif
            for peer in peers {
                if Self.distByPeer.keys.contains(where: { $0 == peer }) || Self.peersToAdd.contains(where: { $0.peerToAdd == peer }) {
                    Self.peersToRemove.insert(peer)
                }
            }
        }
    }

    public static func initiate(
        retries: UInt = 2,
        withInitTimeout: DispatchTimeInterval = .milliseconds(10),
        withSpokeTimeout: DispatchTimeInterval = .milliseconds(10),
        toPeers peers: [PeerID]? = nil
    ) {
        Self.dispatchQueue.async {
            #if DEBUG
            print("TRY: \(retries) WITH TIMEOUT: \(withInitTimeout)") // TODO: remove
            #endif

            Self.updateDistByPeer()
            do {
                try Self.distanceCalculator!.setupForMode(mode: .listener)
            } catch {
                #if DEBUG
                print("\(String(describing: Self.self)): Failed to set up distance calculator for listening mode when initiating. Error: \(error).")
                #endif
                // TODO: Maybe do something else here?
                Self.resetToDone()
                return
            }

            guard peers == nil || peers!.allSatisfy({ p1 in Self.distByPeer[p1] != nil }) else {
                #if DEBUG
                print("Tried to initiate with peers not added to distance manager. Peers: \(String(describing: peers)) Current session: \(Self.distByPeer).")
                #endif
                Self.resetToDone()
                return
            }

            Self.spokeTimeout = withSpokeTimeout

            guard let actualSendDelegate = DistanceManager.sendDelegate else {
                fatalError("Cannot possibly initiate distance measurement protocol without a send delegate.")
            }

            switch Self.dmState {
            case .done:
                Self.dmState = .initiator(.`init`(.certain(0)))
                break
            case .initiator(.`init`(.certain(let numAckedPeers))):
                if numAckedPeers == Self.peersInCurrentRound.count {
                    return
                }
            default:
                Self.resetToDone()
                return
            }

            // Add already calculated peers to ready set because don't want to consider InitAcks from them
            for (k, v) in Self.distByPeer {
                if v != .noneCalculated {
                    Self.initAckedPeers.insert(k)
                }
            }

            let peersInRound = peers ?? Array(Self.distByPeer.filter({ (_, v) in v == .noneCalculated }).keys)
            if Self.peersInCurrentRound.isEmpty {
                for peer in peersInRound {
                    Self.distanceCalculator!.registerPeer(peer: peer)
                }
            }
            Self.peersInCurrentRound = peersInRound

            guard let peerFreqs = Self.distanceCalculator!.calcFreqsForPeers() else {
                #if DEBUG
                print("\(String(describing: Self.self)): Failed getting frequencies for peers in current round")
                #endif
                Self.resetToDone()
                return
            }

            let messages = peerFreqs.map({ peerFreq in
                MessageWrapper.with {
                    $0.data = .neighborAppMessage(NeighborAppMessage.with {
                        $0.data = .distanceProtocolMessage(DistanceProtocolWrapper.with {
                            $0.type = .init_p(Init.with( {
                                $0.freq = UInt32(peerFreq)
                            }))
                        })
                    })
                }
            })

            actualSendDelegate.send(
                toPeers: Self.peersInCurrentRound,
                withMessages: messages,
                withReliability: .reliable
            )

            // FIXME: Make these constants somewhere
            self.speakTimerDelegate?.setup(
                expectedNumPingRoundsPerPeripheral: 16,
                expectedNumConnections: UInt(Self.peersInCurrentRound.count),
                maxConnectionTries: 3
            )

            if retries > 0 {
                Self.scheduleTimeout(
                    expectedStateByDeadline: .initiator(.speak(.any)),
                    timeoutTargetState: nil,
                    deadlineFromNow: withInitTimeout,
                    actionOnUnreachedTarget: {
                        Self.initiate(
                            retries: retries - 1,
                            withInitTimeout: withInitTimeout,
                            toPeers: peers
                        )
                    }
                )
            } else {
                Self.scheduleTimeout(
                    expectedStateByDeadline: .initiator(.speak(.any)),
                    timeoutTargetState: .done,
                    deadlineFromNow: withInitTimeout,
                    actionOnUnreachedTarget: {
                        Self.initAckedPeers.removeAll()
                        Self.resetToDone()
                    }
                )
            }
        }
    }

    public static func receiveMessage(
        message: DistanceProtocolWrapper,
        from: PeerID,
        receivedAt: UInt64,
        withInitTimeout initTimeout: DispatchTimeInterval = .milliseconds(10),
        withSpeakTimeout speakTimeout: DispatchTimeInterval = .milliseconds(10)
    ) throws {
        switch message.type {
        case .init_p(let initMessage):
            #if DEBUG
            print("\(String(describing: Self.self)): Received init message")
            #endif
            Self.dispatchQueue.async { Self.didReceiveInit(fromPeer: from, withFreq: DistanceListener.Freq(initMessage.freq), withTimeout: initTimeout) }
        case .initAck:
            #if DEBUG
            print("\(String(describing: Self.self)): Received init ack message")
            #endif
            Self.dispatchQueue.async { Self.didReceiveInitAck(from: from) }
        case .speak:
            #if DEBUG
            print("\(String(describing: Self.self)): Received speak message")
            #endif
            Self.dispatchQueue.async { Self.didReceiveSpeak(from: from, receivedAt: receivedAt, withTimeout: speakTimeout) }
        case .spoke(let spoke):
            #if DEBUG
            print("\(String(describing: Self.self)): Received spOke message")
            #endif
            Self.dispatchQueue.async { Self.didReceiveSpoke(from: from, receivedAt: receivedAt, delayInNs: spoke.delayInNs) }
        case .done(let done):
            #if DEBUG
            print("\(String(describing: Self.self)): Received done message")
            #endif
            Self.dispatchQueue.async { Self.didReceiveDone(from: from, withCalcDist: done.distanceInM) }
        case .none:
            throw DistanceManagerError.unknownMessageType
        }
    }

    public static func clearAllAndCancel() {
        Self.dispatchQueue.sync {
            // Cancel all timeouts

            // Remove all peers
            Self.peersToAdd.removeAll()
            Self.peersToRemove = Set(Self.distByPeer.keys)
            Self.updateDistByPeer()

            // Reset state
            Self.resetToDone()
        }
    }

// MARK: Private interface
    private init() { }

    private static func scheduleTimeout(
        expectedStateByDeadline: Self.State,
        timeoutTargetState: Self.State?,
        deadlineFromNow: DispatchTimeInterval = .milliseconds(10), // TODO use network latency
        actionOnUnreachedTarget: @escaping () -> Void = {}
    ) {
        let workItem = DispatchWorkItem {
            switch DistanceManager.dmState {
            case expectedStateByDeadline:
                return
            default:
                if let actualTimeoutTargetState = timeoutTargetState {
                    Self.dmState = actualTimeoutTargetState
                }
                actionOnUnreachedTarget()
            }
        }
        Self.timeouts.append(workItem)

        Self.dispatchQueue.asyncAfter(
            deadline: DispatchTime.now().advanced(by: deadlineFromNow),
            execute: workItem
        )
    }

    private static func didReceiveInit(fromPeer: PeerID, withFreq freq: DistanceListener.Freq, withTimeout timeout: DispatchTimeInterval) {
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
        default:
//        case .someCalculated(let calculatedDist):
//            // Already calculated this distance: Resend it to the peer bc they must have missed the done message
//            Self.sendDelegate?.send(
//                toPeers: [fromPeer],
//                withMessage: MessageWrapper.with {
//                    $0.data = .neighborAppMessage(NeighborAppMessage.with {
//                        $0.data = .distanceProtocolMessage(DistanceProtocolWrapper.with {
//                            $0.type = .done(Done.with {
//                                $0.distanceInM = calculatedDist
//                            })
//                        })
//                    })
//                },
//                withReliability: .reliable
//            )
//        case .noneCalculated:
            do {
                try Self.distanceCalculator!.setupForMode(mode: .speaker(freq: freq))
            } catch {
                #if DEBUG
                print("\(String(describing: Self.self)): Failed to set up distance calculator for speaking mode after receiving init. Error: \(error).")
                #endif
                // TODO: Maybe do something else here?
                return
            }

            // FIXME: Make this a constant somewhere
            self.spokeDelegate?.startProtocol(numPingRounds: 16)

            #if DEBUG
            if self.spokeDelegate == nil {
                Self.sendDelegate?.send(
                    toPeers: [fromPeer],
                    withMessage: MessageWrapper.with {
                        $0.data = .neighborAppMessage(NeighborAppMessage.with {
                            $0.data = .distanceProtocolMessage(DistanceProtocolWrapper.with {
                                $0.type = .initAck(InitAck())
                            })
                        })
                    },
                    withReliability: .reliable
                )
            }
            #endif

            Self.dmState = .speaker(.initAcked(.certain(fromPeer)))
            Self.scheduleTimeout(
                expectedStateByDeadline: .speaker(.spoke(.any)),
                timeoutTargetState: .done,
                deadlineFromNow: timeout,
                actionOnUnreachedTarget: {
                    Self.resetToDone()
                }
            )
        }
    }

    private static func didReceiveInitAck(from: PeerID) {
        guard let actualSendDelegate = Self.sendDelegate else {
            fatalError("Received InitAck with no send delegate registered: This should not be possible.")
        }
        #if DEBUG
        print("RECEIVED INIT ACK FROM: \(from) in state \(Self.dmState)") // TODO: remove
        #endif

        switch Self.dmState {
        case .initiator(.`init`(.certain(let numAckedPeers))):
            guard Self.distByPeer[from] != nil else {
                fatalError("Received InitAck from peer not added through `addPeer(peer:)` before `initiate()` was called. This should not be possible.")
            }

            #if DEBUG
            print("RECEIVED INIT ACK FROM: \(from)") // TODO: remove
            #endif
            guard !Self.initAckedPeers.contains(from) else {
                // Already received ack from this peer
                return
            }
            #if DEBUG
            print("ACCEPTED INIT ACK FROM: \(from)") // TODO: remove
            #endif

            Self.initAckedPeers.insert(from)
            if numAckedPeers + 1 == Self.peersInCurrentRound.count {
                Self.cancelTimeouts()

                #if DEBUG
                if self.speakTimerDelegate == nil {
                    do {
                        try Self.distanceCalculator!.listen() // TODO handle errors
                    } catch {
                        #if DEBUG
                        fatalError("\(String(describing: Self.self)): Failed listening for peers with error: \(error)")
                        #endif
                    }
                    actualSendDelegate.send(
                        toPeers: Self.peersInCurrentRound,
                        withMessage: MessageWrapper.with {
                            $0.data = .neighborAppMessage(NeighborAppMessage.with {
                                $0.data = .distanceProtocolMessage(DistanceProtocolWrapper.with {
                                    $0.type = .speak(Speak())
                                })
                            })
                        },
                        withReliability: .reliable
                    )
                }
                #endif

                Self.speakTimerDelegate?.startProtocol()

                Self.dmState = .initiator(.speak(.certain(0)))
                Self.scheduleTimeout(
                    expectedStateByDeadline: .done,
                    timeoutTargetState: .done,
                    deadlineFromNow: Self.spokeTimeout,
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

    private static func didReceiveSpeak(from: PeerID, receivedAt: UInt64, withTimeout timeout: DispatchTimeInterval) {
        guard let actualSendDelegate = Self.sendDelegate else {
            fatalError("Received Speak with no send delegate registered: This should not be possible.")
        }

        switch Self.dmState {
        case .speaker(.initAcked(.certain(let initPeer))):
            if from != initPeer {
                fatalError("Received speak from peer (\(from)) which is not the initiator (\(initPeer)): This should not be possible.")
            }

            #if DEBUG
            if self.spokeDelegate == nil {
                let delay: UInt64
                do {
                    delay = try Self.distanceCalculator!.speak(receivedAt: receivedAt)
                } catch {
                    #if DEBUG
                    print("Failed speaking. Error: \(error).")
                    #endif
                    // TODO: Might want to change this
                    return
                }

                actualSendDelegate.send(
                    toPeers: [initPeer],
                    withMessage: MessageWrapper.with {
                        $0.data = .neighborAppMessage(NeighborAppMessage.with {
                            $0.data = .distanceProtocolMessage(DistanceProtocolWrapper.with {
                                $0.type = .spoke(Spoke.with {
                                    $0.delayInNs = delay
                                })
                            })
                        })
                    },
                    withReliability: .reliable
                )
            }
            #endif

            Self.dmState = .speaker(.spoke(.certain(from)))
            scheduleTimeout(
                expectedStateByDeadline: .done,
                timeoutTargetState: .done,
                deadlineFromNow: timeout,
                actionOnUnreachedTarget: {
                    Self.resetToDone()
                }
            )
            break
        case .speaker(.spoke(let initPeer)):
            fatalError("Received speak from peer (\(from)) while in `spoke` state with initiator (\(initPeer)): This should not be possible")
        default:
            return
        }
    }

    private static func didReceiveSpoke(from: PeerID, receivedAt: UInt64, delayInNs: UInt64) {
        #if DEBUG
        print("RECEIVED SPOKE FROM: \(from) in state \(Self.dmState)") // TODO: remove
        #endif

        switch Self.dmState {
        case .initiator(.speak(.certain(let numSpokenPeers))):
            guard let peerDist = Self.distByPeer[from] else {
                fatalError("Received `Spoke` from peer not added through `addPeer(peer:)` before `initiate()` was called. This should not be possible.")
            }
            #if DEBUG
            print("RECEIVED SPOKE FROM: \(from)") // TODO: remove
            #endif

            switch peerDist {
            case .someCalculated(_):
                fatalError("Received `Spoke` from peer whose distance is already calculated: This should not be possible.")
            default:
                break
            }

            #if DEBUG
            print("ACCEPTED SPOKE FROM: \(from)") // TODO: remove
            #endif

            #if DEBUG
            if self.speakTimerDelegate == nil {
                // FIXME: Until I convert this class to use new swift concurrency this is just how it's gonna be
                let wait = DispatchSemaphore(value: 0)
                Task {
                    do {
                        try Self.distanceCalculator!.heardPeerSpeak(
                            peer: from,
                            recvTimeInNS: receivedAt,
                            reportedSpeakingDelay: delayInNs,
                            withOneWayLatency: 0
                        )
                    } catch {
                        #if DEBUG
                        fatalError("Failed getting latency for spoken peer: \(from).")
                        #endif
                    }
                    wait.signal()
                }
                wait.wait()
            }
            #endif

            if numSpokenPeers + 1 == Self.peersInCurrentRound.count {
                Self.calculateDistances()
            } else {
                Self.dmState = .initiator(.speak(.certain(numSpokenPeers + 1)))
            }
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
        Self.resetToDone()
    }

    private static func cancelTimeouts() {
        for timeoutWorkItem in Self.timeouts {
            timeoutWorkItem.cancel()
        }

        Self.timeouts = []
    }

    private static func resetToDone() {
        #if DEBUG
        print("\(String(describing: Self.self)): Reset to done")
        #endif
        Self.cancelTimeouts()
        if !Self.peersInCurrentRound.isEmpty {
            for peer in Self.peersInCurrentRound {
                Self.distanceCalculator!.deregisterPeer(peer: peer)
            }
            Self.peersInCurrentRound = []
        }
        Self.speakTimerDelegate?.resetProtocol()
        Self.spokeDelegate?.resetProtocol()
        Self.distanceCalculator?.reset()
        Self.initAckedPeers.removeAll()
        Self.dmState = .done
    }

    private static func calculateDistances() {
        let (peerIDs, calcDists): ([PeerID], [DistInMeters]) = Self.distanceCalculator!.calculateDistances()
        for (peerID, calcDist) in zip(peerIDs, calcDists) {
            Self.distByPeer[peerID] = .someCalculated(calcDist)
        }

        let messages = calcDists.map({ calcDist in
            MessageWrapper.with {
                $0.data = .neighborAppMessage(NeighborAppMessage.with {
                    $0.data = .distanceProtocolMessage(DistanceProtocolWrapper.with {
                        $0.type = .done(Done.with {
                            $0.distanceInM = calcDist
                        })
                    })
                })
            }
        })

        if !messages.isEmpty {
            Self.sendDelegate?.send(toPeers: peerIDs, withMessages: messages, withReliability: .reliable)
            Self.updateDelegate?.didUpdate(distancesByPeer: Self.distByPeer)
        }
        Self.resetToDone()
    }

    // Called by initiator
    private static func updateDistByPeer() {
        #if DEBUG
        print("DistanceManager:updateDistByPeer: Adding \(peersToAdd), Removing \(peersToRemove)")
        #endif
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
            case (false, true):
                // Peer was already registered but prioritize given distance
                Self.distByPeer[peerToAdd] =  peerDist
            case (false, false):
                // Peer not registered and user given distance
                Self.distByPeer[peerToAdd] = peerDist
            }
        }

        for peerToRemove in peersToRemove {
            Self.distByPeer[peerToRemove] = nil
        }

        peersToAdd.removeAll()
        peersToRemove.removeAll()
    }

    private static var sendDelegate: (any NeighborMessageSendDelegate)?
    private static var updateDelegate: (any DistanceManagerUpdateDelegate)?
    private static var distanceCalculator: (any DistanceCalculatorProtocol)?
    private static var speakTimerDelegate: (any SpeakTimerDelegate)?
    private static var spokeDelegate: (any SpokeDelegate)?
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
    private static var initAckedPeers: Set<PeerID> = []
    private static var peersInCurrentRound: Array<PeerID> = []
    private static var spokeTimeout: DispatchTimeInterval = .milliseconds(10)

    private static let speakTimerDelegateUpdateDelegate = SpeakTimerDelegateUpdateDelegateClass()
    private static let spokeDelegateUpdateDelegateClass = SpokeDelegateUpdateDelegateClass()

    private class SpeakTimerDelegateUpdateDelegateClass: SpeakTimerDelegateUpdateDelegate {
        func shouldConnectToPeer(
            peer: DistanceManager.PeerID,
            completion: @escaping (Bool) -> Void
        ) {
            // Called from whatever the bluetooth queue is

            // It's ok to access this from (possibly) another thread because
            //   `peersInCurrentRound` is never written to during the protocol
            if DistanceManager.peersInCurrentRound.contains(where: { $0 == peer }) {
                completion(true)
                DistanceManager.dispatchQueue.async {
                    DistanceManager.didReceiveInitAck(from: peer)
                }
            } else {
                #if DEBUG
                print("Peer \(peer) denied with peers in current round \(String(describing: DistanceManager.peersInCurrentRound))")
                #endif
                completion(false)
            }
        }
        
        func receivedSpokeMessage(from peer: DistanceManager.PeerID) {
            // zeros don't matter because `didReceiveSpoke` is using the delegate
            DistanceManager.dispatchQueue.async {
                DistanceManager.didReceiveSpoke(from: peer, receivedAt: 0, delayInNs: 0)
            }
        }
        
        func done() {
            // FIXME: Implement
        }
        
        func error(message: String) {
            #if DEBUG
            fatalError("Something's wrong with the SpeakTimerDelegate: \(message)")
            #else
            DistanceManager.dispatchQueue.async {
                DistanceManager.resetToDone()
            }
            #endif
        }
    }

    private class SpokeDelegateUpdateDelegateClass: SpokeDelegateUpdateDelegate {
        func receivedSpeakMessage(from peer: DistanceManager.PeerID) {
            // zero doesn't matter because `didReceiveSpeak` is using the delegate
            DistanceManager.dispatchQueue.async {
                DistanceManager.didReceiveSpeak(
                    from: peer,
                    receivedAt: 0,
                    withTimeout: BluetoothService.spokeTimeout
                )
            }
        }
        
        func error(message: String) {
            #if DEBUG
            fatalError("Something's wrong with the SpokeDelegate: \(message)")
            #else
            DistanceManager.dispatchQueue.async {
                DistanceManager.resetToDone()
            }
            #endif
        }
    }

    private enum Anyable<T>: Equatable, CustomStringConvertible
    where T: Equatable & CustomStringConvertible {
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

        var description: String {
            switch self {
            case .certain(let value):
                return "\(value)"
            case .any:
                return "Any"
            }
        }
    }

    private enum InitiatorState: Equatable, CustomStringConvertible {
        var description: String {
            switch self {
            case .`init`(let value):
                return "Init: \(value.description)"
            case .speak(let value):
                return "Speak: \(value.description)"
            }
        }

        case `init`(Anyable<UInt>)
        case speak(Anyable<UInt>)
    }

    private enum SpeakerState: Equatable, CustomStringConvertible {
        var description: String {
            switch self {
            case .initAcked(let value):
                return "InitAcked: \(value.description)"
            case .spoke(let value):
                return "Spoke: \(value.description)"
            }
        }
        case initAcked(Anyable<PeerID>)
        case spoke(Anyable<PeerID>)
    }

    private enum State: Equatable, CustomStringConvertible {
        var description: String {
            switch self {
            case .initiator(let initiatorState):
                return "Initiator: \(initiatorState.description)"
            case .speaker(let speakerState):
                return "Speaker: \(speakerState.description)"
            case .done:
                return "Done"
            }
        }
        
        case initiator(InitiatorState)
        case speaker(SpeakerState)
        case done
    }
}
