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
    case audioEngineError(String)
}

protocol DistanceCalculatorLatencyDelegate {
    func getOneWayLatencyInNS(toPeer: DistanceManager.PeerID) -> UInt64
}

fileprivate struct _DistanceCalculator {
    typealias DM = DistanceManager

    static func setupForMode(mode: DistanceCalculatorMode) throws {
        Self.state = mode
        Self.setupAudioSession()
        if mode == .listener {
            try Self.enableBuiltInMicAndSelect()
        }
        try Self.setupListenerOrSpeakerNode()
    }

    static func registerPeer(peer: DM.PeerID, withFrequency freq: UInt) {
        guard Self.state == .listener else {
            #if DEBUG
            print("\(typeName): Tried to register peer not as listener.")
            #endif
            return
        }

        guard Self.estSpokeTimeByPeer[peer] == nil else {
            #if DEBUG
            print("\(typeName): Tried to register peer \(peer) multiple times.")
            #endif
            return
        }

        guard Self.peersByFreq[freq] == nil else {
            #if DEBUG
            print("\(typeName): Tried to register multiple peers with the same freq \(freq).")
            #endif
            return
        }

        guard Self.listener!.addFrequency(frequency: freq) else {
            #if DEBUG
            print("\(typeName): Tried to add frequency but failed in DistanceListener: \(freq).")
            #endif
            return
        }

        Self.peersByFreq[freq] = peer
        Self.estSpokeTimeByPeer[peer] = UInt64.max
    }
    
    static func deregisterPeer(peer: DM.PeerID) {
        guard Self.state == .listener else {
            #if DEBUG
            print("\(typeName): Tried to deregister peer not as speaker.")
            #endif
            return
        }

        guard Self.estSpokeTimeByPeer[peer] != nil else {
            #if DEBUG
            print("\(typeName): Tried to deregister nonexistent peer \(peer)")
            #endif
            return
        }

        let peerFreqIdx = Self.peersByFreq.firstIndex(where: { $1 == peer })
        Self.peersByFreq.remove(at: peerFreqIdx!)
        Self.estSpokeTimeByPeer[peer] = nil
    }
    
    static func speak(receivedAt: UInt64) throws -> UInt64 {
        Self.speaker!.speaking = true
        let spokeAt = getCurrentTimeInNs()
        try Self.audioEngine.start()

        // Return the delay in starting the tone
        return spokeAt - receivedAt
    }
    
    static func listen() throws {
        Self.listener!.beginProcessing()
        try Self.audioEngine.start()
    }
    
    static func heardPeerSpeak(
        peer: DM.PeerID,
        processingDelay: UInt64,
        reportedSpeakingDelay: UInt64,
        withOneWayLatency oneWayLatency: UInt64
    ) {
        let callTime = getCurrentTimeInNs()
        let adjustedSpokeTime = callTime - processingDelay - reportedSpeakingDelay
        Self.estSpokeTimeByPeer[peer] = adjustedSpokeTime - oneWayLatency
    }
    
    static func calculateDistances() -> ([DM.PeerID], [DM.DistInMeters]) {
        // FIXME: Add a continuation function here to make this work from
        //   the dispatch queue code without blocking the thread
        let sem = DispatchSemaphore(value: 0)
        Task {
            // TODO: The listener could call back when it hasn't heard any audio
            //   for a certain amount of time, but since this is called after all
            //   spoke messages have been received, it suffices to wait until the
            //   sound is very probably done playing
            try! await Task.sleep(nanoseconds: UInt64((Double(NSEC_PER_SEC) * Self.expectedToneLen) * Self.calculateWaitTimeMultiplier))
            sem.signal()
        }
        sem.wait()

        var peers: [DM.PeerID] = []
        var distances: [DM.DistInMeters] = []
        guard let recvTimeInNSByFreq = Self.listener!.stopAndCalcRecvTimeInNSByFreq() else {
            #if DEBUG
            print("\(typeName): DistanceListener failed to calculate recv time by freq.")
            #endif
            return ([], [])
        }

        for (freq, peer) in Self.peersByFreq {
            peers.append(peer)
            guard let recvTime = recvTimeInNSByFreq[freq] else {
                continue
            }

            guard let spokeTime = Self.estSpokeTimeByPeer[peer] else {
                #if DEBUG
                print("\(typeName): No spoke time for peer \(peer)")
                #endif
                continue
            }

            let approxDist = Float(Double(recvTime - spokeTime) / Self.speedOfSoundInMPerNS)

            distances.append(approxDist)
        }

        return (peers, distances)
    }
    
    static func reset() {
        switch Self.state {
        case .listener:
            self.listener!.stopAndCalcRecvTimeInNSByFreq()
        case .speaker(_):
            while (!Self.speaker!.done) {
                // TODO: There's probably a better way to do this, but I
                //   don't want to make the audio thread do a callback
            }
        case .none:
            break
        }

        Self.peersByFreq.removeAll()
        Self.estSpokeTimeByPeer.removeAll()
        Self.audioEngine.stop()
        Self.audioEngine.reset()
        Self.listener = nil
        Self.speaker = nil
    }

// Private interface

    private init() {}

    private static func setupListenerOrSpeakerNode() throws {
        let format = Self.audioEngine.inputNode.inputFormat(forBus: AVAudioNodeBus(0))
        guard format.sampleRate >= Double(Self.listenerConstants.maxFreqListenHz! * 2) else {
            throw DistanceCalculatorError.audioEngineError("\(String(describing: Self.self)): Sample rate \(format.sampleRate) is not high enough for max frequency: \(Self.listenerConstants.maxFreqListenHz).")
        }

        switch Self.state {
        case .some(.listener):
            Self.listener = DistanceListener(
                format: format,
                expectedToneTime: Self.expectedToneLen,
                audioEngine: Self.audioEngine,
                constants: Self.listenerConstants
            )
        case .some(.speaker(let freq)):
            Self.speaker = DistanceSpeaker(
                format: format,
                frequencyToSpeak: freq,
                speakTime: Self.expectedToneLen,
                audioEngine: Self.audioEngine
            )
        case .none:
            return
        }

        Self.audioEngine.prepare()
    }

    // MARK: Audio Session config
    private static func setupAudioSession() {
        var sessionOptions: AVAudioSession.CategoryOptions = []
        var category: AVAudioSession.Category

        switch Self.state {
            case .some(.listener):
                category = .record
                sessionOptions = [.mixWithOthers]
            case .some(.speaker):
                category = .playback
                sessionOptions = [.defaultToSpeaker, .interruptSpokenAudioAndMixWithOthers]
            case .none:
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

    private static func enableBuiltInMicAndSelect() throws {
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
            throw DistanceCalculatorError.audioSessionError("Unable to set the built-in mic as the preferred input. Error: \(error)")
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
            throw DistanceCalculatorError.audioSessionError("Unable to select omnidirectional polar pattern. Error: \(error)")
        }

        do {
            try session.setActive(true)
        } catch {
            throw DistanceCalculatorError.audioSessionError("Unable to set session as active. Error: \(error)")
        }
    }
    
    // MARK: Core state
    private static let typeName: String = String(describing: DistanceCalculator.self)
    private static let expectedToneLen: TimeInterval = 1.0
    private static let calculateWaitTimeMultiplier: TimeInterval = 1.2
    // TODO: Would be nice to calculate this more precisely
    private static let speedOfSoundInMPerNS: Double = 343.3 * Double(NSEC_PER_SEC)
    private static let listenerConstants = DistanceListener.Constants(
        highpassCutoff: 6000.0,
        highpassGain: -12,
        highpassQ: 1.0,
        fftSize: 32,
        log2n: 5,
        halfFFTSize: 16,
        hopSize: 16,
        minFreqListenHz: 6000,
        maxFreqListenHz: 20000,
        scoreThresh: 0.2,
        sdSilenceThresh: 0.01,
        toneLenToleranceTime: 0.01
    )
    private static var estSpokeTimeByPeer: [DM.PeerID:UInt64] = [:]
    private static var peersByFreq: [DistanceListener.Freq:DM.PeerID] = [:]
    private static var state: DistanceCalculatorMode? = nil

    // MARK: AVFAudio state
    private static let audioEngine: AVAudioEngine = AVAudioEngine()
    private static var speaker: DistanceSpeaker? = nil
    private static var listener: DistanceListener? = nil
}

class DistanceCalculator: DistanceCalculatorProtocol {
    typealias DM = DistanceManager

    func setupForMode(mode: DistanceCalculatorMode) throws {
        try _DistanceCalculator.setupForMode(mode: mode)
    }

    init(peerFrequencyCalculator: @escaping (DM.PeerID) -> UInt,
         peerLatencyCalculator: any DistanceCalculatorLatencyDelegate) {
        self.peerFrequencyCalculator = peerFrequencyCalculator
        self.peerLatencyCalculator = peerLatencyCalculator
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
    
    func speak(receivedAt: UInt64) throws -> UInt64 {
        try _DistanceCalculator.speak(receivedAt: receivedAt)
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
            reportedSpeakingDelay: reportedSpeakingDelay,
            withOneWayLatency: self.peerLatencyCalculator.getOneWayLatencyInNS(toPeer: peer)
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
    private var peerLatencyCalculator: any DistanceCalculatorLatencyDelegate
}
