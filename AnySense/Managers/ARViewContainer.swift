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
import Combine
import Accelerate
//import WebRTC

struct RecordingFiles {
    let rgbFileName: URL
    let depthFileName: URL
    let timestamp: String
    let rgbImagesDirectory: URL
    let depthImagesDirectory: URL
    let poseFile: URL
    let generalDataDirectory: String
    let tactileFile: URL
}

func createFile(fileURL: URL) throws {
        let success = FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
        if !success {
            throw NSError(domain: "FileCreationError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create file at \(fileURL.path)"])
        }
}

struct ARViewContainer: UIViewRepresentable {
    var session: ARSession
    var arVisualizationManager: ARVisualizationManager
    typealias UIViewType = ARView
    
    func makeUIView(context: Context) -> ARView {
        // Initialize the ARView
        let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        arView.session = session
        arView.environment.sceneUnderstanding.options = [] // No extra scene understanding
        
        // Setup AR visualization with the created ARView
        arVisualizationManager.setupVisualization(with: arView)
        
        // Add tap recognizer for goal setting (point-conditioned models)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        arView.addGestureRecognizer(tap)
        
        return arView
    }
    func updateUIView(_ uiView: ARView, context: Context) {
        if uiView.session !== session {
            uiView.session = session
        }
    }
    
    // MARK: - Coordinator for gesture handling
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    class Coordinator: NSObject {
        let parent: ARViewContainer
        init(_ parent: ARViewContainer) { self.parent = parent }
        
        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let arView = recognizer.view as? ARView else { return }
            let location = recognizer.location(in: arView)

            // Try depth-based unprojection first (for LiDAR devices)
            if let (worldPoint, method) = parent.worldPointFromDepth(at: location, in: arView) {
                print("Using \(method) method for 3D point: \(worldPoint)")

                // Create anchor at the world point
                var t = matrix_identity_float4x4
                t.columns.3 = SIMD4<Float>(worldPoint.x, worldPoint.y, worldPoint.z, 1)
                let goalAnchor = ARAnchor(name: "goal", transform: t)
                arView.session.add(anchor: goalAnchor)

                // Notify ML pipeline with the world point
                NotificationCenter.default.post(
                    name: NSNotification.Name("ARViewTapForGoal"),
                    object: nil,
                    userInfo: [
                        "worldPoint": worldPoint,
                        "method": method,
                        "location": location,
                        "bounds": arView.bounds
                    ]
                )
                return
            }

            // Fallback to raycast if depth unavailable or failed
            if let hit = arView.raycast(from: location, allowing: .estimatedPlane, alignment: .any).first {
                let t = hit.worldTransform
                let world = simd_float3(t.columns.3.x, t.columns.3.y, t.columns.3.z)

                // Create a native ARKit anchor at the hit (world-locked)
                let goalAnchor = ARAnchor(name: "goal", transform: t)
                arView.session.add(anchor: goalAnchor)

                print("Using raycast fallback for 3D point: \(world)")

                // Notify ML pipeline with the world point
                NotificationCenter.default.post(
                    name: NSNotification.Name("ARViewTapForGoal"),
                    object: nil,
                    userInfo: [
                        "worldPoint": world,
                        "method": "raycast",
                        "location": location,
                        "bounds": arView.bounds
                    ]
                )
                return
            }
            // Fallback: still notify with screen info (no hit yet)
            NotificationCenter.default.post(
                name: NSNotification.Name("ARViewTapForGoal"),
                object: nil,
                userInfo: [
                    "location": location,
                    "bounds": arView.bounds
                ]
            )
        }
    }

    // MARK: - Depth-Based Point Calculation
    private func worldPointFromDepth(at location: CGPoint, in arView: ARView) -> (point: simd_float3, method: String)? {
        guard let frame = arView.session.currentFrame,
              let depth = frame.sceneDepth?.depthMap else {
            return nil
        }

        let depthWidth = CVPixelBufferGetWidth(depth)
        let depthHeight = CVPixelBufferGetHeight(depth)
        let viewBounds = arView.bounds

        // 1. Normalize tap location to view coordinates
        let normView = CGPoint(
            x: location.x / viewBounds.width,
            y: location.y / viewBounds.height
        )

        // 2. Apply display transform to get camera image coordinates
        let ori = arView.window?.windowScene?.interfaceOrientation ?? .portrait
        let disp = frame.displayTransform(for: ori, viewportSize: viewBounds.size)
        let camNorm = normView.applying(disp.inverted())

        // 3. Map to depth pixel coordinates
        let u = Int(clamp(camNorm.x, 0, 1) * CGFloat(depthWidth))
        let v = Int(clamp(camNorm.y, 0, 1) * CGFloat(depthHeight))

        // 4. Sample depth with median filtering for noise reduction
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }

        let base = CVPixelBufferGetBaseAddress(depth)!.assumingMemoryBound(to: Float32.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depth) / MemoryLayout<Float32>.size
        let N = 3
        var samples: [Float] = []

        for j in max(0, v - N)...min(depthHeight - 1, v + N) {
            for i in max(0, u - N)...min(depthWidth - 1, u + N) {
                let d = base[j * bytesPerRow + i]
                if d.isFinite, d > 0 {
                    samples.append(d)
                }
            }
        }

        guard !samples.isEmpty else { return nil }
        samples.sort()
        let depthValue = samples[samples.count / 2] // median

        // 5. Unproject to camera coordinates using intrinsics
        let K = frame.camera.intrinsics
        let fx = K.columns.0.x, fy = K.columns.1.y
        let cx = K.columns.2.x, cy = K.columns.2.y

        let xc = (Float(u) - cx) * depthValue / fx
        let yc = (Float(v) - cy) * depthValue / fy
        let zc = depthValue

        // 6. Transform to world coordinates
        let pc = simd_float4(xc, yc, zc, 1)
        let pw = simd_mul(frame.camera.transform, pc)

        return (simd_float3(pw.x, pw.y, pw.z), "depth")
    }

    // MARK: - Helper Functions
    private func clamp<T: Comparable>(_ value: T, _ minVal: T, _ maxVal: T) -> T {
        return min(max(value, minVal), maxVal)
    }
}

