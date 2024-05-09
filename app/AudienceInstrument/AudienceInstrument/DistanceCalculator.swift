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
    case latencyError(String)
}

protocol DistanceCalculatorLatencyDelegate {
    func getOneWayLatencyInNS(toPeer: DistanceManager.PeerID) -> UInt64?
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

    static func calcFreqsForPeers() -> [DistanceListener.Freq]? {
        guard let actualListener = Self.listener else {
            #if DEBUG
            print("\(typeName): Tried to get freqs for peers without setting up listener!")
            #endif
            return nil
        }

        guard let freqs = actualListener.getFreqs(forNumPeers: UInt(Self.estSpokeTimeByPeer.count)) else {
            #if DEBUG
            print("\(typeName): Failed to get frequencies for peers from listener.")
            #endif
            return nil
        }

        for (idx, peer) in Self.estSpokeTimeByPeer.keys.enumerated() {
            guard actualListener.addFrequency(frequency: freqs[idx]) else {
                #if DEBUG
                print("\(typeName): Tried to add frequency but failed in DistanceListener: \(freqs[idx]).")
                #endif
                return nil
            }
            Self.peersByFreq[freqs[idx]] = peer
        }

        return freqs
    }

    static func registerPeer(peer: DM.PeerID) {
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

        Self.estSpokeTimeByPeer[peer] = UInt64.max
    }
    
    static func deregisterPeer(peer: DM.PeerID) {
        guard Self.state == .listener else {
            #if DEBUG
            print("\(typeName): Tried to deregister peer not as listener.")
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
        #if DEBUG
        print("\(typeName): Speaking")
        #endif
        Self.speaker!.amp = 1.0 // FIXME: This should be a constant somewhere
        let spokeAt = getCurrentTimeInNs()
        try Self.audioEngine.start()

        // Return the delay in starting the tone
        return spokeAt - receivedAt
    }
    
    static func listen() throws {
        #if DEBUG
        print("\(typeName): Listening")
        #endif
        Self.listener!.beginProcessing()
        try Self.audioEngine.start()
    }
    
    static func heardPeerSpeak(
        peer: DM.PeerID,
        recvTimeInNS: UInt64,
        reportedSpeakingDelay: UInt64,
        withOneWayLatency oneWayLatency: UInt64
    ) {
        #if DEBUG
        print("\(typeName): Heard peer speak message")
        #endif
        Self.estSpokeTimeByPeer[peer] = recvTimeInNS - oneWayLatency - reportedSpeakingDelay
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
        #if DEBUG
        print("\(typeName): Calculating distances")
        #endif

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

            guard Self.estSpokeTimeByPeer[peer] != nil && Self.estSpokeTimeByPeer[peer]! != UInt64.max else {
                #if DEBUG
                print("\(typeName): No spoke time for peer \(peer)")
                #endif
                continue
            }

            let approxDist = Float(Double(recvTime - Self.estSpokeTimeByPeer[peer]!) / Self.speedOfSoundInMPerNS)

            distances.append(approxDist)
        }

        return (peers, distances)
    }
    
    static func reset() {
        switch Self.state {
        case .listener:
            self.listener?.stopAndCalcRecvTimeInNSByFreq()
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
        try! AVAudioSession.sharedInstance().setActive(false)
        Self.listener = nil
        Self.speaker = nil
        Self.state = nil
    }

// Private interface

    private init() {}

    private static func setupListenerOrSpeakerNode() throws {

        switch Self.state {
        case .some(.listener):
            let format = Self.audioEngine.inputNode.inputFormat(forBus: AVAudioNodeBus(0))
            guard format.sampleRate >= Double(Self.listenerConstants.maxFreqListenHz! * 2) else {
                throw DistanceCalculatorError.audioEngineError("\(String(describing: Self.self)): Sample rate \(format.sampleRate) is not high enough for max frequency: \(String(describing: Self.listenerConstants.maxFreqListenHz)).")
            }

            Self.listener = DistanceListener(
                format: format,
                expectedToneTime: Self.expectedToneLen,
                audioEngine: Self.audioEngine,
                constants: Self.listenerConstants
            )
        case .some(.speaker(let freq)):
            let format = Self.audioEngine.outputNode.outputFormat(forBus: AVAudioNodeBus(0))
            guard format.sampleRate >= Double(Self.listenerConstants.maxFreqListenHz! * 2) else {
                throw DistanceCalculatorError.audioEngineError("\(String(describing: Self.self)): Sample rate \(format.sampleRate) is not high enough for max frequency: \(String(describing: Self.listenerConstants.maxFreqListenHz)).")
            }

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
                sessionOptions = [.interruptSpokenAudioAndMixWithOthers]
            case .none:
                return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(category, mode: .measurement, options: sessionOptions)
            try session.setActive(true)
        } catch {
            fatalError("\(Self.typeName): Failed to configure and activate session for state: \(String(describing: state)) with options: \(sessionOptions). Error: \(error).")
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

        guard let newDataSource = dataSources.first(where: { $0.orientation == .back }) else {
            #if DEBUG
            print(String(describing: dataSources))
            #endif
            throw DistanceCalculatorError.unsupportedDevice("Device does not have back microphone.")
        }

        guard let omniPolarPattern = newDataSource.supportedPolarPatterns?.first(where: { $0 == .subcardioid }) else {
            #if DEBUG
            print(String(describing: newDataSource.supportedPolarPatterns))
            #endif
            throw DistanceCalculatorError.unsupportedDevice("Device does not have back microphone with an omnidirectional polar pattern.")
        }

        do {
            try newDataSource.setPreferredPolarPattern(omniPolarPattern)
        } catch {
            throw DistanceCalculatorError.audioSessionError("Unable to select omnidirectional polar pattern. Error: \(error)")
        }
    }
    
    // MARK: Core state
    private static let typeName: String = String(describing: DistanceCalculator.self)
    private static let expectedToneLen: TimeInterval = 1.0
    private static let calculateWaitTimeMultiplier: TimeInterval = 3.0
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
        maxFreqListenHz: 8000,
        scoreThresh: 0.03,
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

    init(peerLatencyCalculator: (any DistanceCalculatorLatencyDelegate)?) {
        self.peerLatencyCalculator = peerLatencyCalculator
    }

    func setupForMode(mode: DistanceCalculatorMode) throws {
        try _DistanceCalculator.setupForMode(mode: mode)
    }

    func calcFreqsForPeers() -> [DistanceListener.Freq]? {
        return _DistanceCalculator.calcFreqsForPeers()
    }

    func registerPeer(peer: DM.PeerID) {
        _DistanceCalculator.registerPeer(peer: peer)
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
        recvTimeInNS recvTime: UInt64,
        reportedSpeakingDelay: UInt64,
        withOneWayLatency peerLatency: UInt64?
    ) throws {
        #if DEBUG
        if self.peerLatencyCalculator != nil && peerLatency == nil {
            _DistanceCalculator.heardPeerSpeak(
                peer: peer,
                recvTimeInNS: recvTime,
                reportedSpeakingDelay: reportedSpeakingDelay,
                withOneWayLatency: peerLatencyCalculator!.getOneWayLatencyInNS(toPeer: peer)!
            )
            return
        }
        #endif
        _DistanceCalculator.heardPeerSpeak(
            peer: peer,
            recvTimeInNS: recvTime,
            reportedSpeakingDelay: reportedSpeakingDelay,
            withOneWayLatency: peerLatency!
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
    private var peerFrequencyCalculator: (DM.PeerID) -> UInt = { _ in 37 }
    private var peerLatencyCalculator: (any DistanceCalculatorLatencyDelegate)?
}
