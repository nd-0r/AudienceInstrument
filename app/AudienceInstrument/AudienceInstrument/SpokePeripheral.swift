//
//  SpokePeripheral.swift
//  AudienceInstrument
//
//  Created by Andrew Orals on 4/28/24.
//

/**The starter code that this is based on is available [here](https://developer.apple.com/documentation/corebluetooth/transferring-data-between-bluetooth-low-energy-devices) and subject to the following license:
Copyright © 2024 Apple Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
**/

import Foundation
import CoreBluetooth

class SpokePeripheral: NSObject, SpokeDelegate {
    private enum State {
        enum LengthMessageState {
            case length, message
        }

        case advertising
        case sendingPing(bytesWritten: BluetoothService.LengthPrefixType)
        case receivingAck(LengthMessageState, bytesToRead: BluetoothService.LengthPrefixType)
        case receivingSpeak(LengthMessageState, bytesToRead: BluetoothService.LengthPrefixType)
        case sendingSpoke(bytesWritten: BluetoothService.LengthPrefixType)
    }

    private var tmpBuffer: Data = Data(capacity: BluetoothService.bufSize)
    private var sendBuffer: Data = Data(capacity: BluetoothService.bufSize)
    private var readBuffer: Data = Data(capacity: BluetoothService.bufSize)
    private var state: State? = nil

    private var numPingRounds: UInt = 0
    private var pingRoundIdx: UInt32 = 0
    private var timeStartedSending: UInt64? = nil
    private var lastTimeStartedReceiving: UInt64? = nil
    private var timeStartedReceiving: UInt64? = nil
    private var speakingDelay: UInt64? = nil
    private var latency: UInt64? = nil

    private let selfID: DistanceManager.PeerID
    private var peripheralManager: CBPeripheralManager!
    private var transferCharacteristic: CBMutableCharacteristic? = nil
    private var connectedCentral: CBCentral? = nil

    private weak var distanceCalculator: (any DistanceCalculatorProtocol)?
    private weak var updateDelegate: (any SpokeDelegateUpdateDelegate)? = nil

    required init(selfID: DistanceManager.PeerID) {
        self.selfID = selfID
        super.init()
    }

    deinit {
        if self.state != nil {
            self.resetProtocol()
        }
    }

    func registerDistanceCalculator(
        distanceCalculator: any DistanceCalculatorProtocol
    ) {
        self.distanceCalculator = distanceCalculator
    }

    func registerUpdateDelegate(
        updateDelegate: any SpokeDelegateUpdateDelegate
    ) {
        self.updateDelegate = updateDelegate
    }

    func startProtocol(
        numPingRounds: UInt
    ) {
        if self.peripheralManager == nil {
            self.peripheralManager = CBPeripheralManager(
                delegate: self,
                queue: nil,
                options: [CBPeripheralManagerOptionShowPowerAlertKey: true]
            )
        }

        self.numPingRounds = numPingRounds
    }

    func resetProtocol() {
        if let actualPeripheralManager = self.peripheralManager {
            actualPeripheralManager.stopAdvertising()
            actualPeripheralManager.removeAllServices()
        }
        self.state = nil
        self.transferCharacteristic = nil
        self.connectedCentral = nil
        self.tmpBuffer = Data(capacity: BluetoothService.bufSize)
        self.sendBuffer = Data(capacity: BluetoothService.bufSize)
        self.readBuffer = Data(capacity: BluetoothService.bufSize)
        self.numPingRounds = 0
        self.pingRoundIdx = 0
        self.timeStartedSending = nil
        self.timeStartedReceiving = nil
        self.speakingDelay = nil
        self.latency = nil
    }

