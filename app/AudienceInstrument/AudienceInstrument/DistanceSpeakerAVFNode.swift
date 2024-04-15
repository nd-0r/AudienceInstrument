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
        self.timeToSpeak = speakTime
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
        AVAudioSourceNode { [self]
        _, _, frameCount, outputData -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(outputData)

            let numFrames = min(Int(frameCount), self.samplesToSpeak)
            for frameIdx in 0..<numFrames {
                let index0 = Int(self.currWavetableIdx)
                let index1 = index0 + 1

                let frac = self.currWavetableIdx - Float(index0)

                let value0 = self.wavetable[index0]
                let value1 = self.wavetable[index1]

                // Linear interpolation
                let currSample = value0 + frac * (value1 - value0)

                var nextWavetableIdx = self.currWavetableIdx + self.wavetableStep
                // `tableSize - 2` because have to accommodate for linear
                // interpolation. If the table size is 4096, in the worst
                // case, `nextWavetableIdx` is just less than 4095, e.g.
                // 4094.999999... Then, `index1` would be
                // floor(4094.999999...) + 1 = 4095, which is the last
                // index in the table.
                if (nextWavetableIdx > Float(self.tableSize - 1)) {
                    // Wrap around the wavetable
                    nextWavetableIdx -= Float(self.tableSize - 1)
                }
                self.currWavetableIdx = nextWavetableIdx

                for buffer in ablPointer {
                    let buf: UnsafeMutableBufferPointer<Float> = UnsafeMutableBufferPointer(buffer)
                    buf[frameIdx] = currSample
                }
            }
            self.samplesToSpeak -= numFrames

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

    private let timeToSpeak: TimeInterval
    private lazy var samplesToSpeak: Int = {
        return Int(self.timeToSpeak * self.format.sampleRate)
    }()

    private let tableSize: Int = 4096
    private var sourceNode: AVAudioSourceNode! = nil
    private let format: AVAudioFormat
    private let freq: UInt
    private weak var audioEngine: AVAudioEngine? = nil
    private var currWavetableIdx: Float = 0.0
    private var wavetableStep: Float = 0.0
}