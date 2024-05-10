//
//  DistanceManagerTests.swift
//  AudienceInstrumentTests
//
//  Created by Andrew Orals on 4/6/24.
//

import Foundation
import XCTest
import Mockingbird
import MultipeerConnectivity
@testable import AudienceInstrument

fileprivate func makeAppMessage(type: DistanceProtocolWrapper.OneOf_Type) -> MessageWrapper {
    return MessageWrapper.with {
        $0.data = .neighborAppMessage(NeighborAppMessage.with {
            $0.data = .distanceProtocolMessage(DistanceProtocolWrapper.with {
                $0.type = type
            })
        })
    }
}

final class DistanceManagerInitiatorTests: XCTestCase {
    let mockDistanceCalculator = mock(DistanceCalculatorProtocol.self)
    let mockSendDelegate = mock(NeighborMessageSendDelegate.self)
    let mockUpdateDelegate = mock(DistanceManagerUpdateDelegate.self)

    let kTimeoutInNS = 40 * NSEC_PER_MSEC // TODO remove dependency on DistanceManager source

    typealias DM = DistanceManager

    override func setUp() {
        DM.registerSendDelegate(delegate: mockSendDelegate)
        DM.registerUpdateDelegate(delegate: mockUpdateDelegate)
        DM.setup(
            speakTimerDelegate: nil,
            spokeDelegate: nil,
            distanceCalculator: mockDistanceCalculator
        )
    }

    override func tearDown() {
        reset(mockDistanceCalculator)
        reset(mockSendDelegate)
        reset(mockUpdateDelegate)
    }

    func verifyTotalMessage(expected: UInt) {
        verify(mockSendDelegate.send(
            toPeers: any([DistanceManager.PeerID].self),
            withMessage: any(MessageWrapper.self),
            withReliability: .reliable
        )).wasCalled(Int(expected))
    }

    func verifyTotalMessages(expected: UInt) {
        verify(mockSendDelegate.send(
            toPeers: any([DistanceManager.PeerID].self),
            withMessages: any([MessageWrapper].self),
            withReliability: .reliable
        )).wasCalled(Int(expected))
    }

    func verifyPeerRegistrations(peers: [DistanceManager.PeerID]) {
        verify(mockDistanceCalculator.registerPeer(peer: any(DistanceManager.PeerID.self))).wasCalled(peers.count)
        verify(mockDistanceCalculator.deregisterPeer(peer: any(DistanceManager.PeerID.self))).wasCalled(peers.count)

        for peer in peers {
            verify(mockDistanceCalculator.registerPeer(peer: peer)).wasCalled(1)
            verify(mockDistanceCalculator.deregisterPeer(peer: peer)).wasCalled(1)
        }
    }


// MARK: Initiator tests

    func testInitiatorOnePeer() async throws {
        let peer0 = MCPeerID(displayName: "0000000000000000").id
        given(mockDistanceCalculator.calcFreqsForPeers()).willReturn([0])
        DM.addPeers(peers: [peer0])

        DM.initiate(retries: 0)

        try DM.receiveMessage(
            message: DistanceProtocolWrapper.with {
                $0.type = .initAck(InitAck())
            },
            from: peer0,
            receivedAt: 0
        )

        DM.clearAllAndCancel()

        verifyTotalMessage(expected: 1)
        verifyTotalMessages(expected: 1)

        verify(mockSendDelegate.send(
            toPeers: [peer0],
            withMessages: [DistanceListener.Freq](repeating: 0, count: 1).map({ freq in makeAppMessage(type: .init_p(Init.with { $0.freq = UInt32(freq) })) }),
            withReliability: .reliable
        )).wasCalled(1)
        verify(mockSendDelegate.send(
            toPeers: [peer0],
            withMessage: makeAppMessage(type: .speak(Speak())),
            withReliability: .reliable
        )).wasCalled(1)

        verify(mockDistanceCalculator.listen()).wasCalled(1)
        verifyPeerRegistrations(peers: [peer0])
    }
    
    func testInitiatorMultiPeers() async throws {
        let peer0 = MCPeerID(displayName: "0000000000000000").id
        let peer1 = MCPeerID(displayName: "0000000000000001").id
        let peer2 = MCPeerID(displayName: "0000000000000002").id
        DM.addPeers(peers: [peer0, peer1, peer2])
        given(mockDistanceCalculator.calcFreqsForPeers()).willReturn([0, 0, 0])

        DM.initiate(retries: 0)

        for p in [peer0, peer1, peer2] {
            try DM.receiveMessage(
                message: DistanceProtocolWrapper.with {
                    $0.type = .initAck(InitAck())
                },
                from: p,
                receivedAt: 0
            )
        }

        DM.clearAllAndCancel()

        verifyTotalMessage(expected: 1)
        verifyTotalMessages(expected: 1)

        verify(mockSendDelegate.send(
            toPeers: any(containing: peer0, peer1, peer2),
            withMessages: [DistanceListener.Freq](repeating: 0, count: 3).map({ freq in makeAppMessage(type: .init_p(Init.with { $0.freq = UInt32(freq) })) }),
            withReliability: .reliable
        )).wasCalled(1)
        verify(mockSendDelegate.send(
            toPeers: any(containing: peer0, peer1, peer2),
            withMessage: makeAppMessage(type: .speak(Speak())),
            withReliability: .reliable
        )).wasCalled(1)

        verify(mockDistanceCalculator.listen()).wasCalled(1)
        verifyPeerRegistrations(peers: [peer0, peer1, peer2])
    }

