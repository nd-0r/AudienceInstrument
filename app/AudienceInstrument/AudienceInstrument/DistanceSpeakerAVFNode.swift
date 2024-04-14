//
//  DistanceSpeakerAVFNode.swift
//  AudienceInstrument
//
//  Created by Andrew Orals on 4/13/24.
//

import Foundation
import AVFoundation

class DistanceSpeaker {
    init(
        format: AVAudioFormat,
        frequencyToSpeak: UInt,
        speakTime: TimeInterval,
        audioEngine: AVAudioEngine? = nil
    ) {
        self.format = format
        self.freq = frequencyToSpeak
        self.audioEngine = audioEngine
        self.wavetableStep = computeWavetableStep()
        self.sourceNode = makeSourceNode()
        attachAndConnectSource()
    }

    deinit {
        detachAndDisconnectSource()
        wavetable.deallocate()
    }

    func attachAndConnectSource(to: AVAudioNode? = nil) {
        let output = audioEngine?.outputNode

        if to != nil {
            audioEngine?.connect(self.sourceNode, to: to!, format: self.format)
        } else if output != nil {
            audioEngine?.connect(self.sourceNode, to: output!, format: self.format)
        } else {
            return
        }
        audioEngine?.attach(self.sourceNode)
    }

    func detachAndDisconnectSource() {
        audioEngine?.detach(self.sourceNode)
    }

// MARK: Private interface
    private func computeWavetableStep() -> Float {
        let tableSizeOverSampleRate = Float(tableSize) / Float(format.sampleRate);
        return Float(freq) * tableSizeOverSampleRate;
    }

    private func makeSourceNode() -> AVAudioSourceNode {
        AVAudioSourceNode { [weak self]
        _, _, frameCount, outputData -> OSStatus in
            guard let actualSelf = self else {
                return noErr
            }

            let ablPointer = UnsafeMutableAudioBufferListPointer(outputData)

            for frameIdx in 0..<Int(frameCount) {
                let index0 = Int(actualSelf.currWavetableIdx)
                let index1 = index0 + 1

                let frac = actualSelf.currWavetableIdx - Float(index0)

                let value0 = actualSelf.wavetable[index0]
                let value1 = actualSelf.wavetable[index1]

                // Linear interpolation
                let currSample = value0 + frac * (value1 - value0)

                var nextWavetableIdx = actualSelf.currWavetableIdx + actualSelf.wavetableStep
                // `tableSize - 2` because have to accommodate for linear
                // interpolation. If the table size is 4096, in the worst
                // case, `nextWavetableIdx` is just less than 4095, e.g.
                // 4094.999999... Then, `index1` would be
                // floor(4094.999999...) + 1 = 4095, which is the last
                // index in the table.
                if (nextWavetableIdx > Float(actualSelf.tableSize - 1)) {
                    // Wrap around the wavetable
                    nextWavetableIdx -= Float(actualSelf.tableSize - 1)
                }
                actualSelf.currWavetableIdx = nextWavetableIdx

                for buffer in ablPointer {
                    let buf: UnsafeMutableBufferPointer<Float> = UnsafeMutableBufferPointer(buffer)
                    buf[frameIdx] = currSample
                }
            }

            return noErr
        }
    }

    private lazy var wavetable: UnsafeMutablePointer<Float> = {
        let samplesPtr = UnsafeMutablePointer<Float>.allocate(capacity: self.tableSize)

        // Fill with one period of sine
        // (self.tableSize - 2) because of linear interpolation
        let angleDelta = (2 * Double.pi) / Double(self.tableSize - 2)
        var currentAngle = 0.0;
 
        for i in 0..<tableSize {
            let sample = sin(currentAngle)
            samplesPtr[i] = Float(sample)
            currentAngle += angleDelta;
        }

        samplesPtr[tableSize - 1] = samplesPtr[0];

        return samplesPtr
    }()

    private let tableSize: Int = 4096
    private var sourceNode: AVAudioSourceNode! = nil
    private let format: AVAudioFormat
    private let freq: UInt
    private weak var audioEngine: AVAudioEngine? = nil
    private var currWavetableIdx: Float = 0.0
    private var wavetableStep: Float = 0.0
}