    // MARK: - Helper Methods
    private func beginAdvertising() {
        guard !self.peripheralManager.isAdvertising else {
            return
        }

        /// Reference: https://developer.apple.com/documentation/corebluetooth/cbperipheralmanager/startadvertising(_:)
        /// with base64 encoding, an 8-byte integer should fit in 12 bytes, because `4 * ceil(8 / 3)` is 12
        /// Reference: https://stackoverflow.com/questions/13378815/base64-length-calculation
        let base64EncodedSelfID = withUnsafeBytes(of: self.selfID.bigEndian) {
            Data($0).base64EncodedString()
        }

        #if DEBUG
        print("\(#function): Advertising ID \(self.selfID) with base64 encoding \(base64EncodedSelfID)")
        #endif
        self.peripheralManager.startAdvertising([
            CBAdvertisementDataLocalNameKey: base64EncodedSelfID,
            CBAdvertisementDataServiceUUIDsKey: [BluetoothService.serviceUUID]
        ])

        self.state = .advertising
    }

    private func startProtocolWithCentral() {
        guard let state = self.state,
              case .advertising = state else {
            #if DEBUG
            fatalError("Tried to start protocol with central without starting advertising first")
            #else
            return
            #endif
        }

        self.state = .sendingPing(
            bytesWritten: 0
        )

        self.serializePing()

        self.writeAnyData()
    }

    private func readAnyData(_ data: Data) {
        guard let actualState = self.state else {
            #if DEBUG
            print("Tried to call \(#function) without a state")
            #endif
            return
        }

        #if DEBUG
        self.printState("\(#function)")
        #endif

        // only do something for receiving states
        let bytesToRead: BluetoothService.LengthPrefixType

        switch actualState {
        case .receivingAck(
            _,
            bytesToRead: let tmpBytesToRead
        ):
            bytesToRead = min(tmpBytesToRead, BluetoothService.LengthPrefixType(data.count))
        case .receivingSpeak(
            _,
            bytesToRead: let tmpBytesToRead
        ):
            bytesToRead = min(tmpBytesToRead, BluetoothService.LengthPrefixType(data.count))
        default:
            #if DEBUG
            print("Tried to read in non-reading state: \(String(describing: actualState))")
            #endif
            return // Not in a state where writing is necessary
        }

        if bytesToRead > 0 {
            self.readBuffer.append(data.prefix(upTo: Int(bytesToRead)))
        }

        #if DEBUG
        if bytesToRead == 0 {
            print("Called `readAnyData` with no bytes to read")
        }
        #endif
        
        let anotherReadRequired = (self.transitionState(
            numBytesReadOrWritten: bytesToRead
        ) ?? false)

        if anotherReadRequired && data.count > Int(bytesToRead) {
            // TODO: make this a loop instead of recursion
            self.readAnyData(
                data.suffix(from: Int(bytesToRead))
            )
        }
    }

    private func writeAnyData() {
        guard let actualState = self.state else {
            #if DEBUG
            print("Tried to call \(#function) without a state")
            #endif
            return
        }

        guard let actualConnectedCentral = self.connectedCentral else {
            #if DEBUG
            print("Tried to call \(#function) without a connected central")
            #endif
            return
        }

        #if DEBUG
        self.printState("\(#function)")
        #endif

        // only do something for sending states
        let bufBytesWritten: BluetoothService.LengthPrefixType

        switch actualState {
        case .sendingPing (
            bytesWritten: let tmpBytesWritten
        ):
            bufBytesWritten = tmpBytesWritten
        case .sendingSpoke(
            bytesWritten: let tmpBytesWritten
        ):
            bufBytesWritten = tmpBytesWritten
        default:
            #if DEBUG
            print("Tried to write in non-writing state: \(String(describing: actualState))")
            #endif
            return // Not in a state where writing is necessary
        }

        #if DEBUG
        if self.sendBuffer.count == 0 {
            print("Called `writeAnyData` with no bytes to write")
        }
        #endif

        // TODO: consolidate written bytes into one variable
        var bytesWritten: Int = 0
        let maxBytesToWrite = self.sendBuffer.count - Int(bufBytesWritten)
        var didSend = true
        while didSend && bytesWritten < maxBytesToWrite {
            let mtu = actualConnectedCentral.maximumUpdateValueLength
            let numBytesToWrite = min(maxBytesToWrite - bytesWritten, mtu)

            let data = self.sendBuffer.suffix(from: Int(bufBytesWritten) + bytesWritten)
            var rawPacket = [UInt8]()
            data.copyBytes(to: &rawPacket, count: numBytesToWrite)
            let packetData = Data(bytes: &rawPacket, count: numBytesToWrite)

            // Send it
            didSend = self.peripheralManager.updateValue(
                packetData,
                for: self.transferCharacteristic!,
                onSubscribedCentrals: nil
            )
            
            // If it didn't work, drop out and wait for the callback
            guard didSend else {
                #if DEBUG
                print("Couldn't send: MTU \(mtu) bufBytesWritten \(bufBytesWritten) bytesWritten \(bytesWritten) maxBytesToWrite \(maxBytesToWrite)")
                #endif
                break
            }

            bytesWritten += numBytesToWrite
        }

        #if DEBUG
        print("\(#function): bytesWritten: \(bytesWritten)")
        #endif

        let anotherWriteRequired = (self.transitionState(
            numBytesReadOrWritten: BluetoothService.LengthPrefixType(bytesWritten)
        ) ?? false)

        if didSend && anotherWriteRequired {
            // TODO: make this a loop instead of recursion
            self.writeAnyData()
        }
    }