    func testInitiatorMultiPeerAllInitAckMultiTryTimeout() async throws {
        let peer0 = MCPeerID(displayName: "0000000000000000").id
        let peer1 = MCPeerID(displayName: "0000000000000001").id
        let peer2 = MCPeerID(displayName: "0000000000000002").id
        given(mockDistanceCalculator.calcFreqsForPeers()).willReturn([0, 0, 0])
        DM.addPeers(peers: [peer0, peer1, peer2])

        DM.initiate(retries: 2, withInitTimeout: .milliseconds(100))

        try await Task.sleep(nanoseconds: 400 * NSEC_PER_MSEC)

        for p in [peer0, peer1, peer2] {
            try DM.receiveMessage(
                message: DistanceProtocolWrapper.with {
                    $0.type = .initAck(InitAck())
                },
                from: p,
                receivedAt: 0
            )
        }

        DM.clearAllAndCancel()

        verifyTotalMessages(expected: 3)

        verify(mockSendDelegate.send(
            toPeers: any(containing: peer0, peer1, peer2),
            withMessages: [DistanceListener.Freq](repeating: 0, count: 3).map({ freq in makeAppMessage(type: .init_p(Init.with { $0.freq = UInt32(freq) })) }),
            withReliability: .reliable
        )).wasCalled(3)

        verifyPeerRegistrations(peers: [peer0, peer1, peer2])
    }

    func testInitiatorMultiPeerSingleInitAckMultiTryTimeout() async throws {
        let peer0 = MCPeerID(displayName: "0000000000000000").id
        let peer1 = MCPeerID(displayName: "0000000000000001").id
        let peer2 = MCPeerID(displayName: "0000000000000002").id
        given(mockDistanceCalculator.calcFreqsForPeers()).willReturn([0, 0, 0])
        DM.addPeers(peers: [peer0, peer1, peer2])

        DM.initiate(retries: 2)

        for p in [peer0, peer1] {
            try DM.receiveMessage(
                message: DistanceProtocolWrapper.with {
                    $0.type = .initAck(InitAck())
                },
                from: p,
                receivedAt: 0
            )
        }

        try await Task.sleep(nanoseconds: kTimeoutInNS * 3)

        try DM.receiveMessage(
            message: DistanceProtocolWrapper.with {
                $0.type = .initAck(InitAck())
            },
            from: peer2,
            receivedAt: 0
        )

        DM.clearAllAndCancel()

        verifyTotalMessages(expected: 3)

        verify(mockSendDelegate.send(
            toPeers: any(containing: peer0, peer1, peer2),
            withMessages: [DistanceListener.Freq](repeating: 0, count: 3).map({ freq in makeAppMessage(type: .init_p(Init.with { $0.freq = UInt32(freq) })) }),
            withReliability: .reliable
        )).wasCalled(3)

        verifyPeerRegistrations(peers: [peer0, peer1, peer2])
    }

    func testInitiatorMultiPeerAllInitAckMultiTry() async throws {
        let peer0 = MCPeerID(displayName: "0000000000000000").id
        let peer1 = MCPeerID(displayName: "0000000000000001").id
        let peer2 = MCPeerID(displayName: "0000000000000002").id
        given(mockDistanceCalculator.calcFreqsForPeers()).willReturn([0, 0, 0])
        DM.addPeers(peers: [peer0, peer1, peer2])

        DM.initiate(retries: 2, withInitTimeout: .milliseconds(100))

        try await Task.sleep(nanoseconds: 150 * NSEC_PER_MSEC)

        for p in [peer0, peer1, peer2] {
            try DM.receiveMessage(
                message: DistanceProtocolWrapper.with {
                    $0.type = .initAck(InitAck())
                },
                from: p,
                receivedAt: 0
            )
        }

        DM.clearAllAndCancel()

        verify(mockSendDelegate.send(
            toPeers: any([DistanceManager.PeerID].self),
            withMessages: any([MessageWrapper].self),
            withReliability: .reliable
        )).wasCalled(atLeast(2))
        verifyTotalMessage(expected: 1)

        verify(mockSendDelegate.send(
            toPeers: any(containing: peer0, peer1, peer2),
            withMessages: [DistanceListener.Freq](repeating: 0, count: 3).map({ freq in makeAppMessage(type: .init_p(Init.with { $0.freq = UInt32(freq) })) }),
            withReliability: .reliable
        )).wasCalled(atLeast(2))
        verify(mockSendDelegate.send(
            toPeers: any(containing: peer0, peer1, peer2),
            withMessages: [DistanceListener.Freq](repeating: 0, count: 3).map({ freq in makeAppMessage(type: .init_p(Init.with { $0.freq = UInt32(freq) })) }),
            withReliability: .reliable
        )).wasCalled(atMost(3))
        verify(mockSendDelegate.send(
            toPeers: any(containing: peer0, peer1, peer2),
            withMessage: makeAppMessage(type: .speak(Speak())),
            withReliability: .reliable
        )).wasCalled(1)

        verifyPeerRegistrations(peers: [peer0, peer1, peer2])
    }

