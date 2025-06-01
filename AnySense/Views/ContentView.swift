//
//  ContentView.swift
//  Anysense
//
//  Created by Michael on 2024/5/22.
//

import SwiftUI
import CoreBluetooth
import AVFoundation

struct ContentView: View {
    @EnvironmentObject var appStatus : AppInformation
    @StateObject private var arViewModel = ARViewModel()
    
    @State private var hasPermissions = false
    @State private var showPermissionAlert = false
    @State private var showMainPage = false

    var body: some View {
        ZStack{
            Color.customizedBackground
                            .ignoresSafeArea()
            VStack {
                Image("AnySense logo")
                    .resizable()
                    .frame(width:220.0, height: 220.0)
                    .cornerRadius(30.0)
                Text("Welcome to AnySense")
                    .font(.title)
                    .multilineTextAlignment(.center)
                    .bold()
                if hasPermissions {
                    Button(action: {showMainPage = true}) {
                        Image("StartButton")
                            .resizable()
                            .frame(width: 200, height: 200)
                    }
                    .padding(.top, 10.0)
                    .background(.customizedBackground)
                }
            }
            .onAppear {
                checkPermissions()
            }
            .fullScreenCover(isPresented: $showMainPage) {
                MainPage(arViewModel: arViewModel)
            }
            .alert(isPresented: $showPermissionAlert) {
                Alert(
                    title: Text("Camera Access Required"),
                    message: Text("Please enable camera access in Settings to use AR features."),
                    primaryButton: .default(Text("Settings"), action: openAppSettings),
                    secondaryButton: .cancel()
                )
            }
        }

    }
    
    private func checkPermissions() {
        PermissionsManager.checkCameraPermissions { granted in
            if granted {
                arViewModel.setupARSession()
                hasPermissions = true
            } else {
                showPermissionAlert = true
            }
        }
    }
    
    private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

}

class PermissionsManager {
    static func checkCameraPermissions(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        default:
            completion(false)
        }
    }
}


class AppInformation : ObservableObject{
    @Published var animationFPS: Double = 30.0
    @Published var hapticFeedbackLevel: UIImpactFeedbackGenerator.FeedbackStyle = .medium
    @Published var rgbdVideoStreaming: StreamingMode = .off
    @Published var gridProjectionTrigger: GridMode = .off
    @Published var colorMapTrigger: Bool = false
    @Published var ifBluetoothConnected: Bool = false
    @Published var ifAudioRecordingEnabled: Bool = false
}


#Preview {
    ContentView()
        .environmentObject(AppInformation())
}


