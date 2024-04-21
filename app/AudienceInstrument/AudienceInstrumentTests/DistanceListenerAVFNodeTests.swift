//
//  DistanceListenerAVFNodeTests.swift
//  AudienceInstrumentTests
//
//  Created by Andrew Orals on 4/15/24.
//

import Foundation
import XCTest
import AVFoundation
@testable import AudienceInstrument

class DistanceListenerUnitTests: XCTestCase {
    typealias DL = DistanceListener

    static let defaultConstants = DL.Constants()

    static func calcMinBinIdx(
        withNumFreqBins numBins: Int,
        withMinFreq minFreq: DL.Freq,
        withSampleRate sr: Double = 44100
    ) -> Int {
        let bandwidth = DL.Freq(sr / 2)
        let binWidth = DL.Freq(Int(bandwidth) / numBins)
        var out: DL.Freq = 0
        while out * binWidth < minFreq {
            out += 1
        }
        return Int(out)
    }

    func testGetFreqsNoPeers() {
        let sampleRate: Double = 44100 // Sample rate for testing
        let numPeers: UInt = 0
        let expectedFreqs: [DL.Freq] = []

        let resultFreqs = DL.getFreqs(forNumPeers: numPeers, sampleRate: sampleRate)

        XCTAssertNotNil(resultFreqs)
        XCTAssertEqual(resultFreqs?.count, Int(numPeers))
        XCTAssertEqual(resultFreqs!, expectedFreqs)
    }

    func testGetFreqsOnePeer() {
        let sampleRate: Double = 44100 // Sample rate for testing
        let numPeers: UInt = 1
        let expectedFreqs: [DL.Freq] = [21359]

        let resultFreqs = DL.getFreqs(forNumPeers: numPeers, sampleRate: sampleRate)

        XCTAssertNotNil(resultFreqs)
        XCTAssertEqual(resultFreqs?.count, Int(numPeers))
        XCTAssertEqual(resultFreqs!, expectedFreqs)
    }

    func testGetFreqs() {
        let sampleRate: Double = 44100 // Sample rate for testing
        let numPeers: UInt = 5
        let expectedFreqs: [DL.Freq] = [21359, 19981, 18603, 17225, 15847]

        let resultFreqs = DL.getFreqs(forNumPeers: numPeers, sampleRate: sampleRate)

        XCTAssertNotNil(resultFreqs)
        XCTAssertEqual(resultFreqs?.count, Int(numPeers))
        XCTAssertEqual(resultFreqs!, expectedFreqs)
    }

    func testGetFreqsMaxPeers() {
        let sampleRate: Double = 44100 // Sample rate for testing
        let minBinIdx = Self.calcMinBinIdx(
            withNumFreqBins: Self.defaultConstants.halfFFTSize,
            withMinFreq: Self.defaultConstants.minFreqListenHz,
            withSampleRate: sampleRate
        )
        let numPeers: UInt = UInt(Self.defaultConstants.halfFFTSize - minBinIdx)
        var expectedFreqs: [DL.Freq] = []
        var currFreq = 21359
        for _ in 0..<numPeers {
            expectedFreqs.append(DL.Freq(currFreq))
            currFreq -= 1378
        }

        let resultFreqs = DL.getFreqs(forNumPeers: numPeers, sampleRate: sampleRate)

        XCTAssertNotNil(resultFreqs)
        XCTAssertEqual(resultFreqs?.count, Int(numPeers))
        XCTAssertEqual(resultFreqs!, expectedFreqs)
    }

    func testGetFreqsTooManyPeers() {
        let sampleRate: Double = 44100 // Sample rate for testing
        let minBinIdx = Self.calcMinBinIdx(
            withNumFreqBins: Self.defaultConstants.halfFFTSize,
            withMinFreq: Self.defaultConstants.minFreqListenHz,
            withSampleRate: sampleRate
        )
        let numPeers: UInt = UInt(Self.defaultConstants.halfFFTSize - minBinIdx + 1) // 1 too many

        let resultFreqs = DL.getFreqs(forNumPeers: numPeers, sampleRate: sampleRate)

        XCTAssertNil(resultFreqs)
    }

