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
    @State private var selection = 1
    @AppStorage("hasSeenWelcomeModal") private var hasSeenWelcomeModal = false
    @State private var showWelcomeModal = false
    @State private var hasPresentedWelcomeModalThisSession = false
    
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
            // Start AR session on initial load
            if isARTabActive {
                arViewModel.startARSessionIfNeeded()
                print("App launched - starting AR session for default tab \(selection)")
            }
            
            presentWelcomeModalIfNeeded()
            
            // Inference is now tab-scoped: enable only on Inference tab (or when USB streaming is active)
            syncInferenceForSelectedTab(selection)
        }
        .onChange(of: selection) { newTab in
            let isARTab = (newTab == 1 || newTab == 2)
            
            if isARTab {
                // Switching to AR tab - resume session without resetting tracking
                arViewModel.resumeARSession()
                print("Switched to AR tab \(newTab) - resuming AR session")
            } else {
                // Switching away from AR tabs - pause session
                arViewModel.pauseARSession()
                print("Switched to non-AR tab \(newTab) - pausing AR session")
            }
            
            // Inference is now tab-scoped: enable only on Inference tab (or when USB streaming is active)
            syncInferenceForSelectedTab(newTab)
        }
        .onChange(of: arViewModel.isUSBStreamingActive) { _, _ in
            // If USB streaming starts/stops, resync inference enablement without requiring a tab change
            syncInferenceForSelectedTab(selection)
        }
        .onChange(of: phase) { newPhase in
            switch newPhase {
            case .background:
                arViewModel.stopAllActivities()
                arViewModel.pauseARSession()
                print("App backgrounded - all activities stopped")
            case .active:
                if isARTabActive {
                    arViewModel.resumeARSession()
                    print("App active - resuming AR session for tab \(selection)")
                }
                presentWelcomeModalIfNeeded()
            case .inactive:
                print("App inactive")
            @unknown default:
                break
            }
        }
        .overlay {
            if showWelcomeModal {
                ZStack {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                    
                    WelcomeModalView(
                        onClose: {
                            showWelcomeModal = false
                        },
                        onDontShowAgain: {
                            hasSeenWelcomeModal = true
                            showWelcomeModal = false
                        }
                    )
                    .frame(maxWidth: 340)
                    .padding(24)
                }
                .zIndex(200)
            }
        }
    }
    
    private func presentWelcomeModalIfNeeded() {
        guard !hasSeenWelcomeModal, !hasPresentedWelcomeModalThisSession, !showWelcomeModal else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard !hasSeenWelcomeModal else { return }
            showWelcomeModal = true
            hasPresentedWelcomeModalThisSession = true
        }
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

struct WelcomeModalView: View {
    let onClose: () -> Void
    let onDontShowAgain: () -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Welcome to Anysense!")
                .font(.title2)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
            
            ScrollView {
                Text("This app has been developed by the RUM team to allow for easy data collection, and evaluations. We added an inference tab to allow users to load up a RUM model for object pick up, where you can follow instructions to try picking up an object following directions without a robot!")
                    .font(.body)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxHeight: 240)
            
            HStack(spacing: 12) {
                Button("Close") {
                    onClose()
                }
                .buttonStyle(.bordered)
                
                Button(action: {
                    onDontShowAgain()
                }) {
                    Text("Don't show this again")
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                }
                .background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 6)
        )
    }
}

#Preview {
    MainPage(arViewModel: ARViewModel(), modelManager: ModelManager())
        .environmentObject(AppInformation())
}
