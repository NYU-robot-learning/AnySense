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

struct RecordingFiles {
    let rgbFileName: URL
    let depthFileName: URL
    let timestamp: String
    let rgbImagesDirectory: URL?
    let depthImagesDirectory: URL?
    let poseFile: URL
    let generalDataDirectory: String
    let tactileFile: URL
}

enum RecordingMode {
    case none
    case standardRecording
    case mlInference
    case usbStreaming
}

func createFile(fileURL: URL) throws {
        let success = FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
        if !success {
            throw NSError(domain: "FileCreationError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create file at \(fileURL.path)"])
        }
}

// MARK: - Shared AR View Container (hosts the single ARView from ARViewModel)
struct SharedARViewContainer: UIViewRepresentable {
    @ObservedObject var arViewModel: ARViewModel
    
    func makeUIView(context: Context) -> ARView {
        print("SharedARViewContainer: returning shared ARView")
        return arViewModel.getOrCreateSharedARView()
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {
        // ARView is managed by ARViewModel, no updates needed here
    }
}

// MARK: - Tap Coordinator for Shared ARView
class TapCoordinator: NSObject {
    weak var arViewModel: ARViewModel?
    
    init(arViewModel: ARViewModel) {
        self.arViewModel = arViewModel
        super.init()
    }
    
    @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let arView = recognizer.view as? ARView else { return }
        let location = recognizer.location(in: arView)

        // Try LiDAR-backed mesh raycast first
        if let world = meshBackedHit(in: arView, from: location) {
            var t = matrix_identity_float4x4
            t.columns.3 = SIMD4<Float>(world.x, world.y, world.z, 1)
            let goalAnchor = ARAnchor(name: "goal", transform: t)
            arView.session.add(anchor: goalAnchor)
            print("Using LiDAR mesh raycast for 3D point: \(world)")
            NotificationCenter.default.post(
                name: NSNotification.Name("ARViewTapForGoal"),
                object: nil,
                userInfo: ["worldPoint": world, "method": "meshRaycast", "location": location, "bounds": arView.bounds]
            )
            return
        }

        // Fallback: ARKit plane/estimated-surface raycast
        if let hit = arView.raycast(from: location, allowing: .estimatedPlane, alignment: .any).first {
            let t = hit.worldTransform
            let world = simd_float3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            let goalAnchor = ARAnchor(name: "goal", transform: t)
            arView.session.add(anchor: goalAnchor)
            print("Using plane/estimated raycast fallback for 3D point: \(world)")
            NotificationCenter.default.post(
                name: NSNotification.Name("ARViewTapForGoal"),
                object: nil,
                userInfo: ["worldPoint": world, "method": "raycast", "location": location, "bounds": arView.bounds]
            )
            return
        }

        // Final fallback: notify with screen info only
        NotificationCenter.default.post(
            name: NSNotification.Name("ARViewTapForGoal"),
            object: nil,
            userInfo: ["location": location, "bounds": arView.bounds]
        )
    }
    
    private func meshBackedHit(in arView: ARView, from location: CGPoint) -> SIMD3<Float>? {
        guard let ray = arView.ray(through: location) else { return nil }
        let hits = arView.scene.raycast(origin: ray.origin, direction: ray.direction)
        if let hit = hits.first(where: { $0.entity is HasSceneUnderstanding }) {
            return hit.position
        }
        return nil
    }
}

class DepthStatus: ObservableObject {
    @Published var isDepthAvailable: Bool = true
    @Published var showAlert: Bool = false
    
    public func setUnavailable() {
        isDepthAvailable = false
        showAlert = true
    }

    public func dismissAlert() {
        showAlert = false
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
    @Published var arVisualizationManager: ARVisualizationManager
    @Published var goalTapModeEnabled: Bool = false
    @Published var isUSBStreamingActive: Bool = false
    
    // MARK: - Shared ARView (single instance for entire app lifecycle)
    private var sharedARView: ARView?
    private var hasSetupSharedARView = false

    // MARK: - Centralized Recording State Management
    @Published var isRecording: Bool = false
    @Published var recordingMode: RecordingMode = .none
    private var currentRecordingFiles: RecordingFiles?
    
    // MARK: - Inference Playback (no file saving)
    @Published var isInferencePlaying: Bool = false
    @Published var isInferenceEpisodeFinished: Bool = false



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
    private var rgbDirect: URL? = nil
    private var depthDirect: URL? = nil
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
    
    @MainActor
    init() {
        self.arVisualizationManager = ARVisualizationManager()
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
        }
    }
    
