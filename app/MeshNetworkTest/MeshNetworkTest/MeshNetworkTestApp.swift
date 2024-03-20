//
//  MeshNetworkTestApp.swift
//  MeshNetworkTest
//
//  Created by Andrew Orals on 3/15/24.
//

import SwiftUI

@main
struct MeshNetworkTestApp: App {
    @StateObject private var connectionManager = ConnectionManager(displayName: UIDevice.current.name)
//    @StateObject private var connectionManager = createMockConnectionManager()
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                MessengerView().environmentObject(connectionManager)
            }
        }
    }
}
