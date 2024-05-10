//
//  PeerDistanceCalculationView.swift
//  AudienceInstrument
//
//  Created by Andrew Orals on 4/23/24.
//

import SwiftUI
import MultipeerConnectivity

struct PeerDistanceStatusView: View {
    var status: MCSessionState
    var clientName: String
    var clientDistanceInM: DistanceManager.DistInMeters?
    var didMarkCallback: () -> Void
    var marked: Bool

    var body: some View {
        Button {
            print("DID SELECT")
            didMarkCallback()
        } label: {
            HStack {
                Text(clientName)
                    .foregroundStyle(.blue)
                Spacer()
//                if clientDistanceInM != nil {
//                    Text("\(String(format: "%.2f", clientDistanceInM!))m")
//                    .foregroundStyle(.blue)
//                    Spacer()
//                }
            }
        }
        .tint(marked ? .green : .gray)
        .padding()
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

struct PeerDistanceCalculationView: View {
    @EnvironmentObject var connectionManagerModel: ConnectionManagerModel
    @State var connecting = true
    @State var markedPeers: Set<DistanceManager.PeerID> = []
    @State var errorMessage = ""

    init() {
        #if DEBUG
        print("Initializing \(String(describing: Self.self))")
        #endif
    }

    var body: some View {
        #if DEBUG
        let _ = print("Rendering \(String(describing: Self.self))")
        #endif
        let estimatedDists = connectionManagerModel.estimatedDistanceByPeerInM.mapValues({
            val -> DistanceManager.DistInMeters? in
                switch val {
                case .noneCalculated:
                    return nil
                case .someCalculated(let dist):
                    return DistanceManager.DistInMeters(dist)
                }
        })
        #if DEBUG
        let _ = print("Calculated estimatedDists \(String(describing: Self.self))")
        #endif
        VStack {
            ScrollView {
                ForEach(
                    $connectionManagerModel.sessionPeers,
                    id: \.self
                ) { $peerID in
                    PeerDistanceStatusView(
                        status: connectionManagerModel.sessionPeersState[$peerID.wrappedValue]!,
                        clientName: String(describing: $peerID.wrappedValue),
                        clientDistanceInM: estimatedDists[$peerID.wrappedValue] ?? nil,
                        didMarkCallback: {
                            if self.markedPeers.contains($peerID.wrappedValue) {
                                self.markedPeers.remove($peerID.wrappedValue)
                                self.errorMessage = ""
                            } else if self.markedPeers.count < 3 {
                                self.markedPeers.insert($peerID.wrappedValue)
                            } else {
                                self.errorMessage = "Cannot calculate distance to more than 3 neighbors."
                            }
                        },
                        marked: self.markedPeers.contains($peerID.wrappedValue)
                    )
                }
            }
            Spacer()
            Text("\(errorMessage)").foregroundStyle(.red)
            Button {
                connectionManagerModel.initiateDistanceCalculation(
                    withNeighbors: Array(markedPeers)
                )
                markedPeers.removeAll()
            } label: {
                Text("Calculate Distances")
            }
            .disabled(markedPeers.isEmpty)
        }
    }
}

struct PeerDistanceCalculationView_Previews: PreviewProvider {
    static func getEnvironmentObject() {
        
    }
    static var previews: some View {
        return PeerDistanceCalculationView()
            .environmentObject(createMockConnectionManagerModel())
    }
}