    func getBLEManagerInstance() -> BluetoothManager{
        return bluetoothManager!;
    }
    
    // MARK: - Shared ARView Management
    @MainActor
    func getOrCreateSharedARView() -> ARView {
        if let existingView = sharedARView {
            return existingView
        }
        
        print("Creating shared ARView (one-time setup)")
        
        // Create the single ARView instance
        let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        arView.session = session
        
        // Consistent rendering options
        arView.renderOptions = [.disablePersonOcclusion, .disableDepthOfField, .disableMotionBlur]
        
        // Enable scene understanding for raycasts
        arView.environment.sceneUnderstanding.options = [.collision]
        
        // Setup AR visualization
        arVisualizationManager.setupVisualization(with: arView)
        
        // Add tap recognizer for goal setting
        let coordinator = TapCoordinator(arViewModel: self)
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(TapCoordinator.handleTap(_:)))
        arView.addGestureRecognizer(tap)
        // Store coordinator to prevent deallocation
        objc_setAssociatedObject(arView, "tapCoordinator", coordinator, .OBJC_ASSOCIATION_RETAIN)
        
        sharedARView = arView
        hasSetupSharedARView = true
        
        print("Shared ARView created and configured")
        return arView
    }
    
    // Resume AR session 
    @MainActor
    func resumeARSession() {
        guard !isOpen else {
            print("AR session already running")
            return
        }
        
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        guard status == .authorized else { return }
        
        let configuration = createARConfiguration()
        session.run(configuration, options: [])
        isOpen = true
        
        print("AR session resumed (tracking preserved)")
    }
    
    // MARK: - Shared AR Configuration
    private func createARConfiguration() -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        
        for videoFormat in ARWorldTrackingConfiguration.supportedVideoFormats {
            if videoFormat.captureDeviceType == .builtInWideAngleCamera {
                configuration.videoFormat = videoFormat
                break
            }
        }
        
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        configuration.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        configuration.environmentTexturing = .none
        configuration.isAutoFocusEnabled = false
        
        return configuration
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
            var attempts = 0
            let maxAttempts = 50 // Max 500ms wait

            while attempts < maxAttempts {
                guard let currentFrame = self.session.currentFrame else {
                    attempts += 1
                    usleep(10000) // 10ms
                    continue
                }

                let flipTransform = self.computeFlipTransform()

                // Initialize RGB transform if needed
                if self.combinedRGBTransform == nil {
                    self.initializeRGBTransform(frame: currentFrame, flipTransform: flipTransform)
                    print("RGB transform initialized successfully")
                }

                // Try depth transform
                if self.combinedDepthTransform == nil {
                    if self.initializeDepthTransform(frame: currentFrame, flipTransform: flipTransform) {
                        print("Depth transform initialized successfully")
                    }
                }

                // Exit once we have RGB transform (depth is optional)
                if self.combinedRGBTransform != nil {
                    break
                }

                attempts += 1
                usleep(10000)
            }

            if self.combinedRGBTransform == nil {
                print("Note: RGB transform not yet initialized, will compute on-demand")
            }
            if self.combinedDepthTransform == nil {
                print("Note: Depth transform not yet initialized, will compute on-demand")
            }
        }
    }
    
    func ensureTransformsReady() {
        guard let currentFrame = session.currentFrame else { return }
        
        let flipTransform = computeFlipTransform()
        
        if combinedRGBTransform == nil {
            initializeRGBTransform(frame: currentFrame, flipTransform: flipTransform)
            print("RGB transform computed on-demand")
        }
        
        if combinedDepthTransform == nil {
            if initializeDepthTransform(frame: currentFrame, flipTransform: flipTransform) {
                print("Depth transform computed on-demand")
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
    
    @MainActor
    func setupARSession() {
        // Sync orientation with the current interface orientation before configuring transforms
        refreshOrientationFromScene()
        self.startARSession()
        
        if(ifAudioEnable) {
            setupAudioSession()
        }
        
        setupTransforms()
    }

    @MainActor
    func startARSession() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        guard status == .authorized else { return }
        
        let configuration = createARConfiguration()
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isOpen = true
    }

    private func refreshOrientationFromScene() {
        // Keep a consistent transform between tabs; force portrait so Record and Inference align
        orientation = .portrait
    }
    
    @MainActor
    func pauseARSession(){
        session.pause()
        isOpen = false
        clearCachedTransforms()
    }
    
    @MainActor
    func killARSession() {
        session.pause() // Pause before releasing resources
        session = ARSession() // Replace with a new ARSession
        isOpen = false
        clearCachedTransforms()
    }
    
    /// Clear cached transforms so they are recalculated on next session start
    private func clearCachedTransforms() {
        combinedRGBTransform = nil
        combinedDepthTransform = nil
    }
    
    /// Safely extract depth and confidence buffers from an AR frame
    private func getDepthBuffers(from frame: ARFrame) -> (depth: CVPixelBuffer, confidence: CVPixelBuffer)? {
        guard let depthBuffer = frame.sceneDepth?.depthMap,
              let confidenceBuffer = frame.sceneDepth?.confidenceMap else {
            return nil
        }
        return (depthBuffer, confidenceBuffer)
    }
    
    /// Compute flip transform based on current orientation
    private func computeFlipTransform() -> CGAffineTransform {
        orientation.isPortrait
            ? CGAffineTransform(scaleX: -1, y: -1).translatedBy(x: -1, y: -1)
            : .identity
    }

    // MARK: - Safe Session Management
    @MainActor
    func startARSessionIfNeeded() {
        guard !isOpen else {
            print("AR session already running")
            return
        }

        print("Starting AR session for ARViewContainer")
        setupARSession()
    }

    // MARK: - Inference Playback (no file saving)
    @MainActor
    func startInferencePlayback() {
        // MARK: - State Validation Guards
        guard !isInferencePlaying else {
            print("Inference playback already active - ignoring start request")
            return
        }
        
        guard !isUSBStreamingActive else {
            print("Cannot start inference playback while USB streaming is active")
            return
        }
        
        guard !isRecording else {
            print("Cannot start inference playback while recording is active")
            return
        }
        
        guard recordingMode == .none else {
            print("Another recording mode active: \(recordingMode) - stopping first")
            stopAllActivities()
            // stopAllActivities resets state; if it couldn't, bail safely
            guard recordingMode == .none else { return }
            return startInferencePlayback()
        }
        
        // Ensure AR session is running
        startARSessionIfNeeded()
        
        // MARK: - Update Centralized State
        recordingMode = .mlInference
        isInferencePlaying = true
        isInferenceEpisodeFinished = false
        
        // Reset ML inference state for a new playback session (keep goal)
        mlManager?.resetInferenceState()
        mlManager?.latestResult = nil
        mlManager?.lastResult = nil
        
        // Reset visualization state (fresh origin/targets for new episode)
        arVisualizationManager.stopRecordingVisualization()
        arVisualizationManager.enableVisualization()
        arVisualizationManager.ensureVisualizationReady()
        
        let fps = userFPS ?? 30.0
        displayLink = CADisplayLink(target: self, selector: #selector(runInferencePlaybackTick))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(
            minimum: Float(fps),
            maximum: Float(fps),
            preferred: Float(fps)
        )
        displayLink?.add(to: .main, forMode: .common)
        
        print("Inference playback started")
    }
    
    @MainActor
    func stopInferencePlayback(reset: Bool = true) {
        guard isInferencePlaying || recordingMode == .mlInference else {
            return
        }
        
        displayLink?.invalidate()
        displayLink = nil
        
        isInferencePlaying = false
        isInferenceEpisodeFinished = false
        
        if recordingMode == .mlInference {
            recordingMode = .none
        }
        
        if reset {
            mlManager?.resetInferenceState()
            mlManager?.latestResult = nil
            mlManager?.lastResult = nil
            arVisualizationManager.stopRecordingVisualization()
            arVisualizationManager.enableVisualization()
            arVisualizationManager.ensureVisualizationReady()
            // Ensure episode-finished state clears even if last result was CLOSED
            arVisualizationManager.setGripperState(isClosed: false)
        }
        
        print("Inference playback stopped")
    }
    
    @MainActor
    @objc private func runInferencePlaybackTick(link: CADisplayLink) {
        // Avoid doing any work if playback has ended or mode changed
        guard isInferencePlaying, recordingMode == .mlInference else { return }
        
        // Episode finished -> stop processing frames (but keep "Stop" available for reset)
        if arVisualizationManager.isGripperClosed {
            if !isInferenceEpisodeFinished {
                isInferenceEpisodeFinished = true
                print("Episode finished (gripper closed) - waiting for reset")
            }
            return
        }
        
        guard let currentFrame = session.currentFrame else { return }
        let rgbPixelBuffer = currentFrame.capturedImage
        
        if let mlManager = mlManager {
            Task { @MainActor in
                mlManager.performInference(on: rgbPixelBuffer, arFrame: currentFrame, timestamp: CACurrentMediaTime())
            }
        }
    }
    
    @MainActor
    func startUSBStreaming() {
        // MARK: - State Validation Guards
        guard !isUSBStreamingActive else {
            print("USB Streaming already active - ignoring start request")
            return
        }

        guard recordingMode == .none else {
            print("Another recording mode active: \(recordingMode) - stopping first")
            stopAllActivities()
            return
        }
        
        // Ensure transforms are computed before streaming
        ensureTransformsReady()

        // MARK: - Update Centralized State
        recordingMode = .usbStreaming

        // Reset ML inference state for new streaming session
        mlManager?.resetInferenceState()

        displayLink = CADisplayLink(target: self, selector: #selector(sendFrameUSB))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: Float(self.userFPS!), maximum: Float(self.userFPS!), preferred: Float(self.userFPS!))
        displayLink?.add(to: .main, forMode: .common)
        isUSBStreamingActive = true
        mlManager?.setUSBStreamingState(isActive: true)

        print("USB streaming started successfully")
    }
    
    @MainActor
    func stopUSBStreaming() {
        // MARK: - State Validation Guard
        guard isUSBStreamingActive else {
            print("Stop USB streaming called but not currently streaming")
            return
        }

        displayLink?.invalidate()
        displayLink = nil
        isUSBStreamingActive = false
        mlManager?.setUSBStreamingState(isActive: false)

        // Reset ML inference state when stopping
        mlManager?.resetInferenceState()

        // MARK: - Update Centralized State
        if recordingMode == .usbStreaming {
            recordingMode = .none
        }

        print("USB streaming stopped successfully")
    }
    
    @MainActor
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

        // Try to set up depth buffers - optional, won't block if it fails
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

        if depthStatus == kCVReturnSuccess {
            self.depthOutputPixelBufferUSB = depthBuffer

            let depthConfidenceStatus = CVPixelBufferCreate(
                kCFAllocatorDefault,
                Int(depthViewPortSize.width),
                Int(depthViewPortSize.height),
                kCVPixelFormatType_OneComponent8,
                depthConfAttributes as CFDictionary,
                &depthConfidenceBuffer
            )
            if depthConfidenceStatus == kCVReturnSuccess {
                self.depthConfidenceOutputPixelBufferUSB = depthConfidenceBuffer
            }
        }
        
        usbManager.connect()
    }
    
    @MainActor
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
    
    
    @MainActor
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
    
    @MainActor
    func streamVideoFrameUSB() {
        guard let currentFrame = session.currentFrame else {return}
        
        let rgbPixelBuffer = currentFrame.capturedImage

        // Perform ML inference on the RGB frame during streaming (provide ARFrame for odometry/goal updates)
        if let mlManager = mlManager {
            Task { @MainActor in
                mlManager.performInference(on: rgbPixelBuffer, arFrame: currentFrame, timestamp: CACurrentMediaTime())
            }
        }
        
        // Try to get depth data if available, but continue regardless
        let depthBuffers = getDepthBuffers(from: currentFrame)
        let depthPixelBuffer = depthBuffers?.depth
        let depthConfidencePixelBuffer = depthBuffers?.confidence
        
        
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
        
        let rgbOutputBufferUSB = self.rgbOutputPixelBufferUSB
        let depthOutputBufferUSB = self.depthOutputPixelBufferUSB
        let depthConfOutputBufferUSB = self.depthConfidenceOutputPixelBufferUSB
        let latestJointActions = self.mlManager?.latestResult?.jointPositions
        let usbManager = self.usbManager
        
        DispatchQueue.global(qos: .userInitiated).async {
            guard let rgbOutputBufferUSB else { return }
            CVPixelBufferLockBaseAddress(rgbPixelBuffer, .readOnly)
            CVPixelBufferLockBaseAddress(rgbOutputBufferUSB, [])

            let rgbImageData: Data?
            if self.canUseOptimizedTransform(for: rgbPixelBuffer) {
                rgbImageData = self.processRGBOptimized(rgbPixelBuffer)
            } else {
                // Fallback to Core Image pipeline
                let rgbCiImage = CIImage(cvPixelBuffer: rgbPixelBuffer)
                let rgbTransformedImage = rgbCiImage.transformed(by: self.combinedRGBTransform ?? CGAffineTransform.identity)

                guard let rgbCgImage = self.ciContext.createCGImage(rgbTransformedImage, from: rgbTransformedImage.extent) else{
                    return
                }
                rgbImageData = UIImage(cgImage: rgbCgImage).jpegData(compressionQuality: 0.5)
            }

            record3dHeader.rgbSize = UInt32(rgbImageData!.count)
            
            CVPixelBufferUnlockBaseAddress(rgbOutputBufferUSB, [])
            CVPixelBufferUnlockBaseAddress(rgbPixelBuffer, .readOnly)
            
            var compressedDepthData: Data? = nil
            var compressedDepthConfData: Data? = nil
            
            // Process depth data if available
            if let depthBuffer = depthPixelBuffer,
               let depthConfBuffer = depthConfidencePixelBuffer,
               let depthOutputBuffer = depthOutputBufferUSB,
               let depthConfOutputBuffer = depthConfOutputBufferUSB {
                compressedDepthData = self.processDepthStreamData(depthPixelBuffer: depthBuffer, outputBuffer: depthOutputBuffer, isDepth: true)
                compressedDepthConfData = self.processDepthStreamData(depthPixelBuffer: depthConfBuffer, outputBuffer: depthConfOutputBuffer, isDepth: false)

                record3dHeader.depthSize = UInt32(compressedDepthData?.count ?? 0)
                record3dHeader.confidenceMapSize = UInt32(compressedDepthConfData?.count ?? 0)
            }

            // Always send exactly 7 floats (28 bytes) for joint actions
            let jointActionsArray: [Float]
            if let latestJointActions, !latestJointActions.isEmpty {
                // Use actual ML inference results, ensure exactly 7 values
                jointActionsArray = Array(latestJointActions.prefix(7)) + Array(repeating: 0.0, count: max(0, 7 - latestJointActions.count))
            } else {
                // Fallback to zeros if no ML results available
                jointActionsArray = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
            }
            
            // Convert to exactly 28 bytes (7 floats * 4 bytes each)
            let jointActionsData = Data(bytes: jointActionsArray, count: 28)

            usbManager.sendData(
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
    
    @MainActor
    @objc private func updateFrame(link: CADisplayLink) {
        guard lastTimestamp > 0 else {
            // Initialize timestamp on the first call
            lastTimestamp = link.timestamp
            return
        }
        captureVideoFrame()
    }
    
    @MainActor
    func startRecording() -> RecordingFiles? {
        // MARK: - State Validation Guards
        guard !isRecording else {
            print("Recording already active - ignoring start request")
            return currentRecordingFiles
        }

        guard recordingMode == .none else {
            print("Another recording mode active: \(recordingMode) - stopping first")
            stopAllActivities()
            return nil
        }
        
        // Ensure transforms are computed before recording
        ensureTransformsReady()

        guard let saveFileNames = setupRecording() else {
            print("Failed to setup recording")
            return nil
        }

        // MARK: - Update Centralized State
        isRecording = true
        recordingMode = .standardRecording
        currentRecordingFiles = saveFileNames

        // Reset ML inference state for new recording
        mlManager?.resetInferenceState()

        assetWriter?.startWriting()
        startTime = CMTimeMake(value: Int64(CACurrentMediaTime() * 1000), timescale: 1000)
        assetWriter?.startSession(atSourceTime: startTime!)

        let audioEnabled = ifAudioEnable
        let audioSession = self.audioSession
        DispatchQueue.global(qos: .background).async {
            if audioEnabled {
                audioSession.startRunning()
            }
        }
        // Start depth recording if depth writer is available
        if let depthWriter = depthAssetWriter {
            depthWriter.startWriting()
            depthWriter.startSession(atSourceTime: startTime!)
        }

        displayLink = CADisplayLink(target: self, selector: #selector(updateFrame))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: Float(self.userFPS!), maximum: Float(self.userFPS!), preferred: Float(self.userFPS!))
        displayLink?.add(to: .main, forMode: .common)

        print("Recording started successfully")
        return saveFileNames
        
    }
    
    
    @MainActor
    func stopRecording(){
        // MARK: - State Validation Guard
        guard isRecording else {
            print("Stop recording called but not currently recording")
            return
        }

        displayLink?.invalidate()
        displayLink = nil

        // Stop AR pose visualization
        arVisualizationManager.stopRecordingVisualization()

        // Reset ML inference state when stopping
        mlManager?.resetInferenceState()

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

        // MARK: - Update Centralized State
        isRecording = false
        recordingMode = .none
        currentRecordingFiles = nil

        updateDemoCounter()
        print("Recording stopped successfully")
    }

    // MARK: - Comprehensive Cleanup Method
    @MainActor
    func stopAllActivities() {
        // If nothing is active, avoid redundant cleanup work
        if !isRecording && !isUSBStreamingActive && !isInferencePlaying && recordingMode == .none && displayLink == nil {
            print("No active activities to stop")
            return
        }

        print("Stopping all activities...")
        
        // Stop inference playback if active
        if isInferencePlaying || recordingMode == .mlInference {
            stopInferencePlayback(reset: true)
        }

        // Stop recording if active
        if isRecording {
            stopRecording()
        }

        // Stop USB streaming if active
        if isUSBStreamingActive {
            stopUSBStreaming()
        }

        // Reset ML inference state
        mlManager?.resetInferenceState()

        // Stop AR visualization
        arVisualizationManager.stopRecordingVisualization()

        // Invalidate any remaining display links
        displayLink?.invalidate()
        displayLink = nil

        // Reset state
        recordingMode = .none
        currentRecordingFiles = nil
        isInferencePlaying = false
        isInferenceEpisodeFinished = false

        print("All activities stopped")
    }
    
    @MainActor
    func setupRecording() -> RecordingFiles? {
        // Determine all the destinated file saving URL or this recording by its start time
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd-HH_mm_ss"
        let timestamp = dateFormatter.string(from: Date())
        
        var fileNames = [
            "RGB": "RGB_\(timestamp).mp4",
            "Depth": "Depth_\(timestamp).mp4",
            "Pose": "AR_Pose_\(timestamp).txt",
            "Tactile": "Tactile_\(timestamp).bin"
        ]

        // Only include image directories if debug frame saving is enabled
        if mlManager?.saveDebugFrames == true {
            fileNames["RGBImages"] = "RGB_Images_\(timestamp)"
            fileNames["DepthImages"] = isColorMapOpened ? "Depth_Colored_Images_\(timestamp)" : "Depth_Images_\(timestamp)"
        }
        
        let generalDataDirectory = getDocumentsDirect().appendingPathComponent(timestamp)

        guard let rgbFileName = fileNames["RGB"],
              let depthFileName = fileNames["Depth"],
              let poseFileName = fileNames["Pose"],
              let tactileFileName = fileNames["Tactile"] else {
            return nil
        }

        let rgbVideoURL = generalDataDirectory.appendingPathComponent(rgbFileName)
        let depthVideoURL = generalDataDirectory.appendingPathComponent(depthFileName)
        let poseTextURL = generalDataDirectory.appendingPathComponent(poseFileName)
        let tactileFileURL = generalDataDirectory.appendingPathComponent(tactileFileName)

        // Only create image directories if debug frame saving is enabled
        var rgbImagesDirectory: URL?
        var depthImagesDirectory: URL?
        if mlManager?.saveDebugFrames == true,
           let rgbDirName = fileNames["RGBImages"],
           let depthDirName = fileNames["DepthImages"] {
            rgbImagesDirectory = generalDataDirectory.appendingPathComponent(rgbDirName)
            depthImagesDirectory = generalDataDirectory.appendingPathComponent(depthDirName)
        }

        do {
            try FileManager.default.createDirectory(at: generalDataDirectory, withIntermediateDirectories: true)
            if mlManager?.saveDebugFrames == true,
               let depthDir = depthImagesDirectory {
                try FileManager.default.createDirectory(at: depthDir, withIntermediateDirectories: true)
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
            
            // Setup depth recording if supported
            setupDepthRecording(depthVideoURL: depthVideoURL)
            
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
        let transformedImage = ciImage.transformed(by: self.combinedRGBTransform ?? CGAffineTransform.identity) //.cropped(to: cropRect)
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
        
        // Save binary data to a file (only if debug frame saving is enabled)
        if let depthDir = self.depthDirect {
            let fileURL = depthDir.appendingPathComponent("\(Int64(Date().timeIntervalSince1970*1000)).bin")
            do {
                try data.write(to: fileURL)
            } catch {
                // Error saving binary file - continue capture
            }
        }
    }
    
    @MainActor
    func captureVideoFrame() {

        guard let currentFrame = session.currentFrame else {return}

        var imgSuccessFlag = true

        let currentTime = CMTimeMake(value: Int64(CACurrentMediaTime() * 1000), timescale: 1000)
    
        let rgbPixelBuffer = currentFrame.capturedImage
        let depthPixelBuffer = currentFrame.sceneDepth?.depthMap
        
        // Perform ML inference on the RGB frame (provide ARFrame for odometry/goal updates)
        if let mlManager = mlManager {
            Task { @MainActor in
                mlManager.performInference(on: rgbPixelBuffer, arFrame: currentFrame, timestamp: CACurrentMediaTime())
            }
        }
        
        
        
        let cropRect = CGRect(
            x: 0, y: 0, width: self.viewPortSize.width, height: self.viewPortSize.height
        )
        let depthCropRect = CGRect(
            x: 0, y: 0, width: self.depthViewPortSize.width, height: self.depthViewPortSize.height
        )

        DispatchQueue.global(qos: .userInitiated).async {
            let rgbSuccess = self.processRGBCaptureData(rgbPixelBuffer: rgbPixelBuffer, cropRect: cropRect, currentTime: currentTime)
            imgSuccessFlag = imgSuccessFlag && rgbSuccess
            if let depthBuffer = depthPixelBuffer, imgSuccessFlag {
                let depthSuccess = self.processDepthCaptureData(depthPixelBuffer: depthBuffer, cropRect: depthCropRect, currentTime: currentTime)
                imgSuccessFlag = imgSuccessFlag && depthSuccess
            }
            if imgSuccessFlag {
                self.processPoseData(frame: currentFrame)
            }
        }
    }
    
    func getDocumentsDirect() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    func updateDemoCounter() {
        let documentsURL = getDocumentsDirect()
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
            let directories = contents.filter { url in
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                return isDirectory.boolValue
            }
            demosCounter = directories.count
        } catch {
            demosCounter = 0
        }
    }
    
    // MARK: - Model Manager Integration
    @MainActor
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
        
     
    }


    // MARK: - Bluetooth Recording Helpers (Consolidated)
    func startBluetoothRecording(targetURL: URL, fps: Double) {
        do {
            try createFile(fileURL: targetURL)
        } catch {
            print("Error creating tactile file.")
        }

        bluetoothManager?.startRecording(targetURL: targetURL, fps: fps)
    }

    func stopBluetoothRecording() {
        bluetoothManager?.stopRecording()
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
