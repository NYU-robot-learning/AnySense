//
//  ARViewContainer.swift
//  Anysense
//
//  Created by Michael on 2024/7/25.
//

import SwiftUI
import ARKit
import RealityKit
import Foundation
import AVFoundation
import Network
import CoreMedia
import CoreImage
import UIKit
import CoreImage.CIFilterBuiltins
import WebRTC


struct ARViewContainer: UIViewRepresentable {
    var session: ARSession
    typealias UIViewType = ARView
    
    func makeUIView(context: Context) -> ARView {
        // Initialize the ARView
        let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        arView.session = session
        arView.environment.sceneUnderstanding.options = [] // No extra scene understanding
        return arView
    }
    func updateUIView(_ uiView: ARView, context: Context) {
        if uiView.session !== session {
            uiView.session = session
        }
    }
    
    func dismantleUIView(_ uiView: ARView, coordinator: Context) {
        
    }
//    func destroyUIView(_ uiView: ARView, context: Context) {
//            uiView.session.pause()
//    }
    
    
}

class ARViewModel: ObservableObject{
    var session = ARSession()
    var audioSession = AVCaptureSession()
    var audioCaptureDelegate: AudioCaptureDelegate?

    // 100 FPS: 0.01 (Not sure if its possible)
    // 60 FPS: 0.017 : (1.0/60.0)
    // 30 FPS: 0.033 : (1.0/30.0)
    // 25 FPS: 0.04
    
    public var userFPS: Double?
    public var isColorMapOpened = false
    private var usbManager = USBManager()
    
    private var orientation: UIInterfaceOrientation = .portrait
    
    // Control the destination of rgb and depth video file
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelBufferAdapter: AVAssetWriterInputPixelBufferAdaptor?
    private var depthAssetWriter: AVAssetWriter?
    private var depthVideoInput: AVAssetWriterInput?
    private var depthPixelBufferAdapter: AVAssetWriterInputPixelBufferAdaptor?
    private var viewPortSize = CGSize(width: 720, height: 960)
    private var depthViewPortSize = CGSize(width: 192, height: 256)

    private var combinedRGBTransform: CGAffineTransform?
    private var combinedDepthTransform: CGAffineTransform?
    
    private var rgbOutputPixelBufferUSB: CVPixelBuffer?
    private var depthOutputPixelBufferUSB: CVPixelBuffer?
    private var depthConfidenceOutputPixelBufferUSB: CVPixelBuffer?
    
    private var poseFileHandle: FileHandle?
    @Published var isOpen : Bool = false
    
    // Control the destination of rgb images directory and depth images directory
    private var rgbDirect: URL = URL(fileURLWithPath: "")
    private var depthDirect: URL = URL(fileURLWithPath: "")
    // Control the destination of pose data text file
    private var poseURL: URL = URL(fileURLWithPath: "")
    private var generalURL: URL = URL(fileURLWithPath: "")
    private var globalPoseFileName: String = ""
    
    public var rgbImageCount: Int = 0
    public var depthImageCount: Int = 0
    public var timeCount: Double = 0.0
    public var recordTimestamp: Double = 0.0
    
    private var startTime: CMTime?
    private let ciContext: CIContext
    
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    
    private var rgbImagesToSave: [CVPixelBuffer] = []
    private var depthImagesToSave: [CVPixelBuffer] = []
    private let batchSize = 10
    private let assetWritingSemaphore = DispatchSemaphore(value: 1)
    
    private var lastFrameTimestamp: TimeInterval = 0
    
    private var streamConnection: NWConnection?
    
    private var rgbAttributes: [String: Any] = [:]
    private var depthAttributes: [String: Any] = [:]
    private var depthConfAttributes: [String: Any] = [:]
    private var audioOutputSettings: [String: Any] = [:]
    
