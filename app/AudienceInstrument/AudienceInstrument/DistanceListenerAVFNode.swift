//
//  DistanceListenerAVFNode.swift
//  AudienceInstrument
//
//  Created by Andrew Orals on 4/13/24.
//

import Foundation
import AVFoundation
import Accelerate

class DistanceListener {
    typealias Freq = UInt

    init(format: AVAudioFormat,
         frequenciesToListenFor: [Freq],
         expectedToneTime: TimeInterval,
         audioEngine: AVAudioEngine? = nil) {
        guard let minFreq = frequenciesToListenFor.min() else {
            fatalError("\(String(describing: DistanceListener.self)): Must listen for at least one frequency.")
        }

        guard minFreq >= DistanceListener.minFreqListenHz else {
            fatalError("\(String(describing: DistanceListener.self)): Frequencies to listen for must be at least \(DistanceListener.minFreqListenHz)Hz.")
        }

        guard frequenciesToListenFor.max()! <= Freq(format.sampleRate / 2) else {
            fatalError("\(String(describing: DistanceListener.self)): Frequencies to listn for must be at most \(Freq(format.sampleRate / 2))Hz")
        }

        self.format = format
        self.freqs = frequenciesToListenFor
        self.audioEngine = audioEngine
        self.expectedToneLenInSamples = UInt(format.sampleRate * expectedToneTime)
        let toneLenToleranceSamples = UInt(DistanceListener.toneLenToleranceTime * format.sampleRate)
        self.expectedToneLenLBSamples = expectedToneLenInSamples - toneLenToleranceSamples
        self.expectedToneLenUBSamples = expectedToneLenInSamples + toneLenToleranceSamples

        let highpassFreq = Float(minFreq) - DistanceListener.highpassCutoffOffsetFromMinFreq
        self.highpassFilter = DistanceListener.makeHighpass(
            frequency: highpassFreq,
            Q: highpassFreq / DistanceListener.highpassCutoffOffsetFromMinFreq,
            dbGain: DistanceListener.highpassGain,
            sampleRate: Float(format.sampleRate)
        )

        self.sinkNode = makeSinkNode()
        attachAndConnectSink()
    }

    deinit {
        highpassDelayLine.deallocate()
        fftBuffer1.deallocate()
        fftBuffer2.deallocate()
        fftRealInput.deallocate()
        fftComplexInput.deallocate()
        fftRealOutput.deallocate()
        fftComplexOutput.deallocate()
        fftAutospectrumBuffer.deallocate()
        rmsInputBuffer.deallocate()
        freqBinStartSamples.deallocate()
    }

    func stopAndCalcRecvTimeInNSByFreq() -> [Freq:UInt64]? {
        detachAndDisconnectSink()

        guard let actualAnchorTime = self.anchorAudioTime else {
            return nil
        }

        let freqRange = Freq(self.format.sampleRate) / 2
        let binWidth = freqRange / Freq(Self.halfFFTSize)
        let sortedFreqs = self.freqs.sorted()
        var freqIdx = 0
        var out = [Freq:UInt64]()

        binLoop: for binIdx in 0..<Self.halfFFTSize {
            let binLB = Freq(binIdx) * binWidth
            let binUB = binLB + binWidth
            var currFreq = sortedFreqs[freqIdx]
            if currFreq >= binLB && currFreq < binUB {
                let hostTimeForBin = AVAudioTime(
                    sampleTime: AVAudioFramePosition(self.freqBinStartSamples[binIdx]),
                    atRate: self.format.sampleRate
                ).extrapolateTime(fromAnchor: actualAnchorTime)!.hostTime

                repeat {
                    guard currFreq < binUB else {
                        // move to the next bin
                        continue binLoop
                    }
                    out[currFreq] = hostTimeForBin
                    freqIdx += 1
                    currFreq = sortedFreqs[freqIdx]
                } while freqIdx < self.freqs.count

                // no more bins to look at
                break binLoop
            }
        }

        return out
    }