    func testGetFreqsWayTooManyPeers() {
        let sampleRate: Double = 44100 // Sample rate for testing
        let minBinIdx = Self.calcMinBinIdx(
            withNumFreqBins: Self.defaultConstants.halfFFTSize,
            withMinFreq: Self.defaultConstants.minFreqListenHz,
            withSampleRate: sampleRate
        )
        let numPeers: UInt = UInt(Self.defaultConstants.halfFFTSize - minBinIdx + 13) // way too many

        let resultFreqs = DL.getFreqs(forNumPeers: numPeers, sampleRate: sampleRate)

        XCTAssertNil(resultFreqs)
    }

    func testGetFreqsWackySampleRateMaxPeers() {
        let sampleRate: Double = 60058
        let minBinIdx = Self.calcMinBinIdx(
            withNumFreqBins: Self.defaultConstants.halfFFTSize,
            withMinFreq: Self.defaultConstants.minFreqListenHz,
            withSampleRate: sampleRate
        )
        let numPeers: UInt = UInt(Self.defaultConstants.halfFFTSize - minBinIdx)
        var expectedFreqs: [DL.Freq] = []
        var currFreq = 29078
        for _ in 0..<numPeers {
            expectedFreqs.append(DL.Freq(currFreq))
            currFreq -= 1876
        }

        let resultFreqs = DL.getFreqs(forNumPeers: numPeers, sampleRate: sampleRate)

        XCTAssertNotNil(resultFreqs)
        XCTAssertEqual(resultFreqs?.count, Int(numPeers))
        XCTAssertEqual(resultFreqs!, expectedFreqs)
    }

    func testGetFreqsWackySampleRateTooManyPeers() {
        let sampleRate: Double = 60058 // Sample rate for testing
        let minBinIdx = Self.calcMinBinIdx(
            withNumFreqBins: Self.defaultConstants.halfFFTSize,
            withMinFreq: Self.defaultConstants.minFreqListenHz,
            withSampleRate: sampleRate
        )
        let numPeers: UInt = UInt(Self.defaultConstants.halfFFTSize - minBinIdx + 1) // 1 too many

        let resultFreqs = DL.getFreqs(forNumPeers: numPeers, sampleRate: sampleRate)

        XCTAssertNil(resultFreqs)
    }
}

class DistanceListenerBufferProcessorUnitTests: XCTestCase {
    typealias DLBP = DistanceListener.BufferProcessor

    static let defaultConstants = DistanceListener.Constants()

    enum DLBPError: Error {
        case assertionFailed(message: String)
        case internalFailure(String)
    }

    static func makeBuffer(buffer: inout UnsafeMutableBufferPointer<Float>,
                           withFrequencies freqs: [Float],
                           atSampleRate sr: Int) {
        buffer.initialize(repeating: 0.0)
        var phase: Float = 0
        let phaseStepPerSample = 2.0 * Float.pi / Float(sr)
        for bufIdx in 0..<buffer.count {
            for freq in freqs {
                buffer.baseAddress![bufIdx] += (sin(freq * phase) / Float(freqs.count))
            }
            phase += phaseStepPerSample
        }
    }

    static let sampleRate: Float = 44100
    var sampleBuffer = UnsafeMutableBufferPointer<Float>.allocate(
        capacity: DistanceListenerBufferProcessorUnitTests.defaultConstants.fftSize
    )
    var bufferProcessor: DLBP? = nil

    deinit {
        sampleBuffer.deallocate()
    }

    override func setUp() {
        bufferProcessor = DLBP(
            sampleRate: Self.sampleRate,
            constants: Self.defaultConstants,
            expectedToneLenUBSamples: 100, // Arbitrary. Doesn't matter because only processing one frame
            expectedToneLenLBSamples: 50 // Arbitrary. Doesn't matter because only processing one frame
        )
    }

