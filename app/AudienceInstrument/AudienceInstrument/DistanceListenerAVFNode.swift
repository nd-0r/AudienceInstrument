//
//  DistanceListenerAVFNode.swift
//  AudienceInstrument
//
//  Created by Andrew Orals on 4/13/24.
//

/*
New idea:
Detect the onset of a tone with a high delta magnitude and dynamically
set the threshold to the value it starts at?
 */

import CoreAudio
import Foundation
import AVFoundation
import Accelerate

class DistanceListener {
    typealias Freq = UInt

    struct Constants {
        // ==== Biquad constants ====
        var highpassCutoff: Float = 500
        var highpassGain: Float = -12
        var highpassQ: Float = 1.0

        // ==== FFT constants ====
        var fftSize = 32 // For accuracy of at least 1ms at 44100kHZ
        var log2n = 5
        var halfFFTSize = 16
        var hopSize = 16

        // ==== Detection constants ====
        var minFreqListenHz: Freq = 1000
        var maxFreqListenHz: Freq? = nil
        var scoreThresh: Float = 0.2
        var sdSilenceThresh: Float = 0.01
        var toneLenToleranceTime: TimeInterval = 0.01 // arbitrary
    }

    init(format: AVAudioFormat,
         expectedToneTime: TimeInterval,
         audioEngine: AVAudioEngine? = nil,
         constants: Constants = Constants()) {
        self.constants = constants
        self.format = format
        self.audioEngine = audioEngine
        let expectedToneLenInSamples = UInt(format.sampleRate * expectedToneTime)
        let toneLenToleranceSamples = UInt(constants.toneLenToleranceTime * format.sampleRate)

        self.bufferProcessor = DistanceListener.BufferProcessor(
            sampleRate: Float(format.sampleRate),
            constants: constants,
            expectedToneLenUBSamples: expectedToneLenInSamples + toneLenToleranceSamples,
            expectedToneLenLBSamples: expectedToneLenInSamples - toneLenToleranceSamples
        )

        freqBinStartSamples = {
            let ptr = UnsafeMutablePointer<BinState>.allocate(capacity: constants.halfFFTSize)
            ptr.initialize(repeating: .Undetected, count: constants.halfFFTSize)
            return ptr
        }()

        self.sinkNode = makeSinkNode()
        attachAndConnectSink()
    }

    deinit {
        freqBinStartSamples.deallocate()
    }

    func addFrequency(frequency freq: Freq) -> Bool {
        guard self.sampleProcessorWorker == nil else {
            #if DEBUG
            print("Tried to add frequency while DistanceListener is running!")
            #endif
            return false
        }

        guard freq >= constants.minFreqListenHz else {
            #if DEBUG
            print("\(String(describing: DistanceListener.self)): Frequencies to listen for must be at least \(constants.minFreqListenHz)Hz. Got \(freq)Hz.")
            #endif
            return false
        }

        let maxFreqListenHz = constants.maxFreqListenHz ?? Freq(format.sampleRate / 2)
        guard freq <= maxFreqListenHz else {
            #if DEBUG
            print("\(String(describing: DistanceListener.self)): Frequencies to listn for must be at most \(maxFreqListenHz)Hz. Got \(freq)Hz.")
            #endif
            return false
        }

        self.freqs.append(freq)
        return true
    }

    func beginProcessing() {
        #if DEBUG
        print("\(String(describing: DistanceListener.self)): Beginning processing")
        #endif

        let sampleProcessorWorker = DispatchWorkItem {
            self.sampleProcessor()
        }
        self.customDispatchQueue.async(execute: sampleProcessorWorker)
        self.sampleProcessorWorker = sampleProcessorWorker
    }

