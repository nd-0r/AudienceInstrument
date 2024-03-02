//
//  DistanceVectorRouter.swift
//  SWIMNet
//
//  Created by Andrew Orals on 2/21/24.
//

import Foundation

typealias PeerIdT = Sendable & Comparable & Hashable

struct ForwardingEntry<PeerId: PeerIdT>: Sendable, Equatable {
    var linkId: PeerId
    var cost: UInt8

    static func computeForwardingEntry(
        toPeer peerId: PeerId,
        withCost cost: UInt8,
        givenExistingEntry forwardingEntry: ForwardingEntry?
    ) -> ForwardingEntry? {
        guard forwardingEntry != nil else {
            return ForwardingEntry(linkId: peerId, cost: cost)
        }

        if (cost < forwardingEntry!.cost) {
            return ForwardingEntry(linkId: peerId, cost: cost)
        } else if (cost == forwardingEntry!.cost && peerId < forwardingEntry!.linkId) {
            return ForwardingEntry(
                linkId: peerId,
                cost: cost
            )
        }

        return nil // Did not update anything
    }

    init(linkId: PeerId, cost: UInt8) {
        self.linkId = linkId
        self.cost = cost
    }
}

protocol SendDelegate {
    func send(
        sendTo peerId: any PeerIdT,
        withDVDict dv: any Sendable
    ) async throws -> Void
}

// TODO handle removing neighbors
class DistanceVectorRoutingNode<
    PeerId: PeerIdT,
    SendDelegateClass: SendDelegate
> {
    typealias PeerIdInternalT = PeerId
    typealias DistanceVector = WatchableDictionary<PeerId, ForwardingEntry<PeerId>>
    typealias LinkCosts = [PeerId:UInt8]

    private struct WatchableDictionaryUpdateDelegate: DidUpdateCallbackProtocol {
        var owner: DistanceVectorRoutingNode<PeerId, SendDelegateClass>
        func didUpdate() -> Void {
            owner.distanceVectorSenderQueue.async { [owner] in
                Task {
                    try await owner.sendDistanceVectorToPeers(
                        toNeighbors: Array(owner.linkCosts.keys),
                        withDistanceVector: owner.distanceVector.dict,
                        withSendDelegate: owner.sendDelegate
                    )
                }
            }
        }
    }

    var sendDelegate: SendDelegateClass {
        didSet {
            distanceVectorSenderQueue.async { [self] in
                Task {
                    try await sendDistanceVectorToPeers(
                        toNeighbors: Array(linkCosts.keys),
                        withDistanceVector: distanceVector.dict,
                        withSendDelegate: sendDelegate
                    )
                }
            }
        }
    }

    var dVUpdateThreshold: UInt {
        get { return self.distanceVector.updateThreshold }
        set { self.distanceVector.updateThreshold = newValue }
    }

    init(
        linkUpdateThreshold: UInt,
        dvUpdateThreshold: UInt,
        linkCosts: LinkCosts,
        sendDelegate: SendDelegateClass
    ) {
        self.distanceVector = DistanceVector(updateThreshold: dvUpdateThreshold)
        self.linkCosts = linkCosts
        self.sendDelegate = sendDelegate

        self.dVUpdateThreshold = dvUpdateThreshold
        self.distanceVector.didUpdateCallback = WatchableDictionaryUpdateDelegate(owner: self)
    }

    func recvDistanceVector(
        fromNeighbor peerId: PeerId,
        withDistanceVector peerDv: DistanceVector
    ) {
        var updated = false
        for (destId, linkCost) in peerDv {
            let candidate_cost = linkCost.cost
            guard candidate_cost != UInt8.max else {
                continue
            }

            let linkCost = linkCosts[peerId]
            guard linkCost != nil else {
                continue
            }

            let new_cost = candidate_cost + linkCost!

            if let newEntry = ForwardingEntry.computeForwardingEntry(
                toPeer: destId,
                withCost: new_cost,
                givenExistingEntry: distanceVector[destId]
            ) {
                updated = true
                distanceVector[destId] = newEntry
            }
        }

        if updated {
            distanceVectorSenderQueue.async { [self] in
                Task {
                    try await sendDistanceVectorToPeers(
                        toNeighbors: Array(linkCosts.keys),
                        withDistanceVector: distanceVector.dict,
                        withSendDelegate: sendDelegate
                    )
                }
            }
        }
    }

    func updateLinkCost(linkId: PeerId, newCost: UInt8) {
        linkCosts[linkId] = newCost

        if let newEntry = ForwardingEntry.computeForwardingEntry(
            toPeer: linkId,
            withCost: newCost,
            givenExistingEntry: self.distanceVector[linkId]
        ) {
            self.distanceVector[linkId] = newEntry
        }
    }

    func getLinkForDest(dest: PeerId) -> Optional<PeerId> {
        return distanceVector[dest]?.linkId
    }

    private func sendDistanceVectorToPeers(
        toNeighbors neighbors: [PeerId],
        withDistanceVector dv: Dictionary<PeerId, ForwardingEntry<PeerId>>,
        withSendDelegate sd: SendDelegateClass
    ) async throws {
        for peerId in neighbors {
            try await sd.send(
                sendTo: peerId,
                withDVDict: dv
            )
        }
    }
 
    internal var distanceVector: DistanceVector
    private var linkCosts: [PeerId:UInt8]
    private let distanceVectorSenderQueue = DispatchQueue(label: "com.andreworals.distanceVectorSenderQueue")
}
