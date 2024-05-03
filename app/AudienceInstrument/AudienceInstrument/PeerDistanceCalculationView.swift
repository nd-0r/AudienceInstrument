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
                if clientDistanceInM != nil {
                    Text("\(String(format: "%.2f", clientDistanceInM!))m")
                    .foregroundStyle(.blue)
                    Spacer()
                }
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
    @State var markedPeers: Set<MCPeerID> = []
    @State var errorMessage = ""

    var body: some View {
        let estimatedDists = connectionManagerModel.estimatedDistanceByPeerInM.mapValues({
            val -> DistanceManager.DistInMeters? in
                switch val {
                case .noneCalculated:
                    return nil
                case .someCalculated(let dist):
                    return DistanceManager.DistInMeters(dist)
                }
        })
        VStack {
            ScrollView {
                ForEach(
                    Array(connectionManagerModel.sessionPeers.keys),
                    id: \.self
                ) { mcPeerId in
                    PeerDistanceStatusView(
                        status: connectionManagerModel.sessionPeers[mcPeerId]!,
                        clientName: mcPeerId.displayName,
                        clientDistanceInM: estimatedDists[Int64(mcPeerId.hashValue)] ?? nil,
                        didMarkCallback: {
                            if markedPeers.contains(mcPeerId) {
                                markedPeers.remove(mcPeerId)
                                errorMessage = ""
                            } else if markedPeers.count < 3 {
                                markedPeers.insert(mcPeerId)
                            } else {
                                errorMessage = "Cannot calculate distance to more than 3 neighbors."
                            }
                        },
                        marked: markedPeers.contains(mcPeerId)
                    )
                }
            }
            Spacer()
            Text("\(errorMessage)").foregroundStyle(.red)
            Button {
                connectionManagerModel.initiateDistanceCalculation(
                    withNeighbors: Array(
                        markedPeers.map({ Int64($0.hashValue) })
                    )
                )
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

