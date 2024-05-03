//
//  SpokePeripheral.swift
//  AudienceInstrument
//
//  Created by Andrew Orals on 4/28/24.
//

import Foundation
import CoreBluetooth

class SpokePeripheral: NSObject, SpokeDelegate {
    private enum State {
        enum LengthMessageState {
            case length, message
        }

        case advertising
        case sendingPing(LengthMessageState, bytesWritten: BluetoothService.LengthPrefixType)
        case receivingAck(LengthMessageState, bytesToRead: BluetoothService.LengthPrefixType)
        case receivingSpeak(LengthMessageState, bytesToRead: BluetoothService.LengthPrefixType)
        case sendingSpoke(LengthMessageState, bytesWritten: BluetoothService.LengthPrefixType)
    }

    private var sendBuffer: Data!
    private var readBuffer: Data!
    private var state: State? = nil

    private let numPingRounds: UInt
    private var pingRoundIdx: UInt32 = 0
    private var timeStartedSending: UInt64? = nil
    private var timeStartedReceiving: UInt64? = nil
    private var speakingDelay: UInt64? = nil
    private var latency: UInt64? = nil

    private let selfID: DistanceManager.PeerID
    private var peripheralManager: CBPeripheralManager!
    private var transferCharacteristic: CBMutableCharacteristic? = nil
    private var connectedCentral: CBCentral? = nil

    private weak var distanceCalculator: (any DistanceCalculatorProtocol)?
    private weak var updateDelegate: (any SpokeDelegateUpdateDelegate)?

    required init(
        selfID: DistanceManager.PeerID,
        distanceCalculator: any DistanceCalculatorProtocol,
        numPingRounds: UInt,
        updateDelegate: any SpokeDelegateUpdateDelegate
    ) {
        self.selfID = selfID
        self.distanceCalculator = distanceCalculator
        self.numPingRounds = numPingRounds
        self.updateDelegate = updateDelegate
    }

    deinit {
        if self.state != nil {
            self.resetProtocol()
        }
    }

    func beginAdvertising() {
        // All we advertise is our service's UUID.
        peripheralManager.startAdvertising(
            [CBAdvertisementDataServiceUUIDsKey: [BluetoothService.serviceUUID]]
        )

        self.state = .advertising
    }

    // MARK: - Helper Methods

    private func startProtocolWithCentral() {
        self.state = .sendingPing(
            .length,
            bytesWritten: 0
        )

        BluetoothService.serializeLength(
            BluetoothService.LengthPrefixType(MemoryLayout<MeasurementMessage>.stride),
            toBuffer: &self.sendBuffer
        )
    }

    private func resetProtocol() {
        self.state = nil
        self.connectedCentral = nil
        self.pingRoundIdx = 0
        self.timeStartedSending = nil
        self.timeStartedReceiving = nil
        self.latency = nil
        self.peripheralManager.stopAdvertising()
    }

    private func readAnyData(_ data: Data) {
        guard let actualState = self.state else {
            #if DEBUG
            print("Tried to call \(#function) without a state")
            #endif
            return
        }

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
            return // Not in a state where writing is necessary
        }

        if bytesToRead > 0 {
            self.readBuffer.append(data.subdata(in: 0..<Int(bytesToRead)))
        }
        
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

        // only do something for sending states
        var bytesWritten: BluetoothService.LengthPrefixType

        switch actualState {
        case .sendingPing (
            _,
            bytesWritten: let tmpBytesWritten
        ):
            bytesWritten = tmpBytesWritten
        case .sendingSpoke(
            _,
            bytesWritten: let tmpBytesWritten
        ):
            bytesWritten = tmpBytesWritten
        default:
            return // Not in a state where writing is necessary
        }

        var didSend = true
        while didSend && bytesWritten < self.sendBuffer.count {
            let mtu = actualConnectedCentral.maximumUpdateValueLength
            let numBytesToWrite = min(self.sendBuffer.count, mtu)

            let data = self.sendBuffer.suffix(from: Int(bytesWritten))
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
                break
            }

