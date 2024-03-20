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
        Text("This is some text!")
    }
}

#Preview {
    MessengerView()
}