    static func verifyOutput(actual: UnsafeMutableBufferPointer<Float>,
                      expected: [Float],
                      tolerance: Float) throws {
        guard actual.count == expected.count else {
            print("[\(String(describing: actual.baseAddress![0]))\((1..<actual.count).map({ idx in String(describing: actual.baseAddress![idx])}).reduce("", { res, elem in res + ", " + elem}))]")
            throw DLBPError.assertionFailed(message: "Length of expected array \(expected.count) does not match that of the test buffer, \(actual.count).")
        }

        for bufIdx in 0..<expected.count {
            guard abs(expected[bufIdx] - actual.baseAddress![bufIdx]) < tolerance else {
                print("[\(String(describing: actual.baseAddress![0]))\((1..<expected.count).map({ idx in String(describing: actual.baseAddress![idx])}).reduce("", { res, elem in res + ", " + elem}))]")
                throw DLBPError.assertionFailed(message: "Expected \(expected[bufIdx]) but got \(actual.baseAddress![bufIdx]).")
            }
        }
    }

    func testFilterFreq() throws {
        // Calculated in Python
        let expectedIR: [Float] = [0.9644096018059061, -0.07100946072482794, -0.07050506992359529, -0.06968998684054777, -0.06858955843496224, -0.06722878725553867, -0.06563223264057558, -0.06382392087982497, -0.06182726416213638, -0.05966498810205304, -0.05735906761071648, -0.05493067085168971, -0.05240011100053466, -0.04978680550807861, -0.0471092425511726, -0.04438495434127047, -0.04163049695022382, -0.03886143630417505, -0.036092339990212004, -0.03333677451639792, -0.03060730766377876, -0.027915515568867153, -0.02527199417677691, -0.02268637470850476, -0.020167342790695885, -0.01772266090246025, -0.0153591938013007, -0.01308293659884802, -0.0108990451667522, -0.008811868563635188, -0.006824983185355134, -0.0049412283528555475]

        self.sampleBuffer.baseAddress![0] = 1.0
        self.bufferProcessor!.highpassFilter(&self.sampleBuffer)

        do {
            try Self.verifyOutput(actual: self.sampleBuffer, expected: expectedIR, tolerance: 0.00001)
        } catch DLBPError.assertionFailed(let message) {
            XCTFail(message)
        } catch DLBPError.internalFailure(let message) {
            fatalError(message)
        }
    }

    func testMakeBuffer() throws {
        // Calculated in Python
        let expectedBuffer: [Float] = [0.0, 0.32478350804043704, 0.07604331989332527, 0.22301775203994595, 0.1418535563215501, 0.2627964208086163, 0.17702613950675788, 0.30791737248642637, 0.01368506454702395, 0.4840232228753463, 0.5930830276810055, 0.3988344371355775, 0.4799769218213784, 0.3971767410256806, 0.45029890222390057, 0.36058961700176695, 0.3998322052367891, 0.10222131647676945, 0.6371172874691071, 0.5234225688591669, 0.3973001544788751, 0.3804905054671267, 0.3165284330997691, 0.28371093346685056, 0.2234626520577777, 0.14653171299980347, -0.06664045339912064, 0.47401814195442477, 0.20559596687175025, 0.17294746782026177, 0.08519695285078269, 0.07874289594140613]
        let bufFreqs: [Float] = [100, 200, 500, 700, 827, 1000, 5000, 10000, 15000, 20000]
        Self.makeBuffer(
            buffer: &self.sampleBuffer,
            withFrequencies: bufFreqs,
            atSampleRate: Int(Self.sampleRate)
        )

        do {
            try Self.verifyOutput(actual: self.sampleBuffer, expected: expectedBuffer, tolerance: 0.0001)
        } catch DLBPError.assertionFailed(let message) {
            XCTFail(message)
        } catch DLBPError.internalFailure(let message) {
            fatalError(message)
        }
    }