class DepthStatus: ObservableObject {
    @Published var isDepthAvailable: Bool = true
    @Published var showAlert: Bool = false
    
    public func setUnavailable() {
        isDepthAvailable = false
        showAlert = true
    }
}

class ARViewModel: ObservableObject{
    var bluetoothManager: BluetoothManager?
    @Published var isOpen : Bool = false
    @Published var depthStatus = DepthStatus()
    var demosCounter : Int = -1
    var session = ARSession()
    var audioSession = AVCaptureSession()
    var audioCaptureDelegate: AudioCaptureDelegate?
    
    // ML Inference Manager - now optional and initialized later
    @Published var mlManager: MLInferenceManager?
    
    // AR Visualization Manager for 3D pose visualization
    @Published var arVisualizationManager = ARVisualizationManager()
    @Published var goalTapModeEnabled: Bool = false
    @Published var isUSBStreamingActive: Bool = false


    public var userFPS: Double?
    public var isColorMapOpened = false
    public var ifAudioEnable = false
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

    // MARK: - Accelerate Optimization Properties
    private var rgbTransformBuffer: vImage_Buffer?
    private var lastTransformImageSize: CGSize = .zero
    // MARK: - Exposed helpers for MLInferenceManager
    func getARSession() -> ARSession {
        return session
    }
    
    private var poseFileHandle: FileHandle?
    
    // Control the destination of rgb images directory and depth images directory
    private var rgbDirect: URL = URL(fileURLWithPath: "")
    private var depthDirect: URL = URL(fileURLWithPath: "")
    // Control the destination of pose data text file
    private var poseURL: URL = URL(fileURLWithPath: "")
    private var generalURL: URL = URL(fileURLWithPath: "")
    private var globalPoseFileName: String = ""
    
    private var depthRetryCount = 0
    private var maxDepthRetries = 50
    
    private var startTime: CMTime?
    private let ciContext: CIContext
    
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0

    private var streamConnection: NWConnection?
    
    private var rgbAttributes: [String: Any] = [:]
    private var depthAttributes: [String: Any] = [:]
    private var depthConfAttributes: [String: Any] = [:]
    private var audioOutputSettings: [String: Any] = [:]
    
    // Combine subscriptions for ML integration
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        bluetoothManager = BluetoothManager()
        
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
        updateDemoCounter()
        
