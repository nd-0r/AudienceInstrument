//
//  MessengerView.swift
//  AudienceInstrument
//
//  Created by Andrew Orals on 3/16/24.
//

import SwiftUI

struct MessengerView: View {
    @EnvironmentObject var connectionManagerModel: ConnectionManagerModel

    var body: some View {
        VStack {
            ScrollView {
                ForEach(Array(connectionManagerModel.allNodes.filter( { $1.available == true }).keys), id: \.self) { key in
                    NavigationLink(String(format:"%0X", key)) {
                        ChatView(
                            messageManager: connectionManagerModel.allNodes[key]!
                        )
                    }
                    .foregroundStyle(.black)
                    .padding()
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            if connectionManagerModel.sessionPeers.filter({ $1 == .connected }).count > 0 {
                Spacer()
                HStack {
                    NavigationLink("Calculate Distances") {
                        PeerDistanceCalculationView().environmentObject(connectionManagerModel)
                    }
                    .padding()
                    .bold()
                    .foregroundStyle(.blue)
                }
            }
            Spacer()
            HStack {
                NavigationLink("Connect") {
                    PeerConnectionView().environmentObject(connectionManagerModel)
                }
                .foregroundStyle(.blue)
                .bold()
                .padding()
            }
        }
    }
}

struct MessengerView_Previews: PreviewProvider {
    static var previews: some View {
        return MessengerView()
            .environmentObject(createMockConnectionManagerModel())
    }
}