    func testDoRFFT() throws {
        // Calculated in Python
        var inputSamples: [Float] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.08912755067896491, 0.1949101776390478, 0.2155366495670983, 0.11059700126466285, -0.0856400027595326, -0.2798218114574348, -0.36653174802669863, -0.28443163107183556, -0.053018926071690384, 0.22993217579679415, 0.43117199341511325, 0.4457478032520612, 0.2510744386457876, -0.07605537907764641, -0.3899656329020435, -0.5418121495903657, -0.45053838179370415, -0.14518263072622864, 0.24309346673358076, 0.5377687030210724, 0.5977349736482375, 0.38491695184241903]
        let expectedRFFTReal: [Float] = [2.1172271840553183, 2.052690936941501, 1.9554379413390173, 6.889027372094542, -6.362824451280044, -1.134230240832327, -1.1301296959667422, -0.8352099010881906, -0.43086984712202503, -0.3512032794163773, -0.386676347319344, -0.30746501692117356, -0.22237351129809335, -0.23188590520576957, -0.2511608190501722, -0.21721599714502704]
        // TODO: ask: Off by a factor of 2 from python, and the complex output has an extra -0.189 at the beginning... why?
        let expectedRFFTComplex: [Float] = [-0.1890499, -0.3397544042432237, -0.029006580695420364, 5.594527192922264, 4.71656350659978, -0.04801777776935459, -0.2799185312690697, 0.09214979807077736, 0.08165951428271212, -0.06864389299065068, -0.036099563962450176, 0.03807681855356945, 0.0061668397160916655, -0.034065295474244195, -0.004852596473327392, 0.024214946408611465]

        inputSamples.withUnsafeMutableBufferPointer {
            self.bufferProcessor!.doRFFT(&$0)
        }

        do {
            let realOutputBuf = UnsafeMutableBufferPointer<Float>(start: self.bufferProcessor!.fftRealOutput, count: Self.defaultConstants.halfFFTSize)
            let complexOutputBuf = UnsafeMutableBufferPointer<Float>(start: self.bufferProcessor!.fftComplexOutput, count: Self.defaultConstants.halfFFTSize)
            try Self.verifyOutput(actual: realOutputBuf, expected: expectedRFFTReal, tolerance: 0.001)
            try Self.verifyOutput(actual: complexOutputBuf, expected: expectedRFFTComplex, tolerance: 0.001)
        } catch DLBPError.assertionFailed(let message) {
            XCTFail(message)
        } catch DLBPError.internalFailure(let message) {
            fatalError(message)
        }
    }
}


class DistanceListenerIntegrationTests: XCTestCase {
    typealias DL = DistanceListener

    enum DLITError: Error {
        case assertionFailed(testName: String, message: String)
        case internalFailure(String)
    }

    let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    let filePlayerNode = AVAudioPlayerNode()
    let audioEngine = AVAudioEngine()

    static func parseNumTones(_ filename: String) throws -> (Int, String) {
        let pattern = "test_(\\d+)_tone.*"
        
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [])
            if let match = regex.firstMatch(in: filename, options: [], range: NSRange(location: 0, length: filename.utf16.count)) {
                let numberRange = Range(match.range(at: 1), in: filename)!
                let numberString = filename[numberRange]
                if let number = Int(numberString) {
                    return (number, filename)
                }
            }
        } catch {
            throw DLITError.internalFailure("Error creating regex: \(error)")
        }
        
        throw DLITError.internalFailure("Error parsing test filename")
    }

    func calcFreqStartTimesInMS(
        filename: String,
        freqs freqsOverride: [DL.Freq]? = nil,
        overrideNumTones: Int? = nil
    ) async throws -> [DL.Freq:Double]? {
        let (numTones, testName): (Int, String)
        if let actualOverrideNumTones = overrideNumTones {
            (numTones, testName) = (actualOverrideNumTones, filename)
        } else {
            (numTones, testName) = try Self.parseNumTones(filename)
        }

        guard let fileURL = Bundle(for: type(of: self)).url(forResource: filename, withExtension: ".wav") else {
            throw DLITError.internalFailure("\(testName): Failed opening file URL for file \(filename)")
        }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: fileURL)
        } catch {
            throw DLITError.internalFailure("\(testName): Failed reading audio file \(error)")
        }
        let freqs: [DL.Freq]
        if freqsOverride == nil {
            freqs = DL.getFreqs(forNumPeers: UInt(numTones), sampleRate: self.format.sampleRate)!
        } else {
            freqs = freqsOverride!
        }

        let distanceListener = DL(format: self.format,
                                  frequenciesToListenFor: freqs,
                                  expectedToneTime: 1.0)
        guard audioFile.fileFormat.sampleRate == self.format.sampleRate &&
              audioFile.fileFormat.channelCount == 1 else {
            throw DLITError.internalFailure("\(testName): Need audio file with 1 channel at 44.1kHz but got \(audioFile.fileFormat.channelCount) channels at \(audioFile.fileFormat.sampleRate).")
        }

        self.audioEngine.attach(self.filePlayerNode)
        self.audioEngine.connect(self.filePlayerNode, to: self.audioEngine.mainMixerNode, format: self.format)
        self.filePlayerNode.scheduleFile(audioFile, at: nil, completionCallbackType: .dataPlayedBack) { _ in
            print("Test file finished playing")
        }

        do {
            // The maximum number of frames the engine renders in any single render call.
            let maxFrames: AVAudioFrameCount = 4096
            try audioEngine.enableManualRenderingMode(
                .offline,
                format: self.format,
                maximumFrameCount: maxFrames
            )
        } catch {
            fatalError("Enabling manual rendering mode failed: \(error).")
        }

        let approxStartTimeNS: UInt64
        do {
            try self.audioEngine.start()
            approxStartTimeNS = getCurrentTimeInNs()
            distanceListener.anchorAudioTime = AVAudioTime(
                hostTime: approxStartTimeNS,
                sampleTime: self.audioEngine.manualRenderingSampleTime,
                atRate: self.format.sampleRate
            )
            self.filePlayerNode.play()
        } catch {
            throw DLITError.internalFailure("\(testName): Failed starting audio engine: \(error)")
        }


