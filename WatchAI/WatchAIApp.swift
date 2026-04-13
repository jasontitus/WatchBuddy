//
//  WatchAIApp.swift
//  WatchAI
//
//  Created by Jason Titus on 2/18/26.
//

import SwiftUI

@main
struct WatchAIApp: App {
    @AppStorage("has_accepted_privacy") private var hasAccepted = false
    @AppStorage("has_api_key") private var hasApiKey = false

    init() {
        // Sync flag for existing users who have a key in Keychain already
        if !hasApiKey && KeychainManager.load(key: "api_key") != nil {
            hasApiKey = true
        }
    }

    var body: some Scene {
        WindowGroup {
            if hasAccepted {
                ContentView()
            } else {
                ConsentView()
            }
        }
    }
}
