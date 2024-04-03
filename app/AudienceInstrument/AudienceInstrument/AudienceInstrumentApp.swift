//
//  AudienceInstrumentApp.swift
//  AudienceInstrument
//
//  Created by Andrew Orals on 3/15/24.
//

import SwiftUI

@main
struct AudienceInstrumentApp: App {
    @StateObject private var connectionManagerModel = ConnectionManagerModel()
//    @StateObject private var connectionManagerModel = createMockConnectionManagerModel()
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                MessengerView().environmentObject(connectionManagerModel)
            }
        }
    }
}