    // TODO: Compute this at compile time
    static func getFreqs(forNumPeers numPeers: UInt, sampleRate: Double) -> [Freq]? {
        let freqRange = Freq(sampleRate) / 2
        let binWidth = freqRange / Freq(Self.halfFFTSize)

        // Binary search for starting bin index
        var binIdxLB = 0
        var binIdxUB = Self.halfFFTSize
        while binIdxLB != binIdxUB {
            let currBinIdx = binIdxLB + (binIdxUB - binIdxLB) / 2
            let currStartFreq = Freq(currBinIdx) * binWidth
            if currStartFreq < Self.minFreqListenHz {
                binIdxLB = currBinIdx + 1
            } else {
                binIdxUB = currBinIdx
            }
        }
        let numUsableBins = Self.halfFFTSize - binIdxLB
        guard numPeers <= numUsableBins else {
            return nil
        }

        // Just assign the peers sequentially to the highest bin first
        var out = [Freq](repeating: 0, count: Int(numPeers))
        var peerFreq = binWidth * Freq(Self.halfFFTSize - 1) + binWidth / 2
        for outIdx in 0..<Int(numPeers) {
            out[outIdx] = peerFreq
            peerFreq -= binWidth
        }

        return out
    }

// MARK: Private interface

    private func attachAndConnectSink(from: AVAudioNode? = nil) {
        let input = audioEngine?.inputNode

        if from != nil {
            audioEngine?.connect(from!, to: self.sinkNode, format: self.format)
        } else if input != nil {
            audioEngine?.connect(input!, to: self.sinkNode, format: self.format)
        } else {
            return
        }
        audioEngine?.attach(self.sinkNode)
    }

    private func detachAndDisconnectSink() {
        audioEngine?.detach(self.sinkNode)
    }

    private func sampleProcessor() {
        while true {
            guard let sample = self.sampleBuffer.popBack() else {
                // TODO: Maybe sleep here?
                continue
            }
            self.numSamplesFromStart += 1

            switch self.sampleProcessorState {
            case .buffer1(let idx):
                self.fftBuffer1[idx] = sample
                self.fftBuffer2[max(0, idx - Self.hopSize)] = sample
                if idx + 1 >= Self.fftSize {
                    self.processBuffer(&self.fftBuffer1)
                    self.sampleProcessorState = .buffer2(idx: Self.hopSize)
                }
            case .buffer2(let idx):
                self.fftBuffer2[idx] = sample
                self.fftBuffer1[max(0, idx - Self.hopSize)] = sample
                if idx + 1 >= Self.fftSize {
                    self.processBuffer(&self.fftBuffer2)
                    self.sampleProcessorState = .buffer1(idx: Self.hopSize)
                }
            }
        }
    }