        // Listen for goal-tap notifications and start odometry + set goal point
        NotificationCenter.default.addObserver(forName: NSNotification.Name("ARViewTapForGoal"), object: nil, queue: .main) { [weak self] notif in
            guard let self = self, let ml = self.mlManager else { 
                print(" Goal tap: No ML manager")
                return 
            }
            // Only handle taps when using a point-conditioned policy and the user enabled goal-tap mode
            print(" Goal tap received - isPointConditioned: \(ml.isPointConditioned), goalTapMode: \(self.goalTapModeEnabled)")
            guard ml.isPointConditioned, self.goalTapModeEnabled else { 
                print("Goal tap ignored - conditions not met")
                return 
            }
            // Prefer direct world point from depth/raycast if provided
            if let world = notif.userInfo?["worldPoint"] as? simd_float3 {
                let method = notif.userInfo?["method"] as? String ?? "unknown"
                print("Using \(method) world point: \(world)")
                ml.setGoalPoint(world)
                self.goalTapModeEnabled = false
                return
            }
            // No worldPoint provided (no raycast hit) — ignore tap
        }
    }
    


    
    
    func getBLEManagerInstance() -> BluetoothManager{
        return bluetoothManager!;
    }

    
    private func setupAudioSession() {
        guard let audioDevice = AVCaptureDevice.default(for: .audio),
              let audioDeviceInput = try? AVCaptureDeviceInput(device: audioDevice) else {
              return
        }
        audioSession.addInput(audioDeviceInput)
        
        let audioOutput = AVCaptureAudioDataOutput()
        if audioSession.canAddOutput(audioOutput) {
            audioSession.addOutput(audioOutput)
        }
    }
    
    private func setupTransforms() {
        DispatchQueue.global(qos: .userInitiated).async {
            while self.depthRetryCount < self.maxDepthRetries {
                guard let currentFrame = self.session.currentFrame else {
                    usleep(10000)
                    continue
                }
                let flipTransform = (self.orientation.isPortrait)
                    ? CGAffineTransform(scaleX: -1, y: -1).translatedBy(x: -1, y: -1)
                    : .identity
                
                if self.combinedRGBTransform == nil {
                    self.initializeRGBTransform(frame: currentFrame, flipTransform: flipTransform)
                }
                
                if !self.depthStatus.isDepthAvailable { break }
                
                        if self.combinedDepthTransform == nil {
            if self.initializeDepthTransform(frame: currentFrame, flipTransform: flipTransform) {
                break
            }
        }
        
        self.depthRetryCount += 1
        usleep(10000)
    }
        }
    }
    
    private func initializeRGBTransform(frame: ARFrame, flipTransform: CGAffineTransform) {
        let rgbPixelBuffer = frame.capturedImage
        let rgbSize = CGSize(width: CVPixelBufferGetWidth(rgbPixelBuffer), height: CVPixelBufferGetHeight(rgbPixelBuffer))
        let normalizeTransform = CGAffineTransform(scaleX: 1.0/rgbSize.width, y: 1.0/rgbSize.height)
        let displayTransform = frame.displayTransform(for: self.orientation, viewportSize: self.viewPortSize)
        let toViewPortTransform = CGAffineTransform(scaleX: self.viewPortSize.width, y: self.viewPortSize.height)
        
        self.combinedRGBTransform = normalizeTransform
            .concatenating(flipTransform)
            .concatenating(displayTransform)
            .concatenating(toViewPortTransform)
    }
    
    private func initializeDepthTransform(frame: ARFrame, flipTransform: CGAffineTransform) -> Bool {
        guard let depthPixelBuffer = frame.sceneDepth?.depthMap else {
            return false
        }
        let depthSize = CGSize(width: CVPixelBufferGetWidth(depthPixelBuffer), height: CVPixelBufferGetHeight(depthPixelBuffer))
        let normalizeTransform = CGAffineTransform(scaleX: 1.0 / depthSize.width, y: 1.0 / depthSize.height)
        
        let depthDisplayTransform = frame.displayTransform(for: self.orientation, viewportSize: self.depthViewPortSize)
        let toDepthViewPortTransform = CGAffineTransform(scaleX: self.depthViewPortSize.width, y: self.depthViewPortSize.height)
        
        self.combinedDepthTransform = normalizeTransform
            .concatenating(flipTransform)
            .concatenating(depthDisplayTransform)
            .concatenating(toDepthViewPortTransform)

        return true
    }
    
    func setupARSession() {
        self.startARSession()
        
        if(ifAudioEnable) {
            setupAudioSession()
        }
        
        setupTransforms()
    }

    func startARSession() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
            guard status == .authorized else {
                return
        }
        // Create and configure the AR session configuration
        let configuration = ARWorldTrackingConfiguration()
        
        // Loop through available video formats and select the wide-angle camera format
        for videoFormat in ARWorldTrackingConfiguration.supportedVideoFormats {
            if videoFormat.captureDeviceType == .builtInWideAngleCamera {
                configuration.videoFormat = videoFormat
                break
            }
        }
        
        // Set the session configuration properties
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        } else {
            depthStatus.setUnavailable()
        }
        configuration.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        configuration.environmentTexturing = .none
        configuration.isAutoFocusEnabled = false
        
        // Run the session with the configuration
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isOpen = true
    }
    
    func pauseARSession(){
        session.pause()
        isOpen = false
    }
    
    func killARSession() {
        session.pause() // Pause before releasing resources
        session = ARSession() // Replace with a new ARSession
        isOpen = false
    }
    
    func startUSBStreaming() {
        displayLink = CADisplayLink(target: self, selector: #selector(sendFrameUSB))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: Float(self.userFPS!), maximum: Float(self.userFPS!), preferred: Float(self.userFPS!))
        displayLink?.add(to: .main, forMode: .common)
        isUSBStreamingActive = true
        mlManager?.setUSBStreamingState(isActive: true)
    }
    
    func stopUSBStreaming() {
        displayLink?.invalidate()
        displayLink = nil
        isUSBStreamingActive = false
        mlManager?.setUSBStreamingState(isActive: false)
    }
    
    func setupUSBStreaming() {
        var rgbBuffer: CVPixelBuffer?

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(viewPortSize.width),
            Int(viewPortSize.height),
            kCVPixelFormatType_32ARGB,
            rgbAttributes as CFDictionary,
            &rgbBuffer
        )
        guard status == kCVReturnSuccess else {
            return
        }
        self.rgbOutputPixelBufferUSB = rgbBuffer

        if self.depthStatus.isDepthAvailable {
            var depthBuffer: CVPixelBuffer?
            var depthConfidenceBuffer: CVPixelBuffer?

            let depthStatus = CVPixelBufferCreate(
                kCFAllocatorDefault,
                Int(depthViewPortSize.width),
                Int(depthViewPortSize.height),
                kCVPixelFormatType_DepthFloat32,
                depthAttributes as CFDictionary,
                &depthBuffer
            )
            
            guard depthStatus == kCVReturnSuccess else {
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
                return
            }
            self.depthConfidenceOutputPixelBufferUSB = depthConfidenceBuffer
        }
        
        usbManager.connect()
    }
    
    func killUSBStreaming() {
        self.usbManager.disconnect()

        self.rgbOutputPixelBufferUSB = nil
        self.depthOutputPixelBufferUSB = nil
        self.depthConfidenceOutputPixelBufferUSB = nil

        // Clean up vImage buffers
        if let transformBuffer = rgbTransformBuffer {
            free(transformBuffer.data)
            rgbTransformBuffer = nil
        }

        isUSBStreamingActive = false
        mlManager?.setUSBStreamingState(isActive: false)
    }
    
