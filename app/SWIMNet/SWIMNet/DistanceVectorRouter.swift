//
//  DistanceVectorRouter.swift
//  SWIMNet
//
//  Created by Andrew Orals on 2/21/24.
//

import Foundation

public typealias PeerIdT = Sendable & Comparable & Hashable & Codable

private let kMaxPathLen = 16_777_216 // 2^24

public protocol UIntLike {}
// extension UInt: UIntLike {} // (`UIntLike` must be > `kMaxPathLen` in `DistanceVectorRoutingNode`)
// extension UInt8: UIntLike {} // (`UIntLike` must be > `kMaxPathLen` in `DistanceVectorRoutingNode`)
// extension UInt16: UIntLike {} //  (`UIntLike` must be > `kMaxPathLen` in `DistanceVectorRoutingNode`)
extension UInt32: UIntLike {}
extension UInt64: UIntLike {}
public typealias CostT = UIntLike & UnsignedInteger & FixedWidthInteger & Sendable & Codable

public protocol ForwardingEntryProtocol:
    Sendable,
    Equatable,
    CustomStringConvertible
{
    associatedtype P: PeerIdT
    associatedtype C: CostT

    var linkID: P { get set }
    var cost: C { get set}

    init(linkID: P, cost: C)
}

public protocol SendDelegate {
    @Sendable
    func send(
        from: any PeerIdT,
        sendTo peerId: any PeerIdT,
        withDVDict dv: any Sendable
    ) async throws -> Void
}

