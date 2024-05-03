//
//  SpeakTimerCentral.swift
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

class SpeakTimerCentral: NSObject, SpeakTimerDelegate {
    private enum State {
        enum LengthMessageState {
            case length, message
        }

        case discovered
        case receivingPing(
            CBCharacteristic?,
            LengthMessageState,
            bytesToRead: BluetoothService.LengthPrefixType,
            pingRoundIdx: UInt32,
            timeStartedReceivingLastPing: UInt64?,
            timeStartedReceivingCurrentPing: UInt64?
        )
        case sendingAck(
            CBCharacteristic?,
            LengthMessageState,
            bytesWritten: BluetoothService.LengthPrefixType,
            pingRoundIdx: UInt32,
            timeStartedReceivingCurrentPing: UInt64?,
            initiatingPeerID: Int64
        )
        case sendingSpeak(
            CBCharacteristic?,
            LengthMessageState,
            bytesWritten: BluetoothService.LengthPrefixType
        )
        case receivingSpoke(
            CBCharacteristic?,
            LengthMessageState,
            bytesToRead: BluetoothService.LengthPrefixType,
            timeStartedReceiving: UInt64?
        )
    }

    private struct PeripheralState {
        var protocolState: State
        var sendBuffer: Data
        var readBuffer: Data
    }

    private static let kEWMAFactor: Double = 0.875

    var latencyByPeer: [Int64:UInt64] = [:]

    var centralManager: CBCentralManager!
    var discoveredPeripherals: [CBPeripheral]
    private var discoveredPeripheralsState: [CBPeripheral:PeripheralState]
    var transferCharacteristics: [CBCharacteristic]?

    weak var distanceCalculator: (any DistanceCalculatorProtocol)?

    let expectedNumPingRoundsPerPeripheral: UInt

    ///  `numConnected` refers to the number of peers to which the central manager has connected,
    ///  while `numStarted` refers to the number of peers the protocol has started with. `numConnected`
    ///  will decrease as peers are cleaned up, while `numStarted` only increases up to the maximum
    ///  of `numConnected`. __`numConnected` and `expectedNumConnections` tell when
    ///  to stop scanning for new peripherals, while `numStarted` and `numDone` tell when the
    ///  protocol has finished for all peripherals.
    let expectedNumConnections: UInt
    var numConnected: UInt = 0

    let maxConnectionTries: UInt
    var connectionTries: UInt = 0

    var numStarted: UInt = 0
    var numDone: UInt = 0

    let connectedCallback: () -> Void
    let doneCallback: () -> Void