    func testInitiatorMultiPeerSingleInitAckMultiTry() async throws {
        let peer0 = MCPeerID(displayName: "0000000000000000").id
        let peer1 = MCPeerID(displayName: "0000000000000001").id
        let peer2 = MCPeerID(displayName: "0000000000000002").id
        given(mockDistanceCalculator.calcFreqsForPeers()).willReturn([0, 0, 0])
        DM.addPeers(peers: [peer0, peer1, peer2])

        DM.initiate(retries: 2, withInitTimeout: .milliseconds(100))

        for p in [peer0, peer2] {
            try DM.receiveMessage(
                message: DistanceProtocolWrapper.with {
                    $0.type = .initAck(InitAck())
                },
                from: p,
                receivedAt: 0
            )
        }

        try await Task.sleep(nanoseconds: 150 * NSEC_PER_MSEC)

        for p in [peer0, peer2] {
            try DM.receiveMessage(
                message: DistanceProtocolWrapper.with {
                    $0.type = .initAck(InitAck())
                },
                from: p,
                receivedAt: 0
            )
        }

        try await Task.sleep(nanoseconds: 50 * NSEC_PER_MSEC)

        try DM.receiveMessage(
            message: DistanceProtocolWrapper.with {
                $0.type = .initAck(InitAck())
            },
            from: peer1,
            receivedAt: 0
        )

        DM.clearAllAndCancel()
        verify(mockSendDelegate.send(
            toPeers: any([DistanceManager.PeerID].self),
            withMessages: any([MessageWrapper].self),
            withReliability: .reliable
        )).wasCalled(atLeast(2))
        verifyTotalMessage(expected: 1)

        verify(mockSendDelegate.send(
            toPeers: any(containing: peer0, peer1, peer2),
            withMessages: [DistanceListener.Freq](repeating: 0, count: 3).map({ freq in makeAppMessage(type: .init_p(Init.with { $0.freq = UInt32(freq) })) }),
            withReliability: .reliable
        )).wasCalled(atLeast(2))
        verify(mockSendDelegate.send(
            toPeers: any(containing: peer0, peer1, peer2),
            withMessages: [DistanceListener.Freq](repeating: 0, count: 3).map({ freq in makeAppMessage(type: .init_p(Init.with { $0.freq = UInt32(freq) })) }),
            withReliability: .reliable
        )).wasCalled(atMost(3))
        verify(mockSendDelegate.send(
            toPeers: any(containing: peer0, peer1, peer2),
            withMessage: makeAppMessage(type: .speak(Speak())),
            withReliability: .reliable
        )).wasCalled(1)
    }

    func testInitiatorMultiPeerAllSpokeTimeout() async throws {
        let peer0 = MCPeerID(displayName: "0000000000000000").id
        let peer1 = MCPeerID(displayName: "0000000000000001").id
        let peer2 = MCPeerID(displayName: "0000000000000002").id
        DM.addPeers(peers: [peer0, peer1, peer2])

        given(mockDistanceCalculator.calcFreqsForPeers()).willReturn([0, 0, 0])
        given(mockDistanceCalculator.calculateDistances()).willReturn(([], []))
        DM.initiate(retries: 2, withSpokeTimeout: .milliseconds(100))

        for p in [peer0, peer1, peer2] {
            try DM.receiveMessage(
                message: DistanceProtocolWrapper.with {
                    $0.type = .initAck(InitAck())
                },
                from: p,
                receivedAt: 0
            )
        }

        try await Task.sleep(nanoseconds: 150 * NSEC_PER_MSEC)

        for p in [peer0, peer1, peer2] {
            try DM.receiveMessage(
                message: DistanceProtocolWrapper.with {
                    $0.type = .spoke(Spoke.with {
                        $0.delayInNs = 10 * NSEC_PER_MSEC // arbitrary - not tested
                    })
                },
                from: p,
                receivedAt: 1 * NSEC_PER_SEC // arbitrary - not tested
            )
        }

        DM.clearAllAndCancel()

        verifyTotalMessages(expected: 1)
        verifyTotalMessage(expected: 1)

        verify(mockSendDelegate.send(
            toPeers: any(containing: peer0, peer1, peer2),
            withMessages: [DistanceListener.Freq](repeating: 0, count: 3).map({ freq in makeAppMessage(type: .init_p(Init.with { $0.freq = UInt32(freq) })) }),
            withReliability: .reliable
        )).wasCalled(1)

        verify(mockSendDelegate.send(
            toPeers: any(containing: peer0, peer1, peer2),
            withMessage: makeAppMessage(type: .speak(Speak())),
            withReliability: .reliable
        )).wasCalled(1)

        // listening
        verify(mockDistanceCalculator.listen()).wasCalled(1)

        // calculate distances
        verify(mockDistanceCalculator.calculateDistances()).wasCalled(1)
        verify(mockUpdateDelegate.didUpdate(distancesByPeer: any([DM.PeerID:DM.PeerDist].self))).wasNeverCalled()

        // reset
        verifyPeerRegistrations(peers: [peer0, peer1, peer2])
        // `reset()` called twice because of clearAllAndCancel()
        verify(mockDistanceCalculator.reset()).wasCalled(2)
    }

