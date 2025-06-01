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
                .ignoresSafeArea()
            ZStack{
                ARViewContainer(session: arViewModel.session)
                    .edgesIgnoringSafeArea(.all)
                    .frame(width: arViewWidth, height: arViewHeight)
                // .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                    .padding(.bottom, arViewPadding)
                    .opacity(appStatus.rgbdVideoStreaming == .off ? 1 : 0)
                    .allowsHitTesting(appStatus.rgbdVideoStreaming == .off) // Disable interaction in streaming mode
                if appStatus.rgbdVideoStreaming == .off {
                    Text(appStatus.ifBluetoothConnected ? "bluetooth device connected" : "bluetooth device disconnected")
                        .font(.footnote)
                        .foregroundColor(Color.white)
                        .frame(width: screenWidth, height: btBarHeight)
                        .background(appStatus.ifBluetoothConnected ? .green : .red)
                        .padding(.bottom, arViewPadding + arViewHeight + btBarHeight)
                        .ignoresSafeArea()
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
                }
                
                if appStatus.rgbdVideoStreaming == .usb {
                    VStack(alignment: .leading, spacing: 15) { // Reduced spacing
                        // Heading
                        Text("Streaming Mode: USB")
                            .font(.title2) // Semi-bold and slightly smaller than title
                            .fontWeight(.semibold)
                            .padding(.bottom, 5) // Slight padding after the heading
                        
                        // Caption
                        Text("You can disable streaming in settings")
                            .font(.caption) // Small caption font
                            .foregroundColor(.secondary)
                        
                        // Instructions
                        VStack(alignment: .leading, spacing: 8) { // Reduced spacing between instructions
                            Text("1. Connect cable to computer")
                            Text("2. Click the button below to")
                            Text("3. Run python demo-main.py on your computer")
                        }
                        .font(.body) // Regular font for instructions
                        .lineSpacing(4) // Slightly reduced line spacing for compactness
                        
                        // Toggle Instruction
                        Text("Press Toggle to start")
                            .font(.headline) // Smaller than the main heading
                            .fontWeight(.semibold)
                            .padding(.top, 20) // Small padding before this line
                    }
                    .frame(width: 400.0, height: 450.0)
                    .padding()
                }
                HStack{
                    Text("Demos recorded: ")
                    Text("\(arViewModel.demosCounter)")
                        .multilineTextAlignment(.leading)
                }
                .padding(.top, 0.55 * arViewHeight + 0.2 * screenHeight)
                
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
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
                        .padding(.bottom, arViewPadding / 4.0 - (buttonSize / 4.0))
                        Spacer()
                    }
                }
                
                
                
                if appStatus.rgbdVideoStreaming == .off{
                    HStack{
                        VStack{
                            // Delete last record button
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
                                    .frame(height: 40)
                                    .frame(width: 40)
                                    .foregroundStyle(.red)
                                
                            }
                            .padding(.trailing, 250.0)
                            Text("Delete")
                                .foregroundStyle(.red)
                                .font(.caption)
                                .padding(.trailing, 250)
                            Text("last record")
                                .foregroundStyle(.red)
                                .font(.caption)
                                .padding(.trailing, 250)
                        }
                    }
//                    .frame(width: screenWidth / 2.0, alignment: .leading)
                    .padding(.top, 0.66 * arViewHeight + 0.32 * screenHeight)
                    
                    // Flash light control button
                    VStack{
                        Button(action: toggleFlash){
                            if(openFlash){
                                VStack{
                                    Image(systemName: "flashlight.off.circle.fill")
                                        .resizable()
                                        .frame(height: 40)
                                        .frame(width: 40)
                                    Text("Flash light off")
                                        .foregroundStyle(.accent)
                                        .font(.caption)
                                }
                            }else{
                                VStack{
                                    Image(systemName: "flashlight.on.circle.fill")
                                        .resizable()
                                        .frame(height: 40)
                                        .frame(width: 40)
                                    Text("Flash light on")
                                        .foregroundStyle(.accent)
                                        .font(.caption)
                                }
                            }
                        }
                    }
                    .padding(.leading, 240)
                    .padding(.top, 0.8 * arViewHeight + 0.2 * screenHeight)
                }
                
            }
            .frame(width: 10.0, height: 10.0)
            .alert(isPresented: $arViewModel.depthStatus.showAlert) {  // ✅ Show alert when depth is missing
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
        .onChange(of: appStatus.ifAudioRecordingEnabled) { _, newValue in
            arViewModel.ifAudioEnable = newValue
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
//        let rgbImageFolder = FileElement.directory(SubLevelDirectory(url:fileSetNames.rgbImagesDirectory))
        let depthImageFolder = FileElement.directory(SubLevelDirectory(url: fileSetNames.depthImagesDirectory))
        
        return [rgbFile, depthFile, poseFile, depthImageFolder]
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
    