    private func transitionState(
        numBytesReadOrWritten numBytes: BluetoothService.LengthPrefixType
    ) -> Bool? {
        guard let actualState = self.state else {
            return nil
        }
        var newState = actualState
        var doWrite = false

        #if DEBUG
        self.printState("\(#function) FROM")
        #endif

        defer {
            self.state = newState

            if doWrite {
                self.writeAnyData()
            }

            #if DEBUG
            self.printState("\(#function) TO")
            #endif
        }

        switch actualState {
        case .advertising:
            return nil
        case .sendingPing(var bytesWritten):
            bytesWritten += numBytes
            if bytesWritten >= self.sendBuffer.count {
                newState = .receivingAck(
                    .length,
                    bytesToRead: BluetoothService.lengthPrefixSize
                )

                return false
            } else {
                newState = .sendingPing(
                    bytesWritten: bytesWritten
                )

                return true
            }
        case .receivingAck(let lengthMessageState, var bytesToRead):
            bytesToRead -= numBytes
            switch lengthMessageState {
            case .length:
                if bytesToRead == 0 {
                    bytesToRead = BluetoothService.deserializeLength(
                        fromBuffer: self.readBuffer[
                            0..<Data.Index(BluetoothService.lengthPrefixSize)
                        ]
                    )

                    newState = .receivingAck(
                        .message,
                        bytesToRead: bytesToRead
                    )

                    self.lastTimeStartedReceiving = self.timeStartedReceiving
                    self.timeStartedReceiving = getCurrentTimeInNs()

                    return true
                } else {
                    newState = .receivingAck(
                        .length,
                        bytesToRead: bytesToRead
                    )

                    return true
                }
            case .message:
                if bytesToRead == 0 {
                    // Finished a round of ping-ack
                    self.pingRoundIdx += 1

                    // TODO: move slicing into utils
                    let message = BluetoothService.deserializeMeasurementMessage(
                        fromBuffer: self.readBuffer[
                                Data.Index(
                                    BluetoothService.lengthPrefixSize
                                )..<Data.Index(
                                    BluetoothService.lengthPrefixSize + numBytes
                                )
                            ]
                        )

                    self.calcLatency(delay: message.delayInNs)

                    if pingRoundIdx >= self.numPingRounds {
                        // transition to speaking
                        newState = .receivingSpeak(
                            .length,
                            bytesToRead: BluetoothService.lengthPrefixSize
                        )

                        return true
                    } else {
                        newState = .sendingPing(
                            bytesWritten: 0
                        )

                        self.serializePing()

                        // Necessary because transitioning from receiving to sending state
                        doWrite = true

                        return false
                    }
                } else {
                    newState = .receivingAck(
                        .message,
                        bytesToRead: bytesToRead
                    )

                    return true
                }
            }
        case .receivingSpeak(let lengthMessageState, var bytesToRead):
            bytesToRead -= numBytes
            // Even though the speak message is empty, the following is here to
            // make the processing comparable to the ping/ack messages
            switch lengthMessageState {
            case .length:
                if bytesToRead == 0 {
                    bytesToRead = BluetoothService.deserializeLength(
                        fromBuffer: self.readBuffer[
                            0..<Data.Index(BluetoothService.lengthPrefixSize)
                        ]
                    )

                    newState = .receivingSpeak(.message, bytesToRead: bytesToRead)

                    self.speakingDelay = try! self.distanceCalculator?.speak(
                        receivedAt: getCurrentTimeInNs()
                    )

                    return true
                } else {
                    newState = .receivingSpeak(.length, bytesToRead: bytesToRead)
                    return true
                }
            case .message:
                if bytesToRead == 0 {
                    let message = BluetoothService.deserializeProtocolMessage(
                        fromBuffer: self.readBuffer[
                                Data.Index(
                                    BluetoothService.lengthPrefixSize
                                )..<Data.Index(
                                    BluetoothService.lengthPrefixSize + numBytes
                                )
                            ]
                        )

                    self.updateDelegate?.receivedSpeakMessage(from: message.spoke.from)

                    newState = .sendingSpoke(bytesWritten: 0)

                    self.serializeSpoke()

                    // Necessary because transitioning from receiving to sending state
                    doWrite = true

                    return false
                } else {
                    newState = .receivingSpeak(
                        .message,
                        bytesToRead: bytesToRead
                    )

                    return true
                }
            }
        case .sendingSpoke(var bytesWritten):
            bytesWritten += numBytes
            if bytesWritten >= self.sendBuffer.count {
                newState = .advertising

                return nil
            } else {
                newState = .sendingSpoke(
                    bytesWritten: bytesWritten
                )

                return true
            }
        }
    }