    func testInitiatorMultiPeerSingleSpokeTimeout() async throws {
        let peer0 = MCPeerID(displayName: "0000000000000000").id
        let peer1 = MCPeerID(displayName: "0000000000000001").id
        let peer2 = MCPeerID(displayName: "0000000000000002").id
        DM.addPeers(peers: [peer0, peer1, peer2])

        given(mockDistanceCalculator.calcFreqsForPeers()).willReturn([0, 0, 0])
        given(mockDistanceCalculator.calculateDistances()).willReturn(([peer0, peer2], [1.5, 2.3]))
        DM.initiate(retries: 2, withSpokeTimeout: .milliseconds(100))

        for p in [peer0, peer1, peer2] {
            try DM.receiveMessage(
                message: DistanceProtocolWrapper.with {
                    $0.type = .initAck(InitAck())
                },
                from: p,
                receivedAt: 0
            )
        }

        try await Task.sleep(nanoseconds: 5 * NSEC_PER_MSEC)

        for p in [peer0, peer2] {
            try DM.receiveMessage(
                message: DistanceProtocolWrapper.with {
                    $0.type = .spoke(Spoke.with {
                        $0.delayInNs = 10 * NSEC_PER_MSEC // arbitrary - not tested
                    })
                },
                from: p,
                receivedAt: 1 * NSEC_PER_SEC // arbitrary - not tested
            )
        }

        try await Task.sleep(nanoseconds: 150 * NSEC_PER_MSEC)

        try DM.receiveMessage(
            message: DistanceProtocolWrapper.with {
                $0.type = .spoke(Spoke.with {
                    $0.delayInNs = 10 * NSEC_PER_MSEC // arbitrary - not tested
                })
            },
            from: peer2,
            receivedAt: 1 * NSEC_PER_SEC // arbitrary - not tested
        )

        DM.clearAllAndCancel()

        verifyTotalMessage(expected: 1)
        verifyTotalMessages(expected: 2)

        verify(mockSendDelegate.send(
            toPeers: any(containing: peer0, peer1, peer2),
            withMessages: [DistanceListener.Freq](repeating: 0, count: 3).map({ freq in makeAppMessage(type: .init_p(Init.with { $0.freq = UInt32(freq) })) }),
            withReliability: .reliable
        )).wasCalled(1)

        verify(mockSendDelegate.send(
            toPeers: any(containing: peer0, peer1, peer2),
            withMessage: makeAppMessage(type: .speak(Speak())),
            withReliability: .reliable
        )).wasCalled(1)

        // listening
        verify(mockDistanceCalculator.listen()).wasCalled(1)

        // calculate distances
        verify(mockDistanceCalculator.calculateDistances()).wasCalled(1)
        verify(mockSendDelegate.send(
            toPeers: [peer0, peer2],
            withMessages: [
                makeAppMessage(type: .done(Done.with { $0.distanceInM = 1.5 })),
                makeAppMessage(type: .done(Done.with { $0.distanceInM = 2.3 }))
            ],
            withReliability: .reliable
        )).wasCalled(1)
        verify(mockUpdateDelegate.didUpdate(distancesByPeer: any([DM.PeerID:DM.PeerDist].self))).wasCalled(1)

        // reset
        verifyPeerRegistrations(peers: [peer0, peer1, peer2])
        verify(mockDistanceCalculator.reset()).wasCalled(2)
    }

