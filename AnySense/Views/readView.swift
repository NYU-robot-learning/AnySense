//
//  readView.swift
//  Anysense
//
//  Created by Michael on 2024/5/27.
//

import SwiftUI
import UIKit
import CoreBluetooth
import BackgroundTasks
import UserNotifications
import Foundation
import AVFoundation
import ARKit

enum ReadActiveAlert {
    case first, second
}

// MARK: - ReadView Overlay
struct ReadViewOverlay: View {
    @EnvironmentObject var appStatus: AppInformation
    @ObservedObject var arViewModel: ARViewModel
    @State var showingAlert: Bool = false
    @State private var fileSetNames: RecordingFiles?
    @State var openFlash = true
    @State private var activeAlert: ReadActiveAlert = .first
    @State private var isRecordedOnce: Bool = false
    
    var body: some View {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        GeometryReader { geometry in
            let screenWidth = geometry.size.width
            let screenHeight = geometry.size.height
            let arViewHeight = min(screenWidth * 1.33, 0.75 * screenHeight)
            let arViewWidth = min(arViewHeight / 1.33, screenWidth)
            let arViewPadding = 0.2 * arViewHeight
            let buttonSize: CGFloat = min(screenWidth * 0.25, 80)
            let btBarHeight: CGFloat = 25.0
            let gridSize = appStatus.gridProjectionTrigger.rawValue
            
            ZStack {
                Color.clear                
                // Top bar with notch area + Bluetooth status
                VStack(spacing: 0) {
                    // White bar for notch/safe area
                    Color.white
                        .frame(height: geometry.safeAreaInsets.top)
                    
                    // Bluetooth status bar
                    Text(appStatus.ifBluetoothConnected ? "bluetooth device connected" : "bluetooth device disconnected")
                        .font(.footnote)
                        .foregroundColor(Color.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: btBarHeight)
                        .background(appStatus.ifBluetoothConnected ? .green : .red)
                    
                    Spacer()
                }
                .ignoresSafeArea(edges: .top)
                
                // Grid overlay
                if appStatus.gridProjectionTrigger.rawValue > 0 {
                    VStack {
                        Path { path in
                            for col in 1..<gridSize {
                                let x = arViewWidth * CGFloat(col) / CGFloat(gridSize)
                                path.move(to: CGPoint(x: x, y: 0))
                                path.addLine(to: CGPoint(x: x, y: arViewHeight))
                            }
                            for row in 1..<gridSize {
                                let y = arViewHeight * CGFloat(row) / CGFloat(gridSize)
                                path.move(to: CGPoint(x: 0, y: y))
                                path.addLine(to: CGPoint(x: arViewWidth, y: y))
                            }
                        }
                        .stroke(Color.gray, lineWidth: 2)
                        .opacity(0.5)
                    }
                    .frame(width: arViewWidth, height: arViewHeight)
                    .padding(.bottom, arViewPadding)
                }
                
                // Bottom controls with background
                VStack {
                    Spacer()
                    
                    // Controls area with solid background
                    VStack(spacing: 0) {
                        // Demo counter with background
                        HStack {
                            Text("Demos recorded: ")
                            Text("\(arViewModel.demosCounter)")
                                .multilineTextAlignment(.leading)
                        }
                        .padding(.top, 10)
                        
                        ZStack {
                            // Center Button Layer 
                            HStack {
                                Spacer()
                                ZStack {
                                    Image(systemName: "circle")
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(height: buttonSize)
                                        .frame(width: buttonSize)
                                        .foregroundStyle(.deviceWord)
                                        .multilineTextAlignment(.center)
                                    Button(action: {
                                        toggleRecording(mode: appStatus.rgbdVideoStreaming)
                                        isRecordedOnce = true
                                    }) {
                                        Image(systemName: arViewModel.isRecording ? "square.fill" : "circle.fill")
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(height: buttonSize - 10)
                                            .frame(width: buttonSize - 10)
                                            .multilineTextAlignment(.center)
                                            .foregroundStyle(Color.red)
                                    }
                                    .buttonStyle(scaleButtonStyle(isRecording: arViewModel.isRecording))
                                }
                                Spacer()
                            }
                            
                            // Side Buttons Layer
                            HStack(spacing: 20) {
                                // Delete Button
                                VStack(spacing: 4) {
                                    Button(action: {
                                        if isRecordedOnce {
                                            showingAlert = true
                                            self.activeAlert = .first
                                        } else {
                                            showingAlert = true
                                            self.activeAlert = .second
                                        }
                                        UIImpactFeedbackGenerator(style: appStatus.hapticFeedbackLevel).impactOccurred()
                                    }) {
                                        Image(systemName: "trash.circle.fill")
                                            .resizable()
                                            .frame(height: 36)
                                            .frame(width: 36)
                                            .foregroundStyle(.red)
                                    }
                                    Text("Delete")
                                        .foregroundStyle(.red)
                                        .font(.caption)
                                    Text("last record")
                                        .foregroundStyle(.red)
                                        .font(.caption)
                                }
                                
                                Spacer()
                                
                                // Flash Button
                                VStack(spacing: 4) {
                                    Button(action: toggleFlash) {
                                        Image(systemName: openFlash ? "flashlight.off.circle.fill" : "flashlight.on.circle.fill")
                                            .resizable()
                                            .frame(height: 36)
                                            .frame(width: 36)
                                    }
                                    Text(openFlash ? "Flash off" : "Flash on")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                        .padding(.bottom, 10)
                    }
                    .background(Color.customizedBackground)
                }
            }
        }
        .alert(isPresented: $showingAlert) {
            switch activeAlert {
            case .first:
                return Alert(
                    title: Text("Warning").foregroundColor(.red),
                    message: Text("Your last recorded data will all be deleted, are you sure?"),
                    primaryButton: .destructive(Text("Yes")) {
                        showingAlert = false
                        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
                        deleteRecordedData(url: paths, targetDirect: fileSetNames!.generalDataDirectory)
                        arViewModel.updateDemoCounter()
                    },
                    secondaryButton: .cancel(Text("No")) {
                        showingAlert = false
                    }
                )
            case .second:
                return Alert(
                    title: Text("Warning").foregroundColor(.red),
                    message: Text("You did not record any data yet!")
                )
            }
        }
        .onChange(of: appStatus.rgbdVideoStreaming) { oldMode, newMode in
            handleStreamingModeChange(from: oldMode, to: newMode)
        }
        .onAppear {
            initCode()
        }
    }
    
    struct scaleButtonStyle: ButtonStyle {
        let isRecording: Bool
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.scaleEffect(isRecording ? 0.35 : 1)
        }
    }
    
    private func initCode() {
        arViewModel.isColorMapOpened = appStatus.colorMapTrigger
        arViewModel.userFPS = appStatus.animationFPS
    }
    
    private func handleStreamingModeChange(from oldMode: StreamingMode, to newMode: StreamingMode) {
        if arViewModel.isRecording {
            toggleRecording(mode: oldMode)
        }
        switch (oldMode, newMode) {
        case (_, .off):
            arViewModel.killUSBStreaming()
        case (_, .usb):
            arViewModel.setupUSBStreaming()
        }
    }
    
    func toggleRecording(mode: StreamingMode) {
        if arViewModel.isOpen {
            if mode == .off {
                if !arViewModel.isRecording {
                    if let files = arViewModel.startRecording() {
                        fileSetNames = files
                        if arViewModel.getBLEManagerInstance().ifConnected {
                            arViewModel.startBluetoothRecording(targetURL: files.tactileFile, fps: appStatus.animationFPS)
                        }
                    }
                } else {
                    if arViewModel.getBLEManagerInstance().ifConnected {
                        arViewModel.stopBluetoothRecording()
                    }
                    arViewModel.stopRecording()
                }
            } else if mode == .usb {
                if !arViewModel.isUSBStreamingActive {
                    arViewModel.startUSBStreaming()
                } else {
                    arViewModel.stopUSBStreaming()
                }
            }
        }
        UIImpactFeedbackGenerator(style: appStatus.hapticFeedbackLevel).impactOccurred()
    }
    
    func toggleFlash() {
        guard let device = AVCaptureDevice.default(for: AVMediaType.video) else { return }
        if device.hasTorch {
            do {
                try device.lockForConfiguration()
                device.torchMode = openFlash ? .on : .off
                device.unlockForConfiguration()
            } catch {
                print("Flash could not be used")
            }
        }
        openFlash = !openFlash
        UIImpactFeedbackGenerator(style: appStatus.hapticFeedbackLevel).impactOccurred()
    }
    
    func deleteRecordedData(url: [URL], targetDirect: String) {
        do {
            let urlToDelete = url[0].appendingPathComponent(targetDirect)
            try FileManager.default.removeItem(at: urlToDelete)
            print("Successfully deleted file!")
        } catch {
            print("Error deleting file: \(error)")
        }
    }
}

#Preview {
    ReadViewOverlay(arViewModel: ARViewModel())
        .environmentObject(AppInformation())
}
    