    @discardableResult
    func stopAndCalcRecvTimeInNSByFreq() -> [Freq:UInt64]? {
        detachAndDisconnectSink()
        self.sampleProcessorWorker?.cancel()

        guard let actualAnchorTime = self.anchorAudioTime else {
            #if DEBUG
            print("\(String(describing: Self.self)): Tried to calculate receive time of frequencies without anchor time!")
            #endif
            return nil
        }

        guard self.freqs.count > 0 else {
            #if DEBUG
            print("\(String(describing: Self.self)): Tried to calculate receive time without any registered frequencies.")
            #endif
            return nil
        }

        #if DEBUG
        print("Final num samples from start:")
        print(self.numSamplesFromStart)
        print("Final freq bin start samples:")
        print("[\(String(describing: freqBinStartSamples[0]))\((1..<self.constants.halfFFTSize).map({ idx in String(describing: freqBinStartSamples[idx])}).reduce("", { res, elem in res + ", " + elem}))]")
        #endif

        let freqRange = Freq(self.format.sampleRate) / 2
        let binWidth = freqRange / Freq(self.constants.halfFFTSize)
        let sortedFreqs = self.freqs.sorted()
        var freqIdx = 0
        var out = [Freq:UInt64]()

        binLoop: for binIdx in 0..<self.constants.halfFFTSize {
            let binLB = Freq(binIdx) * binWidth
            let binUB = binLB + binWidth
            var currFreq = sortedFreqs[freqIdx]
            if currFreq >= binLB {
                var binHostTime: UInt64? = nil

                let currBinSamples = self.freqBinStartSamples[binIdx]
                // Need to check lower bound because audio might have ended before sample processor could
                //  cancel the frequency bin. No need to check upper bound because either tone was cut off at
                //  the end, or it wasn't in which case the sample processor would have caught it. Also, can't
                //  check upper bound using only the start time and number of samples processed.
                switch currBinSamples {
                case .Detected(let startTime):
                    if let binAudioTime = AVAudioTime(
                        sampleTime: AVAudioFramePosition(actualAnchorTime.sampleTime + Int64(startTime)),
                        atRate: self.format.sampleRate
                    ).extrapolateTime(fromAnchor: actualAnchorTime) {
                        binHostTime = convertHostTimeToNanos(binAudioTime.hostTime)
                    }
                default:
                    break
                }

                repeat {
                    currFreq = sortedFreqs[freqIdx]
                    guard currFreq < binUB else {
                        // move to the next bin
                        continue binLoop
                    }
                    #if DEBUG
                    print("Freq \(currFreq) at samples \(currBinSamples)")
                    #endif
                    out[currFreq] = binHostTime
                    freqIdx += 1
                } while freqIdx < self.freqs.count

                // no more bins to look at
                break binLoop
            }
        }

        return out
    }

    func getFreqs(forNumPeers numPeers: UInt) -> [Freq]? {
        Self.getFreqs(forNumPeers: numPeers, sampleRate: self.format.sampleRate, withConstants: self.constants)
    }

    // TODO: Compute this at compile time
    static func getFreqs(forNumPeers numPeers: UInt, sampleRate: Double, withConstants constants: Constants = Constants()) -> [Freq]? {
        if numPeers == 0 {
            return []
        }

        let freqRange = Freq(sampleRate) / 2
        let binWidth = freqRange / Freq(constants.halfFFTSize)

        let binIdxLB = Freq(binarySearch(lowerBound: 0, upperBound: constants.halfFFTSize, tooLowPredicate: {
            Freq($0) * binWidth < constants.minFreqListenHz
        }))
        let binIdxUB: Freq
        if let maxFreqListenHz = constants.maxFreqListenHz {
            binIdxUB = Freq(binarySearch(lowerBound: Int(binIdxLB), upperBound: constants.halfFFTSize, tooLowPredicate: {
                Freq($0) * binWidth < maxFreqListenHz
            }))
        } else {
            binIdxUB = Freq(constants.halfFFTSize - 1)
        }

        let numUsableBins = binIdxUB - binIdxLB
        guard numPeers <= numUsableBins else {
            return nil
        }

        let halfBinWidthWindowAligned = (binWidth / Freq(2 * constants.fftSize)) * Freq(constants.fftSize)
        let maxFreqListenHzWindowAligned = ((constants.maxFreqListenHz ?? freqRange) / Freq(constants.fftSize)) * Freq(constants.fftSize)

        guard numPeers > 1 else {
            return [maxFreqListenHzWindowAligned - halfBinWidthWindowAligned]
        }

        // Just assign the peers sequentially to the highest freq first as far apart as possible
        let freqDist = (numUsableBins - 1) * binWidth // Pad with 1/2 bin at each end of the bandwidth
        let peerFreqStepWindowAligned = (freqDist / (numPeers * Freq(constants.fftSize))) * Freq(constants.fftSize)
        var out = [Freq](repeating: 0, count: Int(numPeers))
        var peerFreq = maxFreqListenHzWindowAligned - halfBinWidthWindowAligned
        for outIdx in 0..<Int(numPeers) {
            out[outIdx] = peerFreq
            peerFreq -= peerFreqStepWindowAligned
        }

        return out
    }

