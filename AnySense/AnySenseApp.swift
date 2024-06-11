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
    //let backgroundTaskManager = BackgroundTaskManager()
    //@Environment(\.scenePhase) private var phase
    @StateObject var appStatus = AppInformation()
    @StateObject var bluetoothManager = BluetoothManager()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appStatus)
                .environmentObject(bluetoothManager)
        }
    }
}