    init() {
        self.rgbAttributes = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
            kCVPixelBufferWidthKey as String: Int(viewPortSize.width),
            kCVPixelBufferHeightKey as String: Int(viewPortSize.height)
        ]
        self.depthAttributes = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_OneComponent32Float,
            kCVPixelBufferWidthKey as String: Int(depthViewPortSize.width),
            kCVPixelBufferHeightKey as String: Int(depthViewPortSize.height)
        ]
        self.depthConfAttributes = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_OneComponent8,
            kCVPixelBufferWidthKey as String: Int(depthViewPortSize.width),
            kCVPixelBufferHeightKey as String: Int(depthViewPortSize.height)
        ]
        self.audioOutputSettings = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 44100.0,
            AVEncoderBitRateKey: 128000
        ]
        
        self.ciContext = CIContext()
        self.startSession()
        
        guard let audioDevice = AVCaptureDevice.default(for: .audio),
              let audioDeviceInput = try? AVCaptureDeviceInput(device: audioDevice) else {
              fatalError("Unable to access microphone.")
        }
        audioSession.addInput(audioDeviceInput)
        
        let audioOutput = AVCaptureAudioDataOutput()
        if audioSession.canAddOutput(audioOutput) {
            audioSession.addOutput(audioOutput)
        }
        var rgb_init = false
        var depth_init = false
        let flipTransform = (self.orientation.isPortrait) ? CGAffineTransform(scaleX: -1, y: -1).translatedBy(x: -1, y: -1) : .identity
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { timer in
            if let currentFrame = self.session.currentFrame {
//                timer.invalidate() // Stop the timer once the frame is available
                if !rgb_init{
                    let rgbPixelBuffer = currentFrame.capturedImage
                    
                    let rgbSize = CGSize(width: CVPixelBufferGetWidth(rgbPixelBuffer), height: CVPixelBufferGetHeight(rgbPixelBuffer))
                    let normalizeTransform = CGAffineTransform(scaleX: 1.0/rgbSize.width, y: 1.0/rgbSize.height)
                    
                    let displayTransform = currentFrame.displayTransform(for: self.orientation, viewportSize: self.viewPortSize)
                    let toViewPortTransform = CGAffineTransform(scaleX: self.viewPortSize.width, y: self.viewPortSize.height)
                    
                    self.combinedRGBTransform = normalizeTransform.concatenating(flipTransform).concatenating(displayTransform).concatenating(toViewPortTransform)
                    rgb_init = true
                }
                if !depth_init {
                    if let depthPixelBuffer = currentFrame.sceneDepth?.depthMap {
                        // Stop the depth initialization timer once depthMap is available
//                        depthTimer.invalidate()
                        if rgb_init {
                            timer.invalidate()
                        }
                        
                        let depthSize = CGSize(width: CVPixelBufferGetWidth(depthPixelBuffer), height: CVPixelBufferGetHeight(depthPixelBuffer))
                        let normalizeTransform = CGAffineTransform(scaleX: 1.0 / depthSize.width, y: 1.0 / depthSize.height)
                        
                        let depthDisplayTransform = currentFrame.displayTransform(for: self.orientation, viewportSize: self.depthViewPortSize)
                        let toDepthViewPortTransform = CGAffineTransform(scaleX: self.depthViewPortSize.width, y: self.depthViewPortSize.height)
                        
                        self.combinedDepthTransform = normalizeTransform.concatenating(flipTransform).concatenating(depthDisplayTransform).concatenating(toDepthViewPortTransform)
                        depth_init = true
                    } else {
                        print("Depth map unavailable. Retrying initialization")
                    }
                }
            }
        }
        print("Finished setting up transforms")
    }

    func startSession() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
            guard status == .authorized else {
                print("Camera permissions not granted.")
                return
        }
        // Create and configure the AR session configuration
        let configuration = ARWorldTrackingConfiguration()
        
        // Loop through available video formats and select the wide-angle camera format
        for videoFormat in ARWorldTrackingConfiguration.supportedVideoFormats {
            if videoFormat.captureDeviceType == .builtInWideAngleCamera {
                print("Wide-angle camera selected: \(videoFormat)")
                configuration.videoFormat = videoFormat
                break
            } else {
                print("Unsupported video format: \(videoFormat.captureDeviceType)")
            }
        }
        
        // Set the session configuration properties
        configuration.frameSemantics = .sceneDepth
        configuration.planeDetection = []
        configuration.environmentTexturing = .none  // No environment texturing
        configuration.sceneReconstruction = []  // No scene reconstruction
        configuration.isAutoFocusEnabled = false
        
        // Run the session with the configuration
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        print("Starting session")
        isOpen = true
    }
    
    func pauseSession(){
        session.pause()
        isOpen = false
    }
    
    func killSession() {
        session.pause() // Pause before releasing resources
        session = ARSession() // Replace with a new ARSession
        isOpen = false
        print("ARSession killed and reset.")
    }
    
    func startUSBStreaming() {
        displayLink = CADisplayLink(target: self, selector: #selector(sendFrameUSB))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: Float(self.userFPS!), maximum: Float(self.userFPS!), preferred: Float(self.userFPS!))
        displayLink?.add(to: .main, forMode: .common)
    }
    
    func stopUSBStreaming() {
        displayLink?.invalidate()
        displayLink = nil
    }
    
    func setupUSBStreaming() {
        var rgbBuffer: CVPixelBuffer?
        var depthBuffer: CVPixelBuffer?
        var depthConfidenceBuffer: CVPixelBuffer?

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(viewPortSize.width),
            Int(viewPortSize.height),
            kCVPixelFormatType_32ARGB,
            rgbAttributes as CFDictionary,
            &rgbBuffer
        )
        guard status == kCVReturnSuccess else {
            print("Failed to create CVPixelBuffer")
            return
        }
        self.rgbOutputPixelBufferUSB = rgbBuffer
        
        let depthStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(depthViewPortSize.width),
            Int(depthViewPortSize.height),
            kCVPixelFormatType_DepthFloat32,
            depthAttributes as CFDictionary,
            &depthBuffer
        )
        
        guard depthStatus == kCVReturnSuccess else {
            print("Failed to create CVPixelBuffer")
            return
        }
        self.depthOutputPixelBufferUSB = depthBuffer
        
        let depthConfidenceStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(depthViewPortSize.width),
            Int(depthViewPortSize.height),
            kCVPixelFormatType_OneComponent8,
            depthConfAttributes as CFDictionary,
            &depthConfidenceBuffer
        )
        guard depthConfidenceStatus == kCVReturnSuccess else {
            print("Failed to create CVPixelBuffer")
            return
        }
        self.depthConfidenceOutputPixelBufferUSB = depthConfidenceBuffer
        print("Made all USB Buffers")
        usbManager.connect()
    }
    
    func killUSBStreaming() {
        self.usbManager.disconnect()
        
        self.rgbOutputPixelBufferUSB = nil
        self.depthOutputPixelBufferUSB = nil
        self.depthConfidenceOutputPixelBufferUSB = nil
    }
    
    func startWiFiStreaming(host: String, port: UInt16) {
        // Set up the network connection
//        // Start WebRTC connection
//        webRTCManager.setupConnection()
    }

    func stopWiFiStreaming() {
        displayLink?.invalidate()
        displayLink = nil
        streamConnection?.cancel()
        streamConnection = nil
    }
    
    @objc private func sendFrame(link: CADisplayLink) {
        streamVideoFrameUSB()
    }
    
    @objc private func sendFrameUSB(link: CADisplayLink) {
        streamVideoFrameUSB()
    }
    
    func streamVideoFrameUSB() {
        guard let currentFrame = session.currentFrame else {return}
        
        let rgbPixelBuffer = currentFrame.capturedImage
        guard let depthPixelBuffer = currentFrame.sceneDepth?.depthMap else { return }
        guard let depthConfidencePixelBuffer = currentFrame.sceneDepth?.confidenceMap else { return }
        
        let cameraIntrinsics = currentFrame.camera.intrinsics
        var intrinsicCoeffs = IntrinsicMatrixCoeffs(
            fx: cameraIntrinsics.columns.0.x,
            fy: cameraIntrinsics.columns.1.y,
            tx: cameraIntrinsics.columns.2.x,
            ty: cameraIntrinsics.columns.2.y
        )
        let cameraTransform = currentFrame.camera.transform

        // Transform the orientation matrix to unit quaternion
        let quaternion = simd_quaternion(cameraTransform)
        var camera_pose = CameraPose(
            qx: quaternion.vector.x,
            qy: quaternion.vector.y,
            qz: quaternion.vector.z,
            qw: quaternion.vector.w,
            tx: cameraTransform.columns.3.x,
            ty: cameraTransform.columns.3.y,
            tz: cameraTransform.columns.3.z
        )
        var record3dHeader = Record3DHeader(
            rgbWidth: UInt32(self.viewPortSize.width),
            rgbHeight: UInt32(self.viewPortSize.height),
            depthWidth: UInt32(self.depthViewPortSize.width),
            depthHeight: UInt32(self.depthViewPortSize.height),
            confidenceWidth: UInt32(self.depthViewPortSize.width),
            confidenceHeight: UInt32(self.depthViewPortSize.height),
            rgbSize: 0, // Placeholder
            depthSize: 0, // Placeholder
            confidenceMapSize: 0, // Placeholder
            miscSize: 0, // Placeholder
            deviceType: 1 // Placeholder
        )
        
        DispatchQueue.global(qos: .userInitiated).async {
            CVPixelBufferLockBaseAddress(rgbPixelBuffer, .readOnly)
            CVPixelBufferLockBaseAddress(self.rgbOutputPixelBufferUSB!, [])
            
            let rgbCiImage = CIImage(cvPixelBuffer: rgbPixelBuffer)
            let rgbTransformedImage = rgbCiImage.transformed(by: self.combinedRGBTransform!)

            guard let rgbCgImage = self.ciContext.createCGImage(rgbTransformedImage, from: rgbTransformedImage.extent) else{
                return
            }
            let rgbImageData = UIImage(cgImage: rgbCgImage).jpegData(compressionQuality: 0.5)

            record3dHeader.rgbSize = UInt32(rgbImageData!.count)
            
            CVPixelBufferUnlockBaseAddress(self.rgbOutputPixelBufferUSB!, [])
            CVPixelBufferUnlockBaseAddress(rgbPixelBuffer, .readOnly)
            
            CVPixelBufferLockBaseAddress(depthPixelBuffer, .readOnly)
            CVPixelBufferLockBaseAddress(self.depthOutputPixelBufferUSB!, [])
            
            let depthCiImage = CIImage(cvPixelBuffer: depthPixelBuffer)
            let depthTransformedImage = depthCiImage.transformed(by: self.combinedDepthTransform!)
            
            self.ciContext.render(depthTransformedImage, to: self.depthOutputPixelBufferUSB!)
            let compressedDepthData = self.usbManager.compressData(from: self.depthOutputPixelBufferUSB!, isDepth: true)
            
            record3dHeader.depthSize = UInt32(compressedDepthData!.count)
            
            CVPixelBufferUnlockBaseAddress(self.depthOutputPixelBufferUSB!, [])
            CVPixelBufferUnlockBaseAddress(depthPixelBuffer, .readOnly)
            
            CVPixelBufferLockBaseAddress(depthConfidencePixelBuffer, .readOnly)
            CVPixelBufferLockBaseAddress(self.depthConfidenceOutputPixelBufferUSB!, [])
            
            let depthConfidenceCiImage = CIImage(cvPixelBuffer: depthConfidencePixelBuffer)
            let depthConfTransformedImage = depthConfidenceCiImage.transformed(by: self.combinedDepthTransform!)
            self.ciContext.render(depthConfTransformedImage, to: self.depthConfidenceOutputPixelBufferUSB!)
            let compressedDepthConfData = self.usbManager.compressData(from: self.depthConfidenceOutputPixelBufferUSB!, isDepth: false)

            record3dHeader.confidenceMapSize = UInt32(compressedDepthConfData!.count)
            
            CVPixelBufferUnlockBaseAddress(self.depthConfidenceOutputPixelBufferUSB!, [])
            CVPixelBufferUnlockBaseAddress(depthConfidencePixelBuffer, .readOnly)
            self.usbManager.sendData(
                record3dHeaderData: Data(bytes: &record3dHeader, count: MemoryLayout<Record3DHeader>.size),
                intrinsicMatData: Data(bytes: &intrinsicCoeffs, count: MemoryLayout<IntrinsicMatrixCoeffs>.size),
                poseData: Data(bytes: &camera_pose, count: MemoryLayout<CameraPose>.size),
                rgbImageData: rgbImageData!,
                compressedDepthData: compressedDepthData!,
                compressedConfData: compressedDepthConfData!
            )
            
        }
        
    }
    
    @objc private func updateFrame(link: CADisplayLink) {
        guard lastTimestamp > 0 else {
            // Initialize timestamp on the first call
            lastTimestamp = link.timestamp
            return
        }
        captureVideoFrame()
        timeCount += 1.0
    }
    
    func startRecording() -> Array<String> {
        rgbImageCount = 0
        depthImageCount = 0
        timeCount = 0.0
        recordTimestamp = 0.0
        
        let saveFileNames = setupRecording()
        
        assetWriter?.startWriting()
        startTime = CMTimeMake(value: Int64(CACurrentMediaTime() * 1000), timescale: 1000)
        assetWriter?.startSession(atSourceTime: startTime!)
//        audioSession.startRunning()
        
        DispatchQueue.global(qos: .background).async {
            self.audioSession.startRunning()
        }
        
        depthAssetWriter?.startWriting()
        depthAssetWriter?.startSession(atSourceTime: startTime!)

        displayLink = CADisplayLink(target: self, selector: #selector(updateFrame))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: Float(self.userFPS!), maximum: Float(self.userFPS!), preferred: Float(self.userFPS!))
        displayLink?.add(to: .main, forMode: .common)
        
        return saveFileNames
        
    }
    
    
    func stopRecording(){
        displayLink?.invalidate()
        displayLink = nil
        audioSession.stopRunning()
        audioInput?.markAsFinished()
        videoInput?.markAsFinished()
        
        audioCaptureDelegate = nil
        
        assetWriter?.finishWriting {
            self.assetWriter = nil
            print("RGB Video recording finished.")
        }
        
        depthVideoInput?.markAsFinished()
        depthAssetWriter?.finishWriting {
            self.depthAssetWriter = nil
            print("Depth Video recording finished.")
        }

        do {
            try poseFileHandle?.close()
        } catch {
            print("Error closing pose file")
        }

//        displayLink?.invalidate()
//        displayLink = nil
    }
    
    func setupRecording() -> Array<String>{
        // Determine all the destinated file saving URL or this recording by its start time
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd-HH_mm_ss"
        let currentDateTime = dateFormatter.string(from: Date())
        let rgbFileName = "RGB_\(currentDateTime).mp4"
        let depthFileName = "Depth_\(currentDateTime).mp4"
        // let colorMapFileName = "AR_Colored_\(currentDateTime).mp4"
        let rgbImagesDirectName = "RGB_Images_\(currentDateTime)"
        var depthImagesDirectName = "Depth_Images_\(currentDateTime)"
        if isColorMapOpened {
            depthImagesDirectName = "Depth_Colored_Images_\(currentDateTime)"
        }
        let poseFileName = "AR_Pose_\(currentDateTime).txt"
        let generalDataRecordDirectName = "\(currentDateTime)"
        let tactileDataFileName = "Tactile_\(currentDateTime).bin"
        
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let generalDataRecordDirectURL = url[0].appendingPathComponent(generalDataRecordDirectName)
        let rgbVideoURL = generalDataRecordDirectURL.appendingPathComponent(rgbFileName)
        let depthVideoURL = generalDataRecordDirectURL.appendingPathComponent(depthFileName)
        // let coloredVideoURL = generalDataRecordDirectURL.appendingPathComponent(colorMapFileName)
        let rgbImagesDirect = generalDataRecordDirectURL.appendingPathComponent(rgbImagesDirectName)
        let depthImagesDirect = generalDataRecordDirectURL.appendingPathComponent(depthImagesDirectName)
        let poseTextURL = generalDataRecordDirectURL.appendingPathComponent(poseFileName)
        
        do {
            try FileManager.default.createDirectory(at: generalDataRecordDirectURL, withIntermediateDirectories: true, attributes: nil)
            try FileManager.default.createDirectory(at: rgbImagesDirect, withIntermediateDirectories: true, attributes: nil)
            try FileManager.default.createDirectory(at: depthImagesDirect, withIntermediateDirectories: true, attributes: nil)
            try createFile(targetURL: generalDataRecordDirectURL, fileName: poseFileName)
            try createFile(targetURL: generalDataRecordDirectURL, fileName: tactileDataFileName)
            
        } catch {
            print("Error")
        }
        
        rgbDirect = rgbImagesDirect
        depthDirect = depthImagesDirect
        poseURL = poseTextURL
        globalPoseFileName = poseFileName
        generalURL = generalDataRecordDirectURL
        
        do {
            // Determine which video file url the assetWriter will write into
            
            // RGB
            assetWriter = try AVAssetWriter(outputURL: rgbVideoURL, fileType: .mp4)
            
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: viewPortSize.width,
                AVVideoHeightKey: viewPortSize.height,
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
                /*
                AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: 2000000,
                        AVVideoMaxKeyFrameIntervalKey: 30
                ]
                 */
            ]
            
            videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput?.expectsMediaDataInRealTime = true
            assetWriter?.add(videoInput!)
            
            audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioOutputSettings)
            audioInput?.expectsMediaDataInRealTime = true
            assetWriter?.add(audioInput!)
            
            pixelBufferAdapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput!, sourcePixelBufferAttributes: rgbAttributes)
            
            // Update the audio delegate with the new audioWriterInput
            audioCaptureDelegate = AudioCaptureDelegate(writerInput: audioInput!)

            // Attach the new delegate to the existing AVCaptureAudioDataOutput
            if let audioOutput = audioSession.outputs.first(where: { $0 is AVCaptureAudioDataOutput }) as? AVCaptureAudioDataOutput {
                let audioQueue = DispatchQueue(label: "AudioProcessingQueue")
                audioOutput.setSampleBufferDelegate(audioCaptureDelegate, queue: audioQueue)
            }
            
            let depthVideoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(depthViewPortSize.width),
                AVVideoHeightKey: Int(depthViewPortSize.height),
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
                /*
                AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: 2000000,
                        AVVideoMaxKeyFrameIntervalKey: 30
                ]
                 */
            ]
            // Depth
            depthAssetWriter = try AVAssetWriter(outputURL: depthVideoURL, fileType: .mp4)
            depthVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: depthVideoSettings)
            depthVideoInput?.expectsMediaDataInRealTime = true
            depthAssetWriter?.add(depthVideoInput!)

            let recordingDepthAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_OneComponent8,
                kCVPixelBufferWidthKey as String: Int(self.depthViewPortSize.width),
                kCVPixelBufferHeightKey as String: Int(self.depthViewPortSize.height)
            ]
            
            depthPixelBufferAdapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: depthVideoInput!, sourcePixelBufferAttributes: recordingDepthAttributes)
            
            // Colormap
            /*
            coloredAssetWriter = try AVAssetWriter(outputURL: coloredVideoURL, fileType: .mp4)
            coloredVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            coloredVideoInput?.expectsMediaDataInRealTime = true
            coloredAssetWriter?.add(coloredVideoInput!)
            
            let coloredAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: 720,
                kCVPixelBufferHeightKey as String: 960
            ]
            
            coloredPixelBufferAdapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: coloredVideoInput!, sourcePixelBufferAttributes: coloredAttributes)
            
            coloredAssetWriter?.startWriting()
            coloredAssetWriter?.startSession(atSourceTime: startTime!)
            */
            
            poseFileHandle = try FileHandle(forWritingTo: poseTextURL)
            try poseFileHandle?.seekToEnd()
        } catch {
            print("Failed to setup recording: \(error)")
        }

        return [rgbFileName, depthFileName, currentDateTime, rgbImagesDirectName, depthImagesDirectName, poseFileName, generalDataRecordDirectName, tactileDataFileName]
    }
    
    
    func captureVideoFrame() {
//        let preRecvFrameTimestamp = CACurrentMediaTime()
//        print("Time at start: ", preRecvFrameTimestamp - lastFrameTimestamp)

        guard let currentFrame = session.currentFrame else {return}

        var imgSuccessFlag = true

        let currentTime = CMTimeMake(value: Int64(CACurrentMediaTime() * 1000), timescale: 1000)
    
        let rgbPixelBuffer = currentFrame.capturedImage
        guard let depthPixelBuffer = currentFrame.sceneDepth?.depthMap else { return }
        let cropRect = CGRect(
            x: 0, y: 0, width: self.viewPortSize.width, height: self.viewPortSize.height
        )
        let depthCropRect = CGRect(
            x: 0, y: 0, width: self.depthViewPortSize.width, height: self.depthViewPortSize.height
        )
    
        //guard let rgbdPixelBuffer = createRGBDFrame(rgb: rgbPixelBuffer, depth: depthPixelBuffer) else {return}
//        let preImgTimestamp = CACurrentMediaTime()
//        print("Post settings duration: ", preImgTimestamp - postSceneTimestamp)
        DispatchQueue.global(qos: .userInitiated).async {
            
            if let videoInput = self.videoInput, videoInput.isReadyForMoreMediaData == true {
                guard let outputPixelBufferPool = self.pixelBufferAdapter?.pixelBufferPool else { return }
                var outputPixelBuffer: CVPixelBuffer?
                let status = CVPixelBufferPoolCreatePixelBuffer(nil, outputPixelBufferPool, &outputPixelBuffer)
                if status == kCVReturnSuccess, let outputBuffer = outputPixelBuffer {
                    CVPixelBufferLockBaseAddress(rgbPixelBuffer, .readOnly)
                    CVPixelBufferLockBaseAddress(outputBuffer, [])
                    
                    let ciImage = CIImage(cvPixelBuffer: rgbPixelBuffer)
                    let transformedImage = ciImage.transformed(by: self.combinedRGBTransform!) //.cropped(to: cropRect)
                    self.ciContext.render(transformedImage, to: outputBuffer, bounds: cropRect, colorSpace: CGColorSpaceCreateDeviceRGB())
                    
//                    self.assetWritingSemaphore.wait()
//                    defer { self.assetWritingSemaphore.signal() }
                    
                    if let success = self.pixelBufferAdapter?.append(outputBuffer, withPresentationTime: currentTime) {
                        if !success {
                            let isReady = self.pixelBufferAdapter?.assetWriterInput.isReadyForMoreMediaData ?? false
                            print("Failed to append RGB pixel buffer. Pixel buffer adapter state: \(isReady), Time: \(currentTime)")
                            
                            if let error = self.assetWriter?.error {
                                print("Error: \(error.localizedDescription)")
                            } else {
                                print("Unknown asset writer error.")
                            }
                            imgSuccessFlag = false
                        }
                    } else {
                        print("Failed to append RGB pixel buffer: Pixel buffer adapter is nil.")
                        imgSuccessFlag = false
                    }

                    CVPixelBufferUnlockBaseAddress(outputBuffer, [])
                    CVPixelBufferUnlockBaseAddress(rgbPixelBuffer, .readOnly)
                }
            }
            
            
            
            if self.depthVideoInput?.isReadyForMoreMediaData == true {
                
                guard let pixelBufferPool = self.depthPixelBufferAdapter?.pixelBufferPool else {
                    print("Depth pixel buffer pool is nil.")
                    return
                }
                var outputPixelBuffer: CVPixelBuffer?
                let status = CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &outputPixelBuffer)
                guard status == kCVReturnSuccess, let depthOutputBuffer = outputPixelBuffer else {
                    print("Unable to create output pixel buffer for depth.")
                    return
                }
                
                CVPixelBufferLockBaseAddress(depthPixelBuffer, .readOnly)
                CVPixelBufferLockBaseAddress(depthOutputBuffer, [])
                
//                Save metric depth data as binary file
                let width = CVPixelBufferGetWidth(depthPixelBuffer)
                let height = CVPixelBufferGetHeight(depthPixelBuffer)
//                let bytesPerRow = CVPixelBufferGetBytesPerRow(depthPixelBuffer)
                
                guard let baseAddress = CVPixelBufferGetBaseAddress(depthPixelBuffer) else {
                    CVPixelBufferUnlockBaseAddress(depthPixelBuffer, .readOnly)
                    return
                }
                
                let floatBuffer = baseAddress.assumingMemoryBound(to: Float32.self)
                let dataSize = width * height * MemoryLayout<Float32>.size
                let data = Data(bytes: floatBuffer, count: dataSize)
                
                // Save binary data to a file
                let fileURL = self.depthDirect.appendingPathComponent("\(self.depthImageCount).bin")
                do {
                    try data.write(to: fileURL)
//                    print("Saved depth data to \(fileURL)")
                } catch {
                    print("Error saving binary file: \(error)")
                }
                self.depthImageCount += 1
                
                let ciImage = CIImage(cvPixelBuffer: depthPixelBuffer)
                
                let depthFilter = CIFilter(name: "CIColorControls")!
                depthFilter.setValue(ciImage, forKey: kCIInputImageKey)
                depthFilter.setValue(2.0, forKey: kCIInputSaturationKey) // Keep saturation
                depthFilter.setValue(0.0, forKey: kCIInputBrightnessKey) // Adjust brightness
                depthFilter.setValue(3.0, forKey: kCIInputContrastKey) // Increase contrast for clarity
                
                guard let ciImageAfterFiltered = depthFilter.outputImage else {
                    print("Failed to get output image from color controls filter.")
                    return
                }
                
                
                var ciImageToRender = ciImageAfterFiltered
                
                if(self.isColorMapOpened){
                    let falseColorFilter = CIFilter.falseColor()
                    falseColorFilter.color0 = CIColor(red: 1, green: 1, blue: 0)
                    falseColorFilter.color1 = CIColor(red: 0, green: 0, blue: 1)
                    falseColorFilter.inputImage = ciImageAfterFiltered
                    ciImageToRender = falseColorFilter.outputImage!
                }
                
                let transformedImage = ciImageToRender.transformed(by: self.combinedDepthTransform!) //.cropped(to: cropRect)
                
                if(self.isColorMapOpened) {
                    self.ciContext.render(transformedImage, to: depthOutputBuffer, bounds: depthCropRect, colorSpace: CGColorSpaceCreateDeviceRGB())
                } else {
                    self.ciContext.render(transformedImage, to: depthOutputBuffer, bounds: depthCropRect, colorSpace: CGColorSpaceCreateDeviceGray())
                }
                
                if let success = self.depthPixelBufferAdapter?.append(depthOutputBuffer, withPresentationTime: currentTime) {
                    if !success {
                        let isReady = self.pixelBufferAdapter?.assetWriterInput.isReadyForMoreMediaData ?? false
                        print("Failed to append depth pixel buffer. Pixel buffer adapter state: \(isReady), Time: \(currentTime)")
                        imgSuccessFlag = false
                    }
                } else {
                    print("Failed to append depth pixel buffer: Pixel buffer adapter is nil.")
                    imgSuccessFlag = false
                }
                
                CVPixelBufferUnlockBaseAddress(depthOutputBuffer, [])
                CVPixelBufferUnlockBaseAddress(depthPixelBuffer, .readOnly)
            }
            
                        
        }