    func manuallyProcessBuffer(buffer: AVAudioPCMBuffer, len: AVAudioFrameCount) {
        guard buffer.stride == 1 &&
              buffer.format.sampleRate == self.format.sampleRate else {
            fatalError("Buffer format does not match set format")
        }

        let floatChannelData = buffer.floatChannelData!
        let bufPtr = floatChannelData.pointee
        for bufIdx in 0..<Int(len) {
            self.processSample(bufPtr[bufIdx])
        }
    }

    class BufferProcessor {
        init(sampleRate: Float,
             constants: Constants,
             expectedToneLenUBSamples: UInt,
             expectedToneLenLBSamples: UInt) {
            #if DEBUG
            print("BufferProcessor constants:")
            print(constants)
            #endif
            self.constants = constants
            self.expectedToneLenUBSamples = expectedToneLenUBSamples
            self.expectedToneLenLBSamples = expectedToneLenLBSamples
            #if DEBUG
            print("ToneLen lower bound samples: \(expectedToneLenLBSamples)")
            print("ToneLen upper bound samples: \(expectedToneLenUBSamples)")
            #endif
            self.highpassFilter = DistanceListener.makeHighpass(
                frequency: constants.highpassCutoff,
                Q: constants.highpassQ,
                dbGain: constants.highpassGain,
                sampleRate: sampleRate
            )
            self.fftBuffer1 = UnsafeMutableBufferPointer<Float>.allocate(capacity: constants.fftSize)
            self.fftBuffer2 = UnsafeMutableBufferPointer<Float>.allocate(capacity: constants.fftSize)
            self.highpassDelayLine = UnsafeMutablePointer<Float>.allocate(capacity: 2 * Int(DistanceListener.biquadSectionCount) + 2)
            self.window = vDSP.window(ofType: Float.self,
                                      usingSequence: .blackman,
                                      count: constants.fftSize,
                                      isHalfWindow: false)
            self.windowedBuffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: constants.fftSize)
            self.fftSetup = {
                guard let fftSetUp = vDSP_create_fftsetup(vDSP_Length(constants.log2n), FFTRadix(kFFTRadix2)) else {
                    fatalError("\(String(describing: DistanceListener.self)) Can't create FFT Setup.")
                }
                return fftSetUp
            }()
//            {
//                let log2n = vDSP_Length(constants.log2n)
//
//                guard let fftSetUp = vDSP.FFT(log2n: log2n,
//                                              radix: .radix2,
//                                              ofType: DSPSplitComplex.self) else {
//                    fatalError("\(String(describing: DistanceListener.self)) Can't create FFT Setup.")
//                }
//
//                return fftSetUp
//            }()
            self.fftRealInput = {
                let ptr = UnsafeMutablePointer<Float>.allocate(capacity: constants.halfFFTSize)
                ptr.initialize(repeating: 0.0, count: constants.halfFFTSize)
                return ptr
            }()
            self.fftComplexInput = {
                let ptr = UnsafeMutablePointer<Float>.allocate(capacity: constants.halfFFTSize)
                ptr.initialize(repeating: 0.0, count: constants.halfFFTSize)
                return ptr
            }()
            self.fftRealOutput = UnsafeMutablePointer<Float>.allocate(capacity: constants.halfFFTSize)
            self.fftComplexOutput = UnsafeMutablePointer<Float>.allocate(capacity: constants.halfFFTSize)
            self.fftAutospectrumBuffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: constants.halfFFTSize)
            self.rmsInputBuffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: constants.halfFFTSize)
            self.analysisOutputBuffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: constants.halfFFTSize)
        }

        deinit {
            vDSP_destroy_fftsetup(self.fftSetup)
            windowedBuffer.deallocate()
            highpassDelayLine.deallocate()
            fftBuffer1.deallocate()
            fftBuffer2.deallocate()
            fftRealInput.deallocate()
            fftComplexInput.deallocate()
            fftRealOutput.deallocate()
            fftComplexOutput.deallocate()
            fftAutospectrumBuffer.deallocate()
            rmsInputBuffer.deallocate()
            analysisOutputBuffer.deallocate()
        }

        #if DEBUG
        @inline(__always)
        static func verifyFloatBuf(_ buf: UnsafeMutablePointer<Float>, _ n: Int) {
            for i in 0..<n {
                assert(buf[i] != Float.nan && buf[i] != Float.infinity)
            }
        }
        #endif

        @inline(__always)
        func highpassFilter(_ buf: inout UnsafeMutableBufferPointer<Float>) {
            vDSP_biquad(
                self.highpassFilter,
                self.highpassDelayLine,
                buf.baseAddress!, 1,
                buf.baseAddress!, 1,
                vDSP_Length(self.constants.fftSize)
            )
        }

        // FIXME: Writes to windowedBuffer; make in-place
        @inline(__always)
        func applyWindow(_ buf: inout UnsafeMutableBufferPointer<Float>) {
            vDSP.multiply(buf, self.window, result: &self.windowedBuffer)
            #if DEBUG
            Self.verifyFloatBuf(self.windowedBuffer.baseAddress!, self.constants.fftSize)
            #endif
        }

        @inline(__always)
        func doRFFT(_ buf: inout UnsafeMutableBufferPointer<Float>) {
            // Convert signal to complex
            var forwardInput = DSPSplitComplex(realp: self.fftRealInput,
                                               imagp: self.fftComplexInput)
            buf.withMemoryRebound(to: DSPComplex.self) {
                vDSP_ctoz($0.baseAddress!, 2, &forwardInput, 1, vDSP_Length(self.constants.halfFFTSize))
            }

            var forwardOutput = DSPSplitComplex(realp: self.fftRealOutput,
                                                imagp: self.fftComplexOutput)
                                                
            vDSP_fft_zrop(
                self.fftSetup,
                &forwardInput,
                1,
                &forwardOutput,
                1,
                vDSP_Length(self.constants.log2n),
                FFTDirection(kFFTDirection_Forward)
            )
        }

        @inline(__always)
        func calcAutospectrum() {
            var frequencyDomain = DSPSplitComplex(realp: self.fftRealOutput,
                                                  imagp: self.fftComplexOutput)
            // vDSP_zaspec accumulates output
            vDSP.clear(&self.fftAutospectrumBuffer)
            vDSP_zaspec(&frequencyDomain,
                        self.fftAutospectrumBuffer.baseAddress!,
                        vDSP_Length(self.constants.halfFFTSize))
            #if DEBUG
            Self.verifyFloatBuf(self.fftAutospectrumBuffer.baseAddress!, self.constants.halfFFTSize)
            #endif
        }

        @inline(__always)
        fileprivate func calcFreqStartSamples(_ freqBinStartSamples: inout UnsafeMutablePointer<DistanceListener.BinState>,
                                              numSamplesFromStart: UInt64) {
            #if DEBUG
//            print("calcFreqStartSamples")
//            print("[\(String(describing: self.fftAutospectrumBuffer.baseAddress![0]))\((1..<self.constants.halfFFTSize).map({ idx in String(describing: self.fftAutospectrumBuffer.baseAddress![idx])}).reduce("", { res, elem in res + ", " + elem}))]")
            #endif
            // Compute mean of autospectrum
            let mean = vDSP.mean(self.fftAutospectrumBuffer)
            #if DEBUG
            assert(mean != Float.nan && mean != Float.infinity)
//            print(mean)
            #endif

            // Compute standard deviation of autospectrum
            vDSP.add(-mean, self.fftAutospectrumBuffer, result: &self.rmsInputBuffer)
            #if DEBUG
            Self.verifyFloatBuf(self.rmsInputBuffer.baseAddress!, self.constants.halfFFTSize)
            #endif
            let sd = vDSP.rootMeanSquare(self.rmsInputBuffer)
            #if DEBUG
            assert(sd != Float.nan && sd != Float.infinity)
//            print(sd)
            #endif

           // // Compute scores of autospectrum
           // vDSP.divide(self.rmsInputBuffer, sd, result: &self.fftAutospectrumBuffer)
           // vDSP.clear(&self.analysisOutputBuffer)
           // vDSP_vmax( // To account for nans
           //     self.analysisOutputBuffer.baseAddress!,
           //     1,
           //     self.fftAutospectrumBuffer.baseAddress!,
           //     1,
           //     self.analysisOutputBuffer.baseAddress!,
           //     1,
           //     vDSP_Length(self.constants.halfFFTSize)
           // )
           // #if DEBUG
           // Self.verifyFloatBuf(self.analysisOutputBuffer.baseAddress!, self.constants.halfFFTSize)
           // print("[\(String(describing: self.analysisOutputBuffer.baseAddress![0]))\((1..<self.constants.halfFFTSize).map({ idx in String(describing: self.analysisOutputBuffer.baseAddress![idx])}).reduce("", { res, elem in res + ", " + elem}))]")
           // #endif

//            if numSamplesFromStart == 21600 { // FIXME: REMOVE!!!
//                print("[\(String(describing: self.fftAutospectrumBuffer[0]))\((1..<self.constants.halfFFTSize).map({ idx in String(describing: self.fftAutospectrumBuffer[idx])}).reduce("", { res, elem in res + ", " + elem}))]")
//            }

            for binIdx in 0..<self.constants.halfFFTSize {
                let score = self.fftAutospectrumBuffer[binIdx]
                let binState = freqBinStartSamples[binIdx]

                let significant = score >= self.constants.scoreThresh * sd &&
                                  sd > self.constants.sdSilenceThresh
                switch binState {
                case .Undetected:
                    if significant {
                        // If the bin is significant and not noticed yet, set it to the current fft sample index
                        freqBinStartSamples[binIdx] = .Started(startTime: numSamplesFromStart)
                    }
                case .Started(let startTime):
                    if ((significant && numSamplesFromStart - startTime > expectedToneLenUBSamples) ||
                        (!significant && numSamplesFromStart - startTime < expectedToneLenLBSamples)) {
                        // If the bin was significant for too long reset to UInt64.max
                        // If the bin wasn't significant for long enough, reset to UInt64.max
                        // TODO: Might want to have a tolerance of some number of frames so it doesn't have to be significant for the whole time
                        freqBinStartSamples[binIdx] = .Undetected
                    } else {
                        freqBinStartSamples[binIdx] = .Detected(startTime: startTime)
                    }
                default:
                    // Once detected, search no more
                    // TODO: Optimize by doing no processing once everything is detected
                    break
                }
            }
            #if DEBUG
//            print("[\(String(describing: freqBinStartSamples[0]))\((1..<self.constants.halfFFTSize).map({ idx in String(describing: freqBinStartSamples[idx])}).reduce("", { res, elem in res + ", " + elem}))]")
//            print(numSamplesFromStart)
//            print("Done calc freq start samples")
            #endif
        }

        @inline(__always)
        fileprivate func processBuffer(_ buf: inout UnsafeMutableBufferPointer<Float>,
                           _ freqBinStartSamples: inout UnsafeMutablePointer<DistanceListener.BinState>,
                           numSamplesFromStart: UInt64) {
            #if DEBUG
//            print("Processing buffer")
//            print("[\(String(describing: buf.baseAddress![0]))\((1..<self.constants.fftSize).map({ idx in String(describing: buf.baseAddress![idx])}).reduce("", { res, elem in res + ", " + elem}))]")
            #endif
            self.highpassFilter(&buf)
            self.applyWindow(&buf)
            self.doRFFT(&self.windowedBuffer)
            self.calcAutospectrum()
            self.calcFreqStartSamples(
                &freqBinStartSamples,
                numSamplesFromStart: numSamplesFromStart
            )
        }

    // MARK: State
        private let constants: Constants
        let expectedToneLenLBSamples: UInt
        let expectedToneLenUBSamples: UInt
        var fftBuffer1: UnsafeMutableBufferPointer<Float>
        var fftBuffer2: UnsafeMutableBufferPointer<Float>

        // ==== Biquad state ====
        let highpassFilter: vDSP_biquad_Setup
        var highpassDelayLine: UnsafeMutablePointer<Float>

        // ==== FFT State ====
        let window: [Float]
        var windowedBuffer: UnsafeMutableBufferPointer<Float>
        let fftSetup: FFTSetup
        let fftRealInput: UnsafeMutablePointer<Float>
        let fftComplexInput: UnsafeMutablePointer<Float>
        let fftRealOutput: UnsafeMutablePointer<Float>
        let fftComplexOutput: UnsafeMutablePointer<Float>
        var fftAutospectrumBuffer: UnsafeMutableBufferPointer<Float>
        var rmsInputBuffer: UnsafeMutableBufferPointer<Float>
        var analysisOutputBuffer: UnsafeMutableBufferPointer<Float>
    }

