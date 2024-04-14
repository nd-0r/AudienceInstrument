//
//  DistanceCalculator.swift
//  AudienceInstrument
//
//  Created by Andrew Orals on 4/12/24.
//

import Foundation
import AVFoundation

enum DistanceCalculatorError: Error {
    case unsupportedDevice(String)
    case audioSessionError(String)
}

fileprivate struct _DistanceCalculator {
    typealias DM = DistanceManager

    static func registerPeer(peer: DM.PeerID, withFrequency freq: UInt) {
        guard freq >= minFreq && freq <= maxFreq else {
            fatalError("\(typeName) Tried to register peer \(peer) with invalid frequency \(freq). Frequency must be at least \(minFreq) and at most \(maxFreq).")
        }

        guard !peers.contains(peer) else {
            #if DEBUG
            print("\(typeName): Tried to register peer \(peer) multiple times.")
            #endif
            return
        }

        peersByFreq[freq] = peer
        peers.insert(peer)
    }
    
    static func deregisterPeer(peer: DM.PeerID) {
        guard peers.contains(peer) else {
            #if DEBUG
            print("\(typeName): Tried to deregister nonexistent peer \(peer)")
            #endif
            return
        }

        peersByFreq.remove(at: peersByFreq.firstIndex(where: { $0.value == peer })!)
        peers.remove(peer)
    }
    
    static func speak() throws -> UInt64 {
        return 0 // FIXME
    }
    
    static func listen() throws {

    }
    
    static func heardPeerSpeak(
        peer: DM.PeerID,
        processingDelay: UInt64,
        reportedSpeakingDelay: UInt64
    ) {

    }
    
    static func calculateDistances() -> ([DM.PeerID], [DM.DistInMeters]) {
        return ([], []) // FIXME
    }
    
    static func reset() {
        peersByFreq.removeAll()
        peers.removeAll()
        // FIXME: Speaker: Wait to stop speaking
        // FIXME: Listener: If distances not calculated, abort listening
    }

// Private interface

    private init() {}

    // MARK: Audio Session config
    private func setupAudioSession(forState state: State) {
        var sessionOptions: AVAudioSession.CategoryOptions = []
        var category: AVAudioSession.Category

        switch state {
            case .listener:
                category = .record
                sessionOptions = [.mixWithOthers]
            case .speaker:
                category = .playback
                sessionOptions = [.defaultToSpeaker, .interruptSpokenAudioAndMixWithOthers]
            default:
                return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(category, options: sessionOptions)
            try session.setActive(true)
        } catch {
            fatalError("\(Self.typeName): Failed to configure and activate session for state: \(state) with options: \(sessionOptions).")
        }
    }

    private func enableBuiltInMicAndSelect() throws {
        // Get the shared audio session.
        let session = AVAudioSession.sharedInstance()

        // Find the built-in microphone input.
        guard let availableInputs = session.availableInputs,
              let builtInMicInput = availableInputs.first(where: { $0.portType == .builtInMic }) else {
            throw DistanceCalculatorError.unsupportedDevice("\(Self.typeName): The device must have a built-in microphone.")
        }

        // Make the built-in microphone input the preferred input.
        do {
            try session.setPreferredInput(builtInMicInput)
        } catch {
            throw DistanceCalculatorError.audioSessionError("Unable to set the built-in mic as the preferred input.")
        }

        guard let preferredInput = session.preferredInput,
              let dataSources = preferredInput.dataSources else {
            throw DistanceCalculatorError.audioSessionError("Could not get data sources for built-in microphone.")
        }

        guard let newDataSource = dataSources.first(where: { $0.orientation == .back }),
              let omniPolarPattern = newDataSource.supportedPolarPatterns?.first(where: { $0 == .omnidirectional }) else {
            throw DistanceCalculatorError.unsupportedDevice("Device does not have back microphone with an omnidirectional polar pattern.")
        }

        do {
            try newDataSource.setPreferredPolarPattern(omniPolarPattern)
        } catch {
            throw DistanceCalculatorError.audioSessionError("Unable to select omnidirectional polar pattern.")
        }
    }
    
    // MARK: Core state
    private static let typeName: String = String(describing: DistanceCalculator.self)
    private static let minFreq: UInt = 1000
    private static let maxFreq: UInt = sampleRate / 2
    private static let sampleRate: UInt = 44100
    private static var peersByFreq: [UInt:DM.PeerID] = [:]
    private static var peers: Set<DM.PeerID> = []
    private static var state: State = .done

    // MARK: AVFAudio state
    private static var listeningEngine: AVAudioEngine = {
        AVAudioEngine() // FIXME
    }()
    private static var speakingSession: AVAudioEngine = {
        AVAudioEngine() // FIXME
    }()

    private enum State: CustomStringConvertible {
        var description: String {
            switch self {
            case .speaker:
                "Speaker"
            case .listener:
                "Listener"
            case .done:
                "Done"
            }
        }
        case speaker
        case listener
        case done
    }
}

class DistanceCalculator: DistanceCalculatorProtocol {
    typealias DM = DistanceManager

    init(peerFrequencyCalculator: @escaping (DM.PeerID) -> UInt) {
        self.peerFrequencyCalculator = peerFrequencyCalculator
    }

    func registerPeer(peer: DM.PeerID) {
        _DistanceCalculator.registerPeer(
            peer: peer,
            withFrequency: calcPeerFreqMemo(peer: peer)
        )
    }
    
    func deregisterPeer(peer: DM.PeerID) {
        _DistanceCalculator.deregisterPeer(peer: peer)
    }
    
    func speak() throws -> UInt64 {
        try _DistanceCalculator.speak()
    }
    
    func listen() throws {
        try _DistanceCalculator.listen()
    }
    
    func heardPeerSpeak(
        peer: DM.PeerID,
        processingDelay: UInt64,
        reportedSpeakingDelay: UInt64
    ) {
        _DistanceCalculator.heardPeerSpeak(
            peer: peer,
            processingDelay: processingDelay,
            reportedSpeakingDelay: reportedSpeakingDelay
        )
    }
    
    func calculateDistances() -> ([DM.PeerID], [DM.DistInMeters]) {
        _DistanceCalculator.calculateDistances()
    }
    
    func reset() {
        _DistanceCalculator.reset()
        peerFrequencyCache.removeAll()
    }

// Private interface
    private func calcPeerFreqMemo(peer: DM.PeerID) -> UInt {
        if let freq = peerFrequencyCache[peer] {
            return freq
        }

        let freq = peerFrequencyCalculator(peer)
        peerFrequencyCache[peer] = freq
        return freq
    }

    private var peerFrequencyCache: [DM.PeerID:UInt] = [:]
    private var peerFrequencyCalculator: (DM.PeerID) -> UInt
}