            bytesWritten += BluetoothService.LengthPrefixType(numBytesToWrite)
        }

        let anotherWriteRequired = (self.transitionState(
            numBytesReadOrWritten: bytesWritten
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

        defer {
            self.state = newState
        }

        switch actualState {
        case .advertising:
            // FIXME: figure out what the initial state should be
            return nil
        case .sendingPing(let lengthMessageState, var bytesWritten):
            bytesWritten += numBytes
            switch lengthMessageState {
            case .length:
                if bytesWritten >= BluetoothService.lengthPrefixSize {
                    var delay: UInt64 = 0

                    if let actualTimeStartedReceiving = self.timeStartedReceiving {
                        delay = getCurrentTimeInNs() - actualTimeStartedReceiving
                    }

                    BluetoothService.serializeMeasurementMessage(MeasurementMessage.with {
                        $0.sequenceNumber = self.pingRoundIdx
                        $0.initiatingPeerID = self.selfID
                        $0.delayInNs = delay
                    }, toBuffer: &self.sendBuffer)

                    newState = .sendingPing(
                        .message,
                        bytesWritten: 0
                    )

                    self.timeStartedSending = getCurrentTimeInNs()

                    return true
                } else {
                    newState = .sendingPing(
                        .length,
                        bytesWritten: bytesWritten
                    )

                    return true
                }
            case .message:
                if bytesWritten >= self.sendBuffer.count {
                    newState = .receivingAck(
                        .length,
                        bytesToRead: BluetoothService.LengthPrefixType(
                            MemoryLayout<DistanceProtocolWrapper>.stride
                        )
                    )

                    return false
                } else {
                    newState = .sendingPing(
                        .message,
                        bytesWritten: bytesWritten
                    )

                    return true
                }
            }
        case .receivingAck(let lengthMessageState, var bytesToRead):
            bytesToRead -= numBytes
            switch lengthMessageState {
            case .length:
                if bytesToRead == 0 {
                    bytesToRead = BluetoothService.deserializeLength(
                        fromBuffer: self.readBuffer
                    )

                    newState = .receivingAck(
                        .message,
                        bytesToRead: bytesToRead
                    )

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

                    let message = BluetoothService.deserializeMeasurementMessage(
                        fromBuffer: self.readBuffer
                    )

                    self.calcLatency(delay: message.delayInNs)

                    if pingRoundIdx >= self.numPingRounds {
                        // transition to speaking
                        newState = .receivingSpeak(
                            .length,
                            bytesToRead: BluetoothService.LengthPrefixType(
                                MemoryLayout<DistanceProtocolWrapper>.stride
                            )
                        )

                        return true
                    } else {
                        newState = .sendingPing(
                            .length,
                            bytesWritten: 0
                        )

                        BluetoothService.serializeLength(
                            BluetoothService.LengthPrefixType(MemoryLayout<MeasurementMessage>.stride),
                            toBuffer: &self.sendBuffer
                        )

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
                    bytesToRead = BluetoothService.deserializeLength(fromBuffer: self.readBuffer)
                    newState = .receivingSpeak(.message, bytesToRead: bytesToRead)

                    self.speakingDelay = try! self.distanceCalculator?.speak(
                        receivedAt: getCurrentTimeInNs()
                    )

                    self.updateDelegate?.receivedSpeakMessage()

                    return true
                } else {
                    newState = .receivingSpeak(.length, bytesToRead: bytesToRead)
                    return true
                }
            case .message:
                if bytesToRead == 0 {
                    let _ = BluetoothService.deserializeProtocolMessage(
                        fromBuffer: self.readBuffer
                    )

                    newState = .sendingSpoke(.length, bytesWritten: 0)

                    BluetoothService.serializeLength(
                        BluetoothService.LengthPrefixType(MemoryLayout<DistanceProtocolWrapper>.stride),
                        toBuffer: &self.sendBuffer
                    )

                    return false
                } else {
                    newState = .receivingSpeak(
                        .message,
                        bytesToRead: bytesToRead
                    )

                    return true
                }
            }
        case .sendingSpoke(let lengthMessageState, var bytesWritten):
            bytesWritten += numBytes
            switch lengthMessageState {
            case .length:
                if bytesWritten >= BluetoothService.lengthPrefixSize {
                    BluetoothService.serializeProtocolMessage(DistanceProtocolWrapper.with {
                        $0.type = .spoke(Spoke.with {
                            $0.from = self.selfID
                            $0.delayInNs = self.speakingDelay!
                        })
                    }, toBuffer: &self.sendBuffer)

                    newState = .sendingSpoke(
                        .message,
                        bytesWritten: 0
                    )

                    return true
                } else {
                    newState = .sendingSpoke(
                        .length,
                        bytesWritten: bytesWritten
                    )

                    return true
                }
            case .message:
                if bytesWritten >= self.sendBuffer.count {
                    newState = .advertising

                    return nil
                } else {
                    newState = .sendingSpoke(
                        .message,
                        bytesWritten: bytesWritten
                    )

                    return true
                }
            }
        }
    }

    private func setupPeripheral() {
        // Start with the CBMutableCharacteristic.
        let transferCharacteristic = CBMutableCharacteristic(
            type: BluetoothService.characteristicUUID,
            properties: [.notify, .writeWithoutResponse],
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
    }

    private func calcLatency(delay: UInt64) {
        guard let actualTimeStartedReceiving = self.timeStartedReceiving else {
            return
        }

        self.latency = BluetoothService.calcLatency(
            lastLatency: self.latency,
            lastPingRecvTimeInNS: actualTimeStartedReceiving,
            pingRecvTimeInNS: self.timeStartedSending!,
            delayAtPeripheralInNS: delay
        )
    }
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

            self.readAnyData(requestValue)
        }
    }
}
