//
//  SpeakTimerCentral.swift
//  AudienceInstrument
//
//  Created by Andrew Orals on 4/28/24.
//

import Foundation
import CoreBluetooth

class SpeakTimerCentral: NSObject, SpeakTimerDelegate {
    private enum State {
        enum LengthMessageState {
            case length, message
        }

        // TODO: instead of measuring receive <-> receive, measure receive <-> send
        case discovered(DistanceManager.PeerID)
        case subscribed(CBCharacteristic)
        case receivingPing(
            CBCharacteristic?,
            LengthMessageState,
            bytesToRead: BluetoothService.LengthPrefixType,
            timeStartedReceivingLastPing: UInt64?,
            timeStartedReceivingCurrentPing: UInt64?
        )
        case sendingAck(
            CBCharacteristic?,
            bytesWritten: BluetoothService.LengthPrefixType,
            pingRoundIdx: UInt32,
            timeStartedReceivingCurrentPing: UInt64?,
            initiatingPeerID: DistanceManager.PeerID
        )
        case sendingSpeak(
            CBCharacteristic?,
            bytesWritten: BluetoothService.LengthPrefixType,
            timeStartedSendingSpeak: UInt64?
        )
        case receivingSpoke(
            CBCharacteristic?,
            LengthMessageState,
            bytesToRead: BluetoothService.LengthPrefixType,
            timeStartedSendingSpeak: UInt64,
            timeStartedReceiving: UInt64?
        )
    }

    private struct PeripheralBuffers {
        var sendBuffer: Data = Data(capacity: BluetoothService.bufSize)
        var readBuffer: Data = Data(capacity: BluetoothService.bufSize)
        var tmpBuffer: Data = Data(capacity: BluetoothService.bufSize)
    }

    private let selfID: DistanceManager.PeerID

    var reconnectablePeersOwned: [DistanceManager.PeerID] = []
    var latencyByPeer: [DistanceManager.PeerID:UInt64] = [:]

    var centralManager: CBCentralManager!
    var discoveredPeripherals: [CBPeripheral] = []
    private var discoveredPeripheralsState: [CBPeripheral:State] = [:]
    private var discoveredPeripheralsBuffers: [CBPeripheral:PeripheralBuffers] = [:]
    var transferCharacteristics: [CBCharacteristic]?

    weak var distanceCalculator: (any DistanceCalculatorProtocol)?

    var expectedNumPingRoundsPerPeripheral: UInt = 0

    var expectedNumSubscriptions: UInt = 0
    var numSubscribed: UInt = 0
    var numDone: UInt = 0

    var maxConnectionTries: UInt = 0
    var connectionTries: UInt = 0

    private weak var updateDelegate: (any SpeakTimerDelegateUpdateDelegate)?

    required init(selfID: DistanceManager.PeerID) {
        self.selfID = selfID
        super.init()
    }

    deinit {
        if centralManager.isScanning {
            self.resetProtocol()
        }
    }

    func registerDistanceCalculator(distanceCalculator: any DistanceCalculatorProtocol) {
        self.distanceCalculator = distanceCalculator
    }

    func registerUpdateDelegate(updateDelegate: any SpeakTimerDelegateUpdateDelegate) {
        self.updateDelegate = updateDelegate
    }

    func setup(
        expectedNumPingRoundsPerPeripheral: UInt,
        expectedNumConnections: UInt,
        maxConnectionTries: UInt
    ) {
        if self.centralManager == nil {
            self.centralManager = CBCentralManager(
                delegate: self,
                queue: nil,
                options: [CBCentralManagerOptionShowPowerAlertKey: true]
            )
            self.expectedNumPingRoundsPerPeripheral = expectedNumPingRoundsPerPeripheral
            self.expectedNumSubscriptions = expectedNumConnections
            self.maxConnectionTries = maxConnectionTries
        }
    }

    func startProtocol() {
        #if DEBUG
        print("Starting protocol")
        #endif

        // TODO: maybe handle error
        try! self.distanceCalculator?.listen()

        for peripheral in discoveredPeripherals {
            self.startProtocolForPeripheral(peripheral)
        }
    }

    func resetProtocol() {
        if let actualCentralManager = self.centralManager {
            actualCentralManager.stopScan()
            #if DEBUG
            print("Scanning stopped")
            #endif
        }
        self.centralManager = nil
        self.reconnectablePeersOwned.removeAll()
        self.latencyByPeer = [:]
        self.discoveredPeripherals = []
        self.discoveredPeripheralsState = [:]
        self.transferCharacteristics = []
        self.expectedNumPingRoundsPerPeripheral = 0
        self.expectedNumSubscriptions = 0
        self.numSubscribed = 0
        self.maxConnectionTries = 0
        self.connectionTries = 0
        self.numDone = 0
    }

// MARK: - Helper Functions

