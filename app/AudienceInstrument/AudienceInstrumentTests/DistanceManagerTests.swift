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

final class DistanceManagerInitiatorTests: XCTestCase {
    let mockDistanceCalculator = mock(DistanceCalculatorProtocol.self)
    let mockSendDelegate = mock(DistanceManagerSendDelegate.self)
    let mockUpdateDelegate = mock(DistanceManagerUpdateDelegate.self)

    let kTimeoutInNS = 40 * NSEC_PER_MSEC // TODO remove dependency on DistanceManager source

    typealias DM = DistanceManager

    override func setUp() {
        DM.registerSendDelegate(delegate: mockSendDelegate)
        DM.registerUpdateDelegate(delegate: mockUpdateDelegate)
        DM.setup(distanceCalculator: mockDistanceCalculator)
    }

    override func tearDown() {
        reset(mockDistanceCalculator)
        reset(mockSendDelegate)
        reset(mockUpdateDelegate)
    }

    func verifyTotalMessage(expected: UInt) {
        verify(mockSendDelegate.send(
            toPeers: any([MCPeerID].self),
            withMessage: any(DistanceProtocolWrapper.self))
        ).wasCalled(Int(expected))
    }

    func verifyTotalMessages(expected: UInt) {
        verify(mockSendDelegate.send(
            toPeers: any([MCPeerID].self),
            withMessages: any([DistanceProtocolWrapper].self))
        ).wasCalled(Int(expected))
    }

    func verifyPeerRegistrations(peers: [MCPeerID]) {
        verify(mockDistanceCalculator.registerPeer(peer: any(MCPeerID.self))).wasCalled(peers.count)
        verify(mockDistanceCalculator.deregisterPeer(peer: any(MCPeerID.self))).wasCalled(peers.count)

        for peer in peers {
            verify(mockDistanceCalculator.registerPeer(peer: peer)).wasCalled(1)
            verify(mockDistanceCalculator.deregisterPeer(peer: peer)).wasCalled(1)
        }
    }


// MARK: Initiator tests

    func testInitiatorOnePeer() async throws {
        let peer0 = MCPeerID(displayName: "test-peer0")
        DM.addPeers(peers: [peer0])

        DM.initiate(retries: 0)

        try DM.receiveMessage(
            message: DistanceProtocolWrapper.with {
                $0.type = .initAck(InitAck())
            },
            from: peer0,
            receivedAt: 0
        )

        DM.reset()

        verifyTotalMessage(expected: 2)

        verify(mockSendDelegate.send(
            toPeers: [peer0],
            withMessage: DistanceProtocolWrapper.with {
                $0.type = .init_p(Init())
            }
        )).wasCalled(1)
        verify(mockSendDelegate.send(
            toPeers: [peer0],
            withMessage: DistanceProtocolWrapper.with {
                $0.type = .speak(Speak())
            }
        )).wasCalled(1)

        verify(mockDistanceCalculator.listen()).wasCalled(1)
        verifyPeerRegistrations(peers: [peer0])
    }
    
    func testInitiatorMultiPeers() async throws {
        let peer0 = MCPeerID(displayName: "test-peer0")
        let peer1 = MCPeerID(displayName: "test-peer1")
        let peer2 = MCPeerID(displayName: "test-peer2")
        DM.addPeers(peers: [peer0, peer1, peer2])

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

        DM.reset()

        verifyTotalMessage(expected: 2)

        verify(mockSendDelegate.send(
            toPeers: any(containing: peer0, peer1, peer2),
            withMessage: DistanceProtocolWrapper.with {
                $0.type = .init_p(Init())
            }
        )).wasCalled(1)
        verify(mockSendDelegate.send(
            toPeers: any(containing: peer0, peer1, peer2),
            withMessage: DistanceProtocolWrapper.with {
                $0.type = .speak(Speak())
            }
        )).wasCalled(1)

        verify(mockDistanceCalculator.listen()).wasCalled(1)
        verifyPeerRegistrations(peers: [peer0, peer1, peer2])
    }

    func testInitiatorMultiPeerAllInitAckMultiTryTimeout() {}

    func testInitiatorMultiPeerSingleInitAckMultiTryTimeout() {}