    @inline(__always)
    private func processBuffer(_ buf: inout UnsafeMutableBufferPointer<Float>) {
        vDSP_biquad(
            self.highpassFilter,
            self.highpassDelayLine,
            buf.baseAddress!, 1,
            buf.baseAddress!, 1,
            vDSP_Length(Self.fftSize)
        )

        vDSP.multiply(buf, self.hanningWindow, result: &buf)

        var forwardInput = DSPSplitComplex(realp: self.fftRealInput,
                                           imagp: self.fftComplexInput)


        // Convert signal to complex
        buf.withMemoryRebound(to: [DSPComplex].self) {
            vDSP.convert(interleavedComplexVector: $0.baseAddress!.pointee, toSplitComplexVector: &forwardInput)
        }
        var forwardOutput = DSPSplitComplex(realp: self.fftRealOutput,
                                            imagp: self.fftComplexOutput)
        self.fftSetup.forward(input: forwardInput, output: &forwardOutput)

        // vDSP_zaspec accumulates output
        vDSP.clear(&self.fftAutospectrumBuffer)

        var frequencyDomain = DSPSplitComplex(realp: self.fftRealOutput,
                                              imagp: self.fftComplexOutput)

        vDSP_zaspec(&frequencyDomain,
                    self.fftAutospectrumBuffer.baseAddress!,
                    vDSP_Length(Self.halfFFTSize))

        // Compute mean of autospectrum
        let mean = vDSP.mean(self.fftAutospectrumBuffer)

        // Compute standard deviation of autospectrum
        vDSP.add(-mean, self.fftAutospectrumBuffer, result: &self.rmsInputBuffer)
        let sd = vDSP.rootMeanSquare(self.rmsInputBuffer)

        // Compute scores of autospectrum
        vDSP.divide(self.rmsInputBuffer, sd, result: &self.fftAutospectrumBuffer)

        for binIdx in 0..<Self.halfFFTSize {
            let score = self.fftAutospectrumBuffer[binIdx]
            let binStart = self.freqBinStartSamples[binIdx]

            if score >= Self.scoreThresh {
                // If the bin is significant and not noticed yet, set it to the current fft sample index
                if binStart == UInt64.max {
                    self.freqBinStartSamples[binIdx] = self.numSamplesFromStart
                }
            } else if binStart != UInt64.max &&
                      (self.numSamplesFromStart - binStart < self.expectedToneLenLBSamples ||
                       self.numSamplesFromStart - binStart > self.expectedToneLenUBSamples) {
                // if the bin wasn't significant for long enough, reset to -1
                // TODO: Might want to have a tolerance of some number of frames so it doesn't have to be significant for the whole time
                self.freqBinStartSamples[binIdx] = UInt64.max
            }
        }
    }

    private func makeSinkNode() -> AVAudioSinkNode {
        AVAudioSinkNode { [self]
        timestamp, frameCount, inputData -> OSStatus in
            let abList = inputData.pointee

            if abList.mNumberBuffers == 1 {
                if self.anchorAudioTime == nil &&
                   timestamp.pointee.mFlags.contains(.sampleHostTimeValid) {
                    self.anchorAudioTime = AVAudioTime(
                        audioTimeStamp: timestamp,
                        sampleRate: self.format.sampleRate
                    )
                } else if self.anchorAudioTime == nil {
                    // Record host and sample time when it is value. Hopefully
                    //     that happens, otherwise out of luck
                    // TODO: maybe wait until we get an anchor point before stopping?
                    #if DEBUG
                    print("\(String(describing: Self.self)): HOST TIME INVALID?!")
                    #endif
//                    return noErr
                }

                let bufPtr: UnsafeMutableBufferPointer<Float> = UnsafeMutableBufferPointer(abList.mBuffers)

                for sampleIdx in 0..<frameCount {
                    #if DEBUG
                    if !self.sampleBuffer.pushFront(element: bufPtr[Int(sampleIdx)]) {
                        print("\(String(describing: Self.self)): RING BUFFER FULL?!")
                    }
                    #else
                    self.sampleBuffer.pushFront(element: bufPtr[sampleIdx])
                    #endif
                }
            }

            return noErr
        }
    }

