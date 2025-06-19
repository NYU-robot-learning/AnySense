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
    @Published var animationFPS: Double {
        didSet { UserDefaults.standard.set(animationFPS, forKey: "animationFPS") }
    }
    @Published var hapticFeedbackLevelRaw: Int {
        didSet { UserDefaults.standard.set(hapticFeedbackLevelRaw, forKey: "hapticFeedbackLevel") }
    }
    var hapticFeedbackLevel: UIImpactFeedbackGenerator.FeedbackStyle {
        get { UIImpactFeedbackGenerator.FeedbackStyle(rawValue: hapticFeedbackLevelRaw) ?? .medium }
        set { hapticFeedbackLevelRaw = newValue.rawValue }
    }
    @Published var rgbdVideoStreaming: StreamingMode {
        didSet { UserDefaults.standard.set(rgbdVideoStreaming.rawValue, forKey: "rgbdVideoStreaming") }
    }
    @Published var gridProjectionTrigger: GridMode {
        didSet { UserDefaults.standard.set(gridProjectionTrigger.rawValue, forKey: "gridProjectionTrigger") }
    }
    @Published var colorMapTrigger: Bool {
        didSet { UserDefaults.standard.set(colorMapTrigger, forKey: "colorMapTrigger") }
    }
    @Published var ifBluetoothConnected: Bool = false
    @Published var ifAudioRecordingEnabled: Bool {
        didSet { UserDefaults.standard.set(ifAudioRecordingEnabled, forKey: "ifAudioRecordingEnabled") }
    }
    @Published var bimanualMode: Bool {
        didSet { UserDefaults.standard.set(bimanualMode, forKey: "bimanualMode") }
    }
    @Published var rightHand: Bool {
        didSet { UserDefaults.standard.set(rightHand, forKey: "rightHand") }
    }

    init() {
        let defaults = UserDefaults.standard
        self.animationFPS = defaults.object(forKey: "animationFPS") as? Double ?? 30.0
        self.hapticFeedbackLevelRaw = defaults.object(forKey: "hapticFeedbackLevel") as? Int ?? UIImpactFeedbackGenerator.FeedbackStyle.medium.rawValue
        if let raw = defaults.string(forKey: "rgbdVideoStreaming"), let mode = StreamingMode(rawValue: raw) {
            self.rgbdVideoStreaming = mode
        } else {
            self.rgbdVideoStreaming = .off
        }
        let gridRaw = defaults.integer(forKey: "gridProjectionTrigger")
        self.gridProjectionTrigger = GridMode(rawValue: gridRaw) ?? .off
        self.colorMapTrigger = defaults.bool(forKey: "colorMapTrigger")
        self.ifAudioRecordingEnabled = defaults.bool(forKey: "ifAudioRecordingEnabled")
        self.bimanualMode = defaults.bool(forKey: "bimanualMode")
        self.rightHand = defaults.bool(forKey: "rightHand")
    }
}


#Preview {
    ContentView()
        .environmentObject(AppInformation())
        .environmentObject(BluetoothManager())
        .environmentObject(VolumeButtonManager())
}