    required init(
        expectedNumPingRoundsPerPeripheral: UInt,
        expectedNumConnections: UInt,
        maxConnectionTries: UInt,
        distanceCalculator: any DistanceCalculatorProtocol,
        connectedCallback: @escaping () -> Void,
        doneCallback: @escaping () -> Void
    ) {
        self.expectedNumPingRoundsPerPeripheral = expectedNumPingRoundsPerPeripheral
        self.expectedNumConnections = expectedNumConnections
        self.maxConnectionTries = maxConnectionTries
        self.connectedCallback = connectedCallback
        self.doneCallback = doneCallback
        self.distanceCalculator = distanceCalculator
        self.centralManager = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    deinit {
        self.centralManager.stopScan()
        #if DEBUG
        print("Scanning stopped")
        #endif
    }

    // FIXME: -
    func sendSpeak() {
    }

    // MARK: - Helper Methods

    private func didDiscover(peripheral: CBPeripheral) {
        // Device is in range - have we already seen it?
        if !self.discoveredPeripherals.contains(where: { $0 == peripheral }) {
            // Save a local copy of the peripheral, so CoreBluetooth doesn't get rid of it.
            self.discoveredPeripherals.append(peripheral)
            self.discoveredPeripheralsState[peripheral] = PeripheralState(
                protocolState: .discovered,
                sendBuffer: Data(),
                readBuffer: Data()
            )
            
            #if DEBUG
            print("Connecting to peripheral \(peripheral)")
            #endif
            self.centralManager.connect(peripheral, options: nil)
            self.connectionTries += 1

            // Stop scanning if out of tries
            if self.connectionTries >= self.maxConnectionTries {
                self.centralManager.stopScan()
                #if DEBUG
                print("Scanning stopped with \(self.numConnected) out of \(self.expectedNumConnections) connections")
                #endif
            }
        }
    }

    private func didConnect(toPeripheral peripheral: CBPeripheral) {
        self.numConnected += 1

        // Stop scanning if reached expected number of peers
        if self.numConnected >= self.expectedNumConnections {
            self.centralManager.stopScan()
            #if DEBUG
            print("Scanning stopped with \(self.numConnected) out of \(self.expectedNumConnections) connections")
            #endif
        }

    }

    /*
     * We will first check if we are already connected to our counterpart
     * Otherwise, scan for peripherals - specifically for our service's 128bit CBUUID
     */
    private func retrievePeripherals() {
        let connectedPeripherals: [CBPeripheral] = (centralManager.retrieveConnectedPeripherals(withServices: [BluetoothService.serviceUUID]))

        guard !connectedPeripherals.isEmpty else {
            // If nothing's connected yet, start scanning
            centralManager.scanForPeripherals(withServices: [BluetoothService.serviceUUID],
                                              options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            return
        }

        #if DEBUG
        print("Found connected Peripherals with transfer service: \(connectedPeripherals)")
        #endif
        for connectedPeripheral in connectedPeripherals {
//            if self.discoveredPeripheralsState[connectedPeripheral] != nil {
                // Wait until characteristic is found to move out of discovered state
//                self.discoveredPeripheralsState[connectedPeripheral] = .discovered
//            }
            // Since other apps might be connected to the peripheral, apparently it's
            //   necessary to connect and associate the peripheral with this app
            // TODO: maybe `CBConnectPeripheralOptionEnableAutoReconnect
            self.centralManager.connect(connectedPeripheral)
        }
    }
    
    private func readAnyData(_ data: Data, fromPeripheral peripheral: CBPeripheral) {
        guard var peripheralState = self.discoveredPeripheralsState[peripheral] else {
            #if DEBUG
            print("Tried to call \(#function) without a state for peripheral \(String(describing: peripheral))")
            #endif
            return
        }

        // only do something for receiving states
        let bytesToRead: BluetoothService.LengthPrefixType
        let timeStartedReceiving: UInt64?

        switch peripheralState.protocolState {
        case .receivingPing(
            _,
            _,
            bytesToRead: let tmpBytesToRead,
            pingRoundIdx: _,
            timeStartedReceivingLastPing: _,
            timeStartedReceivingCurrentPing: let timeStartedReceivingCurrentPing
        ):
            bytesToRead = min(tmpBytesToRead, BluetoothService.LengthPrefixType(data.count))
            timeStartedReceiving = timeStartedReceivingCurrentPing ?? getCurrentTimeInNs()
        case .receivingSpoke(
            _,
            _,
            bytesToRead: let tmpBytesToRead,
            timeStartedReceiving: let timeStartedReceivingSpoke
        ):
            bytesToRead = min(tmpBytesToRead, BluetoothService.LengthPrefixType(data.count))
            timeStartedReceiving = timeStartedReceivingSpoke ?? getCurrentTimeInNs()
        default:
            return // Not in a state where writing is necessary
        }

        if bytesToRead > 0 {
            peripheralState.readBuffer.append(data.subdata(in: 0..<Int(bytesToRead)))
            let anotherReadRequired = (self.transitionStateForPeripheral(
                peripheral,
                numBytesReadOrWritten: bytesToRead,
                opStartTime: timeStartedReceiving
            ) ?? false)
            if anotherReadRequired {
                // TODO: make this a loop instead of recursion
                self.readAnyData(
                    data.suffix(from: Int(bytesToRead)),
                    fromPeripheral: peripheral
                )
            }
        }
    }

    private func writeAnyData(toPeripheral peripheral: CBPeripheral) {
        guard let peripheralState = self.discoveredPeripheralsState[peripheral] else {
            #if DEBUG
            print("Tried to call \(#function) without a state for peripheral \(String(describing: peripheral))")
            #endif
            return
        }

        // only do something for sending states
        let characteristic: CBCharacteristic?
        var bytesWritten: BluetoothService.LengthPrefixType

        switch peripheralState.protocolState {
        case .sendingAck(
            let tmpCharacteristic,
            _,
            bytesWritten: let tmpBytesWritten,
            pingRoundIdx: _,
            timeStartedReceivingCurrentPing: _,
            initiatingPeerID: _
        ):
            characteristic = tmpCharacteristic
            bytesWritten = tmpBytesWritten
        case .sendingSpeak(
            let tmpCharacteristic,
            _,
            bytesWritten: let tmpBytesWritten
        ):
            characteristic = tmpCharacteristic
            bytesWritten = tmpBytesWritten
        default:
            return // Not in a state where writing is necessary
        }

        // check to see if number of iterations completed and peripheral can accept more data
        while bytesWritten < peripheralState.sendBuffer.count &&
              peripheral.canSendWriteWithoutResponse {
            let mtu = peripheral.maximumWriteValueLength(for: .withoutResponse)

            let data = peripheralState.sendBuffer.suffix(from: Int(bytesWritten))
            var rawPacket = [UInt8]()
            let numBytesToWrite = min(mtu, data.count)
			data.copyBytes(to: &rawPacket, count: numBytesToWrite)
            let packetData = Data(bytes: &rawPacket, count: numBytesToWrite)

            peripheral.writeValue(packetData, for: characteristic!, type: .withoutResponse)

            bytesWritten += BluetoothService.LengthPrefixType(numBytesToWrite)
        }

        // this is confusing. If the result is nil, then it is coalesced
        // to `true` so that not `true`, i.e. `false`, says that
        // another write is _not_ required.
        let anotherWriteRequired = (self.transitionStateForPeripheral(
            peripheral,
            numBytesReadOrWritten: bytesWritten,
            opStartTime: nil
        ) ?? true)

        if peripheral.canSendWriteWithoutResponse && anotherWriteRequired {
            // TODO: make this a loop instead of recursion
            self.writeAnyData(toPeripheral: peripheral)
        }
    }

    private func startProtocolForPeripheral(
        _ peripheral: CBPeripheral,
        _ characteristic: CBCharacteristic
    ) {
        if self.numStarted == 0 {
            self.connectedCallback()
        }

        self.numStarted += 1
        self.discoveredPeripheralsState[peripheral] = PeripheralState(
            protocolState: .receivingPing(
                characteristic,
                .length,
                bytesToRead: BluetoothService.LengthPrefixType(BluetoothService.lengthPrefixSize),
                pingRoundIdx: 0,
                timeStartedReceivingLastPing: nil,
                timeStartedReceivingCurrentPing: nil
            ),
            sendBuffer: Data(),
            readBuffer: Data()
        )
    }

    private func finishProtocolForPeripheral(_ peripheral: CBPeripheral) {
        self.numDone += 1
        self.cleanup(discoveredPeripheral: peripheral)
        self.discoveredPeripheralsState[peripheral] = PeripheralState(
            protocolState: .discovered,
            sendBuffer: Data(),
            readBuffer: Data()
        )

        if self.numDone >= self.numStarted {
            self.doneCallback()
        }
    }

    private static func serializeLength(_ len: BluetoothService.LengthPrefixType, toBuffer buf: inout Data) {
        withUnsafeBytes(of: len) { rawBufPtr in
            #if DEBUG
            assert(rawBufPtr.count == BluetoothService.lengthPrefixSize)
            #endif
            buf = Data(bytes: rawBufPtr.baseAddress!, count: rawBufPtr.count)
        }
    }

    private static func serializeMeasurementMessage(_ message: MeasurementMessage, toBuffer buf: inout Data) {
        buf = try! message.serializedData()
    }

    private static func serializeProtocolMessage(_ message: DistanceProtocolWrapper, toBuffer buf: inout Data) {
        buf = try! message.serializedData()
    }

    private static func deserializeLength(fromBuffer buf: Data) -> BluetoothService.LengthPrefixType {
        var len: BluetoothService.LengthPrefixType = 0
        withUnsafeMutablePointer(to: &len) { ptr in
            buf.copyBytes(to: ptr, count: Int(BluetoothService.lengthPrefixSize))
        }
        return len
    }

    private static func deserializeMeasurementMessage(fromBuffer buf: Data) -> MeasurementMessage {
        return try! MeasurementMessage(serializedData: buf)
    }

    private static func deserializeProtocolMessage(fromBuffer buf: Data) -> DistanceProtocolWrapper {
        return try! DistanceProtocolWrapper(serializedData: buf)
    }

    // Returns whether the new state is a read (true) or write (false) state. Returns nil if done
    // TODO: this is a huge function
    private func transitionStateForPeripheral(
        _ peripheral: CBPeripheral,
        numBytesReadOrWritten numBytes: BluetoothService.LengthPrefixType,
        opStartTime: UInt64?
    ) -> Bool? {
        guard var peripheralState = self.discoveredPeripheralsState[peripheral] else {
            return nil
        }

        var newState = peripheralState.protocolState

        defer {
            peripheralState.protocolState = newState
            self.discoveredPeripheralsState[peripheral] = peripheralState
        }

        switch peripheralState.protocolState {
        case .discovered:
            // The only thing that can transition from this state is when the
            //   characteristic is discovered
            return nil
        case .receivingPing(
            let characteristic,
            let lengthMessageState,
            bytesToRead: var bytesToRead,
            pingRoundIdx: let pingRoundIdx,
            timeStartedReceivingLastPing: let timeStartedReceivingLastPing,
            timeStartedReceivingCurrentPing: let timeStartedReceivingCurrentPing
        ):
            bytesToRead -= numBytes
            switch lengthMessageState {
            case .length:
                if bytesToRead == 0 {
                    bytesToRead = Self.deserializeLength(fromBuffer: peripheralState.readBuffer)

                    newState = .receivingPing(
                        characteristic,
                        .message,
                        bytesToRead: bytesToRead,
                        pingRoundIdx: pingRoundIdx,
                        timeStartedReceivingLastPing: timeStartedReceivingLastPing,
                        timeStartedReceivingCurrentPing: timeStartedReceivingCurrentPing
                    )

                    return true
                } else {
                    newState = .receivingPing(
                        characteristic,
                        .length,
                        bytesToRead: bytesToRead,
                        pingRoundIdx: pingRoundIdx,
                        timeStartedReceivingLastPing: timeStartedReceivingLastPing,
                        timeStartedReceivingCurrentPing: timeStartedReceivingCurrentPing
                    )

                    return true
                }
            case .message:
                if bytesToRead == 0 {
                    let pingMessage = Self.deserializeMeasurementMessage(fromBuffer: peripheralState.readBuffer)

                    self.calcLatencyForPeer(
                        peer: pingMessage.initiatingPeerID,
                        lastPingRecvTimeInNS: timeStartedReceivingLastPing,
                        pingRecvTimeInNS: timeStartedReceivingCurrentPing!,
                        delayAtPeripheralInNS: pingMessage.delayInNs
                    )

                    Self.serializeLength(
                        BluetoothService.LengthPrefixType(MemoryLayout<MeasurementMessage>.stride),
                        toBuffer: &peripheralState.sendBuffer
                    )

                    newState = .sendingAck(
                        characteristic,
                        .length,
                        bytesWritten: 0,
                        pingRoundIdx: pingRoundIdx,
                        timeStartedReceivingCurrentPing: timeStartedReceivingCurrentPing,
                        initiatingPeerID: pingMessage.initiatingPeerID
                    )

                    return false
                } else {
                    newState = .receivingPing(
                        characteristic,
                        .message,
                        bytesToRead: bytesToRead,
                        pingRoundIdx: pingRoundIdx,
                        timeStartedReceivingLastPing: timeStartedReceivingLastPing,
                        timeStartedReceivingCurrentPing: timeStartedReceivingCurrentPing
                    )

                    return true
                }
            }
        case .sendingAck(
            let characteristic,
            let lengthMessageState,
            bytesWritten: var bytesWritten,
            pingRoundIdx: var pingRoundIdx,
            timeStartedReceivingCurrentPing: let timeStartedReceivingCurrentPing,
            initiatingPeerID: let initiatingPeerID
        ):
            bytesWritten += numBytes
            switch lengthMessageState {
            case .length:
                if bytesWritten >= BluetoothService.lengthPrefixSize {
                    Self.serializeMeasurementMessage(MeasurementMessage.with {
                        $0.sequenceNumber = pingRoundIdx
                        $0.initiatingPeerID = initiatingPeerID
                        $0.toPeer = initiatingPeerID
                        $0.delayInNs = getCurrentTimeInNs() - timeStartedReceivingCurrentPing!
                    }, toBuffer: &peripheralState.sendBuffer)

                    newState = .sendingAck(
                        characteristic,
                        .message,
                        bytesWritten: 0,
                        pingRoundIdx: pingRoundIdx,
                        timeStartedReceivingCurrentPing: timeStartedReceivingCurrentPing,
                        initiatingPeerID: initiatingPeerID
                    )

                    return false
                } else {
                    newState = .sendingAck(
                        characteristic,
                        .length,
                        bytesWritten: bytesWritten,
                        pingRoundIdx: pingRoundIdx,
                        timeStartedReceivingCurrentPing: timeStartedReceivingCurrentPing,
                        initiatingPeerID: initiatingPeerID
                    )

                    return false
                }
            case .message:
                if bytesWritten >= peripheralState.sendBuffer.count {
                    // Finished a round of ping-ack
                    pingRoundIdx += 1
                    if pingRoundIdx >= self.expectedNumPingRoundsPerPeripheral {
                        // transition to speaking
                        // TODO: maybe handle error
                        try! self.distanceCalculator?.listen()

                        Self.serializeLength(
                            BluetoothService.LengthPrefixType(MemoryLayout<DistanceProtocolWrapper>.stride),
                            toBuffer: &peripheralState.sendBuffer
                        )

                        newState = .sendingSpeak(characteristic, .length, bytesWritten: 0)

                        return false
                    } else {
                        newState = .receivingPing(
                            characteristic,
                            .length,
                            bytesToRead: BluetoothService.lengthPrefixSize,
                            pingRoundIdx: pingRoundIdx,
                            timeStartedReceivingLastPing: timeStartedReceivingCurrentPing,
                            timeStartedReceivingCurrentPing: nil
                        )

                        return true
                    }
                } else {
                    newState = .sendingAck(
                        characteristic,
                        .message,
                        bytesWritten: bytesWritten,
                        pingRoundIdx: pingRoundIdx,
                        timeStartedReceivingCurrentPing: timeStartedReceivingCurrentPing,
                        initiatingPeerID: initiatingPeerID
                    )

                    return false
                }
            }
        case .sendingSpeak(let characteristic, let lengthMessageState, bytesWritten: var bytesWritten):
            bytesWritten += numBytes
            switch lengthMessageState {
            case .length:
                if bytesWritten >= BluetoothService.lengthPrefixSize {
                    Self.serializeProtocolMessage(DistanceProtocolWrapper.with {
                        $0.type = .speak(Speak())
                    }, toBuffer: &peripheralState.sendBuffer)
                
                    newState = .sendingSpeak(characteristic, .message, bytesWritten: 0)

                    return false
                } else {
                    newState = .sendingSpeak(characteristic, .length, bytesWritten: bytesWritten)

                    return false
                }
            case .message:
                if bytesWritten >= peripheralState.sendBuffer.count {
                    newState = .receivingSpoke(
                        characteristic,
                        .length,
                        bytesToRead: BluetoothService.lengthPrefixSize,
                        timeStartedReceiving: nil
                    )

                    return true
                } else {
                    newState = .sendingSpeak(characteristic, .message, bytesWritten: bytesWritten)

                    return false
                }
            }
        case .receivingSpoke(
            let characteristic,
            let lengthMessageState,
            bytesToRead: var bytesToRead,
            timeStartedReceiving: let timeStartedReceiving
        ):
            bytesToRead -= numBytes
            switch lengthMessageState {
            case .length:
                if bytesToRead == 0 {
                    bytesToRead = Self.deserializeLength(fromBuffer: peripheralState.readBuffer)

                    newState = .receivingSpoke(
                        characteristic,
                        .message,
                        bytesToRead: bytesToRead,
                        timeStartedReceiving: timeStartedReceiving
                    )

                    return true
                } else {
                    newState = .receivingSpoke(
                        characteristic,
                        .length,
                        bytesToRead: bytesToRead,
                        timeStartedReceiving: timeStartedReceiving
                    )

                    return true
                }
            case .message:
                if bytesToRead == 0 {
                    let spokeMessage = Self.deserializeProtocolMessage(fromBuffer: peripheralState.readBuffer)

                    let peerLatency = self.latencyByPeer[spokeMessage.spoke.from]!
                    try! self.distanceCalculator?.heardPeerSpeak(
                        peer: spokeMessage.spoke.from,
                        recvTimeInNS: timeStartedReceiving!,
                        reportedSpeakingDelay: spokeMessage.spoke.delayInNs,
                        withOneWayLatency: peerLatency
                    )

                    newState = .discovered

                    return nil
                } else {
                    newState = .receivingSpoke(
                        characteristic,
                        .message,
                        bytesToRead: bytesToRead,
                        timeStartedReceiving: timeStartedReceiving
                    )

                    return true
                }
            }
        @unknown default:
            #if DEBUG
            print("You can't even keep track of the states in your own code. Sad.")
            #endif
            return nil
        }
    }

    // TODO: function can be optimized
    private func calcLatencyForPeer(
        peer: Int64,
        lastPingRecvTimeInNS lastRecvTime: UInt64?,
        pingRecvTimeInNS recvTime: UInt64,
        delayAtPeripheralInNS delay: UInt64
    ) {
        guard let actualLastRecvTime = lastRecvTime else {
            return
        }

        let estOneWayLatency = ((recvTime - actualLastRecvTime) - delay)
        let lastLatency = self.latencyByPeer[peer] ?? estOneWayLatency
        self.latencyByPeer[peer] =
            UInt64(Self.kEWMAFactor * Double(lastLatency)) + UInt64((1.0 - Self.kEWMAFactor) * Double(estOneWayLatency))
    }

    /*
     *  Call this when things either go wrong, or you're done with the connection.
     *  This cancels any subscriptions if there are any, or straight disconnects if not.
     *  (didUpdateNotificationStateForCharacteristic will cancel the connection if a subscription is involved)
     */
    private func cleanup(discoveredPeripheral: CBPeripheral) {
        guard discoveredPeripheral.state == .connected else {
            return
        }

        guard self.numConnected > 0 else {
            #if DEBUG
            print("Tried to clean up more times than connected")
            #endif
            return
        }

        for service in (discoveredPeripheral.services ?? [] as [CBService]) {
            for characteristic in (service.characteristics ?? [] as [CBCharacteristic]) {
                if characteristic.uuid == BluetoothService.characteristicUUID && characteristic.isNotifying {
                    // It is notifying, so unsubscribe
                    discoveredPeripheral.setNotifyValue(false, for: characteristic)
                }
            }
        }
        
        // If we've gotten this far, we're connected, but we're not subscribed, so we just disconnect
        centralManager.cancelPeripheralConnection(discoveredPeripheral)
        self.discoveredPeripheralsState[discoveredPeripheral] = PeripheralState(
            protocolState: .discovered,
            sendBuffer: Data(),
            readBuffer: Data()
        )
        self.discoveredPeripherals.removeAll(where: { $0 == discoveredPeripheral })
        self.numConnected -= 1
    }
}

extension SpeakTimerCentral: CBCentralManagerDelegate {
    internal func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            // ... so start working with the peripheral
            #if DEBUG
            print("CBManager is powered on")
            #endif
            self.retrievePeripherals()
        case .poweredOff:
            #if DEBUG
            print("CBManager is not powered on")
            #endif
            // FIXME: handle state
            return
        case .resetting:
            #if DEBUG
            print("CBManager is resetting")
            #endif
            // FIXME: handle state
            return
        case .unauthorized:
            // FIXME: handle state
            if #available(iOS 13.0, *) {
                switch central.authorization {
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
            // FIXME: handle state
            return
        case .unsupported:
            #if DEBUG
            print("Bluetooth is not supported on this device")
            #endif
            // FIXME: handle state
            return
        @unknown default:
            #if DEBUG
            print("A previously unknown central manager state occurred")
            #endif
            // FIXME: handle state
            return
        }
    }

    /*
     *  This callback comes whenever a peripheral that is advertising the transfer serviceUUID is discovered.
     *  We check the RSSI, to make sure it's close enough that we're interested in it, and if it is,
     *  we start the connection process
     */
    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        
        // Reject if the signal strength is too low to attempt data transfer.
        // Change the minimum RSSI value depending on your app’s use case.
        guard RSSI.intValue >= BluetoothService.rssiDiscoveryThresh else {
                #if DEBUG
                print(String(format: "Discovered peripheral not in expected range, at %d", RSSI.intValue))
                #endif
                return
        }

        #if DEBUG
        print(String(format: "Discovered %s at %d", String(describing: peripheral.name), RSSI.intValue))
        #endif

        self.didDiscover(peripheral: peripheral)
    }

