//
//  MessengerView.swift
//  MeshNetworkTest
//
//  Created by Andrew Orals on 3/16/24.
//

import SwiftUI

struct MessengerView: View {
    @EnvironmentObject var connectionManager: ConnectionManager

    var body: some View {
        VStack {
            ScrollView {
                ForEach(Array(connectionManager.allNodes.keys), id: \.self) { key in
                    NavigationLink(destination: ChatView(
                        messageManager: connectionManager.allNodes[key]!
                    )) {
                        HStack {
                            Spacer()
                            Text(String(format:"%0X", key))
                                .foregroundStyle(.black)
                            Spacer()
                        }
                    }
                    .padding()
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            Spacer()
            HStack {
                NavigationLink(destination: PeerConnectionView().environmentObject(connectionManager.startBrowsingAndAdvertising())) {
                    Text("Connect")
                        .foregroundStyle(.blue)
                        .bold()
                        .padding()
                }
            }
        }
    }
}

struct MessengerView_Previews: PreviewProvider {
    static var previews: some View {
        return MessengerView()
            .environmentObject(createMockConnectionManager())
    }
}

