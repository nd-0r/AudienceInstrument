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
            withNumFreqBins: DL.halfFFTSize,
            withMinFreq: DL.minFreqListenHz,
            withSampleRate: sampleRate
        )
        let numPeers: UInt = UInt(DL.halfFFTSize - minBinIdx)
        var expectedFreqs: [DL.Freq] = []
        var currFreq = 21359
        for _ in 0..<numPeers {
            expectedFreqs.append(DL.Freq(currFreq))
            currFreq -= 1378
        }
        print(expectedFreqs)

        let resultFreqs = DL.getFreqs(forNumPeers: numPeers, sampleRate: sampleRate)

        XCTAssertNotNil(resultFreqs)
        XCTAssertEqual(resultFreqs?.count, Int(numPeers))
        XCTAssertEqual(resultFreqs!, expectedFreqs)
    }

    func testGetFreqsTooManyPeers() {
        let sampleRate: Double = 44100 // Sample rate for testing
        let minBinIdx = Self.calcMinBinIdx(
            withNumFreqBins: DL.halfFFTSize,
            withMinFreq: DL.minFreqListenHz,
            withSampleRate: sampleRate
        )
        let numPeers: UInt = UInt(DL.halfFFTSize - minBinIdx + 1) // 1 too many

        let resultFreqs = DL.getFreqs(forNumPeers: numPeers, sampleRate: sampleRate)

        XCTAssertNil(resultFreqs)
    }

    func testGetFreqsWayTooManyPeers() {
        let sampleRate: Double = 44100 // Sample rate for testing
        let minBinIdx = Self.calcMinBinIdx(
            withNumFreqBins: DL.halfFFTSize,
            withMinFreq: DL.minFreqListenHz,
            withSampleRate: sampleRate
        )
        let numPeers: UInt = UInt(DL.halfFFTSize - minBinIdx + 13) // way too many

        let resultFreqs = DL.getFreqs(forNumPeers: numPeers, sampleRate: sampleRate)

        XCTAssertNil(resultFreqs)
    }

    func testGetFreqsWackySampleRateMaxPeers() {
        let sampleRate: Double = 60058
        let minBinIdx = Self.calcMinBinIdx(
            withNumFreqBins: DL.halfFFTSize,
            withMinFreq: DL.minFreqListenHz,
            withSampleRate: sampleRate
        )
        let numPeers: UInt = UInt(DL.halfFFTSize - minBinIdx)
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
            withNumFreqBins: DL.halfFFTSize,
            withMinFreq: DL.minFreqListenHz,
            withSampleRate: sampleRate
        )
        let numPeers: UInt = UInt(DL.halfFFTSize - minBinIdx + 1) // 1 too many

        let resultFreqs = DL.getFreqs(forNumPeers: numPeers, sampleRate: sampleRate)

        XCTAssertNil(resultFreqs)
    }
}


class DistanceListenerIntegrationTests: XCTestCase {
    typealias DL = DistanceListener

    enum DLITError: Error {
        case assertionFailed(String)
        case internalFailure(String)
    }

    let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    let filePlayerNode = AVAudioPlayerNode()
    let audioEngine = AVAudioEngine()

    static func parseNumTones(_ filename: String) throws -> (Int, String) {
        let pattern = "test_(\\d+)_tones_(.*)\\.wav"
        
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [])
            if let match = regex.firstMatch(in: filename, options: [], range: NSRange(location: 0, length: filename.utf16.count)) {
                let numberRange = Range(match.range(at: 1), in: filename)!
                let nameRange = Range(match.range(at: 2), in: filename)!
                let numberString = filename[numberRange]
                let nameString = filename[nameRange]
                if let number = Int(numberString) {
                    return (number, String(nameString))
                }
            }
        } catch {
            throw DLITError.internalFailure("Error creating regex: \(error)")
        }
        
        throw DLITError.internalFailure("Error parsing test filename")
    }

    func performTest(filename: String) throws {
        let (numTones, testName) = try Self.parseNumTones(filename)
        let freqs = DL.getFreqs(forNumPeers: UInt(numTones), sampleRate: self.format.sampleRate)!
        let distanceListener = DL(format: self.format,
                                  frequenciesToListenFor: freqs,
                                  expectedToneTime: 1.0)

        self.audioEngine.attach(self.filePlayerNode)
        self.audioEngine.attach(distanceListener.sinkNode)
        self.audioEngine.connect(self.filePlayerNode, to: distanceListener.sinkNode, format: self.format)
    }
}
