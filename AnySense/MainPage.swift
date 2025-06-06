//
//  MainPage.swift
//  Anysense
//
//  Created by Michael on 2024/5/22.
//

import SwiftUI

struct MainPage: View {
    @EnvironmentObject private var appStatus : AppInformation
    @Environment(\.scenePhase) private var phase
    let arViewModel: ARViewModel
    // Start the default page be the read page
    @State private var selection = 1
    
    var body: some View {
        TabView(selection: $selection){
            Group{
                PeripheralView(arViewModel: arViewModel, bluetoothManager: arViewModel.getBLEManagerInstance())
                    .tabItem {
                        Label("ble-device", systemImage: "iphone.gen1.radiowaves.left.and.right")
                }
                    .tag(0)
                
                ReadView(arViewModel: arViewModel)
                    .tabItem {
                        Label("read", systemImage: "dot.scope")
                }
                    .tag(1)
                
                
                SettingsView()
                    .tabItem {
                        Label("settings", systemImage: "gear")
            
                    }
                    .tag(2)
            }
                .toolbarBackground(.tabBackground, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
        }
        .accentColor(.accentColor)
    }
    
}

#Preview {
    MainPage(arViewModel: ARViewModel())
        .environmentObject(AppInformation())
}