//    func startWiFiStreaming(host: String, port: UInt16) {
        // Set up the network connection
//        // Start WebRTC connection
//        webRTCManager.setupConnection()
//    }

//    func stopWiFiStreaming() {
//        displayLink?.invalidate()
//        displayLink = nil
//        streamConnection?.cancel()
//        streamConnection = nil
//    }
    
    @objc private func sendFrame(link: CADisplayLink) {
        streamVideoFrameUSB()
    }
    
    @objc private func sendFrameUSB(link: CADisplayLink) {
        streamVideoFrameUSB()
    }
    
    private func processDepthStreamData(depthPixelBuffer: CVPixelBuffer, outputBuffer: CVPixelBuffer, isDepth: Bool) -> Data? {
        CVPixelBufferLockBaseAddress(depthPixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(outputBuffer, [])

        // Try optimized depth processing
        if canUseOptimizedDepthTransform(for: depthPixelBuffer) {
            processDepthOptimized(depthPixelBuffer, outputBuffer: outputBuffer)
        } else {
            // Fallback to Core Image
            let depthCiImage = CIImage(cvPixelBuffer: depthPixelBuffer)
            let depthTransformedImage = depthCiImage.transformed(by: self.combinedDepthTransform ?? CGAffineTransform.identity)
            self.ciContext.render(depthTransformedImage, to: outputBuffer)
        }

        let compressedData = self.usbManager.compressData(from: outputBuffer, isDepth: isDepth)

        CVPixelBufferUnlockBaseAddress(outputBuffer, [])
        CVPixelBufferUnlockBaseAddress(depthPixelBuffer, .readOnly)

        return compressedData
    }
    
    func streamVideoFrameUSB() {
        guard let currentFrame = session.currentFrame else {return}
        
        let rgbPixelBuffer = currentFrame.capturedImage

        // Perform ML inference on the RGB frame during streaming (provide ARFrame for odometry/goal updates)
        mlManager?.performInference(on: rgbPixelBuffer, arFrame: currentFrame, timestamp: CACurrentMediaTime())
        
        

        // TODO: Check if we need to change this at all
        var depthPixelBuffer: CVPixelBuffer? = nil
        var depthConfidencePixelBuffer: CVPixelBuffer? = nil
        if self.depthStatus.isDepthAvailable {
            guard let depthBuffer = currentFrame.sceneDepth?.depthMap else { return }
            depthPixelBuffer = depthBuffer
            guard let depthConfidenceBuffer = currentFrame.sceneDepth?.confidenceMap else { return }
            depthConfidencePixelBuffer = depthConfidenceBuffer
        }
        
        
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
            rgbSize: 0,
            depthSize: 0,
            confidenceMapSize: 0,
            miscSize: 0,
            deviceType: 1
        )
        
        DispatchQueue.global(qos: .userInitiated).async {
            CVPixelBufferLockBaseAddress(rgbPixelBuffer, .readOnly)
            CVPixelBufferLockBaseAddress(self.rgbOutputPixelBufferUSB!, [])

            // Try optimized path first
            let rgbImageData: Data?
            if self.canUseOptimizedTransform(for: rgbPixelBuffer) {
                rgbImageData = self.processRGBOptimized(rgbPixelBuffer)
            } else {
                // Fallback to Core Image pipeline
                let rgbCiImage = CIImage(cvPixelBuffer: rgbPixelBuffer)
                let rgbTransformedImage = rgbCiImage.transformed(by: self.combinedRGBTransform!)

                guard let rgbCgImage = self.ciContext.createCGImage(rgbTransformedImage, from: rgbTransformedImage.extent) else{
                    return
                }
                rgbImageData = UIImage(cgImage: rgbCgImage).jpegData(compressionQuality: 0.5)
            }

            record3dHeader.rgbSize = UInt32(rgbImageData!.count)
            
            CVPixelBufferUnlockBaseAddress(self.rgbOutputPixelBufferUSB!, [])
            CVPixelBufferUnlockBaseAddress(rgbPixelBuffer, .readOnly)
            
            var compressedDepthData: Data? = nil
            var compressedDepthConfData: Data? = nil
            
            if self.depthStatus.isDepthAvailable {
                compressedDepthData = self.processDepthStreamData(depthPixelBuffer: depthPixelBuffer!, outputBuffer: self.depthOutputPixelBufferUSB!, isDepth: true)
                compressedDepthConfData = self.processDepthStreamData(depthPixelBuffer: depthConfidencePixelBuffer!, outputBuffer: self.depthConfidenceOutputPixelBufferUSB!, isDepth: false)

                record3dHeader.depthSize = UInt32(compressedDepthData?.count ?? 0)
                record3dHeader.confidenceMapSize = UInt32(compressedDepthConfData?.count ?? 0)
            }

            // Always send exactly 7 floats (28 bytes) for joint actions
            let jointActionsArray: [Float]
            if let latestJointActions = self.mlManager?.latestResult?.jointPositions, !latestJointActions.isEmpty {
                // Use actual ML inference results, ensure exactly 7 values
                jointActionsArray = Array(latestJointActions.prefix(7)) + Array(repeating: 0.0, count: max(0, 7 - latestJointActions.count))
            } else {
                // Fallback to zeros if no ML results available
                jointActionsArray = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
            }
            
            // Convert to exactly 28 bytes (7 floats * 4 bytes each)
            let jointActionsData = Data(bytes: jointActionsArray, count: 28)

            self.usbManager.sendData(
                record3dHeaderData: Data(bytes: &record3dHeader, count: MemoryLayout<Record3DHeader>.size),
                intrinsicMatData: Data(bytes: &intrinsicCoeffs, count: MemoryLayout<IntrinsicMatrixCoeffs>.size),
                poseData: Data(bytes: &camera_pose, count: MemoryLayout<CameraPose>.size),
                rgbImageData: rgbImageData!,
                jointActionsData: jointActionsData,
                compressedDepthData: compressedDepthData,
                compressedConfData: compressedDepthConfData
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
    }
    
    func startRecording() -> RecordingFiles {
        let saveFileNames = setupRecording()
        
        // Start AR pose visualization with origin at current camera position
        arVisualizationManager.startRecordingVisualization()
        
        assetWriter?.startWriting()
        startTime = CMTimeMake(value: Int64(CACurrentMediaTime() * 1000), timescale: 1000)
        assetWriter?.startSession(atSourceTime: startTime!)
        
        DispatchQueue.global(qos: .background).async {
            if(self.ifAudioEnable) {
                self.audioSession.startRunning()
            }
        }
        if self.depthStatus.isDepthAvailable {
            depthAssetWriter?.startWriting()
            depthAssetWriter?.startSession(atSourceTime: startTime!)
        }
        
        displayLink = CADisplayLink(target: self, selector: #selector(updateFrame))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: Float(self.userFPS!), maximum: Float(self.userFPS!), preferred: Float(self.userFPS!))
        displayLink?.add(to: .main, forMode: .common)
        
        return saveFileNames!
        
    }
    
    
    func stopRecording(){
        displayLink?.invalidate()
        displayLink = nil
        
        // Stop AR pose visualization
        arVisualizationManager.stopRecordingVisualization()
        
        if(ifAudioEnable) {
            audioSession.stopRunning()
            audioInput?.markAsFinished()
        }
        videoInput?.markAsFinished()
        
        audioCaptureDelegate = nil
        
        assetWriter?.finishWriting {
            self.assetWriter = nil
        }
        
        depthVideoInput?.markAsFinished()
        depthAssetWriter?.finishWriting {
            self.depthAssetWriter = nil
        }

        do {
            try poseFileHandle?.close()
        } catch {
            // Error closing pose file - continue cleanup
        }
        
        updateDemoCounter()
    }
    
    func setupRecording() -> RecordingFiles? {
        // Determine all the destinated file saving URL or this recording by its start time
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd-HH_mm_ss"
        let timestamp = dateFormatter.string(from: Date())
        
        let fileNames = [
            "RGB": "RGB_\(timestamp).mp4",
            "Depth": "Depth_\(timestamp).mp4",
            "Pose": "AR_Pose_\(timestamp).txt",
            "Tactile": "Tactile_\(timestamp).bin",
            "RGBImages": "RGB_Images_\(timestamp)",
            "DepthImages": isColorMapOpened ? "Depth_Colored_Images_\(timestamp)" : "Depth_Images_\(timestamp)"
        ]
        
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        
        let generalDataDirectory = documentsURL.appendingPathComponent(timestamp)
        let rgbVideoURL = generalDataDirectory.appendingPathComponent(fileNames["RGB"]!)
        let depthVideoURL = generalDataDirectory.appendingPathComponent(fileNames["Depth"]!)
        let poseTextURL = generalDataDirectory.appendingPathComponent(fileNames["Pose"]!)
        let tactileFileURL = generalDataDirectory.appendingPathComponent(fileNames["Tactile"]!)
        let rgbImagesDirectory = generalDataDirectory.appendingPathComponent(fileNames["RGBImages"]!)
        let depthImagesDirectory = generalDataDirectory.appendingPathComponent(fileNames["DepthImages"]!)
        
        do {
            try FileManager.default.createDirectory(at: generalDataDirectory, withIntermediateDirectories: true)
            if self.depthStatus.isDepthAvailable {
                try FileManager.default.createDirectory(at: depthImagesDirectory, withIntermediateDirectories: true)
            }
            try createFile(fileURL: poseTextURL)
        } catch {
            // Error creating directories - continue with setup
        }
        
        self.rgbDirect = rgbImagesDirectory
        self.depthDirect = depthImagesDirectory
        self.poseURL = poseTextURL
        self.generalURL = generalDataDirectory
        
        do {
            // Determine which video file url the assetWriter will write into
            
            // RGB
            self.assetWriter = try AVAssetWriter(outputURL: rgbVideoURL, fileType: .mp4)
            
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
            
            self.videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            self.videoInput?.expectsMediaDataInRealTime = true
            self.assetWriter?.add(videoInput!)
            
            if(ifAudioEnable) {
                self.audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioOutputSettings)
                self.audioInput?.expectsMediaDataInRealTime = true
                self.assetWriter?.add(audioInput!)
                
                // Update the audio delegate with the new audioWriterInput
                self.audioCaptureDelegate = AudioCaptureDelegate(writerInput: audioInput!)

                // Attach the new delegate to the existing AVCaptureAudioDataOutput
                if let audioOutput = self.audioSession.outputs.first(where: { $0 is AVCaptureAudioDataOutput }) as? AVCaptureAudioDataOutput {
                    let audioQueue = DispatchQueue(label: "AudioProcessingQueue")
                    audioOutput.setSampleBufferDelegate(self.audioCaptureDelegate, queue: audioQueue)
                }
            }
            
            self.pixelBufferAdapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput!, sourcePixelBufferAttributes: rgbAttributes)
            
            if self.depthStatus.isDepthAvailable {
                setupDepthRecording(depthVideoURL: depthVideoURL)
            }
            
            self.poseFileHandle = try FileHandle(forWritingTo: poseTextURL)
            try poseFileHandle?.seekToEnd()
        } catch {
            // Failed to setup recording - continue with available configuration
        }

        return RecordingFiles(
            rgbFileName: rgbVideoURL,
            depthFileName: depthVideoURL,
            timestamp: timestamp,
            rgbImagesDirectory: rgbImagesDirectory,
            depthImagesDirectory: depthImagesDirectory,
            poseFile: poseTextURL,
            generalDataDirectory: timestamp,
            tactileFile: tactileFileURL
        )
    }
    
    private func setupDepthRecording(depthVideoURL: URL) {
        do {
            depthAssetWriter = try AVAssetWriter(outputURL: depthVideoURL, fileType: .mp4)
            let depthVideoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(depthViewPortSize.width),
                AVVideoHeightKey: Int(depthViewPortSize.height),
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
            ]
            depthVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: depthVideoSettings)
            depthVideoInput?.expectsMediaDataInRealTime = true
            depthAssetWriter?.add(depthVideoInput!)

            let recordingDepthAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_OneComponent8,
                kCVPixelBufferWidthKey as String: Int(self.depthViewPortSize.width),
                kCVPixelBufferHeightKey as String: Int(self.depthViewPortSize.height)
            ]
                
            depthPixelBufferAdapter = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: depthVideoInput!,
                sourcePixelBufferAttributes: recordingDepthAttributes
            )
        } catch {
            // Failed to setup depth recording - continue without depth
        }
    }
    
    private func processRGBCaptureData(rgbPixelBuffer: CVPixelBuffer, cropRect: CGRect, currentTime: CMTime) -> Bool {
        guard let videoInput = self.videoInput, videoInput.isReadyForMoreMediaData else { return false }
        guard let outputPixelBufferPool = self.pixelBufferAdapter?.pixelBufferPool else { return false }
        
        var outputPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, outputPixelBufferPool, &outputPixelBuffer)
        guard status == kCVReturnSuccess, let outputBuffer = outputPixelBuffer else { return false }
        
        CVPixelBufferLockBaseAddress(rgbPixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(outputBuffer, [])
        
        let ciImage = CIImage(cvPixelBuffer: rgbPixelBuffer)
        let transformedImage = ciImage.transformed(by: self.combinedRGBTransform!) //.cropped(to: cropRect)
        self.ciContext.render(transformedImage, to: outputBuffer, bounds: cropRect, colorSpace: CGColorSpaceCreateDeviceRGB())
        
        guard let pixelBufferAdapter = self.pixelBufferAdapter else {
            return false
        }
        
        if !pixelBufferAdapter.append(outputBuffer, withPresentationTime: currentTime) {
            return false
        }
        CVPixelBufferUnlockBaseAddress(outputBuffer, [])
        CVPixelBufferUnlockBaseAddress(rgbPixelBuffer, .readOnly)
        return true
    }
    
    private func processDepthCaptureData(depthPixelBuffer: CVPixelBuffer?, cropRect: CGRect, currentTime: CMTime) -> Bool {
        guard let depthVideoInput = self.depthVideoInput, depthVideoInput.isReadyForMoreMediaData else { return false }
        guard let depthPixelBuffer = depthPixelBuffer else { return false }
        guard let pixelBufferPool = self.depthPixelBufferAdapter?.pixelBufferPool else {
            return false
        }
        
        var outputPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &outputPixelBuffer)
        guard status == kCVReturnSuccess, let depthOutputBuffer = outputPixelBuffer else {
            return false
        }
            
        CVPixelBufferLockBaseAddress(depthPixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(depthOutputBuffer, [])
            
        self.saveBinaryDepthData(depthPixelBuffer: depthPixelBuffer)

        let ciImage = CIImage(cvPixelBuffer: depthPixelBuffer)
        let processedDepthImage = self.applyDepthFilters(ciImage: ciImage)
        
        self.ciContext.render(
            processedDepthImage,
            to: depthOutputBuffer,
            bounds: cropRect,
            colorSpace: self.isColorMapOpened ? CGColorSpaceCreateDeviceRGB() : CGColorSpaceCreateDeviceGray()
        )
        
        guard let depthPixelBufferAdapter = self.depthPixelBufferAdapter else {
            return false
        }
        
        if !depthPixelBufferAdapter.append(depthOutputBuffer, withPresentationTime: currentTime) {
            return false
        }
        CVPixelBufferUnlockBaseAddress(depthOutputBuffer, [])
        CVPixelBufferUnlockBaseAddress(depthPixelBuffer, .readOnly)
        return true
    }
    
    private func processPoseData(frame: ARFrame) {
        let cameraTransform = frame.camera.transform
        // Transform the orientation matrix to unit quaternion
        let quaternion = simd_quaternion(cameraTransform)
        
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        
        let poseValues: [Float] = [
            quaternion.vector.x, quaternion.vector.y, quaternion.vector.z, quaternion.vector.w,
            cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z
        ]
        let poseString = "\"<\(timestamp)>\" ," + poseValues.map { String($0) }.joined(separator: ",") + "\n"
        
        do {
            if let data = poseString.data(using: .utf8) {
                try self.poseFileHandle?.write(contentsOf: data)
            }
        } catch {
            // Error writing pose data - continue capture
        }
    }
    
    private func applyDepthFilters(ciImage: CIImage) -> CIImage {
        var filteredImage = ciImage
        
        let depthFilter = CIFilter(name: "CIColorControls")!
        depthFilter.setValue(ciImage, forKey: kCIInputImageKey)
        depthFilter.setValue(2.0, forKey: kCIInputSaturationKey) // Keep saturation
        depthFilter.setValue(0.0, forKey: kCIInputBrightnessKey) // Adjust brightness
        depthFilter.setValue(3.0, forKey: kCIInputContrastKey) // Increase contrast for clarity
        
        if let outputImage = depthFilter.outputImage {
            filteredImage = outputImage
        }
        
        if(self.isColorMapOpened){
            let falseColorFilter = CIFilter.falseColor()
            falseColorFilter.color0 = CIColor(red: 1, green: 1, blue: 0)
            falseColorFilter.color1 = CIColor(red: 0, green: 0, blue: 1)
            falseColorFilter.inputImage = filteredImage
            if let outputImage = falseColorFilter.outputImage {
                filteredImage = outputImage
            }
        }
        return filteredImage.transformed(by: self.combinedDepthTransform ?? CGAffineTransform.identity) //.cropped(to: cropRect)
    }

    // MARK: - Accelerate Optimizations
    private func canUseOptimizedTransform(for pixelBuffer: CVPixelBuffer) -> Bool {
        // Only use optimized path for simple transforms (scale + translate)
        // Skip if transform contains rotation or complex operations
        guard let transform = combinedRGBTransform else { return false }

        // Check if transform is approximately a simple scale/translate
        let hasRotation = abs(transform.b) > 0.001 || abs(transform.c) > 0.001
        return !hasRotation
    }

    private func processRGBOptimized(_ pixelBuffer: CVPixelBuffer) -> Data? {
        // For now, use a simple direct conversion approach
        // This bypasses the expensive CIImage -> CGImage -> UIImage pipeline

        guard let cgImage = createCGImageDirect(from: pixelBuffer) else {
            return nil
        }

        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.5)
    }

    private func createCGImageDirect(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)

        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }

        return context.makeImage()
    }

    private func canUseOptimizedDepthTransform(for pixelBuffer: CVPixelBuffer) -> Bool {
        guard let transform = combinedDepthTransform else { return false }
        // Check if transform is simple enough for vImage optimization
        let hasRotation = abs(transform.b) > 0.001 || abs(transform.c) > 0.001
        return !hasRotation
    }

    private func processDepthOptimized(_ inputBuffer: CVPixelBuffer, outputBuffer: CVPixelBuffer) {
        // Simple memcpy for identity or simple scaling transforms
        // This avoids Core Image overhead for depth data

        let inputWidth = CVPixelBufferGetWidth(inputBuffer)
        let inputHeight = CVPixelBufferGetHeight(inputBuffer)
        let outputWidth = CVPixelBufferGetWidth(outputBuffer)
        let outputHeight = CVPixelBufferGetHeight(outputBuffer)

        guard let inputData = CVPixelBufferGetBaseAddress(inputBuffer),
              let outputData = CVPixelBufferGetBaseAddress(outputBuffer) else {
            return
        }

        let inputBytesPerRow = CVPixelBufferGetBytesPerRow(inputBuffer)
        let outputBytesPerRow = CVPixelBufferGetBytesPerRow(outputBuffer)

        if inputWidth == outputWidth && inputHeight == outputHeight {
            // Direct copy for same-size buffers
            let totalBytes = min(inputHeight * inputBytesPerRow, outputHeight * outputBytesPerRow)
            memcpy(outputData, inputData, totalBytes)
        } else {
            // Use vImage for scaling if available
            var sourceBuffer = vImage_Buffer(
                data: inputData,
                height: vImagePixelCount(inputHeight),
                width: vImagePixelCount(inputWidth),
                rowBytes: inputBytesPerRow
            )

            var destBuffer = vImage_Buffer(
                data: outputData,
                height: vImagePixelCount(outputHeight),
                width: vImagePixelCount(outputWidth),
                rowBytes: outputBytesPerRow
            )

            // Use vImage scaling for better performance than Core Image
            let error = vImageScale_Planar16F(&sourceBuffer, &destBuffer, nil, vImage_Flags(kvImageNoFlags))
            if error != kvImageNoError {
                print("vImage scaling failed: \(error)")
            }
        }
    }
    
    private func saveBinaryDepthData(depthPixelBuffer: CVPixelBuffer) {
//      Save metric depth data as binary file
        let width = CVPixelBufferGetWidth(depthPixelBuffer)
        let height = CVPixelBufferGetHeight(depthPixelBuffer)
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthPixelBuffer) else {
            CVPixelBufferUnlockBaseAddress(depthPixelBuffer, .readOnly)
            return
        }
        
        let floatBuffer = baseAddress.assumingMemoryBound(to: Float32.self)
        let dataSize = width * height * MemoryLayout<Float32>.size
        let data = Data(bytes: floatBuffer, count: dataSize)
        
        // Save binary data to a file
        let fileURL = self.depthDirect.appendingPathComponent("\(Int64(Date().timeIntervalSince1970*1000)).bin")
        do {
            try data.write(to: fileURL)
        } catch {
            // Error saving binary file - continue capture
        }
    }
    
    func captureVideoFrame() {

        guard let currentFrame = session.currentFrame else {return}

        var imgSuccessFlag = true

        let currentTime = CMTimeMake(value: Int64(CACurrentMediaTime() * 1000), timescale: 1000)
    
        let rgbPixelBuffer = currentFrame.capturedImage
        var depthPixelBuffer: CVPixelBuffer?
        
        if self.depthStatus.isDepthAvailable {
            guard let depthBuffer = currentFrame.sceneDepth?.depthMap else { return }
            depthPixelBuffer = depthBuffer
        }
        
        // Perform ML inference on the RGB frame (provide ARFrame for odometry/goal updates)
        mlManager?.performInference(on: rgbPixelBuffer, arFrame: currentFrame, timestamp: CACurrentMediaTime())
        
        
        
        let cropRect = CGRect(
            x: 0, y: 0, width: self.viewPortSize.width, height: self.viewPortSize.height
        )
        let depthCropRect = CGRect(
            x: 0, y: 0, width: self.depthViewPortSize.width, height: self.depthViewPortSize.height
        )

        DispatchQueue.global(qos: .userInitiated).async {
            let rgbSuccess = self.processRGBCaptureData(rgbPixelBuffer: rgbPixelBuffer, cropRect: cropRect, currentTime: currentTime)
            imgSuccessFlag = imgSuccessFlag && rgbSuccess
            if self.depthStatus.isDepthAvailable && imgSuccessFlag {
                let depthSuccess = self.processDepthCaptureData(depthPixelBuffer: depthPixelBuffer, cropRect: depthCropRect, currentTime: currentTime)
                imgSuccessFlag = imgSuccessFlag && depthSuccess
            }
            if imgSuccessFlag {
                self.processPoseData(frame: currentFrame)
            }
        }
    }
    
    func getDocumentsDirect() -> URL{
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0]
    }
    
    func updateDemoCounter() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        do{
            let contents = try FileManager.default.contentsOfDirectory(at: documentsURL[0], includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
            demosCounter = contents.count
        } catch {
            demosCounter = 0
        }
    }
    
    // MARK: - Model Manager Integration
    func initializeMLManager(with modelManager: ModelManager) {
        self.mlManager = MLInferenceManager(modelManager: modelManager)
        
        // Connect AR visualization to ML inference
        self.mlManager?.arVisualizationManager = self.arVisualizationManager
        // Provide AR session access to ML manager for goal and odometry
        self.mlManager?.setARViewContainer(self)
        
        // Forward mlManager's property changes to arViewModel so SwiftUI updates
        self.mlManager?.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        
        // ML results are now accessed directly during streaming for better real-time performance
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
            return
        }
        writerInput?.append(sampleBuffer)
    }
}