    func testInitiatorMultiPeerAllInitAckMultiTry() {}

    func testInitiatorMultiPeerSinglInitAckMultiTry() {}

    func testInitiatorMultiPeerAllSpokeTimeout() {}

    func testInitiatorMultiPeerSingleSpokeTimeout() {}

    func testInitiatorMultiPhaseAddPeer() {}

    func testInitiatorMultiPhaseRemovePeer() {}
}

// MARK: Speaker tests
/// Must execute in serial because DistanceManager is not thread-safe
final class DistanceManagerSpeakerTests: XCTestCase {
    let mockDistanceCalculator = mock(DistanceCalculatorProtocol.self)
    let mockSendDelegate = mock(DistanceManagerSendDelegate.self)
    let mockUpdateDelegate = mock(DistanceManagerUpdateDelegate.self)

    let initiatorID = MCPeerID(displayName: "test-initiator")
    let selfID = MCPeerID(displayName: "test-speaker")

    let kTimeoutInNS = 40 * NSEC_PER_MSEC // TODO remove dependency on DistanceManager source

    typealias DM = DistanceManager

    override func setUp() {
        DM.registerSendDelegate(delegate: mockSendDelegate)
        DM.registerUpdateDelegate(delegate: mockUpdateDelegate)
        DM.setup(distanceCalculator: mockDistanceCalculator)
    }

    override func tearDown() {
        reset(mockDistanceCalculator)
        reset(mockSendDelegate)
        reset(mockUpdateDelegate)
    }

    func verifyTotalMessage(expected: UInt) {
        verify(mockSendDelegate.send(
            toPeers: any([MCPeerID].self),
            withMessage: any(DistanceProtocolWrapper.self))
        ).wasCalled(Int(expected))
    }

    func verifyPeerRegistrations(extraPeers: [MCPeerID]) {
        verify(mockDistanceCalculator.registerPeer(peer: any(MCPeerID.self))).wasCalled(extraPeers.count + 1)
        verify(mockDistanceCalculator.deregisterPeer(peer: any(MCPeerID.self))).wasCalled(extraPeers.count + 1)

        verify(mockDistanceCalculator.registerPeer(peer: initiatorID)).wasCalled(1)
        verify(mockDistanceCalculator.deregisterPeer(peer: initiatorID)).wasCalled(1)

        for extraPeer in extraPeers {
            verify(mockDistanceCalculator.registerPeer(peer: extraPeer)).wasCalled(1)
            verify(mockDistanceCalculator.deregisterPeer(peer: extraPeer)).wasCalled(1)
        }
    }

    func testSpeakerInitSendsInitAck() async throws {
        DM.addPeers(peers: [initiatorID])
        try DM.receiveMessage(
            message: DistanceProtocolWrapper.with {
                $0.type = .init_p(Init())
            },
            from: initiatorID,
            receivedAt: 0
        )

        DM.reset()

        verifyTotalMessage(expected: 1)

        verify(mockSendDelegate.send(
            toPeers: [initiatorID],
            withMessage: DistanceProtocolWrapper.with {
                $0.type = .initAck(InitAck())
            }
        )).wasCalled(1)

        verifyPeerRegistrations(extraPeers: [])
    }


    func testSpeakerInitResendsInitAck() async throws {
        DM.addPeers(peers: [initiatorID])
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

        DM.reset()

        verifyTotalMessage(expected: 2)
        verify(mockSendDelegate.send(
            toPeers: [initiatorID],
            withMessage: DistanceProtocolWrapper.with {
                $0.type = .initAck(InitAck())
            }
        )).wasCalled(2)

        verifyPeerRegistrations(extraPeers: [])
    }

    func testSpeakerInitDoesntSendInitAckToUnknownInitiator() async throws {
        DM.addPeers(peers: [initiatorID])
        let unknownInitiator = MCPeerID(displayName: "test-unknown-initiator")
        try DM.receiveMessage(
            message: DistanceProtocolWrapper.with {
                $0.type = .init_p(Init())
            },
            from: unknownInitiator,
            receivedAt: 0
        )

        DM.reset()

        verifyTotalMessage(expected: 0)

        verifyPeerRegistrations(extraPeers: [])
    }

