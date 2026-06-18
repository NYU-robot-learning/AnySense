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
    @ObservedObject var arViewModel: ARViewModel
    let modelManager: ModelManager
    // Start the default page be the read page
    @State private var selection = 2
    
    // Track if AR tabs are active for showing/hiding the shared AR view
    private var isARTabActive: Bool {
        selection == 1 || selection == 2
    }
    
    var body: some View {
        ZStack {
            // MARK: - Background layer (AR for tabs 1,2 or solid color for others)
            if isARTabActive {
                SharedARViewContainer(arViewModel: arViewModel)
                    .ignoresSafeArea()
            } else {
                Color.customizedBackground
                    .ignoresSafeArea()
            }
            
            // MARK: - Content layer (overlays only, no backgrounds)
            VStack(spacing: 0) {
                // Main content area
                Group {
                    switch selection {
                    case 0:
                        PeripheralView(arViewModel: arViewModel, bluetoothManager: arViewModel.getBLEManagerInstance())
                    case 1:
                        ReadViewOverlay(arViewModel: arViewModel)
                    case 2:
                        InferenceViewOverlay(arViewModel: arViewModel)
                    case 3:
                        SettingsView(arViewModel: arViewModel, modelManager: modelManager)
                    default:
                        ReadViewOverlay(arViewModel: arViewModel)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                // Custom tab bar at bottom
                HStack {
                    TabBarButton(icon: "iphone.gen1.radiowaves.left.and.right", label: "ble-device", tag: 0, selection: $selection)
                    TabBarButton(icon: "record.circle", label: "record", tag: 1, selection: $selection)
                    TabBarButton(icon: "brain.head.profile", label: "inference", tag: 2, selection: $selection)
                    TabBarButton(icon: "gear", label: "settings", tag: 3, selection: $selection)
                }
                .padding(.vertical, 8)
                .background(Color.tabBackground)
            }
        }
        .onAppear {
            syncRecordingSettings()
            syncARSessionForSelectedTab(selection)
            syncInferenceForSelectedTab(selection)
        }
        .onChange(of: selection) { _, newTab in
            syncARSessionForSelectedTab(newTab)
            syncInferenceForSelectedTab(newTab)
        }
        .onChange(of: arViewModel.isRecording) { _, _ in
            syncARSessionForSelectedTab(selection)
        }
        .onChange(of: arViewModel.isUSBStreamingActive) { _, _ in
            syncARSessionForSelectedTab(selection)
            syncInferenceForSelectedTab(selection)
        }
        .onChange(of: appStatus.ifAudioRecordingEnabled) { _, _ in
            syncRecordingSettings()
        }
        .onChange(of: appStatus.rgbdVideoStreaming) { oldMode, newMode in
            handleStreamingModeChange(from: oldMode, to: newMode)
        }
        .onChange(of: phase) { newPhase in
            switch newPhase {
            case .background:
                arViewModel.stopAllActivities()
                arViewModel.pauseARSession()
                print("App backgrounded - all activities stopped")
            case .active:
                syncARSessionForSelectedTab(selection)
            case .inactive:
                print("App inactive")
            @unknown default:
                break
            }
        }
    }
    
    @MainActor
    private func syncRecordingSettings() {
        arViewModel.ifAudioEnable = appStatus.ifAudioRecordingEnabled
    }

    private func shouldKeepARSessionRunning(tab: Int) -> Bool {
        tab == 1 || tab == 2 || arViewModel.isRecording || arViewModel.isUSBStreamingActive
    }

    @MainActor
    private func syncARSessionForSelectedTab(_ tab: Int) {
        if shouldKeepARSessionRunning(tab: tab) {
            arViewModel.resumeARSession()
        } else {
            arViewModel.pauseARSession()
        }
    }

    @MainActor
    private func handleStreamingModeChange(from _: StreamingMode, to newMode: StreamingMode) {
        if arViewModel.isRecording {
            if arViewModel.getBLEManagerInstance().ifConnected {
                arViewModel.stopBluetoothRecording()
            }
            arViewModel.stopRecording()
        }

        switch newMode {
        case .off:
            if arViewModel.isUSBStreamingActive {
                arViewModel.stopUSBStreaming()
            }
            arViewModel.killUSBStreaming()
        case .usb:
            arViewModel.setupUSBStreaming()
        }

        syncARSessionForSelectedTab(selection)
        syncInferenceForSelectedTab(selection)
    }

    @MainActor
    private func syncInferenceForSelectedTab(_ tab: Int) {
        // Inference is active only in the Inference tab, except when USB streaming explicitly needs it.
        if tab == 2 {
            arViewModel.mlManager?.enableInference()
            return
        }
        
        // Leaving inference tab: stop playback and disable inference unless USB streaming is active.
        arViewModel.stopInferencePlayback(reset: true)
        if arViewModel.isUSBStreamingActive {
            // USB streaming sends joint actions; ensure inference is enabled to avoid all-zero actions.
            arViewModel.mlManager?.enableInference()
        } else {
            arViewModel.mlManager?.disableInference()
        }
    }
}

// MARK: - Custom Tab Bar Button
struct TabBarButton: View {
    let icon: String
    let label: String
    let tag: Int
    @Binding var selection: Int
    
    var body: some View {
        Button(action: {
            selection = tag
        }) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                Text(label)
                    .font(.caption2)
            }
            .foregroundColor(selection == tag ? .accentColor : .gray)
            .frame(maxWidth: .infinity)
        }
    }
}

#Preview {
    MainPage(arViewModel: ARViewModel(), modelManager: ModelManager())
        .environmentObject(AppInformation())
}