    func testInitiatorMultiPhaseAddPeer() async throws {
        // Calculate distances to 2 of 3 peers
        // Add a 4th peer and reinitiate
        let peer0 = MCPeerID(displayName: "0000000000000000").id
        let peer1 = MCPeerID(displayName: "0000000000000001").id
        let peer2 = MCPeerID(displayName: "0000000000000002").id
        let peer3 = MCPeerID(displayName: "0000000000000003").id

        let updateExpectation = XCTestExpectation(description: "DistanceManager notifies the client of calculated distances for peer0 and peer2.")

        given(mockDistanceCalculator.calcFreqsForPeers()).willReturn([0, 0, 0])
        given(mockUpdateDelegate.didUpdate(distancesByPeer: any([DM.PeerID:DM.PeerDist].self))).will({ _ in
            updateExpectation.fulfill()
        })
        given(mockDistanceCalculator.calculateDistances()).willReturn(([peer0, peer2], [1.5, 2.3]))

        DM.addPeers(peers: [peer0, peer1, peer2])
        DM.initiate(retries: 2, withSpokeTimeout: .milliseconds(100))

        for p in [peer0, peer1, peer2] {
            try DM.receiveMessage(
                message: DistanceProtocolWrapper.with {
                    $0.type = .initAck(InitAck())
                },
                from: p,
                receivedAt: 0
            )
        }

        for p in [peer0, peer2] {
            try DM.receiveMessage(
                message: DistanceProtocolWrapper.with {
                    $0.type = .spoke(Spoke.with {
                        $0.delayInNs = 10 * NSEC_PER_MSEC // arbitrary - not tested
                    })
                },
                from: p,
                receivedAt: 1 * NSEC_PER_SEC // arbitrary - not tested
            )
        }

        try await Task.sleep(nanoseconds: 150 * NSEC_PER_MSEC)

        try DM.receiveMessage(
            message: DistanceProtocolWrapper.with {
                $0.type = .spoke(Spoke.with {
                    $0.delayInNs = 10 * NSEC_PER_MSEC // arbitrary - not tested
                })
            },
            from: peer2,
            receivedAt: 1 * NSEC_PER_SEC // arbitrary - not tested
        )

        await fulfillment(of: [updateExpectation], timeout: 1.0)

        given(mockDistanceCalculator.calcFreqsForPeers()).willReturn([0, 0])
        given(mockUpdateDelegate.didUpdate(distancesByPeer: any([DM.PeerID:DM.PeerDist].self))).will({ _ in }) // reset this
        given(mockDistanceCalculator.calculateDistances()).willReturn(([peer1, peer3], [2.7, 3.1]))

        DM.addPeers(peers: [peer3])
        DM.initiate(retries: 2, withSpokeTimeout: .milliseconds(100))

        for p in [peer1, peer3] {
            try DM.receiveMessage(
                message: DistanceProtocolWrapper.with {
                    $0.type = .initAck(InitAck())
                },
                from: p,
                receivedAt: 0
            )
        }

        for p in [peer1, peer3] {
            try DM.receiveMessage(
                message: DistanceProtocolWrapper.with {
                    $0.type = .spoke(Spoke.with {
                        $0.delayInNs = 10 * NSEC_PER_MSEC // arbitrary - not tested
                    })
                },
                from: p,
                receivedAt: 1 * NSEC_PER_SEC // arbitrary - not tested
            )
        }

        DM.clearAllAndCancel()

        verifyTotalMessage(expected: 2)
        verifyTotalMessages(expected: 4)

        verify(mockSendDelegate.send(
            toPeers: any(containing: peer0, peer1, peer2),
            withMessages: [DistanceListener.Freq](repeating: 0, count: 3).map({ freq in makeAppMessage(type: .init_p(Init.with { $0.freq = UInt32(freq) })) }),
            withReliability: .reliable
        )).wasCalled(1)

        verify(mockSendDelegate.send(
            toPeers: any(containing: peer1, peer3),
            withMessages: [DistanceListener.Freq](repeating: 0, count: 2).map({ freq in makeAppMessage(type: .init_p(Init.with { $0.freq = UInt32(freq) })) }),
            withReliability: .reliable
        )).wasCalled(1)

        verify(mockSendDelegate.send(
            toPeers: any(containing: peer1, peer3),
            withMessage: makeAppMessage(type: .speak(Speak())),
            withReliability: .reliable
        )).wasCalled(1)

        // listening
        verify(mockDistanceCalculator.listen()).wasCalled(2)

        // calculate distances
        verify(mockDistanceCalculator.calculateDistances()).wasCalled(2)
        verify(mockSendDelegate.send(
            toPeers: [peer1, peer3],
            withMessages: [
                makeAppMessage(type: .done(Done.with { $0.distanceInM = 2.7 })),
                makeAppMessage(type: .done(Done.with { $0.distanceInM = 3.1 }))
            ],
            withReliability: .reliable
        )).wasCalled(1)
        verify(mockUpdateDelegate.didUpdate(distancesByPeer: [
            peer0:.someCalculated(1.5),
            peer1:.noneCalculated,
            peer2:.someCalculated(2.3)
        ])).wasCalled(1)
        verify(mockUpdateDelegate.didUpdate(distancesByPeer: [
            peer0:.someCalculated(1.5),
            peer1:.someCalculated(2.7),
            peer2:.someCalculated(2.3),
            peer3:.someCalculated(3.1)
        ])).wasCalled(1)

        // reset
        // 3 peers for first round and 2 for the next
        verify(mockDistanceCalculator.registerPeer(peer: any(DistanceManager.PeerID.self))).wasCalled(5)
        verify(mockDistanceCalculator.deregisterPeer(peer: any(DistanceManager.PeerID.self))).wasCalled(5)
        verify(mockDistanceCalculator.registerPeer(peer: peer0)).wasCalled(1)
        verify(mockDistanceCalculator.registerPeer(peer: peer1)).wasCalled(2)
        verify(mockDistanceCalculator.registerPeer(peer: peer2)).wasCalled(1)
        verify(mockDistanceCalculator.registerPeer(peer: peer3)).wasCalled(1)
        verify(mockDistanceCalculator.deregisterPeer(peer: peer0)).wasCalled(1)
        verify(mockDistanceCalculator.deregisterPeer(peer: peer1)).wasCalled(2)
        verify(mockDistanceCalculator.deregisterPeer(peer: peer2)).wasCalled(1)
        verify(mockDistanceCalculator.deregisterPeer(peer: peer3)).wasCalled(1)
        verify(mockDistanceCalculator.reset()).wasCalled(3)
    }