    func testSpeakerInitSendsDistanceIfAlreadyKnown() async throws {
        DM.addPeers(peers: [initiatorID])
        DM.addPeers(peersWithDist: [(initiatorID, .someCalculated(1.0))])

        try DM.receiveMessage(
            message: DistanceProtocolWrapper.with {
                $0.type = .init_p(Init())
            },
            from: initiatorID,
            receivedAt: 0
        )

        DM.reset()

        verifyTotalMessage(expected: 1)
        verify(mockSendDelegate.send(
            toPeers: [initiatorID],
            withMessage: DistanceProtocolWrapper.with {
                $0.type = .done(Done.with {
                    $0.distanceInM = 1.0
                })
            }
        )).wasCalled(1)

        verifyPeerRegistrations(extraPeers: [])
    }

    func testSpeakerTimeoutReceivingSpeakCommand() async throws {
        DM.addPeers(peers: [initiatorID])
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

        DM.reset()

        verifyTotalMessage(expected: 1)

        verify(mockSendDelegate.send(
            toPeers: [initiatorID],
            withMessage: DistanceProtocolWrapper.with {
                $0.type = .initAck(InitAck())
            }
        )).wasCalled(1)

        verifyPeerRegistrations(extraPeers: [])
    }

    func testSpeakerSpeak() async throws {
        DM.addPeers(peers: [initiatorID])
        given(mockDistanceCalculator.speak()).willReturn(293)

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

        DM.reset()

        verifyTotalMessage(expected: 2)

        verify(mockSendDelegate.send(
            toPeers: [initiatorID],
            withMessage: DistanceProtocolWrapper.with {
                $0.type = .initAck(InitAck())
            }
        )).wasCalled(1)

        verify(mockSendDelegate.send(
            toPeers: [initiatorID],
            withMessage: DistanceProtocolWrapper.with {
                $0.type = .spoke(Spoke.with {
                    $0.delayInNs = 293
                })
            }
        )).wasCalled(1)

        verifyPeerRegistrations(extraPeers: [])
    }

    func testSpeakerSpeakTimeoutReceivingDone() async throws {
        DM.addPeers(peers: [initiatorID])
        given(mockDistanceCalculator.speak()).willReturn(127)
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

        DM.reset()

        verifyTotalMessage(expected: 2)

        verify(mockSendDelegate.send(
            toPeers: [initiatorID],
            withMessage: DistanceProtocolWrapper.with {
                $0.type = .initAck(InitAck())
            }
        )).wasCalled(1)

        verify(mockSendDelegate.send(
            toPeers: [initiatorID],
            withMessage: DistanceProtocolWrapper.with {
                $0.type = .spoke(Spoke.with {
                    $0.delayInNs = 127
                })
            }
        )).wasCalled(1)

        verify(mockUpdateDelegate.didUpdate(distancesByPeer: any([DM.PeerID:DM.PeerDist].self))).wasCalled(0)

        verifyPeerRegistrations(extraPeers: [])
    }

    func testSpeakerReceiveDone() async throws {
        DM.addPeers(peers: [initiatorID])
        given(mockDistanceCalculator.speak()).willReturn(101)
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

        DM.reset()

        verifyTotalMessage(expected: 2)

        verify(mockSendDelegate.send(
            toPeers: [initiatorID],
            withMessage: DistanceProtocolWrapper.with {
                $0.type = .initAck(InitAck())
            }
        )).wasCalled(1)

        verify(mockSendDelegate.send(
            toPeers: [initiatorID],
            withMessage: DistanceProtocolWrapper.with {
                $0.type = .spoke(Spoke.with {
                    $0.delayInNs = 101
                })
            }
        )).wasCalled(1)

        verify(mockUpdateDelegate.didUpdate(distancesByPeer: any([DM.PeerID:DM.PeerDist].self))).wasCalled(1)
        verify(mockUpdateDelegate.didUpdate(
            distancesByPeer: [initiatorID:.someCalculated(1.73)]
        )).wasCalled(1)

        verifyPeerRegistrations(extraPeers: [])
    }
}
