//
//  PeerConnectionView.swift
//  AudienceInstrument
//
//  Created by Andrew Orals on 3/16/24.
//

import SwiftUI
import MultipeerConnectivity

struct PeerConnectionStatusView: View {
    var status: MCSessionState
    var clientName: String
    var clientLatencyInNs: UInt64?
    var didSelectCallback: () -> Void

    var body: some View {
        Button {
            print("DID SELECT")
            didSelectCallback()
        } label: {
            HStack {
                Text(clientName)
                    .foregroundStyle(.blue)
                Spacer()
                if clientLatencyInNs != nil {
                    Text("\(String(format: "%.2f", Double(clientLatencyInNs!) / 1_000_000.0))ms")
                    Spacer()
                }
            }
            switch status {
            case MCSessionState.connected:
                Circle().foregroundStyle(.green).frame(width: 40, height: 40)
            case MCSessionState.notConnected:
                Circle().foregroundStyle(.red).frame(width: 40, height: 40)
            default:
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaledToFit()
            }
        }
        .padding()
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

struct PeerConnectionView: View {
    @EnvironmentObject var connectionManagerModel: ConnectionManagerModel
    @State var connecting = true

    var body: some View {
        ScrollView {
            ForEach(
                $connectionManagerModel.sessionPeers,
                id: \.self
            ) { $mcPeerId in
                PeerConnectionStatusView(
                    status: connectionManagerModel.sessionPeersState[$mcPeerId.wrappedValue]!,
                    clientName: String(describing: $mcPeerId.wrappedValue),
                    clientLatencyInNs: connectionManagerModel.estimatedLatencyByPeerInNs[$mcPeerId.wrappedValue],
                    didSelectCallback: {
                        connectionManagerModel.connect(toPeer: $mcPeerId.wrappedValue)
                    }
                )
            }
        }
        .onAppear() {
            connectionManagerModel.startBrowsing()
        }
    }
}

struct PeerConnectionView_Previews: PreviewProvider {
    static func getEnvironmentObject() {
        
    }
    static var previews: some View {
        return PeerConnectionView()
            .environmentObject(createMockConnectionManagerModel())
    }
}