    func testInitiatorMultiPhaseRemovePeer() async throws {
        // Calculate distance to 4 peers, get 2 of 4 distances
        // Remove one node that wasn't and one node that was calculated and do another round
        // Calculate distance to remaining peer, get distance
        let peer0 = MCPeerID(displayName: "0000000000000000").id
        let peer1 = MCPeerID(displayName: "0000000000000001").id
        let peer2 = MCPeerID(displayName: "0000000000000002").id
        let peer3 = MCPeerID(displayName: "0000000000000003").id

        let updateExpectation = XCTestExpectation(description: "DistanceManager notifies the client of calculated distances for peer0 and peer2.")

        given(mockDistanceCalculator.calcFreqsForPeers()).willReturn([0, 0, 0, 0])
        given(mockUpdateDelegate.didUpdate(distancesByPeer: any([DM.PeerID:DM.PeerDist].self))).will({ _ in
            updateExpectation.fulfill()
        })
        given(mockDistanceCalculator.calculateDistances()).willReturn(([peer0, peer2], [1.5, 2.3]))

        DM.addPeers(peers: [peer0, peer1, peer2, peer3])
        DM.initiate(retries: 2, withSpokeTimeout: .milliseconds(100))

        for p in [peer0, peer1, peer2, peer3] {
            try DM.receiveMessage(
                message: DistanceProtocolWrapper.with {
                    $0.type = .initAck(InitAck())
                },
                from: p,
                receivedAt: 0
            )
        }

        for p in [peer0, peer2] {
            try DM.receiveMessage(
                message: DistanceProtocolWrapper.with {
                    $0.type = .spoke(Spoke.with {
                        $0.delayInNs = 10 * NSEC_PER_MSEC // arbitrary - not tested
                    })
                },
                from: p,
                receivedAt: 1 * NSEC_PER_SEC // arbitrary - not tested
            )
        }

        await fulfillment(of: [updateExpectation], timeout: 1.0)

        given(mockDistanceCalculator.calcFreqsForPeers()).willReturn([0])
        given(mockUpdateDelegate.didUpdate(distancesByPeer: any([DM.PeerID:DM.PeerDist].self))).will({ _ in }) // reset this
        given(mockDistanceCalculator.calculateDistances()).willReturn(([peer3], [2.7]))

        DM.removePeers(peers: [peer1, peer2])
        DM.initiate(retries: 2, withSpokeTimeout: .milliseconds(100))

        try DM.receiveMessage(
            message: DistanceProtocolWrapper.with {
                $0.type = .initAck(InitAck())
            },
            from: peer3,
            receivedAt: 0
        )

        try DM.receiveMessage(
            message: DistanceProtocolWrapper.with {
                $0.type = .spoke(Spoke.with {
                    $0.delayInNs = 10 * NSEC_PER_MSEC // arbitrary - not tested
                })
            },
            from: peer3,
            receivedAt: 1 * NSEC_PER_SEC // arbitrary - not tested
        )

        DM.clearAllAndCancel()

        verifyTotalMessage(expected: 2)
        verifyTotalMessages(expected: 4)

        verify(mockSendDelegate.send(
            toPeers: any(containing: peer0, peer1, peer2, peer3),
            withMessages: [DistanceListener.Freq](repeating: 0, count: 4).map({ freq in makeAppMessage(type: .init_p(Init.with { $0.freq = UInt32(freq) })) }),
            withReliability: .reliable
        )).wasCalled(1)

        verify(mockSendDelegate.send(
            toPeers: any(containing: peer0, peer1, peer2, peer3),
            withMessage: makeAppMessage(type: .speak(Speak())),
            withReliability: .reliable
        )).wasCalled(1)

        verify(mockSendDelegate.send(
            toPeers: [peer3],
            withMessages: [DistanceListener.Freq](repeating: 0, count: 1).map({ freq in makeAppMessage(type: .init_p(Init.with { $0.freq = UInt32(freq) })) }),
            withReliability: .reliable
        )).wasCalled(1)

        verify(mockSendDelegate.send(
            toPeers: [peer3],
            withMessage: makeAppMessage(type: .speak(Speak())),
            withReliability: .reliable
        )).wasCalled(1)

        // listening
        verify(mockDistanceCalculator.listen()).wasCalled(2)

        // calculate distances
        verify(mockDistanceCalculator.calculateDistances()).wasCalled(2)
        verify(mockSendDelegate.send(
            toPeers: [peer0, peer2],
            withMessages: [
                makeAppMessage(type: .done(Done.with { $0.distanceInM = 1.5 })),
                makeAppMessage(type: .done(Done.with { $0.distanceInM = 2.3 }))
            ],
            withReliability: .reliable
        )).wasCalled(1)
        verify(mockSendDelegate.send(
            toPeers: [peer3],
            withMessages: [
                makeAppMessage(type: .done(Done.with { $0.distanceInM = 2.7 })),
            ],
            withReliability: .reliable
        )).wasCalled(1)
        verify(mockUpdateDelegate.didUpdate(distancesByPeer: [
            peer0:.someCalculated(1.5),
            peer1:.noneCalculated,
            peer2:.someCalculated(2.3),
            peer3: .noneCalculated
        ])).wasCalled(1)
        verify(mockUpdateDelegate.didUpdate(distancesByPeer: [
            peer0:.someCalculated(1.5),
            peer3:.someCalculated(2.7)
        ])).wasCalled(1)

        // reset
        // 3 peers for first round and 2 for the next
        verify(mockDistanceCalculator.registerPeer(peer: any(DistanceManager.PeerID.self))).wasCalled(5)
        verify(mockDistanceCalculator.deregisterPeer(peer: any(DistanceManager.PeerID.self))).wasCalled(5)
        verify(mockDistanceCalculator.registerPeer(peer: peer0)).wasCalled(1)
        verify(mockDistanceCalculator.registerPeer(peer: peer1)).wasCalled(1)
        verify(mockDistanceCalculator.registerPeer(peer: peer2)).wasCalled(1)
        verify(mockDistanceCalculator.registerPeer(peer: peer3)).wasCalled(2)
        verify(mockDistanceCalculator.deregisterPeer(peer: peer0)).wasCalled(1)
        verify(mockDistanceCalculator.deregisterPeer(peer: peer1)).wasCalled(1)
        verify(mockDistanceCalculator.deregisterPeer(peer: peer2)).wasCalled(1)
        verify(mockDistanceCalculator.deregisterPeer(peer: peer3)).wasCalled(2)
        verify(mockDistanceCalculator.reset()).wasCalled(3)
        verify(mockDistanceCalculator.reset()).wasCalled(3)
    }
}