    private func serializePing() {
        var delay: UInt64 = 0

        self.timeStartedSending = getCurrentTimeInNs()

        if let actualLastTimeStartedReceiving = self.lastTimeStartedReceiving {
            delay = self.timeStartedSending! - actualLastTimeStartedReceiving
        }

        BluetoothService.serializeMeasurementMessage(MeasurementMessage.with {
            $0.sequenceNumber = self.pingRoundIdx
            $0.initiatingPeerID = self.selfID
            $0.delayInNs = delay
        }, toBuffer: &self.tmpBuffer)

        BluetoothService.serializeLength(
            BluetoothService.LengthPrefixType(self.tmpBuffer.count),
            toBuffer: &self.sendBuffer
        )

        self.sendBuffer.append(self.tmpBuffer)
    }

    private func serializeSpoke() {
        BluetoothService.serializeProtocolMessage(DistanceProtocolWrapper.with {
            $0.type = .spoke(Spoke.with {
                $0.from = self.selfID
                $0.delayInNs = self.speakingDelay!
            })
        }, toBuffer: &self.tmpBuffer)

        BluetoothService.serializeLength(
            BluetoothService.LengthPrefixType(MemoryLayout<DistanceProtocolWrapper>.stride),
            toBuffer: &self.sendBuffer
        )

        self.sendBuffer.append(self.tmpBuffer)
    }

    private func setupPeripheral() {
        if self.state == nil {
            // Make sure we start in a clean state
            self.peripheralManager.removeAllServices()
            self.peripheralManager.stopAdvertising()
        }

        // Start with the CBMutableCharacteristic.
        // TODO: initialize the value to save a step and make things prettier
        let transferCharacteristic = CBMutableCharacteristic(
            type: BluetoothService.characteristicUUID,
            properties: [.read, .write, .notify, .writeWithoutResponse],
            value: nil,
            permissions: [.readable, .writeable]
        )
        
        // Create a service from the characteristic.
        let transferService = CBMutableService(type: BluetoothService.serviceUUID, primary: true)
        
        // Add the characteristic to the service.
        transferService.characteristics = [transferCharacteristic]
        
        // And add it to the peripheral manager.
        self.peripheralManager.add(transferService)
        
        // Save the characteristic for later.
        self.transferCharacteristic = transferCharacteristic

        self.beginAdvertising()
    }

