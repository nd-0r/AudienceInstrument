//
//  ChatView.swift
//  AudienceInstrument
//
//  Created by Andrew Orals on 3/19/24.
//

import SwiftUI

import SwiftUI

struct MessageComposerView: View {
    @Binding var message: String
    let sendCallback: () -> Void

    var body: some View {
        VStack {
            HStack {
                TextField("Type a message...", text: $message)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding(10)
                    .background(Color.white)
                    .cornerRadius(20)
                    .padding(.horizontal)
                
                Button(action: {
                    sendCallback()
                }) {
                    Text("Send")
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.blue)
                        .cornerRadius(20)
                }
            }
            .padding(.bottom)
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ChatView: View {
    @StateObject var messageManager: NodeMessageManager
    @State var currentMessage: String = ""

    var body: some View {
        VStack {
            ScrollView {
                ForEach(messageManager.messages, id: \.self) { message in
                    Text(message)
                }
            }
            Spacer()
            MessageComposerView(
                message: $currentMessage,
                sendCallback: {
                    self.messageManager.sendMessage(message: currentMessage)
                    currentMessage = ""
                }
            )
        }
    }
}

struct ChatView_Previews: PreviewProvider {
    static var previews: some View {
        let mockConnectionManagerModel = createMockConnectionManagerModel()
        return ChatView(messageManager: Array(mockConnectionManagerModel.allNodes.values)[0])
    }
}

