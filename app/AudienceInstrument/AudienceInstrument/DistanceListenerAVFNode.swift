//
//  DistanceListenerAVFNode.swift
//  AudienceInstrument
//
//  Created by Andrew Orals on 4/13/24.
//

import Foundation
import AVFoundation

class DistanceListener {
    init(format: AVAudioFormat, frequenciesToListenFor: [UInt], audioEngine: AVAudioEngine? = nil) {
        self.format = format
        self.freqs = frequenciesToListenFor
        self.audioEngine = audioEngine
        self.sinkNode = makeSinkNode()
        attachAndConnectSink()
    }

    deinit {
        detachAndDisconnectSink()
    }

    func attachAndConnectSink(from: AVAudioNode? = nil) {
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

    func detachAndDisconnectSink() {
        audioEngine?.detach(self.sinkNode)
    }

// MARK: Private interface
    /* FIXME
    @inline
    private static func calcFFT() {
        let frameCount = vDSP_Length(audioBuffer.frameLength)
        let log2n = vDSP_Length(log2(Float(frameCount)))
        let fftLength = frameCount / 2
        let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        
        // Create DSPSplitComplex for real and imaginary parts
        var real = [Float](repeating: 0.0, count: Int(fftLength))
        var imag = [Float](repeating: 0.0, count: Int(fftLength))
        var splitComplex = DSPSplitComplex(realp: &real, imagp: &imag)
        
        // Compute FFT
        floatData.withMemoryRebound(to: DSPComplex.self, capacity: Int(frameCount)) { complexBuffer in
            vDSP_fft_zip(fftSetup, &complexBuffer, 1, log2n, FFTDirection(FFT_FORWARD))
        }
        
        vDSP_destroy_fftsetup(fftSetup)
        
        // Compute magnitudes
        var magnitudes = [Float](repeating: 0.0, count: Int(fftLength))
        vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, fftLength)
        
        return magnitudes
    }
     */

    private func makeSinkNode() -> AVAudioSinkNode {
        AVAudioSinkNode { [weak self, freqs]
        timestamp, frameCount, inputData -> OSStatus in

            for f in freqs {
                print("\(f)")
            }
            // FIXME: implement

            return noErr
        }
    }

    private var sinkNode: AVAudioSinkNode! = nil
    private let format: AVAudioFormat
    private let freqs: [UInt]
    private weak var audioEngine: AVAudioEngine? = nil
}
