//
//  DistanceVectorRouter.swift
//  SWIMNet
//
//  Created by Andrew Orals on 2/21/24.
//

import Foundation

typealias PeerIdT = Sendable & Comparable & Hashable

protocol UIntLike {}
extension UInt: UIntLike {}
extension UInt8: UIntLike {}
extension UInt16: UIntLike {}
extension UInt32: UIntLike {}
extension UInt64: UIntLike {}
typealias CostT = UIntLike & UnsignedInteger & FixedWidthInteger & Sendable

struct ForwardingEntry<PeerId: PeerIdT, Cost: CostT>:
    Sendable,
    Equatable,
    CustomStringConvertible
{
    var linkId: PeerId
    var cost: Cost
    var description: String {
        "NextHop: \(linkId) Cost: \(cost)"
    }

    static func computeForwardingEntry(
        fromNeighbor peerId: PeerId,
        toPeer destId: PeerId,
        withCost cost: Cost,
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

    init(linkId: PeerId, cost: Cost) {
        self.linkId = linkId
        self.cost = cost
    }
}

protocol SendDelegate {
    @Sendable
    func send(
        from: any PeerIdT,
        sendTo peerId: any PeerIdT,
        withDVDict dv: any Sendable
    ) async throws -> Void
}

protocol PrintableAsDistanceVector {
    var dvstr: String { get }
}

extension Dictionary: PrintableAsDistanceVector where Key: Comparable, Value: CustomStringConvertible {
    var dvstr: String {
        var out = "{"
        for key in self.keys.sorted() {
            out += "\n  dest: \(key) \(self[key]!)"
        }
        out += "\n}\n"

        return out
    }
}

actor DistanceVectorRoutingNode<
    PeerId: PeerIdT,
    Cost: CostT,
    SendDelegateClass: SendDelegate
> {
    internal typealias DVEnt = ForwardingEntry<PeerId, Cost>
    internal typealias DistanceVector = [PeerId:DVEnt]
    typealias LinkCosts = [PeerId:Cost]

    private func getLinks() -> LinkCosts.Keys {
        return linkCosts.keys
    }

    private func getDistanceVector() -> DistanceVector {
        return distanceVector
    }

    private func getSendDelegate() -> SendDelegateClass {
        return sendDelegate
    }

    var sendDelegate: SendDelegateClass {
        didSet { sendDistanceVectorToPeers() }
    }

    init(
        selfId: PeerId,
        dvUpdateThreshold: UInt,
        linkCosts: LinkCosts = [:],
        sendDelegate: SendDelegateClass
    ) {
        self.selfId = selfId
        distanceVector = [
            selfId: ForwardingEntry(linkId: selfId, cost: 0),
        ]

        for (linkId, linkCost) in linkCosts {
            distanceVector[linkId] = ForwardingEntry(
                linkId: linkId,
                cost: linkCost
            )
        }

        self.linkCosts = linkCosts
        self.sendDelegate = sendDelegate
    }

    func recvDistanceVector(
        fromNeighbor peerId: PeerId,
        withDistanceVector peerDv: DistanceVector
    ) {
        var updated = false

        defer {
            if updated {
                sendDistanceVectorToPeers()
            }
        }

        for (destId, peerForwardingEntry) in peerDv {
            let candidate_cost = peerForwardingEntry.cost
            let existingEntry = distanceVector[destId]

            guard candidate_cost != Cost.max else {
                if existingEntry?.linkId == peerId && linkCosts[destId] != nil {
                    // can still reach host through direct link
                    distanceVector[destId] = ForwardingEntry(linkId: destId, cost: linkCosts[destId]!)
                    updated = true
                } else if existingEntry?.linkId == peerId {
                    // route to host is down
                    distanceVector[destId] = ForwardingEntry(linkId: peerId, cost: Cost.max)
                } else {
                    updated = true
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
                distanceVector[destId] = newEntry
                updated = true
            }
        }
    }

    func updateLinkCost(linkId: PeerId, newCost: Cost?) {
        linkCosts[linkId] = newCost
        var updated = false

        defer {
            if updated {
                sendDistanceVectorToPeers()
            }
        }

        guard newCost != nil else {
            for (destId, forwardingEntry) in self.distanceVector {
                if forwardingEntry.linkId == linkId {
                    // Tombstone the destination because the neighbor is unreachable
                    distanceVector[destId] = ForwardingEntry(linkId: linkId, cost: Cost.max)
                }
            }
            updated = true
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
            updated = true
        }
    }

    func getLinkForDest(dest: PeerId) -> Optional<(PeerId, Cost)> {
        if let entry = distanceVector[dest] {
            guard entry.cost != Cost.max else {
                return nil
            }

            return (entry.linkId, entry.cost)
        }

        return nil
    }

    func sendDistanceVectorToPeers() {
        distanceVectorSenderQueue.async { [
            selfId = self.selfId,
            neighbors = self.linkCosts.keys,
            distanceVector = self.distanceVector,
            sendDelegate = self.sendDelegate
        ] in
            Task {
                for peerId in neighbors {
                    try await sendDelegate.send(
                        from: selfId,
                        sendTo: peerId,
                        withDVDict: distanceVector
                    )
                }
            }
        }
    }
 
    internal var distanceVector: DistanceVector
    private var selfId: PeerId
    private var linkCosts: LinkCosts
    private let distanceVectorSenderQueue = DispatchQueue(label: "com.andreworals.distanceVectorSenderQueue")
}