// MARK: Private interface

    private func attachAndConnectSink(from: AVAudioNode? = nil) {
        let input = audioEngine?.inputNode
        audioEngine?.attach(self.sinkNode)

        if from != nil {
            audioEngine?.connect(from!, to: self.sinkNode, format: self.format)
        } else if input != nil {
            audioEngine?.connect(input!, to: self.sinkNode, format: self.format)
        } else {
            return
        }
    }

    private func detachAndDisconnectSink() {
        audioEngine?.detach(self.sinkNode)
    }

    private func sampleProcessor() {
        while true {
            guard let sample = self.sampleBuffer.popBack() else {
                // TODO: Sleep here until there are more samples
                continue
            }

            self.processSample(sample)
        }
    }

    private func processSample(_ sample: Float) {
        switch self.sampleProcessorState {
        case .buffer1(let idx):
            self.bufferProcessor.fftBuffer1[idx] = sample
            self.bufferProcessor.fftBuffer2[max(0, idx - self.constants.hopSize)] = sample
            if idx + 1 >= self.constants.fftSize {
                self.bufferProcessor.processBuffer(
                    &self.bufferProcessor.fftBuffer1,
                    &self.freqBinStartSamples,
                    numSamplesFromStart: self.numSamplesFromStart
                )
                self.sampleProcessorState = .buffer2(idx: self.constants.hopSize)
                self.numSamplesFromStart += UInt64(self.constants.hopSize)
            } else {
                self.sampleProcessorState = .buffer1(idx: idx + 1)
            }
        case .buffer2(let idx):
            self.bufferProcessor.fftBuffer2[idx] = sample
            self.bufferProcessor.fftBuffer1[max(0, idx - self.constants.hopSize)] = sample
            if idx + 1 >= self.constants.fftSize {
                self.bufferProcessor.processBuffer(
                    &self.bufferProcessor.fftBuffer2,
                    &self.freqBinStartSamples,
                    numSamplesFromStart: self.numSamplesFromStart
                )
                self.sampleProcessorState = .buffer1(idx: self.constants.hopSize)
                self.numSamplesFromStart += UInt64(self.constants.hopSize)
            } else {
                self.sampleProcessorState = .buffer2(idx: idx + 1)
            }
        }
    }


    private func makeSinkNode() -> AVAudioSinkNode {
        #if DEBUG
        print("\(String(describing: Self.self)): Made sink node")
        #endif
        return AVAudioSinkNode { [self]
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
                    guard self.sampleBuffer.pushFront(element: bufPtr[Int(sampleIdx)]) else {
                        fatalError("Failed to push to sample buffer; consumer not fast enough!")
                    }
                    #else
                    self.sampleBuffer.pushFront(element: bufPtr[Int(sampleIdx)])
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

    // MARK: CONSTANTS
    private let constants: Constants
    // ==== Biquad constants ====
    private static let biquadSectionCount = vDSP_Length(1)
    // END CONSTANTS

    // MARK: BEGIN STATE
    // ==== Buffer processor ====
    private let bufferProcessor: BufferProcessor

    // ==== Detection state ====
    private let format: AVAudioFormat
    private var freqs: [Freq] = []
    private var sampleProcessorState: SampleProcessorState = .buffer1(idx: 0)
    var anchorAudioTime: AVAudioTime? = nil
    private let sampleBuffer: RingBuffer<Float> = RingBuffer(capacity: 4096)
    private var numSamplesFromStart: UInt64 = 0 // TODO: use timestamp in render function
    private var freqBinStartSamples: UnsafeMutablePointer<BinState>

    // ==== Custom dispatch queue ====
    private var sampleProcessorWorker: DispatchWorkItem? = nil
    private let customDispatchQueue = DispatchQueue(
        label: "com.andreworals.DistanceListenerAVFNode",
        qos: .userInteractive
    )

    // ==== AVAudio state ====
    private(set) var sinkNode: AVAudioSinkNode! = nil
    private weak var audioEngine: AVAudioEngine? = nil
    // END STATE

    fileprivate enum BinState: Equatable {
        case Undetected
        case Started(startTime: UInt64)
        case Detected(startTime: UInt64)
    }

    private enum SampleProcessorState {
        case buffer1(idx: Int), buffer2(idx: Int)
    }
}