//        let postImgTimestamp = CACurrentMediaTime()
//        print("Image retrieval time:", postImgTimestamp - preImgTimestamp)
        if !imgSuccessFlag {return}
//        print("Did not return", imgSuccessFlag)
        let cameraTransform = currentFrame.camera.transform

        // Transform the orientation matrix to unit quaternion
        let quaternion = simd_quaternion(cameraTransform)

        // Extract the value
        let orientationX = quaternion.vector.x
        let orientationY = quaternion.vector.y
        let orientationZ = quaternion.vector.z
        let orientationW = quaternion.vector.w
        
        // Use the last column's vlaue, which is the representation of translation
        let translationX = cameraTransform.columns.3.x
        let translationY = cameraTransform.columns.3.y
        let translationZ = cameraTransform.columns.3.z
        
        let currentTimer = Date()
        let dataReadTimeStamp = Int64(currentTimer.timeIntervalSince1970 * 1000)
        
        let poseWithTime = ["\"<\(dataReadTimeStamp)>\"", orientationX, orientationY, orientationZ, orientationW, translationX, translationY, translationZ] as [Any]
//        let postPoseTimestamp = CACurrentMediaTime()
//        print("Pose retrieval time:", postPoseTimestamp - postImgTimestamp)
        
        do {
            let line = poseWithTime.map { String(describing: $0)}.joined(separator: ",") + "\n"
            if let data = line.data(using: .utf8) {
                try self.poseFileHandle?.write(contentsOf: data)
            }
        } catch {
            print("Error when writing to the pose text file\n")
        }
        
//        let postWriteTimestamp = CACurrentMediaTime()
//        print("Saving time: ", postWriteTimestamp - postPoseTimestamp)
//        
//        let currentTimestamp = CACurrentMediaTime()
//        print("Iteration time: ", currentTimestamp - lastFrameTimestamp)
//
//        lastFrameTimestamp = currentTimestamp
    }
    
    func getDocumentsDirect() -> URL{
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        print(paths[0].path)
        return paths[0]
    }
    
    func createFile(targetURL: URL, fileName: String) throws {
            let fileURL = targetURL.appendingPathComponent(fileName)
            let success = FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
            if !success {
                throw NSError(domain: "FileCreationError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create file at \(fileURL.path)"])
            }
    }
    
}

class AudioCaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let writerInput: AVAssetWriterInput?

    init(writerInput: AVAssetWriterInput) {
        self.writerInput = writerInput
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Append audio sample buffer to the writer input
        guard writerInput?.isReadyForMoreMediaData == true else {
            print("Not ready")
            return
        }
        writerInput?.append(sampleBuffer)
    }
}