public protocol AvailableNodesUpdateDelegate {
    func availableNodesDidUpdate(newAvailableNodes: [any PeerIdT])
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

public enum DistanceVectorRoutingNodeError: Error {
    case invalidCost(message: String)
}

public actor DistanceVectorRoutingNode<
    PeerId: PeerIdT,
    Cost: CostT,
    SendDelegateClass: SendDelegate,
    ForwardingEntry: ForwardingEntryProtocol
> where ForwardingEntry.P == PeerId, ForwardingEntry.C == Cost {
    public typealias DVEnt = ForwardingEntry
    public typealias DistanceVector = [PeerId:DVEnt]
    public typealias LinkCosts = [PeerId:Cost]

    private let kMaxPathlen = 16_777_216 // 2^24
    nonisolated let kMaxCost: Cost = Cost.max / Cost(kMaxPathLen) - 1

    private func getLinks() -> LinkCosts.Keys {
        return linkCosts.keys
    }

    private func getDistanceVector() -> DistanceVector {
        return distanceVector
    }

    private func getSendDelegate() -> SendDelegateClass? {
        return sendDelegate
    }

    public var sendDelegate: SendDelegateClass? {
        didSet { sendDistanceVectorToPeers() }
    }

    public var updateDelegate: (any AvailableNodesUpdateDelegate)?

    public init(
        selfId: PeerId,
        dvUpdateThreshold: UInt,
        linkCosts: LinkCosts = [:],
        sendDelegate: SendDelegateClass? = nil,
        updateDelegate: (any AvailableNodesUpdateDelegate)? = nil
    ) {
        self.selfId = selfId
        distanceVector = [
            selfId: ForwardingEntry(linkID: selfId, cost: 0),
        ]

        for (linkId, linkCost) in linkCosts {
            distanceVector[linkId] = ForwardingEntry(
                linkID: linkId,
                cost: linkCost
            )
        }

        self.linkCosts = linkCosts
        self.sendDelegate = sendDelegate
        self.updateDelegate = updateDelegate
    }

    public func recvDistanceVector(
        fromNeighbor peerId: PeerId,
        withDistanceVector peerDv: DistanceVector
    ) {
        var updated = false
        var addedOrRemovedPeers = false
        var toExclude: Set<PeerId> = Set()

        defer {
            if updated {
                sendDistanceVectorToPeers(excluding: toExclude)
            }

            if addedOrRemovedPeers {
                callUpdateDelegateWithAvailablePeers()
            }
        }

        for (destId, peerForwardingEntry) in peerDv {
            let candidate_cost = peerForwardingEntry.cost
            let existingEntry = distanceVector[destId]

            guard candidate_cost != Cost.max else {
                updated = true
                if linkCosts[destId] != nil {
                    // can still reach host through direct link
                    // assuming that each host has a maximum 1 link to neighbors
                    distanceVector[destId] = ForwardingEntry(linkID: destId, cost: linkCosts[destId]!)
                } else if existingEntry?.linkID == peerId {
                    // route to host is down
                    distanceVector[destId] = ForwardingEntry(linkID: peerId, cost: Cost.max)
                    addedOrRemovedPeers = true
                    toExclude.insert(peerId)
                } else {
                    toExclude.insert(peerId)
                }
                continue
            }

            let linkCost = linkCosts[peerId]

            guard linkCost != nil else {
                // can't reach host, but don't insert tombstone because neighbor is unknown.
                //   neighbor first has to be added to the list of links
                continue
            }

            if existingEntry != nil &&
               existingEntry?.cost != Cost.max &&
               candidate_cost > linkCost! + existingEntry!.cost {
                // neighbor needs to update its distance vector
                updated = true
                continue
            }

            let new_cost = candidate_cost + linkCost!

            if let (newEntry, entryAddedOrRemoved) = DistanceVectorRoutingNode<PeerId, Cost, SendDelegateClass, ForwardingEntry>.computeForwardingEntry(
                fromNeighbor: peerId,
                toPeer: destId,
                withCost: new_cost,
                givenExistingEntry: distanceVector[destId],
                givenDirectLinkToDest: linkCosts[destId]
            ) {
                distanceVector[destId] = newEntry
                updated = true
                addedOrRemovedPeers = addedOrRemovedPeers || entryAddedOrRemoved
            }
        }
    }

    public func updateLinkCost(linkId: PeerId, newCost: Cost?) throws {
        guard (newCost ?? 0) <= kMaxCost else {
            throw DistanceVectorRoutingNodeError.invalidCost(
                message: "Cost \(newCost ?? Cost(0)) must be <= \(kMaxCost)"
            )
        }

        linkCosts[linkId] = newCost
        var addedOrRemovedPeers = false
        var updated = true

        defer {
            if updated {
                sendDistanceVectorToPeers()
            }

            if addedOrRemovedPeers {
                callUpdateDelegateWithAvailablePeers()
            }
        }

        guard newCost != nil else {
            for (destId, forwardingEntry) in self.distanceVector {
                if forwardingEntry.linkID == linkId {
                    // Tombstone the destination because the neighbor is unreachable
                    distanceVector[destId] = ForwardingEntry(linkID: linkId, cost: Cost.max)
                    addedOrRemovedPeers = true
                }
            }
            updated = true
            return
        }

        // Calculate new forwarding entry for direct link to neighbor
        if let (newEntry, entryAddedOrRemoved) = DistanceVectorRoutingNode<PeerId, Cost, SendDelegateClass, ForwardingEntry>.computeForwardingEntry(
            fromNeighbor: linkId,
            toPeer: linkId,
            withCost: newCost!,
            givenExistingEntry: self.distanceVector[linkId],
            givenDirectLinkToDest: newCost
        ) {
            self.distanceVector[linkId] = newEntry
            updated = true
            addedOrRemovedPeers = addedOrRemovedPeers || entryAddedOrRemoved
        }
    }

    public func getLinkForDest(dest: PeerId) -> Optional<(PeerId, Cost)> {
        if let entry = distanceVector[dest] {
            guard entry.cost != Cost.max else {
                return nil
            }

            return (entry.linkID, entry.cost)
        }

        return nil
    }

    private func sendDistanceVectorToPeers(
        excluding nodesToExclude: Set<PeerId> = Set()
    ) {
        guard self.sendDelegate != nil else {
            return
        }

        distanceVectorSenderQueue.async { [
            nodesToExclude = nodesToExclude,
            selfId = self.selfId,
            linkCosts = self.linkCosts,
            distanceVector = self.distanceVector,
            sendDelegate = self.sendDelegate!
        ] in
            Task {
                for (peerId, cost) in linkCosts {
                    guard !nodesToExclude.contains(peerId) &&
                          cost != Cost.max else {
                        continue
                    }

                    try await sendDelegate.send(
                        from: selfId,
                        sendTo: peerId,
                        withDVDict: distanceVector
                    )
                }
            }
        }
    }

    private func callUpdateDelegateWithAvailablePeers() {
        let availableNodes = Array(self.distanceVector.filter({ $1.cost != Cost.max }).keys)
        self.updateDelegate?.availableNodesDidUpdate(newAvailableNodes: availableNodes)
    }
    
    /// Computes a forwarding entry or none at all from a given entry and candidate information
    /// depending on whether the existing entry was updated or not. Updated means that the
    /// `ForwardingEntry` changed or was created.
    /// - Parameters:
    ///   - peerId: The neighbor from which the candidate update was received
    ///   - destId: The destination to which the forwarding entry pertains
    ///   - cost: The new cost candidate for the from the neighbor with ID `peerId` existing entry
    ///   - forwardingEntry: The existing forwarding entry; `nil` indicates nonexistent
    ///   - linkCost: The cost of the direct link to the neighbor with ID `peerId`
    /// - Returns: A pair containing the updated forwarding entry and a boolean which is true if
    ///     this reprents a discovery or disappearance of a peer and false otherwise, or nil if no update
    ///     is necessary.
    private static func computeForwardingEntry(
        fromNeighbor peerId: PeerId,
        toPeer destId: PeerId,
        withCost cost: Cost,
        givenExistingEntry forwardingEntry: ForwardingEntry?,
        givenDirectLinkToDest linkCost: Cost?
    ) -> (ForwardingEntry, Bool)? {
        guard forwardingEntry != nil else {
            return (ForwardingEntry(linkID: peerId, cost: cost), true)
        }

        if (cost < forwardingEntry!.cost) {
            return (ForwardingEntry(linkID: peerId, cost: cost), false)
        } else if (cost == forwardingEntry!.cost &&
                   peerId < forwardingEntry!.linkID) {
            return (ForwardingEntry(linkID: peerId, cost: cost), false)
        } else if (peerId == forwardingEntry!.linkID &&
                   cost > forwardingEntry!.cost) {
            return (ForwardingEntry(linkID: peerId, cost: cost), false)
        }

        return nil // Did not update anything
    }
 
    internal var distanceVector: DistanceVector
    private var selfId: PeerId
    private var linkCosts: LinkCosts
    private let distanceVectorSenderQueue = DispatchQueue(label: "com.andreworals.distanceVectorSenderQueue")
}