// MARK: Speaker tests
final class DistanceManagerSpeakerTests: XCTestCase {
    let mockDistanceCalculator = mock(DistanceCalculatorProtocol.self)
    let mockSendDelegate = mock(NeighborMessageSendDelegate.self)
    let mockUpdateDelegate = mock(DistanceManagerUpdateDelegate.self)

    let initiatorID = MCPeerID(displayName: "000000000000000A").id
    let selfID = MCPeerID(displayName: String(repeating: "000000000000000B", count: 16)).id

    let kTimeoutInNS = 40 * NSEC_PER_MSEC // TODO remove dependency on DistanceManager source

    typealias DM = DistanceManager

    override func setUp() {
        DM.registerSendDelegate(delegate: mockSendDelegate)
        DM.registerUpdateDelegate(delegate: mockUpdateDelegate)
        DM.setup(
            speakTimerDelegate: nil,
            spokeDelegate: nil,
            distanceCalculator: mockDistanceCalculator
        )
    }

    override func tearDown() {
        reset(mockDistanceCalculator)
        reset(mockSendDelegate)
        reset(mockUpdateDelegate)
    }

    func verifyTotalMessage(expected: UInt) {
        verify(mockSendDelegate.send(
            toPeers: any([DistanceManager.PeerID].self),
            withMessage: any(MessageWrapper.self),
            withReliability: .reliable
        )).wasCalled(Int(expected))
    }

    func verifyPeerRegistrations(extraPeers _: [DistanceManager.PeerID]) {
        verify(mockDistanceCalculator.registerPeer(peer: any(DistanceManager.PeerID.self))).wasNeverCalled()
    }

    func testSpeakerInitSendsInitAck() async throws {
        DM.addPeers(peers: [initiatorID])
        given(mockDistanceCalculator.speak(receivedAt: any(UInt64.self))).willReturn(0)
        try DM.receiveMessage(
            message: DistanceProtocolWrapper.with {
                $0.type = .init_p(Init())
            },
            from: initiatorID,
            receivedAt: 0
        )

        DM.clearAllAndCancel()

        verifyTotalMessage(expected: 1)

        verify(mockSendDelegate.send(
            toPeers: [initiatorID],
            withMessage: makeAppMessage(type: .initAck(InitAck())),
            withReliability: .reliable
        )).wasCalled(1)

        verifyPeerRegistrations(extraPeers: [])
    }


    func testSpeakerInitResendsInitAck() async throws {
        DM.addPeers(peers: [initiatorID])
        given(mockDistanceCalculator.speak(receivedAt: any(UInt64.self))).willReturn(0)
        try DM.receiveMessage(
            message: DistanceProtocolWrapper.with {
                $0.type = .init_p(Init())
            },
            from: initiatorID,
            receivedAt: 0
        )

        try DM.receiveMessage(
            message: DistanceProtocolWrapper.with {
                $0.type = .init_p(Init())
            },
            from: initiatorID,
            receivedAt: 0
        )

        DM.clearAllAndCancel()

        verifyTotalMessage(expected: 2)
        verify(mockSendDelegate.send(
            toPeers: [initiatorID],
            withMessage: makeAppMessage(type: .initAck(InitAck())),
            withReliability: .reliable
        )).wasCalled(2)

        verifyPeerRegistrations(extraPeers: [])
    }

    func testSpeakerInitDoesntSendInitAckToUnknownInitiator() async throws {
        DM.addPeers(peers: [initiatorID])
        given(mockDistanceCalculator.speak(receivedAt: any(UInt64.self))).willReturn(0)
        let unknownInitiator = MCPeerID(displayName: "BADBADBADBADBEEF").id
        try DM.receiveMessage(
            message: DistanceProtocolWrapper.with {
                $0.type = .init_p(Init())
            },
            from: unknownInitiator,
            receivedAt: 0
        )

        DM.clearAllAndCancel()

        verifyTotalMessage(expected: 0)

        verifyPeerRegistrations(extraPeers: [])
    }

    func testSpeakerInitSendsDistanceIfAlreadyKnown() async throws {
        DM.addPeers(peers: [initiatorID])
        DM.addPeers(peersWithDist: [(initiatorID, .someCalculated(1.0))])
        given(mockDistanceCalculator.speak(receivedAt: any(UInt64.self))).willReturn(0)

        try DM.receiveMessage(
            message: DistanceProtocolWrapper.with {
                $0.type = .init_p(Init())
            },
            from: initiatorID,
            receivedAt: 0
        )

        DM.clearAllAndCancel()

        verifyTotalMessage(expected: 1)
        verify(mockSendDelegate.send(
            toPeers: [initiatorID],
            withMessage: makeAppMessage(type: .done(Done.with {
                    $0.distanceInM = 1.0
                })),
            withReliability: .reliable
        )).wasCalled(1)

        verifyPeerRegistrations(extraPeers: [])
    }