    // MARK: - discovery phase: this is called from setup
    /*
     * We will first check if we are already connected to our counterpart
     * Otherwise, scan for peripherals - specifically for our service's 128bit CBUUID
     */
    private func retrievePeripherals() {
        #if DEBUG
        print("Retrieving peripherals")
        guard maxConnectionTries != 0 else {
            fatalError("Must call `setup` before retrieving peripherals")
        }
        #endif

        let connectedPeripherals: [CBPeripheral] = (centralManager.retrieveConnectedPeripherals(withServices: [BluetoothService.serviceUUID]))

        guard !connectedPeripherals.isEmpty else {
            // If nothing's connected yet, start scanning
            centralManager.scanForPeripherals(
                withServices: [BluetoothService.serviceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
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


    private func didDiscover(peripheral: CBPeripheral, peerID: DistanceManager.PeerID) {
        // Device is in range - have we already seen it?
        if !self.discoveredPeripherals.contains(where: { $0 == peripheral }) {
            // Save a local copy of the peripheral, so CoreBluetooth doesn't get rid of it.
            self.discoveredPeripherals.append(peripheral)
            self.discoveredPeripheralsState[peripheral] = .discovered(peerID)

            #if DEBUG
            print("Connecting to peripheral \(peripheral)")
            #endif
            self.centralManager.connect(peripheral, options: nil)
            self.connectionTries += 1

            // Stop scanning if out of tries
            if self.connectionTries >= self.maxConnectionTries {
                self.stopScanning()
                self.updateDelegate?.error(message: "SpeakTimerCentral Ran out of connection tries")
                #if DEBUG
                print("Scanning stopped with \(self.numSubscribed) out of \(self.expectedNumSubscriptions) connections")
                #endif
            }
        }
    }

    private func stopScanning() {
        if self.centralManager.isScanning {
            self.centralManager.stopScan()
            #if DEBUG
            print("Scanning stopped with \(self.numSubscribed) out of \(self.expectedNumSubscriptions) connections")
            #endif
        }
    }

    // MARK: - connection phase: This happens automatically when discovering a peripheral
    private func didConnect(peripheral: CBPeripheral) {
        #if DEBUG
        print("\(#function) called with \(String(describing: peripheral))")
        #endif

        guard let state = self.discoveredPeripheralsState[peripheral],
              case .discovered(_) = state else {
            fatalError("\(#function) called with peripheral not discovered yet.")
        }

        // Make sure we get the discovery callbacks
        peripheral.delegate = self

        // Search only for services that match our UUID
        peripheral.discoverServices([BluetoothService.serviceUUID])
    }

    // MARK: - ready to subscribe: After the peripheral is connected, characteristics are discovered so that the client can start the protocol immediately
    private func didDiscoverCharacteristic(
        _ characteristic: CBCharacteristic,
        forPeripheral peripheral: CBPeripheral
    ) {
        guard let state = self.discoveredPeripheralsState[peripheral],
              case .discovered(let peerID) = state else {
            #if DEBUG
            fatalError("Tried to subscribe to peripheral not in connected state.")
            #else
            return
            #endif
        }

        #if DEBUG
        if self.updateDelegate == nil {
            fatalError("Running \(#function) without an update delegate")
        }
        #endif

        let connectContinuation: (Bool) -> Void = { shouldConnect in
            if shouldConnect {
                #if DEBUG
                print("Allowed peripheral connection")
                #endif

                self.reconnectablePeersOwned.append(peerID)
                // Ready to start protocol
                self.discoveredPeripheralsState[peripheral] = .subscribed(characteristic)
                self.discoveredPeripheralsBuffers[peripheral] = PeripheralBuffers()
            } else {
                #if DEBUG
                print("Denied peripheral connection")
                #endif
                self.removePeripheral(withPeripheral: peripheral)
            }
        }

        if self.reconnectablePeersOwned.contains(peerID) {
            connectContinuation(true)
        } else {
            self.updateDelegate!.shouldConnectToPeer(peer: peerID, completion: connectContinuation)
        }
    }

    // MARK: - subscribed: Called from client with `startProtocol` to start the protocol
    private func startProtocolForPeripheral(
        _ peripheral: CBPeripheral
    ) {
        #if DEBUG
        print("Starting protocol for peripheral: \(String(describing: peripheral))")
        #endif

        guard let state = self.discoveredPeripheralsState[peripheral],
              case .subscribed(let characteristic) = state else {
            #if DEBUG
            print("Tried to start protocol for peripheral not in connected state.")
            #endif
            return
        }

        self.subscribeToCharacteristic(atPeripheral: peripheral, characteristic)

        self.stopScanning()
        self.discoveredPeripheralsState[peripheral] = .receivingPing(
            characteristic,
            .length,
            bytesToRead: BluetoothService.LengthPrefixType(BluetoothService.lengthPrefixSize),
            timeStartedReceivingLastPing: nil,
            timeStartedReceivingCurrentPing: nil
        )

        if let characteristicData = characteristic.value {
            self.readAnyData(characteristicData.subdata(in: 0..<characteristicData.count), fromPeripheral: peripheral)
        }
    }

    private func subscribeToCharacteristic(
        atPeripheral peripheral: CBPeripheral,
        _ characteristic: CBCharacteristic
    ) {
        // Subscribe
        peripheral.setNotifyValue(true, for: characteristic)

        // TODO: might need an ID associated with the session
        self.numSubscribed += 1

        // Stop scanning if reached expected number of peers
        if self.numSubscribed >= self.expectedNumSubscriptions {
            self.stopScanning()
        }
    }

    // MARK: - Finish the protocol: Called from state machine
    private func finishProtocolForPeripheral(_ peripheral: CBPeripheral) {
        #if DEBUG
        print("Finishing protocol for peripheral: \(String(describing: peripheral))")
        #endif

        self.numDone += 1
        self.cleanup(discoveredPeripheral: peripheral)

        if self.numDone >= self.numSubscribed {
            self.updateDelegate?.done()
        }
    }

// MARK: - read and write functions

    private func readAnyData(_ data: Data, fromPeripheral peripheral: CBPeripheral) {
        guard let state = self.discoveredPeripheralsState[peripheral],
              var buffers = self.discoveredPeripheralsBuffers[peripheral] else {
            #if DEBUG
            print("Tried to call \(#function) without a state for peripheral \(String(describing: peripheral))")
            #endif
            return
        }

        #if DEBUG
        self.printState(forPeripheral: peripheral, "\(#function)")
        #endif

        // only do something for receiving states
        let bytesToRead: BluetoothService.LengthPrefixType
        let timeStartedReceiving: UInt64?

        switch state {
        case .receivingPing(
            _,
            _,
            bytesToRead: let tmpBytesToRead,
            timeStartedReceivingLastPing: _,
            timeStartedReceivingCurrentPing: let timeStartedReceivingCurrentPing
        ):
            bytesToRead = min(tmpBytesToRead, BluetoothService.LengthPrefixType(data.count))
            timeStartedReceiving = timeStartedReceivingCurrentPing ?? getCurrentTimeInNs()
        case .receivingSpoke(
            _,
            _,
            bytesToRead: let tmpBytesToRead,
            timeStartedSendingSpeak: let _,
            timeStartedReceiving: let timeStartedReceivingSpoke
        ):
            bytesToRead = min(tmpBytesToRead, BluetoothService.LengthPrefixType(data.count))
            timeStartedReceiving = timeStartedReceivingSpoke ?? getCurrentTimeInNs()
        default:
            return // Not in a state where writing is necessary
        }

        guard Int(bytesToRead) <= data.count else {
            #if DEBUG
            print("\(#function): Waiting for another notification because not enough data in buffer. Buffer size: \(data.count)")
            #endif
            return
        }

        if bytesToRead > 0 {
            buffers.readBuffer.append(data.prefix(Int(bytesToRead)))
        }

        self.transitionStateForPeripheral(
            peripheral,
            currPeripheralState: state,
            currPeripheralBuffers: &buffers,
            numBytesReadOrWritten: bytesToRead,
            opStartTime: timeStartedReceiving,
            readBuffer: data
        )
    }

    private func writeAnyData(toPeripheral peripheral: CBPeripheral) {
        guard let state = self.discoveredPeripheralsState[peripheral],
              var buffers = self.discoveredPeripheralsBuffers[peripheral] else {
            #if DEBUG
            print("Tried to call \(#function) without a state for peripheral \(String(describing: peripheral))")
            #endif
            return
        }

        #if DEBUG
        self.printState(forPeripheral: peripheral, "\(#function)")
        #endif

        // only do something for sending states
        let characteristic: CBCharacteristic?
        let bufBytesWritten: BluetoothService.LengthPrefixType
        var timeStartedSending: UInt64? = nil

        switch state {
        case .sendingAck(
            let tmpCharacteristic,
            bytesWritten: let tmpBytesWritten,
            pingRoundIdx: _,
            timeStartedReceivingCurrentPing: _,
            initiatingPeerID: _
        ):
            characteristic = tmpCharacteristic
            bufBytesWritten = tmpBytesWritten
        case .sendingSpeak(
            let tmpCharacteristic,
            bytesWritten: let tmpBytesWritten,
            timeStartedSendingSpeak: let timeStartedSendingSpeak
        ):
            characteristic = tmpCharacteristic
            bufBytesWritten = tmpBytesWritten
            timeStartedSending = timeStartedSendingSpeak ?? getCurrentTimeInNs()
        default:
            return // Not in a state where writing is necessary
        }

        // check to see if done writing bytes and peripheral can accept more data
        var bytesWritten: Int = 0
        let maxBytesToWrite = buffers.sendBuffer.count - Int(bufBytesWritten)
        while bytesWritten < maxBytesToWrite &&
              peripheral.canSendWriteWithoutResponse {
            let mtu = peripheral.maximumWriteValueLength(for: .withoutResponse)

            let data = buffers.sendBuffer.suffix(from: Int(bufBytesWritten) + bytesWritten)
            let numBytesToWrite = min(mtu, maxBytesToWrite - bytesWritten)
            var rawPacket = [UInt8]()
			data.copyBytes(to: &rawPacket, count: numBytesToWrite)
            let packetData = Data(bytes: &rawPacket, count: numBytesToWrite)

            peripheral.writeValue(packetData, for: characteristic!, type: .withoutResponse)

            bytesWritten += numBytesToWrite
        }

        self.transitionStateForPeripheral(
            peripheral,
            currPeripheralState: state,
            currPeripheralBuffers: &buffers,
            numBytesReadOrWritten: BluetoothService.LengthPrefixType(bytesWritten),
            opStartTime: timeStartedSending,
            canSendWrite: peripheral.canSendWriteWithoutResponse
        )
    }

// MARK: - state machine

    // Returns true if action (read or write) needs to be repeated. Returns nil if done.
    // TODO: this is a huge function
    private func transitionStateForPeripheral(
        _ peripheral: CBPeripheral,
        currPeripheralState state: State,
        currPeripheralBuffers buffers: inout PeripheralBuffers,
        numBytesReadOrWritten numBytes: BluetoothService.LengthPrefixType,
        opStartTime: UInt64?,
        readBuffer: Data? = nil,
        canSendWrite: Bool = false
    ) {
        var newState = state
        enum NextStateAction {
            case read, write
        }
        var nextStateAction: NextStateAction? = nil

        defer {
            #if DEBUG
            print("Transitioning peripheral \(String(describing: peripheral)) from state \(String(describing: state)) to state \(String(describing: newState))")
            #endif

            self.discoveredPeripheralsState[peripheral] = newState
            self.discoveredPeripheralsBuffers[peripheral] = buffers

            switch nextStateAction {
            case .none:
                break
            case .some(.read):
                self.readAnyData(
                    readBuffer!.suffix(
                        from: Data.Index(numBytes)
                    ),
                    fromPeripheral: peripheral
                )
            case .some(.write):
                self.writeAnyData(toPeripheral: peripheral)
            }
        }

        switch state {
        case .discovered, .subscribed(_):
            return
        case .receivingPing(
            let characteristic,
            let lengthMessageState,
            bytesToRead: var bytesToRead,
            timeStartedReceivingLastPing: let timeStartedReceivingLastPing,
            timeStartedReceivingCurrentPing: var timeStartedReceivingCurrentPing
        ):
            bytesToRead -= numBytes

            if timeStartedReceivingCurrentPing == nil {
                timeStartedReceivingCurrentPing = opStartTime!
            }

            switch lengthMessageState {
            case .length:
                if bytesToRead == 0 {
                    bytesToRead = BluetoothService.deserializeLength(
                        fromBuffer: buffers.readBuffer[
                            0..<Data.Index(BluetoothService.lengthPrefixSize)
                        ]
                    )

                    newState = .receivingPing(
                        characteristic,
                        .message,
                        bytesToRead: bytesToRead,
                        timeStartedReceivingLastPing: timeStartedReceivingLastPing,
                        timeStartedReceivingCurrentPing: timeStartedReceivingCurrentPing
                    )
                } else {
                    newState = .receivingPing(
                        characteristic,
                        .length,
                        bytesToRead: bytesToRead,
                        timeStartedReceivingLastPing: timeStartedReceivingLastPing,
                        timeStartedReceivingCurrentPing: timeStartedReceivingCurrentPing
                    )
                }

                if readBuffer!.count - Int(numBytes) >= bytesToRead {
                    nextStateAction = .read
                }
            case .message:
                if bytesToRead == 0 {
                    let pingMessage = BluetoothService.deserializeMeasurementMessage(
                        fromBuffer: buffers.readBuffer[
                                Data.Index(
                                    BluetoothService.lengthPrefixSize
                                )..<Data.Index(
                                    BluetoothService.lengthPrefixSize + numBytes
                                )
                            ]
                        )

                    #if DEBUG
                    print("Received ping: seq \(pingMessage.sequenceNumber); initiator \(pingMessage.initiatingPeerID); delay: \(pingMessage.delayInNs)")
                    #endif

                    self.calcLatencyForPeer(
                        peer: pingMessage.initiatingPeerID,
                        lastPingRecvTimeInNS: timeStartedReceivingLastPing,
                        pingRecvTimeInNS: timeStartedReceivingCurrentPing!,
                        delayAtPeripheralInNS: pingMessage.delayInNs
                    )

                    self.serializeAck(
                        pingRoundIdx: pingMessage.sequenceNumber,
                        initiatingPeerID: pingMessage.initiatingPeerID,
                        timeStartedReceivingCurrentPing: timeStartedReceivingCurrentPing!,
                        sendBuffer: &buffers.sendBuffer,
                        tmpBuffer: &buffers.tmpBuffer
                    )

                    newState = .sendingAck(
                        characteristic,
                        bytesWritten: 0,
                        pingRoundIdx: pingMessage.sequenceNumber,
                        timeStartedReceivingCurrentPing: timeStartedReceivingCurrentPing,
                        initiatingPeerID: pingMessage.initiatingPeerID
                    )

                    // Necessary because transitioning from receive to send state
                    nextStateAction = .write
                } else {
                    newState = .receivingPing(
                        characteristic,
                        .message,
                        bytesToRead: bytesToRead,
                        timeStartedReceivingLastPing: timeStartedReceivingLastPing,
                        timeStartedReceivingCurrentPing: timeStartedReceivingCurrentPing
                    )

                    if readBuffer!.count - Int(numBytes) >= bytesToRead {
                        nextStateAction = .read
                    }
                }
            }
        case .sendingAck(
            let characteristic,
            bytesWritten: var bytesWritten,
            pingRoundIdx: let pingRoundIdx,
            timeStartedReceivingCurrentPing: let timeStartedReceivingCurrentPing,
            initiatingPeerID: let initiatingPeerID
        ):
            bytesWritten += numBytes
            if bytesWritten >= buffers.sendBuffer.count {
                // Finished a round of ping-ack
                #if DEBUG
                print("Sent ack for ping round \(pingRoundIdx)")
                #endif

                if pingRoundIdx + 1 >= self.expectedNumPingRoundsPerPeripheral {
                    // transition to speaking
                    /* Moved this to `startProtocol` to give the audio engine more time to set up
                    // TODO: maybe handle error
                    try! self.distanceCalculator?.listen()
                    */

                    self.serializeSpeak(
                        sendBuffer: &buffers.sendBuffer,
                        tmpBuffer: &buffers.tmpBuffer
                    )

                    newState = .sendingSpeak(
                        characteristic,
                        bytesWritten: 0,
                        timeStartedSendingSpeak: nil
                    )

                    if canSendWrite {
                        nextStateAction = .write
                    }
                } else {
                    newState = .receivingPing(
                        characteristic,
                        .length,
                        bytesToRead: BluetoothService.lengthPrefixSize,
                        timeStartedReceivingLastPing: timeStartedReceivingCurrentPing,
                        timeStartedReceivingCurrentPing: nil
                    )

                    buffers.readBuffer.removeAll(keepingCapacity: true)
                    // wait for data from peripheral
                }
            } else {
                newState = .sendingAck(
                    characteristic,
                    bytesWritten: bytesWritten,
                    pingRoundIdx: pingRoundIdx,
                    timeStartedReceivingCurrentPing: timeStartedReceivingCurrentPing,
                    initiatingPeerID: initiatingPeerID
                )

                if canSendWrite {
                    nextStateAction = .write
                }
            }
        case .sendingSpeak(
            let characteristic,
            bytesWritten: var bytesWritten,
            timeStartedSendingSpeak: var timeStartedSendingSpeak
        ):
            bytesWritten += numBytes

            if timeStartedSendingSpeak == nil {
                timeStartedSendingSpeak = opStartTime!
            }

            if bytesWritten >= buffers.sendBuffer.count {
                newState = .receivingSpoke(
                    characteristic,
                    .length,
                    bytesToRead: BluetoothService.lengthPrefixSize,
                    timeStartedSendingSpeak: timeStartedSendingSpeak!,
                    timeStartedReceiving: nil
                )

                buffers.readBuffer.removeAll(keepingCapacity: true)
                // wait for more data
            } else {
                newState = .sendingSpeak(
                    characteristic,
                    bytesWritten: bytesWritten,
                    timeStartedSendingSpeak: timeStartedSendingSpeak
                )

                if canSendWrite {
                    nextStateAction = .write
                }
            }
        case .receivingSpoke(
            let characteristic,
            let lengthMessageState,
            bytesToRead: var bytesToRead,
            timeStartedSendingSpeak: let timeStartedSendingSpeak,
            timeStartedReceiving: var timeStartedReceiving
        ):
            bytesToRead -= numBytes

            if timeStartedReceiving == nil {
                timeStartedReceiving = opStartTime!
            }

            switch lengthMessageState {
            case .length:
                if bytesToRead == 0 {
                    bytesToRead = BluetoothService.deserializeLength(
                        fromBuffer: buffers.readBuffer[
                            0..<Data.Index(BluetoothService.lengthPrefixSize)
                        ]
                    )

                    newState = .receivingSpoke(
                        characteristic,
                        .message,
                        bytesToRead: bytesToRead,
                        timeStartedSendingSpeak: timeStartedSendingSpeak,
                        timeStartedReceiving: timeStartedReceiving
                    )
                } else {
                    newState = .receivingSpoke(
                        characteristic,
                        .length,
                        bytesToRead: bytesToRead,
                        timeStartedSendingSpeak: timeStartedSendingSpeak,
                        timeStartedReceiving: timeStartedReceiving
                    )
                }

                if readBuffer!.count - Int(numBytes) >= bytesToRead {
                    nextStateAction = .read
                }
            case .message:
                if bytesToRead == 0 {
                    let spokeMessage = BluetoothService.deserializeProtocolMessage(
                        fromBuffer: buffers.readBuffer[
                                Data.Index(
                                    BluetoothService.lengthPrefixSize
                                )..<Data.Index(
                                    BluetoothService.lengthPrefixSize + numBytes
                                )
                            ]
                        )

//                    self.calcLatencyForPeer(
//                        peer: spokeMessage.spoke.from,
//                        lastPingRecvTimeInNS: timeStartedSendingSpeak,
//                        pingRecvTimeInNS: timeStartedReceiving!,
//                        delayAtPeripheralInNS: spokeMessage.spoke.delayInNs
//                    )

                    let peerLatency = self.latencyByPeer[spokeMessage.spoke.from]!
                    try! self.distanceCalculator?.heardPeerSpeak(
                        peer: spokeMessage.spoke.from,
                        recvTimeInNS: timeStartedReceiving!,
                        reportedSpeakingDelay: spokeMessage.spoke.delayInNs,
                        withOneWayLatency: peerLatency
                    )

                    self.updateDelegate?.receivedSpokeMessage(from: spokeMessage.spoke.from)

                    self.finishProtocolForPeripheral(peripheral)
                } else {
                    newState = .receivingSpoke(
                        characteristic,
                        .message,
                        bytesToRead: bytesToRead,
                        timeStartedSendingSpeak: timeStartedSendingSpeak,
                        timeStartedReceiving: timeStartedReceiving
                    )

                    if readBuffer!.count - Int(numBytes) >= bytesToRead {
                        nextStateAction = .read
                    }
                }
            }
        }
    }

    private func serializeAck(
        pingRoundIdx: UInt32,
        initiatingPeerID: DistanceManager.PeerID,
        timeStartedReceivingCurrentPing: UInt64,
        sendBuffer: inout Data,
        tmpBuffer: inout Data
    ) {
        sendBuffer.removeAll(keepingCapacity: true)
        BluetoothService.serializeMeasurementMessage(MeasurementMessage.with {
            $0.sequenceNumber = pingRoundIdx
            $0.initiatingPeerID = initiatingPeerID
            $0.delayInNs = getCurrentTimeInNs() - timeStartedReceivingCurrentPing
        }, toBuffer: &tmpBuffer)

        BluetoothService.serializeLength(
            BluetoothService.LengthPrefixType(tmpBuffer.count),
            toBuffer: &sendBuffer
        )

        sendBuffer.append(tmpBuffer)
    }

    private func serializeSpeak(
        sendBuffer: inout Data,
        tmpBuffer: inout Data
    ) {
        sendBuffer.removeAll(keepingCapacity: true)
        BluetoothService.serializeProtocolMessage(DistanceProtocolWrapper.with {
            $0.type = .speak(Speak.with {
                $0.from = self.selfID
            })
        }, toBuffer: &tmpBuffer)

        BluetoothService.serializeLength(
            BluetoothService.LengthPrefixType(tmpBuffer.count),
            toBuffer: &sendBuffer
        )

        sendBuffer.append(tmpBuffer)
    }

    private func calcLatencyForPeer(
        peer: DistanceManager.PeerID,
        lastPingRecvTimeInNS lastRecvTime: UInt64?,
        pingRecvTimeInNS recvTime: UInt64,
        delayAtPeripheralInNS delay: UInt64
    ) {
        guard let actualLastRecvTime = lastRecvTime else {
            return
        }

        self.latencyByPeer[peer] = BluetoothService.calcLatency(
            lastLatency: self.latencyByPeer[peer],
            lastPingRecvTimeInNS: actualLastRecvTime,
            pingRecvTimeInNS: recvTime,
            delayAtPeripheralInNS: delay
        )

        print("Delay at peripheral: \(delay)")
        print("Latency: \(Double(self.latencyByPeer[peer]!) / Double(NSEC_PER_MSEC))")
    }

// MARK: - cleanup functions

    private func removePeripheral(withPeripheral peripheral: CBPeripheral) {
        peripheral.delegate = nil // TODO: maybe this is handled internally?
        self.discoveredPeripheralsState[peripheral] = nil
        self.discoveredPeripheralsBuffers[peripheral] = nil
        self.discoveredPeripherals.removeAll(where: { $0 == peripheral })

        switch peripheral.state {
        case .connecting:
            break
        case .connected:
            break
        default:
            #if DEBUG
            print("Tried to remove peripheral already disconnected or disconnecting")
            #endif
            return
        }

        for service in (peripheral.services ?? [] as [CBService]) {
            for characteristic in (service.characteristics ?? [] as [CBCharacteristic]) {
                if characteristic.uuid == BluetoothService.characteristicUUID && characteristic.isNotifying {
                    // It is notifying, so unsubscribe
                    peripheral.setNotifyValue(false, for: characteristic)
                }
            }
        }
        
        // If we've gotten this far, we're connected, but we're not subscribed, so we just disconnect
        self.centralManager.cancelPeripheralConnection(peripheral)
    }

    /*
     * Use this to cancel a peripheral connection with a subscribed characteristic
     */
    private func cleanup(discoveredPeripheral: CBPeripheral) {
        #if DEBUG
        print("Cleaning up peripheral \(String(describing: discoveredPeripheral))")
        #endif
        guard let state = self.discoveredPeripheralsState[discoveredPeripheral] else {
            #if DEBUG
            print("Tried to clean up peripheral \(String(describing: discoveredPeripheral)) not connected")
            #endif
            return
        }

        switch state {
        case .discovered(_):
            #if DEBUG
            print("Tried to clean up peripheral \(String(describing: discoveredPeripheral)) not connected")
            #endif
            return
        default:
            break
        }

        guard self.numSubscribed > 0 else {
            #if DEBUG
            print("Tried to clean up more times than subscribed to characteristics")
            #endif
            return
        }

        self.numSubscribed -= 1
        self.removePeripheral(withPeripheral: discoveredPeripheral)
    }

    #if DEBUG
    private func printState(forPeripheral peripheral: CBPeripheral, _ message: String) {
        guard let state = self.discoveredPeripheralsState[peripheral],
              let buffers = self.discoveredPeripheralsBuffers[peripheral] else {
            print("\(message) :: No state for peripheral \(String(describing: peripheral))")
            return
        }

        print("\(message) :: \(String(describing: peripheral.name)) :: State: \(String(describing: state)); Send Buffer: \(String(describing: buffers.sendBuffer)); Read Buffer: \(String(describing: buffers.readBuffer))")
    }
    #endif
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
                print(String(format: "Discovered peripheral %s not in expected range, at %d", String(describing: peripheral.name), RSSI.intValue))
                #endif
                return
        }

        // Reject if the peripheral doesn't have our service
        guard let servicesArray = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? Array<CBUUID>),
              servicesArray.contains(BluetoothService.serviceUUID) else {
            #if DEBUG
            print("Discovered peripheral does not have this app's service")
            #endif
            return
        }

        #if DEBUG
        print(String(format: "Discovered %s with our service at %d", String(describing: peripheral.name), RSSI.intValue))
        #endif

        guard let peerIDStr = advertisementData[CBAdvertisementDataLocalNameKey],
              let peerIDData = Data(base64Encoded: (peerIDStr as! NSString) as String) else {
            #if DEBUG
            print("Failed to parse peerID from advertisement data for peripheral \(String(describing: peripheral)). Might be a signal not from this app.")
            #endif
            return
        }

        // Need to own the data because CBCentralManager might deallocate it apparently
        var tmp = [UInt8](repeating: 0, count: 8)
        peerIDData.copyBytes(to: &tmp, count: peerIDData.count)
        let peerIDDataCopy = Data(bytes: tmp, count: peerIDData.count)
        let peerID = peerIDDataCopy.withUnsafeBytes {
            $0.load(as: DistanceManager.PeerID.self).bigEndian
        }

        #if DEBUG
        print("Bluetooth discovered peer ID \(peerID) base64 encoded \(peerIDStr)")
        #endif

        self.didDiscover(peripheral: peripheral, peerID: peerID)
    }

    /*
     *  If the connection fails for whatever reason, we need to deal with it.
     */
    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        #if DEBUG
        print("Failed to connect to \(peripheral): \(String(describing: error))")
        #endif

        self.removePeripheral(withPeripheral: peripheral)
    }
    
