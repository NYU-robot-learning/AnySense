//
//  AnySenseApp.swift
//  Anysense
//
//  Created by Michael on 2024/5/22.
//

import SwiftUI
import BackgroundTasks
    
@main
struct AnySenseApp: App {
    @StateObject var appStatus = AppInformation()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appStatus)
        }
    }
}
