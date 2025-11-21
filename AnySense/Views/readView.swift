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

enum ActiveAlert {
    case first, second
}

struct ReadView : View{
    @EnvironmentObject var appStatus : AppInformation
    @ObservedObject var arViewModel: ARViewModel
    @State private var isReading = false
    @State var showingAlert : Bool = false
    @Environment(\.scenePhase) private var phase
    @State private var fileSetNames: RecordingFiles?
    @State var openFlash = true
    @State private var activeAlert: ActiveAlert = .first
    @State private var isRecordedOnce: Bool = false
    var body : some View{
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        GeometryReader { geometry in
            let screenWidth = geometry.size.width
            let screenHeight = geometry.size.height
            let arViewHeight = min(screenWidth * 1.33, 0.75 * screenHeight)
            let arViewWidth = min(arViewHeight / 1.33, screenWidth)
            let arViewPadding = 0.2 * arViewHeight
            let buttonSize: CGFloat = min(screenWidth * 0.3, 100)
//            let buttonPadding: CGFloat =
            let btBarHeight: CGFloat = 25.0
            let gridSize = appStatus.gridProjectionTrigger.rawValue
             
            ZStack {
            // Apply the custom background color
            Color.customizedBackground
                .ignoresSafeArea(edges: .top)
            ZStack{
                ZStack {
                    ARViewContainer(
                        session: arViewModel.session,
                        arVisualizationManager: arViewModel.arVisualizationManager
                    )
                    .allowsHitTesting(true)
                    
                    // Gripper Overlay on AR View
                    if let mlManager = arViewModel.mlManager,
                       let overlayImage = mlManager.currentGripperOverlayImage {
                        Image(uiImage: overlayImage)
                            .resizable()
                            .scaledToFit()
                            .allowsHitTesting(false)
                    }
                    
                    // Manual Next Action Button 
                    if let mlManager = arViewModel.mlManager,
                       appStatus.mlInferenceEnabled && mlManager.isInferenceEnabled {
                        VStack {
                            HStack {
                                Spacer()
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
                                .padding(.trailing, 12)
                                .padding(.top, 12)
                            }
                            Spacer()
                        }
                    }
                }
                .frame(width: arViewWidth, height: arViewHeight)
                .padding(.bottom, arViewPadding)
                
                // ML Status Overlay (shown in all modes)
                VStack {
                    HStack {
                        VStack(alignment: .leading, spacing: 8) {
                            // ML Inference Results (only when enabled)
                            if appStatus.mlInferenceEnabled && arViewModel.mlManager?.isInferenceEnabled == true {
                                if let mlManager = arViewModel.mlManager {
                                    MLInferenceResultsView(mlManager: mlManager)
                                }
                            }
                            
                            // Action State Display (cube visualization status)
                            if arViewModel.arVisualizationManager.isVisualizationEnabled {
                                HStack(spacing: 4) {
                                    Text("Next action:")
                                        .font(.caption)
                                        .foregroundColor(.white)
                                    Text(arViewModel.arVisualizationManager.actionState.displayName)
                                        .font(.caption)
                                        .bold()
                                        .foregroundColor(arViewModel.arVisualizationManager.actionState == .waiting ? .yellow : .green)
                                }
                                .padding(8)
                                .background(Color.black.opacity(0.6))
                                .cornerRadius(8)
                            }
                            
                        }
                        Spacer()
                    }
                    Spacer()
                    // AR Visualization Status Overlay
                    // HStack {
                    //                             VStack(alignment: .leading, spacing: 4) {
                    //     if arViewModel.arVisualizationManager.isVisualizationEnabled {
                    //         Text("Movement Tracking: ON")
                    //             .font(.caption)
                    //             .foregroundColor(.green)
                    //         Text("Max Arrows: \(arViewModel.arVisualizationManager.maxArrows)")
                    //             .font(.caption2)
                    //             .foregroundColor(.secondary)
                    //     } else {
                    //         Text("Movement Tracking: OFF")
                    //             .font(.caption)
                    //             .foregroundColor(.red)
                    //     }
                    // }
                    //     .padding(8)
                    //     .background(Color.black.opacity(0.6))
                    //     .cornerRadius(8)
                    //     Spacer()
                    // }
                    .padding(.bottom, 10)
                }
                .frame(width: arViewWidth, height: arViewHeight)
                .padding(.bottom, arViewPadding)
                
                
                // Bluetooth status bar (shown in all modes)
                Text(appStatus.ifBluetoothConnected ? "bluetooth device connected" : "bluetooth device disconnected")
                    .font(.footnote)
                    .foregroundColor(Color.white)
                    .frame(width: screenWidth, height: btBarHeight)
                    .background(appStatus.ifBluetoothConnected ? .green : .red)
                    .padding(.bottom, arViewPadding + arViewHeight + btBarHeight)
                    .ignoresSafeArea(edges: .top)
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
                
                
                HStack{
                    Text("Demos recorded: ")
                    Text("\(arViewModel.demosCounter)")
                        .multilineTextAlignment(.leading)
                }
                .padding(.top, 0.55 * arViewHeight + 0.2 * screenHeight)
                
                VStack {
                    Spacer()
                    HStack(spacing: 20) {
                        // Delete (left)
                        VStack(spacing: 4) {
                            Button(action: {
                                if(isRecordedOnce){
                                    showingAlert = true
                                    self.activeAlert = .first
                                } else {
                                    showingAlert = true
                                    self.activeAlert = .second
                                }
                                UIImpactFeedbackGenerator(style: appStatus.hapticFeedbackLevel).impactOccurred()
                            }){
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
                        
                        // Record button (center)
                        ZStack{
                            Image(systemName: "circle")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(height: buttonSize)
                                .frame(width: buttonSize)
                                .foregroundStyle(.deviceWord)
                                .multilineTextAlignment(.center)
                            Button(action: {
                                toggleRecording(mode:appStatus.rgbdVideoStreaming)
                                isRecordedOnce = true
                            }) {
                                Image(systemName: isReading ? "square.fill" : "circle.fill")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(height: buttonSize - 10)
                                    .frame(width: buttonSize - 10)
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(Color.red)
                            }
                            .buttonStyle(scaleButtonStyle(isRecording: $isReading))
                        }

                        Spacer()

                        // Right side: goal (if applicable), flashlight, and debug
                        HStack(spacing: 20) {
                            if (arViewModel.mlManager?.isPointConditioned ?? false) {
                                VStack(spacing: 4) {
                                    Button(action: {
                                        let newValue = !arViewModel.goalTapModeEnabled
                                        arViewModel.goalTapModeEnabled = newValue
                                        if newValue {
                                            // Clear existing goal so the next tap sets a fresh one
                                            arViewModel.mlManager?.clearGoalPoint()
                                            arViewModel.arVisualizationManager.clearTargetPose()
                                        }
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
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, arViewPadding / 4.0 - (buttonSize / 4.0))
                }
                
            }
            .alert(isPresented: $arViewModel.depthStatus.showAlert) {  // Show alert when depth is missing
                Alert(
                    title: Text("Depth Data Unavailable"),
                    message: Text("Your device does not support depth data, or it is temporarily unavailable."),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
        .alert(isPresented: $showingAlert) {
            switch activeAlert {
            case .first:
                return Alert(title: Text("Warning")
                    .foregroundColor(.red),
                             message: Text("Your last recorded data will all be deleted, are you sure?"),
                             primaryButton: .destructive(Text("Yes")) {
                    showingAlert = false
                    deleteRecordedData(url: paths, targetDirect: fileSetNames!.generalDataDirectory)
                    arViewModel.updateDemoCounter()
                },
                             secondaryButton: .cancel(Text("No")) {
                    showingAlert = false
                    
                }
                )
            case .second:
                return Alert(title: Text("Warning")
                    .foregroundColor(.red),
                             message: Text("You did not record any data yet!")
                )
            }
        }

        .onChange(of: appStatus.rgbdVideoStreaming) { oldMode, newMode in
            handleStreamingModeChange(from: oldMode, to: newMode)
        }
        .onChange(of: appStatus.mlInferenceEnabled) { oldValue, newValue in
            if newValue {
                arViewModel.mlManager?.enableInference()
            } else {
                arViewModel.mlManager?.disableInference()
            }
        }
        .onAppear {
            initCode()
        }
    }
    }
    
    // Custom scale effect for the animation of record button
    struct scaleButtonStyle : ButtonStyle {
        @Binding var isRecording: Bool
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.scaleEffect(isRecording ? 0.35 : 1)
        }
    }
    
    private func initCode() {
        arViewModel.isColorMapOpened = appStatus.colorMapTrigger
        arViewModel.userFPS = appStatus.animationFPS
        
        // Sync ML inference setting
        if appStatus.mlInferenceEnabled {
            arViewModel.mlManager?.enableInference()
        } else {
            arViewModel.mlManager?.disableInference()
        }
    }
    
    private func handleStreamingModeChange(from oldMode: StreamingMode, to newMode: StreamingMode) {
        if isReading {
            toggleRecording(mode: oldMode)
        }
        switch (oldMode, newMode) {
        case (_, .off):
            arViewModel.killUSBStreaming()
            print("Switched to \(newMode): ARView is active.")
        case (_, .usb):
            print("Switched to \(newMode): ARView is hidden.")
            arViewModel.setupUSBStreaming()
        }
    }
    
    func toggleRecording(mode: StreamingMode) {
        isReading = !isReading
        if arViewModel.isOpen {
            if mode == .off {
                if isReading {
                    fileSetNames = arViewModel.startRecording()
                    if(arViewModel.getBLEManagerInstance().ifConnected){
                        startRecordingBT(targetURL: fileSetNames!.tactileFile)
                    }
                    
//                    print(fileSetNames)
                } else {
                    if(arViewModel.getBLEManagerInstance().ifConnected){
                        stopRecordingBT()
                        print("This stop recording is when shared bluetooth manager is connected")
                    }
                    arViewModel.stopRecording()
                    
                }
            }
            else if mode == .usb {
                if isReading {
                    arViewModel.startUSBStreaming()
                } else {
                    arViewModel.stopUSBStreaming()
                }
            }
        }
        UIImpactFeedbackGenerator(style: appStatus.hapticFeedbackLevel).impactOccurred()
                    
    }

    
    func toggleFlash() {
        guard let device = AVCaptureDevice.default(for: AVMediaType.video)
        else {return}
        if device.hasTorch {
            do {
                try device.lockForConfiguration()
                if openFlash == true { device.torchMode = .on // set on
                } else {
                    device.torchMode = .off // set off
                }
                device.unlockForConfiguration()
            } catch {
                print("Flash could not be used")
            }
        } else {
            print("Flash is not available")
        }
        openFlash = !openFlash
        UIImpactFeedbackGenerator(style: appStatus.hapticFeedbackLevel).impactOccurred()
    }

    func startRecordingBT(targetURL:URL) {
        do {
            try createFile(fileURL: targetURL)
        }
        catch {
            print("Error creating tactile file.")
        }
        
        arViewModel.getBLEManagerInstance().startRecording(
            targetURL: targetURL,
            fps: appStatus.animationFPS
        )
    }

    func stopRecordingBT() {
        arViewModel.getBLEManagerInstance().stopRecording()
    }
    
    
    func createDocumentaryFolderFiles(paths: [URL], fileSetNames: RecordingFiles?) -> [FileElement] {
        guard let fileSetNames = fileSetNames else {
            print("❌ Error: Insufficient paths or fileSetNames elements")
            return []
        }
        
        let rgbFile = FileElement.videoFile(VideoFile(url:fileSetNames.rgbFileName))
        let depthFile = FileElement.videoFile(VideoFile(url:fileSetNames.depthFileName))
        let poseFile = FileElement.textFile(TextFile(url:fileSetNames.poseFile.path))

        var elements = [rgbFile, depthFile, poseFile]

        // Only include image folders if they exist (debug mode was enabled)
        if let depthImagesDir = fileSetNames.depthImagesDirectory {
            let depthImageFolder = FileElement.directory(SubLevelDirectory(url: depthImagesDir))
            elements.append(depthImageFolder)
        }

        if let rgbImagesDir = fileSetNames.rgbImagesDirectory {
            let rgbImageFolder = FileElement.directory(SubLevelDirectory(url: rgbImagesDir))
            elements.append(rgbImageFolder)
        }

        return elements
    }
    
    func deleteRecordedData(url: [URL], targetDirect: String){
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
    ReadView(arViewModel: ARViewModel())
        .environmentObject(AppInformation())
}
    