    private func calcLatency(delay: UInt64) {
        guard let actualTimeStartedReceiving = self.timeStartedReceiving else {
            return
        }

        self.latency = BluetoothService.calcLatency(
            lastLatency: self.latency,
            lastPingRecvTimeInNS: self.timeStartedSending!,
            pingRecvTimeInNS: actualTimeStartedReceiving,
            delayAtPeripheralInNS: delay
        )
        #if DEBUG
        print("Latency: \(Double(self.latency!) / Double(NSEC_PER_MSEC))")
        #endif
    }

    #if DEBUG
    private func printState(_ message: String) {
        print("\(message) :: State: \(String(describing: self.state)); Send Buffer: \(String(describing: self.sendBuffer)); Read Buffer: \(String(describing: self.readBuffer))")
    }
    #endif
}

extension SpokePeripheral: CBPeripheralManagerDelegate {
    // implementations of the CBPeripheralManagerDelegate methods

    /*
     *  Required protocol method.  A full app should take care of all the possible states,
     *  but we're just waiting for to know when the CBPeripheralManager is ready
     *
     *  Starting from iOS 13.0, if the state is CBManagerStateUnauthorized, you
     *  are also required to check for the authorization state of the peripheral to ensure that
     *  your app is allowed to use bluetooth
     */
    internal func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            // ... so start working with the peripheral
            #if DEBUG
            print("CBManager is powered on")
            #endif
            self.setupPeripheral()
        case .poweredOff:
            #if DEBUG
            print("CBManager is not powered on")
            #endif
            // In a real app, you'd deal with all the states accordingly
            return
        case .resetting:
            #if DEBUG
            print("CBManager is resetting")
            #endif
            // In a real app, you'd deal with all the states accordingly
            return
        case .unauthorized:
            // In a real app, you'd deal with all the states accordingly
            if #available(iOS 13.0, *) {
                switch peripheral.authorization {
                case .denied:
                    #if DEBUG
                    print("You are not authorized to use Bluetooth")
                    #endif
                case .restricted:
                    #if DEBUG
                    print("Bluetooth is restricted")
                    #endif
                default:
                    #if DEBUG
                    print("Unexpected authorization")
                    #endif
                }
            } else {
                // Fallback on earlier versions
            }
            return
        case .unknown:
            #if DEBUG
            print("CBManager state is unknown")
            #endif
            // In a real app, you'd deal with all the states accordingly
            return
        case .unsupported:
            #if DEBUG
            print("Bluetooth is not supported on this device")
            #endif
            // In a real app, you'd deal with all the states accordingly
            return
        @unknown default:
            #if DEBUG
            print("A previously unknown peripheral manager state occurred")
            #endif
            // In a real app, you'd deal with yet unknown cases that might occur in the future
            return
        }
    }

    /*
     *  Catch when someone subscribes to our characteristic, then start sending them data
     */
    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        #if DEBUG
        print("Central subscribed to characteristic")
        #endif

        // save central
        self.connectedCentral = central
        // TODO: experiment with this
        peripheral.setDesiredConnectionLatency(.low, for: central)

        // setup state
        self.startProtocolWithCentral()

        // Start sending
        self.writeAnyData()
    }
    
    /*
     *  Recognize when the central unsubscribes
     */
    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        #if DEBUG
        print("Central unsubscribed from characteristic")
        #endif

        self.resetProtocol()
    }
    
    /*
     *  This callback comes in when the PeripheralManager is ready to send the next chunk of data.
     *  This is to ensure that packets will arrive in the order they are sent
     */
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        // Start sending again
        #if DEBUG
        print("peripheral manager ready to update subscribers")
        #endif
        self.writeAnyData()
    }
    
    /*
     * This callback comes in when the PeripheralManager received write to characteristics
     */
    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveWrite requests: [CBATTRequest]
    ) {
        for request in requests {
            guard let requestValue = request.value else {
                continue
            }

            self.readAnyData(requestValue.subdata(in: 0..<Int(requestValue.count)))
        }
    }
}
