//
//  DistanceVectorRouter.swift
//  SWIMNet
//
//  Created by Andrew Orals on 2/21/24.
//

import Foundation

typealias PeerIdT = Sendable & Comparable & Hashable
typealias CostT = UInt8

struct ForwardingEntry<PeerId: PeerIdT>: Sendable, Equatable {
    var linkId: PeerId
    var cost: CostT

    static func computeForwardingEntry(
        fromNeighbor peerId: PeerId,
        toPeer destId: PeerId,
        withCost cost: CostT,
        givenExistingEntry forwardingEntry: ForwardingEntry?
    ) -> ForwardingEntry? {
        guard forwardingEntry != nil else {
            return ForwardingEntry(linkId: peerId, cost: cost)
        }

        if (cost < forwardingEntry!.cost) {
            return ForwardingEntry(linkId: peerId, cost: cost)
        } else if (cost == forwardingEntry!.cost &&
                   peerId < forwardingEntry!.linkId) {
            return ForwardingEntry(
                linkId: peerId,
                cost: cost
            )
        }

        return nil // Did not update anything
    }

    init(linkId: PeerId, cost: CostT) {
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
    typealias DistanceVector = WatchableDictionary<PeerId, ForwardingEntry<PeerId>>
    typealias DistanceVectorDict = [PeerId:ForwardingEntry<PeerId>]
    typealias LinkCosts = [PeerId:CostT]

    private struct WatchableDictionaryUpdateDelegate: DidUpdateCallbackProtocol {
        var owner: DistanceVectorRoutingNode<PeerId, SendDelegateClass>
        func didUpdate() -> Void {
            // Values have to be captured explicitly so that they are passed by value
            owner.distanceVectorSenderQueue.async { [
                sendDistanceVectorToPeers = owner.sendDistanceVectorToPeers,
                neighbors = owner.linkCosts.keys,
                distanceVector = owner.distanceVector.dict,
                sendDelegate = owner.sendDelegate
            ] in
                Task {
                    try await sendDistanceVectorToPeers(
                        Array(neighbors),
                        distanceVector,
                        sendDelegate
                    )
                }
            }
        }
    }

    var sendDelegate: SendDelegateClass {
        didSet {
            distanceVectorSenderQueue.async { [
                sendDistanceVectorToPeers = self.sendDistanceVectorToPeers,
                neighbors = self.linkCosts.keys,
                distanceVector = self.distanceVector.dict,
                sendDelegate = self.sendDelegate
            ] in
                Task {
                    try await sendDistanceVectorToPeers(
                        Array(neighbors),
                        distanceVector,
                        sendDelegate
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
        selfId: PeerId,
        linkUpdateThreshold: UInt,
        dvUpdateThreshold: UInt,
        linkCosts: LinkCosts,
        sendDelegate: SendDelegateClass
    ) {
        var backingDict: DistanceVectorDict = [
            selfId: ForwardingEntry(linkId: selfId, cost: 0),
        ]

        for (linkId, linkCost) in linkCosts {
            backingDict[linkId] = ForwardingEntry(
                linkId: linkId,
                cost: linkCost
            )
        }

        self.distanceVector = DistanceVector(
            updateThreshold: dvUpdateThreshold,
            backingDict: backingDict
        )
        self.linkCosts = linkCosts
        self.sendDelegate = sendDelegate

        self.dVUpdateThreshold = dvUpdateThreshold
        self.distanceVector.didUpdateCallback = WatchableDictionaryUpdateDelegate(owner: self)
    }

    func recvDistanceVector(
        fromNeighbor peerId: PeerId,
        withDistanceVector peerDv: DistanceVectorDict
    ) {
        var updates: [(PeerId, ForwardingEntry<PeerId>)] = []
        for (destId, peerForwardingEntry) in peerDv {
            let candidate_cost = peerForwardingEntry.cost

            guard candidate_cost != CostT.max else {
                let linkCostDirectToDest = linkCosts[destId]
                if linkCostDirectToDest != nil {
                    // can still reach host through direct link
                    updates.append((destId, ForwardingEntry(linkId: destId, cost: linkCostDirectToDest!)))
                } else {
                    // can't reach host, insert tombstone
                    updates.append((destId, ForwardingEntry(linkId: peerId, cost: CostT.max)))
                }
                continue
            }

            let linkCost = linkCosts[peerId]

            guard linkCost != nil else {
                // can't reach host, but don't insert tombstone because neighbor is unknown.
                //   neighbor first has to be added to the list of links
                continue
            }

            let new_cost = candidate_cost + linkCost!

            if let newEntry = ForwardingEntry.computeForwardingEntry(
                fromNeighbor: peerId,
                toPeer: destId,
                withCost: new_cost,
                givenExistingEntry: distanceVector[destId]
            ) {
                updates.append((destId, newEntry))
            }
        }

        distanceVector.batchUpdate(keyValuePairs: updates)
    }

    func updateLinkCost(linkId: PeerId, newCost: CostT?) {
        linkCosts[linkId] = newCost

        guard newCost != nil else {
            var updates: [(PeerId, ForwardingEntry<PeerId>)] = []
            for (destId, forwardingEntry) in self.distanceVector {
                if forwardingEntry.linkId == linkId {
                    // Tombstone the destination because the neighbor is unreachable
                    updates.append((destId, ForwardingEntry(linkId: linkId, cost: CostT.max)))
                }
            }
            distanceVector.batchUpdate(keyValuePairs: updates)
            return
        }

        // Calculate new forwarding entry for direct link to neighbor
        if let newEntry = ForwardingEntry.computeForwardingEntry(
            fromNeighbor: linkId,
            toPeer: linkId,
            withCost: newCost!,
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
        withDistanceVector dv: DistanceVectorDict,
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
    private var linkCosts: LinkCosts
    private let distanceVectorSenderQueue = DispatchQueue(label: "com.andreworals.distanceVectorSenderQueue")
}
