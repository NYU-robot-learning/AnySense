//
//  InferenceView.swift
//  Anysense
//
//  Created by Krish Mehta
//  ML Inference and AR Visualization View
//

import SwiftUI
import UIKit
import CoreBluetooth
import BackgroundTasks
import UserNotifications
import Foundation
import AVFoundation
import ARKit

// MARK: - InferenceView Overlay 
struct InferenceViewOverlay: View {
    @EnvironmentObject var appStatus: AppInformation
    @ObservedObject var arViewModel: ARViewModel
    @State var openFlash = true
    
    var body: some View {
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
                // Transparent background - AR view shows through from MainPage
                Color.clear
                
                ZStack {
                    // Gripper Overlay on AR View
                    if let mlManager = arViewModel.mlManager,
                       let overlayImage = mlManager.currentGripperOverlayImage {
                        Image(uiImage: overlayImage)
                            .resizable()
                            .scaledToFit()
                            .allowsHitTesting(false)
                    }
                    
                    // Guided Flow Instructions
                    VStack {
                        Spacer()
                        
                        let instructionText: String = {
                            // Step 1: AI guidance is off
                            if !appStatus.mlInferenceEnabled {
                                return "Enable AI Guidance in Settings"
                            }
                            // Step 2: AI on, but Set Goal not clicked yet
                            if !arViewModel.goalTapModeEnabled {
                                return "Click on Set Goal"
                            }
                            // Step 3: Set Goal clicked, waiting for tap
                            if arViewModel.mlManager?.currentGoalPoint == nil {
                                return "Tap a point to set a target object"
                            }
                            // Step 4: Goal is set, follow the arrow
                            return "Follow the arrow"
                        }()
                        
                        Text(instructionText)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.gray.opacity(0.6))
                            .cornerRadius(8)
                            .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
                            .animation(.easeInOut, value: instructionText)
                        
                        Spacer()
                            .frame(height: 60)
                    }
                    
                    // Manual Next Action Button
                    if let mlManager = arViewModel.mlManager,
                       appStatus.mlInferenceEnabled && mlManager.isInferenceEnabled {
                        VStack {
                            HStack {
                                Spacer()
                                VStack(spacing: 2) {
                                    Button(action: {
                                        mlManager.triggerInferenceManually()
                                        UIImpactFeedbackGenerator(style: appStatus.hapticFeedbackLevel).impactOccurred()
                                    }) {
                                        Image(systemName: "arrow.forward.circle.fill")
                                            .font(.title2)
                                            .foregroundColor(.white)
                                            .background(
                                                Circle()
                                                    .fill(Color.blue.opacity(0.8))
                                                    .frame(width: 44, height: 44)
                                            )
                                            .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                                    }
                                    
                                    Text("Get next action")
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.black.opacity(0.7))
                                        .cornerRadius(3)
                                        .shadow(color: .black.opacity(0.4), radius: 1, x: 0, y: 0.5)
                                }
                                .padding(.trailing, 12)
                                .padding(.top, 12)
                            }
                            Spacer()
                        }
                    }
                    