    /*
     *  We've connected to the peripheral, now we need to discover the services and characteristics to find the 'transfer' characteristic.
     */
    func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        #if DEBUG
        print("Peripheral Connected")
        #endif

        self.didConnect(peripheral: peripheral)
    }

    /*
     *  Once the disconnection happens, we need to clean up our local copy of the peripheral
     */
    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        #if DEBUG
        print("Perhiperal \(peripheral) disconnected")
        #endif

        self.removePeripheral(withPeripheral: peripheral)

        // TODO: Maybe try retrieving peripherals again?
        // self.retrievePeripherals()
    }

}

extension SpeakTimerCentral: CBPeripheralDelegate {
    // implementations of the CBPeripheralDelegate methods

    /*
     *  The peripheral letting us know when services have been invalidated.
     */
    func peripheral(
        _ peripheral: CBPeripheral,
        didModifyServices invalidatedServices: [CBService]
    ) {
        for service in invalidatedServices
        where service.uuid == BluetoothService.serviceUUID {
            #if DEBUG
            print("Transfer service is invalidated - rediscover services")
            #endif

            peripheral.discoverServices([BluetoothService.serviceUUID])
        }
    }

    /*
     *  The Transfer Service was discovered
     */
    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        if let error = error {
            #if DEBUG
            print("Error discovering services: \(error.localizedDescription)")
            #endif
            self.removePeripheral(withPeripheral: peripheral)
            return
        }