    /*
     *  If the connection fails for whatever reason, we need to deal with it.
     */
    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        #if DEBUG
        print("Failed to connect to \(peripheral): \(String(describing: error))")
        #endif
        self.cleanup(discoveredPeripheral: peripheral)
    }
    
    /*
     *  We've connected to the peripheral, now we need to discover the services and characteristics to find the 'transfer' characteristic.
     */
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        #if DEBUG
        print("Peripheral Connected")
        #endif

        // Make sure we get the discovery callbacks
        peripheral.delegate = self

        // Search only for services that match our UUID
        peripheral.discoverServices([BluetoothService.serviceUUID])

        self.didConnect(toPeripheral: peripheral)
    }

    /*
     *  Once the disconnection happens, we need to clean up our local copy of the peripheral
     */
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        #if DEBUG
        print("Perhiperal \(peripheral) disconnected")
        #endif
        self.cleanup(discoveredPeripheral: peripheral)
        
        // Try retrieving peripherals again
        self.retrievePeripherals()
    }

}

extension SpeakTimerCentral: CBPeripheralDelegate {
    // implementations of the CBPeripheralDelegate methods

    /*
     *  The peripheral letting us know when services have been invalidated.
     */
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        for service in invalidatedServices where service.uuid == BluetoothService.serviceUUID {
            #if DEBUG
            print("Transfer service is invalidated - rediscover services")
            #endif

            peripheral.discoverServices([BluetoothService.serviceUUID])
        }
    }

    /*
     *  The Transfer Service was discovered
     */
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            #if DEBUG
            print("Error discovering services: \(error.localizedDescription)")
            #endif
            self.cleanup(discoveredPeripheral: peripheral)
            return
        }

        // Discover the characteristic we want...
        // Loop through the newly filled peripheral.services array, just in case there's more than one.
        guard let peripheralServices = peripheral.services else { return }
        for service in peripheralServices {
            peripheral.discoverCharacteristics([BluetoothService.characteristicUUID], for: service)
        }
    }

    /*
     *  The Transfer characteristic was discovered.
     *  Once this has been found, we want to subscribe to it, which lets the peripheral know we want the data it contains
     */
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        // Deal with errors (if any).
        if let error = error {
            #if DEBUG
            print("Error discovering characteristics: \(error.localizedDescription)")
            #endif
            self.cleanup(discoveredPeripheral: peripheral)
            return
        }

        guard let peripheralState = self.discoveredPeripheralsState[peripheral] else {
            #if DEBUG
            // This implies that CB disagrees with self about whether the peer is discovered
            print("\(#function): Could not find state for peripheral \(String(describing: peripheral)) with discovered characteristic")
            #endif
            return
        }

        // Again, we loop through the array, just in case and check if it's the right one
        guard let serviceCharacteristics = service.characteristics else { return }
        for characteristic in serviceCharacteristics where characteristic.uuid == BluetoothService.characteristicUUID {
            // If it is, subscribe to it and start the protocol
            self.startProtocolForPeripheral(peripheral, characteristic)
            peripheral.setNotifyValue(true, for: characteristic)
        }
        
        // Once this is complete, we just need to wait for the data to come in.
    }
    
    /*
     *   This callback lets us know more data has arrived via notification on the characteristic
     */
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // Deal with errors (if any)
        if let error = error {
            #if DEBUG
            print("Error discovering characteristics: \(error.localizedDescription)")
            #endif
            self.cleanup(discoveredPeripheral: peripheral)
            return
        }
        
        guard let characteristicData = characteristic.value else {
            return
        }

        self.readAnyData(characteristicData, fromPeripheral: peripheral)
    }

    /*
     *  The peripheral letting us know whether our subscribe/unsubscribe happened or not
     */
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        // Deal with errors (if any)
        if let error = error {
            #if DEBUG
            print("Error changing notification state: \(error.localizedDescription)")
            #endif
            return
        }

        // Exit if it's not the transfer characteristic
        guard characteristic.uuid == BluetoothService.characteristicUUID else { return }

        if characteristic.isNotifying {
            // Notification has started
            #if DEBUG
            print(String(format: "Notification began on %@", characteristic))
            #endif
        } else {
            // Notification has stopped, so disconnect from the peripheral
            #if DEBUG
            print(String(format: "Notification stopped on %@. Disconnecting", characteristic))
            #endif
            self.cleanup(discoveredPeripheral: peripheral)
        }
    }
    
    /*
     *  This is called when peripheral is ready to accept more data when using write without response
     */
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        self.writeAnyData(toPeripheral: peripheral)
    }
}