    func testSpeakerTimeoutReceivingSpeakCommand() async throws {
        DM.addPeers(peers: [initiatorID])
        given(mockDistanceCalculator.speak(receivedAt: any(UInt64.self))).willReturn(0)
        try DM.receiveMessage(
            message: DistanceProtocolWrapper.with {
                $0.type = .init_p(Init())
            },
            from: initiatorID,
            receivedAt: 0
        )

        try await Task.sleep(nanoseconds: kTimeoutInNS)

        try DM.receiveMessage(
            message: DistanceProtocolWrapper.with {
                $0.type = .speak(Speak())
            },
            from: initiatorID,
            receivedAt: 0
        )

        DM.clearAllAndCancel()

        verifyTotalMessage(expected: 1)

        verify(mockSendDelegate.send(
            toPeers: [initiatorID],
            withMessage: makeAppMessage(type: .initAck(InitAck())),
            withReliability: .reliable
        )).wasCalled(1)

        verifyPeerRegistrations(extraPeers: [])
    }

    func testSpeakerSpeak() async throws {
        DM.addPeers(peers: [initiatorID])
        given(mockDistanceCalculator.speak(receivedAt: any(UInt64.self))).willReturn(0)
        given(mockDistanceCalculator.speak(receivedAt: any())).willReturn(293)

        try DM.receiveMessage(
            message: DistanceProtocolWrapper.with {
                $0.type = .init_p(Init())
            },
            from: initiatorID,
            receivedAt: 0
        )

        try DM.receiveMessage(
            message: DistanceProtocolWrapper.with {
                $0.type = .speak(Speak())
            },
            from: initiatorID,
            receivedAt: 0
        )

        DM.clearAllAndCancel()

        verifyTotalMessage(expected: 2)

        verify(mockSendDelegate.send(
            toPeers: [initiatorID],
            withMessage: makeAppMessage(type: .initAck(InitAck())),
            withReliability: .reliable
        )).wasCalled(1)

        verify(mockSendDelegate.send(
            toPeers: [initiatorID],
            withMessage: makeAppMessage(type: .spoke(Spoke.with {
                    $0.delayInNs = 293
                })),
            withReliability: .reliable
        )).wasCalled(1)

        verifyPeerRegistrations(extraPeers: [])
    }

    func testSpeakerSpeakTimeoutReceivingDone() async throws {
        DM.addPeers(peers: [initiatorID])
        given(mockDistanceCalculator.speak(receivedAt: any(UInt64.self))).willReturn(0)
        given(mockDistanceCalculator.speak(receivedAt: any())).willReturn(127)
        try DM.receiveMessage(
            message: DistanceProtocolWrapper.with {
                $0.type = .init_p(Init())
            },
            from: initiatorID,
            receivedAt: 0
        )

        try DM.receiveMessage(
            message: DistanceProtocolWrapper.with {
                $0.type = .speak(Speak())
            },
            from: initiatorID,
            receivedAt: 0
        )

        try await Task.sleep(nanoseconds: kTimeoutInNS)

        try DM.receiveMessage(
            message: DistanceProtocolWrapper.with {
                $0.type = .done(Done.with {
                    $0.distanceInM = 1.73
                })
            },
            from: initiatorID,
            receivedAt: 0
        )

        DM.clearAllAndCancel()

        verifyTotalMessage(expected: 2)

        verify(mockSendDelegate.send(
            toPeers: [initiatorID],
            withMessage: makeAppMessage(type: .initAck(InitAck())),
            withReliability: .reliable
        )).wasCalled(1)

        verify(mockSendDelegate.send(
            toPeers: [initiatorID],
            withMessage: makeAppMessage(type: .spoke(Spoke.with {
                    $0.delayInNs = 127
                })),
            withReliability: .reliable
        )).wasCalled(1)

        verify(mockUpdateDelegate.didUpdate(distancesByPeer: any([DM.PeerID:DM.PeerDist].self))).wasCalled(0)

        verifyPeerRegistrations(extraPeers: [])
    }

    func testSpeakerReceiveDone() async throws {
        DM.addPeers(peers: [initiatorID])
        given(mockDistanceCalculator.speak(receivedAt: any(UInt64.self))).willReturn(0)
        given(mockDistanceCalculator.speak(receivedAt: any())).willReturn(101)
        try DM.receiveMessage(
            message: DistanceProtocolWrapper.with {
                $0.type = .init_p(Init())
            },
            from: initiatorID,
            receivedAt: 0
        )

        try DM.receiveMessage(
            message: DistanceProtocolWrapper.with {
                $0.type = .speak(Speak())
            },
            from: initiatorID,
            receivedAt: 0
        )

        try DM.receiveMessage(
            message: DistanceProtocolWrapper.with {
                $0.type = .done(Done.with {
                    $0.distanceInM = 1.73
                })
            },
            from: initiatorID,
            receivedAt: 0
        )

        DM.clearAllAndCancel()

        verifyTotalMessage(expected: 2)

        verify(mockSendDelegate.send(
            toPeers: [initiatorID],
            withMessage: makeAppMessage(type: .initAck(InitAck())),
            withReliability: .reliable
        )).wasCalled(1)

        verify(mockSendDelegate.send(
            toPeers: [initiatorID],
            withMessage: makeAppMessage(type: .spoke(Spoke.with {
                    $0.delayInNs = 101
                })),
            withReliability: .reliable
        )).wasCalled(1)

        verify(mockUpdateDelegate.didUpdate(distancesByPeer: any([DM.PeerID:DM.PeerDist].self))).wasCalled(1)
        verify(mockUpdateDelegate.didUpdate(
            distancesByPeer: [initiatorID:.someCalculated(1.73)]
        )).wasCalled(1)

        verifyPeerRegistrations(extraPeers: [])
    }
}