    private static func makeHighpass(frequency: Float,
                                     Q: Float,
                                     dbGain: Float,
                                     sampleRate: Float) -> vDSP_biquad_Setup {
        let omega = 2.0 * .pi * frequency / sampleRate
        let sinOmega = sin(omega)
        let alpha = sinOmega / (2 * Q)
        let cosOmega = cos(omega)

        let b0 = (1 + cosOmega) / 2
        let b1 = -(1 + cosOmega)
        let b2 = (1 + cosOmega) / 2
        let a0 = 1 + alpha
        let a1 = -2 * cosOmega
        let a2 = 1 - alpha

        let biquadCoeffs = [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
        let sectionCoeffs = [[Float]](
            repeating: biquadCoeffs,
            count: Int(DistanceListener.biquadSectionCount)
        ).flatMap {
            $0
        }

        return vDSP_biquad_CreateSetup(vDSP.floatToDouble(sectionCoeffs), DistanceListener.biquadSectionCount)!
    }

    // MARK: BEGIN STATIC CONSTANTS
    // ==== Biquad constants ====
    private static let biquadSectionCount = vDSP_Length(1)
    private static let highpassCutoffOffsetFromMinFreq: Float = -500
    private static let highpassGain: Float = -12

    // ==== FFT constants ====
    private static let fftSize = 32 // For accuracy of at least 1ms at 44100kHZ
    private static let halfFFTSize = 16
    private static let hopSize = 16

    // ==== Detection constants ====
    private static let minFreqListenHz: Freq = 1000
    private static let scoreThresh: Float = 0.5
    private static let toneLenToleranceTime: TimeInterval = 0.002 // arbitrary
    // END STATIC CONSTANTS

    // MARK: BEGIN STATE
    // ==== Biquad state ====
    private let highpassFilter: vDSP_biquad_Setup
    private var highpassDelayLine = UnsafeMutablePointer<Float>.allocate(capacity: 2 * Int(DistanceListener.biquadSectionCount) + 2)

    // ==== FFT state ====
    private let hanningWindow = vDSP.window(ofType: Float.self,
                                            usingSequence: .hanningDenormalized,
                                            count: DistanceListener.fftSize,
                                            isHalfWindow: false)
    private let fftSetup = {
        let log2n = vDSP_Length(log2(Float(DistanceListener.fftSize)))

        guard let fftSetUp = vDSP.FFT(log2n: log2n,
                                      radix: .radix2,
                                      ofType: DSPSplitComplex.self) else {
            fatalError("\(String(describing: DistanceListener.self)) Can't create FFT Setup.")
        }

        return fftSetUp
    }()
    private var fftBuffer1 = UnsafeMutableBufferPointer<Float>.allocate(capacity: DistanceListener.fftSize)
    private var fftBuffer2 = UnsafeMutableBufferPointer<Float>.allocate(capacity: DistanceListener.fftSize)
    private let fftRealInput = {
        let ptr = UnsafeMutablePointer<Float>.allocate(capacity: DistanceListener.fftSize)
        ptr.initialize(repeating: 0.0, count: DistanceListener.fftSize)
        return ptr
    }()
    private let fftComplexInput = {
        let ptr = UnsafeMutablePointer<Float>.allocate(capacity: DistanceListener.fftSize)
        ptr.initialize(repeating: 0.0, count: DistanceListener.fftSize)
        return ptr
    }()
    private let fftRealOutput = UnsafeMutablePointer<Float>.allocate(capacity: DistanceListener.fftSize / 2)
    private let fftComplexOutput = UnsafeMutablePointer<Float>.allocate(capacity: DistanceListener.fftSize / 2)
    private var fftAutospectrumBuffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: DistanceListener.halfFFTSize)

    // ==== Detection state ====
    private let format: AVAudioFormat
    private let freqs: [Freq]
    private var sampleProcessorState: SampleProcessorState = .buffer1(idx: 0)
    private var rmsInputBuffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: DistanceListener.halfFFTSize)
    private var anchorAudioTime: AVAudioTime? = nil
    private let sampleBuffer: RingBuffer<Float> = RingBuffer(capacity: 4096)
    private var numSamplesFromStart: UInt64 = 0 // TODO: use timestamp
    private let expectedToneLenInSamples: UInt
    private let expectedToneLenLBSamples: UInt
    private let expectedToneLenUBSamples: UInt
    private var freqBinStartSamples = {
        let ptr = UnsafeMutablePointer<UInt64>.allocate(capacity: DistanceListener.halfFFTSize)
        ptr.initialize(repeating: UInt64.max, count: DistanceListener.halfFFTSize)
        return ptr
    }()

    // ==== AVAudio state ====
    private var sinkNode: AVAudioSinkNode! = nil
    private weak var audioEngine: AVAudioEngine? = nil
    // END STATE

    private enum SampleProcessorState {
        case buffer1(idx: Int), buffer2(idx: Int)
    }
}
