//
//  WatchAIWatchApp.swift
//  WatchAIWatch Watch App
//
//  Created by Jason Titus on 2/18/26.
//

import SwiftUI

@main
struct WatchAIWatch_Watch_AppApp: App {
    @AppStorage("has_accepted_privacy") private var hasAccepted = false

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