//        self.audioEngine.detach(self.filePlayerNode)
//        self.audioEngine.detach(distanceListener.sinkNode)

        // Just scratch space for the audio engine
        let buffer = AVAudioPCMBuffer(pcmFormat: self.audioEngine.manualRenderingFormat,
                                      frameCapacity: self.audioEngine.manualRenderingMaximumFrameCount)!
        // Adapted from: https://developer.apple.com/documentation/avfaudio/audio_engine/performing_offline_audio_processing
        while self.audioEngine.manualRenderingSampleTime < audioFile.length {
            do {
                let frameCount = audioFile.length - self.audioEngine.manualRenderingSampleTime
                let framesToRender = min(AVAudioFrameCount(frameCount), buffer.frameCapacity)

                let status = try self.audioEngine.renderOffline(framesToRender, to: buffer)

                switch status {
                case .success:
                    // The data rendered successfully.
                    distanceListener.manuallyProcessBuffer(buffer: buffer, len: framesToRender)
                    break
                case .insufficientDataFromInputNode:
                    // Applicable only when using the input node as one of the sources.
                    break
                case .cannotDoInCurrentContext:
                    // The engine couldn't render in the current render call.
                    // Retry in the next iteration.
                    break
                case .error:
                    // An error occurred while rendering the audio.
                    fatalError("The manual rendering failed.")
                default:
                    fatalError("Unknown case. Need to update something.")
                }
            } catch {
                fatalError("The manual rendering failed: \(error).")
            }
        }

        // Stop the player node and engine.
        self.filePlayerNode.stop()
        self.audioEngine.stop()
        // End adapted
        self.audioEngine.reset()
        self.filePlayerNode.reset()

        guard let actualTimeInNSByfreq = distanceListener.stopAndCalcRecvTimeInNSByFreq() else {
            return nil
        }
        print("Times in NS by freq: \(actualTimeInNSByfreq)")

        var out: [DL.Freq:Double] = [:]
        for (freq, timeInNS) in actualTimeInNSByfreq {
            guard let actualTimeInNS = timeInNS else {
                out[freq] = nil
                continue
            }

            out[freq] = Double(Float(actualTimeInNS - approxStartTimeNS) / Float(NSEC_PER_MSEC))
        }

        return out
    }

    func checkActualAgainstExpected(
        testName name: String,
        actual: [DL.Freq:Double?]?,
        expected: [DL.Freq:Double?]?,
        toleranceInMS: Double = 1.0
    ) throws {
        guard let actualActual = actual else {
            if let actualExpected = expected {
                throw DLITError.assertionFailed(
                    testName: name,
                    message: "Unexpected `nil`. Expected: \(actualExpected)."
                )
            }
            return
        }

        guard let actualExpected = expected else {
            throw DLITError.assertionFailed(
                testName: name,
                message: "Unexpected \(actualActual). Expected `nil`."
            )
        }

        guard actualActual.count == actualExpected.count else {
            throw DLITError.assertionFailed(
                testName: name,
                message: "Unexpected length \(actualActual.count). Expected length: \(actualExpected.count)"
            )
        }

        for (expectedFreq, expectedTime) in actualExpected {
            guard let actualActualActualTime = actualActual[expectedFreq] else {
                throw DLITError.assertionFailed(
                    testName: name,
                    message: "Expected frequency \(expectedFreq) does not exist in actual output. Expected: \(actualExpected), Actual: \(actualActual)"
                )
            }

            if let actualExpectedTime = expectedTime {
                guard let actualActualTime = actualActualActualTime else {
                    throw DLITError.assertionFailed(
                        testName: name,
                        message: "Unexpected `nil` for frequency \(expectedFreq). Expected: \(actualExpected). Actual: \(actualActual). Expected: \(actualExpected)."
                    )
                }

                let delta = abs(actualActualTime - actualExpectedTime)
                guard delta <= toleranceInMS else {
                    throw DLITError.assertionFailed(testName: name, message: "Expected time \(actualExpectedTime) but got \(actualActualTime) for freq with delta \(delta) outside tolerance \(toleranceInMS). Expected: \(actualExpected). Actual: \(actualActual).")
                }
            } else {
                if let actualActualTime = actualActualActualTime {
                    throw DLITError.assertionFailed(testName: name, message: "Expected `nil` for frequency \(expectedFreq) but got \(actualActualTime). Expected: \(actualExpected). Actual: \(actualActual).")
                }
            }
        }
    }

    func test1Tone() async throws {
        let filename = "test_1_tone"
        let freqStartTimesInMS = try await calcFreqStartTimesInMS(filename: filename, freqs: [DL.Freq(4800)])

        let expected: [DL.Freq:Double?]? = [
            4800:500
        ]

        do {
            try checkActualAgainstExpected(testName: filename, actual: freqStartTimesInMS, expected: expected)
        } catch DLITError.assertionFailed(let testName, let message) {
            XCTFail("\(testName): \(message)")
        } catch DLITError.internalFailure(let message) {
            fatalError(message)
        }
    }

    func test3TonesSeparate() async throws {
        let filename = "test_3_tones_separate"
        let freqStartTimesInMS = try await calcFreqStartTimesInMS(filename: filename, freqs: [7552, 13056, 18560])

        let expected: [DL.Freq:Double?]? = [
            7552:1000,
            13056:2500,
            18560:4000,
        ]

        do {
            try checkActualAgainstExpected(testName: filename, actual: freqStartTimesInMS, expected: expected)
        } catch DLITError.assertionFailed(let testName, let message) {
            XCTFail("\(testName): \(message)")
        } catch DLITError.internalFailure(let message) {
            fatalError(message)
        }
    }

    func test3TonesSameTime() async throws {
        let filename = "test_3_tones_same_time"
        let freqStartTimesInMS = try await calcFreqStartTimesInMS(filename: filename, freqs: [8928, 14432, 18560])

        let expected: [DL.Freq:Double?]? = [
            8928:2000,
            14432:2000,
            18560:2000,
        ]

        do {
            try checkActualAgainstExpected(testName: filename, actual: freqStartTimesInMS, expected: expected)
        } catch DLITError.assertionFailed(let testName, let message) {
            XCTFail("\(testName): \(message)")
        } catch DLITError.internalFailure(let message) {
            fatalError(message)
        }
    }

    func test3TonesStaggered() async throws {
        let filename = "test_3_tones_staggered"
        let freqStartTimesInMS = try await calcFreqStartTimesInMS(filename: filename, freqs: [8928, 14432, 19936])

        let expected: [DL.Freq:Double?]? = [
            8928: 1000,
            14432: 1500,
            19936: 2000
        ]

        do {
            try checkActualAgainstExpected(testName: filename, actual: freqStartTimesInMS, expected: expected)
        } catch DLITError.assertionFailed(let testName, let message) {
            XCTFail("\(testName): \(message)")
        } catch DLITError.internalFailure(let message) {
            fatalError(message)
        }
    }

    // TODO: test for false positives
}
