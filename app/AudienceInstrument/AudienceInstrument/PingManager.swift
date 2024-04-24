//
//  PingManager.swift
//  AudienceInstrument
//
//  Created by Andrew Orals on 4/22/24.
//

import Foundation
import MultipeerConnectivity

protocol PingManagerUpdateDelegate {
    func didUpdate(latenciesByPeer: [MCPeerID:UInt64])
}

actor PingManager: NeighborMessageSender, NeighborMessageReceiver, DistanceCalculatorLatencyDelegate {
    init() {
        class TimerClosure { // lol
            weak var owner: PingManager? = nil

            func callAsFunction() -> Void {
                if let owner = self.owner {
                    owner.initiateLatencyTestHelper()
                }
            }
        }

        let timerClosure = TimerClosure()
        self.pingTimer = Timer.scheduledTimer(
            withTimeInterval: kPingInterval,
            repeats: true
        ) { _ in timerClosure() }

        RunLoop.current.add(pingTimer!, forMode: .common)
        timerClosure.owner = self
    }

    deinit {
        pingTimer!.invalidate()
    }

    func getOneWayLatencyInNS(toPeer: DistanceManager.PeerID) async -> UInt64? {
        return self.latencyByPeerInNS[toPeer]
    }

    func addPeers(peers: [MCPeerID]) async {
        self.peers = self.peers.union(Set<MCPeerID>(peers))
    }
    
    func removePeers(peers: [MCPeerID]) async {
        self.peers.subtract(Set<MCPeerID>(peers))
        // TODO: keep latencies by peer up to date
    }

    func registerSendDelegate(delegate: NeighborMessageSendDelegate, selfID: MCPeerID) async {
        self.selfID = selfID
        self.sendDelegate = delegate
        return
    }

    func registerUpdateDelegate(delegate: any PingManagerUpdateDelegate) async {
        self.updateDelegate = delegate
    }
    
    func receiveMessage(message: NeighborAppMessage, from: MCPeerID, receivedAt: UInt64) async throws {
        switch message.data {
        case .measurementMessage(var measurementMessage):
            if measurementMessage.initiatingPeerID == self.selfID.hashValue {
                await self.completeLatencyTest(
                    fromPeer: from,
                    atTime: receivedAt,
                    withSeqNum: measurementMessage.sequenceNumber,
                    withReplyDelay: measurementMessage.delayInNs
                )
            } else {
                // reply to the ping
                measurementMessage.delayInNs = getCurrentTimeInNs() - receivedAt
                let outMessage = MessageWrapper.with {
                    $0.data = .neighborAppMessage(NeighborAppMessage.with {
                        $0.data = .measurementMessage(measurementMessage)
                    })
                }
                self.sendDelegate?.send(toPeers: [from], withMessage: outMessage, withReliability: .unreliable)
            }
        default:
            return
        }
    }
    
// MARK: Private interface

    private func initiateLatencyTest() async {
        guard self.sendDelegate != nil else {
            return
        }

        self.pingSeqNum += 1
        self.expectedPingReplies = UInt(self.peers.count)
        self.pingStartTimeNs = getCurrentTimeInNs()

        let data = MessageWrapper.with {
            $0.data = .neighborAppMessage(NeighborAppMessage.with {
                $0.data = .measurementMessage(MeasurementMessage.with {
                    $0.initiatingPeerID = Int64(self.selfID.hashValue)
                    $0.sequenceNumber = self.pingSeqNum
                })
            })
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.sendDelegate?.send(
                    toPeers: Array(self.peers),
                    withMessage: data,
                    withReliability: .unreliable
                )
            }

            await group.waitForAll()
        }
    }

    private func completeLatencyTest(
        fromPeer: MCPeerID,
        atTime recvTime: UInt64,
        withSeqNum seqNum: UInt32,
        withReplyDelay replyDelay: UInt64
    ) async {
        guard seqNum == pingSeqNum else {
            // A message from a stray ping round shouldn't get past here
            return
        }

        guard let currPingStartTimeNs = self.pingStartTimeNs else {
            // received uninitiated latency message with correct sequence number
            return
        }

        // Must be still connected to the peer to record latency
        guard self.peers.contains(fromPeer) else {
            return
        }

        let currLatency = Double(recvTime - currPingStartTimeNs - replyDelay) / 2.0

        if let lastLatency = self.latencyByPeerInNS[fromPeer] {
            self.latencyByPeerInNS[fromPeer] =
                UInt64(kEWMAFactor * Double(lastLatency)) + UInt64((1.0 - kEWMAFactor) * currLatency)
        } else {
            self.latencyByPeerInNS[fromPeer] = UInt64(currLatency)
        }
        self.updateDelegate?.didUpdate(latenciesByPeer: self.latencyByPeerInNS)

        currPingReplies += 1
        if currPingReplies == expectedPingReplies {
            currPingReplies = 0
            pingSemaphore.signal()
        }
    }

    // Synchronous because called from timer
    nonisolated private func initiateLatencyTestHelper() {
        // Make sure that `pingStartTimeNs` is valid for
        // `kPingInterval / 2` seconds, then continue anyway with a new sequence
        // number
        _ = pingSemaphore.wait(timeout: DispatchTime(uptimeNanoseconds: UInt64(1_000_000_000 * kPingInterval / 2.0)))
        Task {
            await self.initiateLatencyTest()
        }
    }

    private var latencyByPeerInNS: [MCPeerID:UInt64] = [:]
    private var sendDelegate: NeighborMessageSendDelegate? = nil
    private var updateDelegate: PingManagerUpdateDelegate? = nil
    private var peers: Set<MCPeerID> = []

    // Latency properties
    nonisolated private let pingTimer: Timer?
    nonisolated private let pingSemaphore: DispatchSemaphore = DispatchSemaphore(value: 1)
    nonisolated private let kEWMAFactor: Double = 0.875
    nonisolated private let kPingInterval: TimeInterval = 1.0

    private var selfID: MCPeerID? = nil
    private var pingStartTimeNs: UInt64? = nil
    private var pingSeqNum: UInt32 = 0
    private var expectedPingReplies: UInt = 0
    private var currPingReplies: UInt = 0
    // End latency properties
}