        // Discover the characteristic we want...
        // Loop through the newly filled peripheral.services array, just in case there's more than one.
        guard let peripheralServices = peripheral.services else {
            return
        }

        for service in peripheralServices {
            peripheral.discoverCharacteristics([BluetoothService.characteristicUUID], for: service)
        }
    }

    /*
     *  The Transfer characteristic was discovered.
     *  Once this has been found, we want to subscribe to it, which lets the peripheral know we want the data it contains
     */
    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        #if DEBUG
        print("Discovered characteristic for peripheral: \(String(describing: peripheral))")
        #endif

        // Deal with errors (if any).
        if let error = error {
            #if DEBUG
            print("Error discovering characteristics: \(error.localizedDescription)")
            #endif
            self.removePeripheral(withPeripheral: peripheral)
            return
        }

        guard self.discoveredPeripheralsState[peripheral] != nil else {
            #if DEBUG
            // This implies that CB disagrees with self about whether the peer is discovered
            fatalError("\(#function): Could not find state for peripheral \(String(describing: peripheral)) with discovered characteristic")
            #else
            return
            #endif
        }

        // Again, we loop through the array, just in case and check if it's the right one
        guard let serviceCharacteristics = service.characteristics else {
            return
        }

        for characteristic in serviceCharacteristics
        where characteristic.uuid == BluetoothService.characteristicUUID {
            // If it is, update the peer's state
            self.didDiscoverCharacteristic(characteristic, forPeripheral: peripheral)
        }
    }
    
    /*
     *   This callback lets us know more data has arrived via notification on the characteristic
     */
    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
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

        self.readAnyData(characteristicData.subdata(in: 0..<characteristicData.count), fromPeripheral: peripheral)
    }

    /*
     *  The peripheral letting us know whether our subscribe/unsubscribe happened or not
     */
    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
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