                    // Model Loading Indicator
                    if let mlManager = arViewModel.mlManager, mlManager.isModelLoading {
                        ZStack {
                            Color.black.opacity(0.4)
                                .ignoresSafeArea()
                            VStack(spacing: 16) {
                                ProgressView()
                                    .controlSize(.large)
                                    .tint(.white)
                                Text("Preparing Model...")
                                    .font(.headline)
                                    .foregroundColor(.white)
                            }
                        }
                        .transition(.opacity)
                        .zIndex(100)
                    }
                }
                .frame(width: arViewWidth, height: arViewHeight)
                .padding(.bottom, arViewPadding)
                
                // ML Status Overlay
                VStack {
                    HStack {
                        VStack(alignment: .leading, spacing: 8) {
                            if appStatus.mlInferenceEnabled && arViewModel.mlManager?.isInferenceEnabled == true {
                                if let mlManager = arViewModel.mlManager {
                                    MLInferenceResultsView(mlManager: mlManager)
                                }
                            }
                        }
                        Spacer()
                    }
                    Spacer()
                        .padding(.bottom, 10)
                }
                .frame(width: arViewWidth, height: arViewHeight)
                .padding(.bottom, arViewPadding)
                
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
                        // Demo counter
                        HStack {
                            Text("Demos recorded: ")
                            Text("\(arViewModel.demosCounter)")
                                .multilineTextAlignment(.leading)
                        }
                        .padding(.top, 10)
                        
                        ZStack {
                            // Center Button Layer (Record Button)
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
                                // Left Side: Goal button (conditional)
                                if arViewModel.mlManager?.isPointConditioned ?? false {
                                    VStack(spacing: 4) {
                                        Button(action: {
                                            let newValue = !arViewModel.goalTapModeEnabled
                                            arViewModel.goalTapModeEnabled = newValue
                                            if newValue {
                                                arViewModel.mlManager?.clearGoalPoint()
                                                arViewModel.arVisualizationManager.clearTargetPose()
                                            }
                                            UIImpactFeedbackGenerator(style: appStatus.hapticFeedbackLevel).impactOccurred()
                                        }) {
                                            Image(systemName: arViewModel.goalTapModeEnabled ? "dot.circle.fill" : "target")
                                                .resizable()
                                                .frame(height: 36)
                                                .frame(width: 36)
                                                .foregroundStyle(arViewModel.goalTapModeEnabled ? Color.green : Color.blue)
                                        }
                                        Text("Set goal")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                
                                Spacer()
                                
                                // Right Side: Flash
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
        .onChange(of: appStatus.mlInferenceEnabled) { oldValue, newValue in
            if newValue {
                arViewModel.mlManager?.enableInference()
            } else {
                arViewModel.mlManager?.disableInference()
            }
        }
        .onChange(of: appStatus.showGripperOverlay) { oldValue, newValue in
            arViewModel.mlManager?.showGripperOverlayOnScreen = newValue
        }
        .onChange(of: appStatus.enableGripperOverlayInModel) { oldValue, newValue in
            arViewModel.mlManager?.enableGripperOverlay = newValue
        }
        .onChange(of: appStatus.arVisualizationEnabled) { oldValue, newValue in
            arViewModel.arVisualizationManager.isVisualizationEnabled = newValue
        }
        .onChange(of: appStatus.visualizationFrequency) { oldValue, newValue in
            arViewModel.arVisualizationManager.visualizationFrequency = newValue
        }
        .onAppear {
            initCode()
        }
    }
    
    private func initCode() {
        arViewModel.isColorMapOpened = appStatus.colorMapTrigger
        arViewModel.userFPS = appStatus.animationFPS
        arViewModel.arVisualizationManager.isVisualizationEnabled = appStatus.arVisualizationEnabled
        arViewModel.arVisualizationManager.visualizationFrequency = appStatus.visualizationFrequency
        initializeMLSettings()
    }
    
    private func initializeMLSettings() {
        arViewModel.mlManager?.clearPendingState()
        guard let mlManager = arViewModel.mlManager else {
            print("ML manager not available during InferenceViewOverlay initialization")
            return
        }
        if appStatus.mlInferenceEnabled {
            mlManager.enableInference()
        } else {
            mlManager.disableInference()
        }
        mlManager.showGripperOverlayOnScreen = appStatus.showGripperOverlay
        mlManager.enableGripperOverlay = appStatus.enableGripperOverlayInModel
        print("ML settings initialized successfully for InferenceViewOverlay")
    }
    
    struct scaleButtonStyle: ButtonStyle {
        let isRecording: Bool
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.scaleEffect(isRecording ? 0.35 : 1)
        }
    }
    
    func toggleRecording(mode: StreamingMode) {
        if arViewModel.isOpen {
            if mode == .off {
                if !arViewModel.isRecording {
                    // Start recording (for inference, we don't need to save file references)
                    if let files = arViewModel.startRecording() {
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
}

#Preview {
    InferenceViewOverlay(arViewModel: ARViewModel())
        .environmentObject(AppInformation())
}