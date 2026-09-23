//
//  ContentView.swift
//  Yellowhammer
//
//  Created by Max Rozdobudko on 13.09.2026.
//

import SwiftUI

struct ContentView: View {
    @State private var notificationsPost = true

    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Hello, world!")
            if !notificationsPost {
                Text(
                    "Local notifications are off. Halted and closed Nights still reach you on the Night Card in Linear."
                )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .task {
            notificationsPost = await NotificationPermission.requestAtSetup()
        }
    }
}

#Preview {
    ContentView()
}
