//
//  MLInferenceManager.swift
//  AnySense
//
//  Created by Krish on 2025/2/1.
//

import Foundation
import ImageIO
import CoreML
import Vision
import CoreVideo
import QuartzCore
import Combine
import RealityKit
import CoreImage
import ARKit
import simd
import UIKit
import Accelerate

// MARK: - ML Inference Results
struct InferenceResult {
    let jointPositions: [Float]  // 7 joint action values
    let inferenceTime: TimeInterval
}

// MARK: - ML Inference Manager
@MainActor
class MLInferenceManager: ObservableObject {
    
    // MARK: - Published Properties
    @Published var latestResult: InferenceResult?
    @Published var lastResult: InferenceResult?
    @Published var isInferencePendingUI: Bool = false

    @MainActor
    func clearPendingState() {
        isInferencePending = false
        isInferencePendingUI = false
    }
    @Published var isInferenceEnabled: Bool = false
    @Published var inferenceFrequency: InferenceFrequency = .medium
    @Published var currentGoalPoint: simd_float3?
    @Published var modelMetadata: ModelMetadata?
    @Published var isModelLoading: Bool = false // Tracks loading and warm-up
    
    // MARK: - Private Properties
    private var model: MLModel?
    private var lastInferenceTime: CFTimeInterval = 0
    private var inferenceQueue = DispatchQueue(label: "MLInferenceQueue", qos: .userInitiated)
    
    // MARK: - Goal Point Management
    
    // MARK: - Goal Point Management
    
    func setGoalPoint(_ point: simd_float3) {
        self.currentGoalPoint = point
        arVisualizationManager?.setTargetPose(point)
        // Reset goal frame count when new goal is set
        goalFrameCount = 0
    }
    
    // Goal conditioning mode (point-conditioned models use 3D goals)
    private var goalDimension: Int = 3
    
    // Track how many times goal has been used (for first-frame offset)
    private var goalFrameCount: Int = 0
    
    // MARK: - Frame Buffering for Temporal Models
    private struct FrameBufferEntry {
        let mlArray: MLMultiArray  // Pre-processed [1,3,H,W] frame
        let goalPoint: [Float]?     // Goal at time of capture
    }
    private var frameBuffer: [FrameBufferEntry] = []
    private var maxBufferSize: Int = 3  // Always maintain 3 action trigger frames

    // Current frame processing (still processes every frame for potential storage)
    private var currentFrameEntry: FrameBufferEntry?
    
    // MARK: - Proximity-based Inference Control
    private var proximityReached: Bool = false
    private var isInferencePending: Bool = false
    private var hasRunFirstInference: Bool = false  // Track if we've run initial inference
    
    // MARK: - Model Management
    private var modelManager: ModelManager
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - AR Visualization Integration
    weak var arVisualizationManager: ARVisualizationManager?
    
    // MARK: - Frame Processing (Taken from ARViewContainer)
    private let ciContext: CIContext
    private var modelInputSize = CGSize(width: 224, height: 224)
    
    // MARK: - Shared Buffers (Reused to avoid allocations)
    private var sharedOutputPixelBuffer: CVPixelBuffer?  // Reused CVPixelBuffer for frame processing
    private var sharedMLMultiArrayBuffer: MLMultiArray?  // Pre-allocated MLMultiArray for frame conversion
    private var cachedGripperOverlays: [String: CIImage] = [:]  // Cached transformed gripper overlays

    // MARK: - Gripper Overlay Properties
    private var gripperOpenCIImage: CIImage?
    private var gripperClosedCIImage: CIImage?
    private var gripperOpenUIImage: UIImage?
    private var gripperClosedUIImage: UIImage?
    private var gripperOverlayBuffer: vImage_Buffer?
    private var isUSBStreamingActive: Bool = false
    private var currentGripperValue: Float = 1.0  // Track latest gripper value
    @Published var enableGripperOverlay: Bool = true  // Default enabled (for model input)
    @Published var showGripperOverlayOnScreen: Bool = true  // Show overlay on AR view
    @Published var currentGripperOverlayImage: UIImage?  // Current overlay image for display
    @Published var saveDebugFrames: Bool = false     // For testing
    
    // MARK: - Inference Settings
    enum InferenceFrequency: CaseIterable {
        case high, medium, low, minute
        
        var interval: TimeInterval {
            switch self {
            case .high: return 0.0
            case .medium: return 1.0 
            case .low: return 10.0
            case .minute: return 60.0
            }
        }
        
        var displayName: String {
            switch self {
            case .high: return "High (30 FPS)"
            case .medium: return "Medium (1 Hz)"
            case .low: return "Low (0.1 FPS)"
            case .minute: return "Minute (1/min)"
            }
        }
    }
    
    // MARK: - Transform/Debug Settings
    var rotationUnit: ActionTransformUtils.RotationUnit = .eulerXYZ
    var enableTransformDebug: Bool = true
    var debugLoggingEnabled: Bool = true  // Enable detailed logging
    // Apply server-style image orientation (Record3D publisher does rotations/mirrors)
    var applyServerImageOrientation: Bool = false
    
    // Initialization
    init(modelManager: ModelManager) {
        self.modelManager = modelManager
        self.ciContext = CIContext()
        initializeSharedBuffers()  // Initialize shared buffers early
        loadActiveModel()
        loadGripperOverlay()

        // Listen for active model changes
        modelManager.$activeModel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (activeModel: ModelInfo?) in
                self?.loadActiveModel()
            }
            .store(in: &cancellables)
        
        // Listen for proximity reached notifications from ARVisualizationManager
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ProximityReached"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleProximityReached()
        }
    }
    
    // MARK: - Gripper Overlay Methods
    private func loadGripperOverlay() {
        // Load open gripper (default/original)
        if let openImage = UIImage(named: "gripper_overlay") {
            gripperOpenCIImage = CIImage(image: openImage)
            gripperOpenUIImage = openImage
            print("Open gripper overlay loaded:")
            print("  - Size: \(openImage.size)")
            print("  - Scale: \(openImage.scale)")
            print("  - CIImage extent: \(gripperOpenCIImage?.extent ?? .zero)")
        } else {
            print("Warning: Could not load gripper_overlay (open) image from assets")
        }

        // Load closed gripper
        if let closedImage = UIImage(named: "gripper_closed") {
            gripperClosedCIImage = CIImage(image: closedImage)
            gripperClosedUIImage = closedImage
            print("Closed gripper overlay loaded:")
            print("  - Size: \(closedImage.size)")
            print("  - Scale: \(closedImage.scale)")
            print("  - CIImage extent: \(gripperClosedCIImage?.extent ?? .zero)")
        } else {
            print("Warning: Could not load gripper_closed image from assets")
        }

        // Setup vImage buffer with open gripper as default
        if let openImage = UIImage(named: "gripper_overlay") {
            setupGripperOverlayBuffer(from: openImage)
        }
        
        // Set initial overlay image for display
        Task { @MainActor in
            updateGripperOverlayDisplay()
        }
    }
    
    @MainActor
    private func updateGripperOverlayDisplay() {
        guard shouldApplyGripperOverlay() else {
            currentGripperOverlayImage = nil
            return
        }

        let isGripperClosed = currentGripperValue < 0.7
        let baseImage = isGripperClosed ? gripperClosedUIImage : gripperOpenUIImage

        print("DEBUG: Updating gripper overlay - value: \(String(format: "%.3f", currentGripperValue)), closed: \(isGripperClosed)")

        // Update published property (automatically triggers objectWillChange)
        currentGripperOverlayImage = baseImage
        print("DEBUG: Gripper overlay image updated: \(isGripperClosed ? "CLOSED" : "OPEN")")
    }

    private func setupGripperOverlayBuffer(from uiImage: UIImage) {
        guard let cgImage = uiImage.cgImage else { return }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bufferLength = height * bytesPerRow

        guard let data = malloc(bufferLength) else {
            print("Warning: Could not allocate memory for gripper overlay buffer")
            return
        }

        var buffer = vImage_Buffer(
            data: data,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: bytesPerRow
        )

        // Convert CGImage to vImage buffer
        var format = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: nil,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            version: 0,
            decode: nil,
            renderingIntent: .defaultIntent
        )

        let error = vImageBuffer_InitWithCGImage(&buffer, &format, nil, cgImage, vImage_Flags(kvImageNoFlags))
        if error == kvImageNoError {
            gripperOverlayBuffer = buffer
        } else {
            free(data)
            print("Warning: Failed to create vImage buffer for gripper overlay: \(error)")
        }
    }

    func setUSBStreamingState(isActive: Bool) {
        isUSBStreamingActive = isActive
        print("USB streaming state: \(isActive ? "ON" : "OFF") - Gripper overlay: \(shouldApplyGripperOverlay() ? "ENABLED" : "DISABLED")")
        Task { @MainActor in
            updateGripperOverlayDisplay()
        }
    }

    private func shouldApplyGripperOverlay() -> Bool {
        // Use gripper overlay when USB streaming is OFF (virtual gripper proxy)
        // Disable when USB streaming is ON (robot has real gripper)
        return enableGripperOverlay && !isUSBStreamingActive
    }

    private func getCurrentGripperOverlay() -> CIImage? {
        // Use closed gripper when gripper value < 0.6, otherwise open gripper
        let isGripperClosed = currentGripperValue < 0.7
        if saveDebugFrames {
            print("Gripper state: \(String(format: "%.3f", currentGripperValue)) → \(isGripperClosed ? "CLOSED" : "OPEN")")
        }

        if isGripperClosed {
            return gripperClosedCIImage
        } else {
            return gripperOpenCIImage
        }
    }

    private func applyGripperOverlay(to image: CIImage) -> CIImage {
        guard shouldApplyGripperOverlay() else {
            if saveDebugFrames {
                print("DEBUG: Gripper overlay skipped - enableGripperOverlay: \(enableGripperOverlay), isUSBStreaming: \(isUSBStreamingActive)")
            }
            return image
        }

        guard let gripperOverlay = getCurrentGripperOverlay() else {
            if saveDebugFrames {
                print("DEBUG: No gripper overlay image available - openCIImage: \(gripperOpenCIImage != nil), closedCIImage: \(gripperClosedCIImage != nil)")
            }
            return image
        }

        // Check cache first to avoid expensive transform operations
        let cacheKey = "\(currentGripperValue < 0.7 ? "closed" : "open")_\(Int(image.extent.width))x\(Int(image.extent.height))"
        if let cachedOverlay = cachedGripperOverlays[cacheKey] {
            return applyCachedGripperOverlay(to: image, overlay: cachedOverlay)
        }

        if saveDebugFrames {
            print("DEBUG: Applying gripper overlay - value: \(String(format: "%.3f", currentGripperValue))")
        }
        let result = applyGripperOverlayCoreImage(to: image, overlay: gripperOverlay)

        // Cache the transformed overlay for reuse
        if cachedGripperOverlays.count < 10 { // Limit cache size
            let transformedOverlay = createTransformedGripperOverlay(gripperOverlay, imageSize: image.extent.size)
            cachedGripperOverlays[cacheKey] = transformedOverlay
        }

        return result
    }

    // MARK: - Cached Gripper Overlay Methods
    private func createTransformedGripperOverlay(_ gripperOverlay: CIImage, imageSize: CGSize) -> CIImage {
        // Apply same transformations as camera frames: scale to fit, then rotate if needed
        let scale = min(imageSize.width / gripperOverlay.extent.width, imageSize.height / gripperOverlay.extent.height)

        // Build combined transform: scale -> optional orientation -> rotation -> translation
        var transform = CGAffineTransform(scaleX: scale, y: scale)

        // Apply same orientation as camera frames
        if applyServerImageOrientation {
            transform = transform.concatenating(CGAffineTransform(rotationAngle: CGFloat.pi))
        }

        // Additional +90 degree rotation to align gripper direction with viewpoint
        transform = transform.concatenating(CGAffineTransform(rotationAngle: CGFloat.pi / 2))

        // Apply combined transform
        var transformedOverlay = gripperOverlay.transformed(by: transform)

        // After rotation, translate back to origin for proper overlay positioning
        let rotatedExtent = transformedOverlay.extent
        transformedOverlay = transformedOverlay.transformed(by: CGAffineTransform(translationX: -rotatedExtent.origin.x, y: -rotatedExtent.origin.y))

        return transformedOverlay
    }

    private func applyCachedGripperOverlay(to image: CIImage, overlay cachedOverlay: CIImage) -> CIImage {
        guard let compositeFilter = CIFilter(name: "CISourceOverCompositing") else {
            return image
        }

        compositeFilter.setValue(cachedOverlay, forKey: kCIInputImageKey)
        compositeFilter.setValue(image, forKey: kCIInputBackgroundImageKey)

        return compositeFilter.outputImage ?? image
    }

    private func applyGripperOverlayCoreImage(to image: CIImage, overlay gripperOverlay: CIImage) -> CIImage {
        let imageSize = image.extent.size

        if saveDebugFrames {
            print("DEBUG: Starting composite - image: \(imageSize)")
            print("DEBUG: Original overlay extent: \(gripperOverlay.extent)")
        }

        let transformedOverlay = createTransformedGripperOverlay(gripperOverlay, imageSize: imageSize)

        if saveDebugFrames {
            print("DEBUG: Server orientation: \(applyServerImageOrientation)")
            print("DEBUG: Final overlay extent: \(transformedOverlay.extent)")
        }

        guard let compositeFilter = CIFilter(name: "CISourceOverCompositing") else {
            if saveDebugFrames {
                print("DEBUG: Failed to create CISourceOverCompositing filter")
            }
            return image
        }

        compositeFilter.setValue(transformedOverlay, forKey: kCIInputImageKey)
        compositeFilter.setValue(image, forKey: kCIInputBackgroundImageKey)

        if let result = compositeFilter.outputImage {
            if saveDebugFrames {
                print("DEBUG: Composite successful, result extent: \(result.extent)")
            }
            return result
        } else {
            if saveDebugFrames {
                print("DEBUG: Composite filter returned nil")
            }
            return image
        }
    }

    // MARK: - Debug Frame Saving
    private func saveDebugFrame(_ image: CIImage, prefix: String) {
        guard saveDebugFrames else { return }

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let filename = "\(prefix)_\(timestamp).png"

        // Get Documents directory
        guard let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("Warning: Could not access Documents directory")
            return
        }

        let fileURL = documentsDirectory.appendingPathComponent(filename)

        // Convert CIImage to Data
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        guard let data = ciContext.pngRepresentation(of: image, format: .RGBA8, colorSpace: colorSpace) else {
            print("Warning: Could not create PNG data for debug frame")
            return
        }

        do {
            try data.write(to: fileURL)
            print("Debug frame saved: \(fileURL.lastPathComponent)")
        } catch {
            print("Warning: Could not save debug frame: \(error)")
        }
    }
    
    // MARK: - Model Loading
    private func loadActiveModel() {
        guard let activeModel = modelManager.activeModel,
              activeModel.compilationStatus.isCompiled else {
            // No active compiled model available
            model = nil
            modelMetadata = nil
            frameBuffer.removeAll()
            hasRunFirstInference = false
            return
        }
        
        // Indicate loading started
        DispatchQueue.main.async {
            self.isModelLoading = true
        }
        
        // Perform loading on background thread to keep UI responsive
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }

            do {
                let loadedModel = try await self.modelManager.loadModelAsync(for: activeModel)
                
                // Extract model metadata for type detection
                let metadata = try ModelMetadata(from: loadedModel)
                
                await MainActor.run {
                    self.model = loadedModel
                    self.modelMetadata = metadata

                    // Always maintain 3-frame rolling buffer
                    self.frameBuffer.removeAll()
                    self.hasRunFirstInference = false  // Reset for new model

                    print("Model loaded: \(activeModel.name)")
                    print("  Temporal frames: \(metadata.temporalFrames)")
                    print("  Goal conditioning: \(metadata.requiresGoalPoint)")
                    print("  Buffer size: \(self.maxBufferSize)")

                    self.modelInputSize = CGSize(width: 224, height: 224)
                    self.initializeSharedBuffers()
                    self.goalDimension = 3

                    // Mark loading as complete
                    self.isModelLoading = false
                }
            } catch {
                print("Error loading model: \(error)")
                await MainActor.run {
                    self.model = nil
                    self.modelMetadata = nil
                    self.frameBuffer.removeAll()
                    self.hasRunFirstInference = false
                    self.isModelLoading = false
                }
            }
        }
    }
    
    // MARK: - Shared Buffer Initialization
    private func initializeSharedBuffers() {
        // Initialize shared output pixel buffer (224x224 ARGB) - reused for all frame processing
        if sharedOutputPixelBuffer == nil {
            let width = 224
            let height = 224
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width, height,
                kCVPixelFormatType_32ARGB,
                attributes as CFDictionary,
                &pixelBuffer
            )
            if status == kCVReturnSuccess {
                sharedOutputPixelBuffer = pixelBuffer
            }
        }

        // Initialize shared MLMultiArray buffer (224x224x3) - reused for frame conversion
        if sharedMLMultiArrayBuffer == nil {
            do {
                sharedMLMultiArrayBuffer = try MLMultiArray(shape: [1, 3, 224, 224], dataType: .float32)
            } catch {
                print("Warning: Could not create shared MLMultiArray buffer: \(error)")
            }
        }
    }
    
    // MARK: - Model Management Integration
    var hasAvailableModel: Bool {
        return modelManager.hasAvailableModel && model != nil
    }
    
    var requiresGoalPoint: Bool {
        return modelMetadata?.requiresGoalPoint ?? false
    }
    
    var isPointConditioned: Bool {
        return true  // All models are point-conditioned now
    }
    
    var activeModelName: String? {
        return modelManager.activeModel?.name
    }
    
    var isUsingUploadedModel: Bool {
        return modelManager.hasCompiledModel
    }
    
    // MARK: - Goal Point Management
     
    
    func clearGoalPoint() {
        currentGoalPoint = nil
        goalFrameCount = 0
    }
    
    // MARK: - Odometry Integration Methods (removed)
    
    /// Set goal dimension (2D or 3D goal conditioning)
    func setGoalDimension(_ dimension: Int) {
        goalDimension = dimension
    }
    
    /// Get goal point for model input (2D or 3D based on goal_dim)
    func getGoalPointForModel() -> [Float]? {
        // Standardize 3D goals to labels.json frame from the CURRENT camera frame: [-x, z, y]
        if goalDimension == 3 {
            guard let session = getARSession(), let frame = session.currentFrame else {
                return nil
            }


            // Use the world-locked goal point (ARKit keeps it fixed in world space)
            guard let p_w = currentGoalPoint else { return nil }
            // World (ARKit) → Camera
            let T_wc = frame.camera.transform
            let T_cw = simd_inverse(T_wc)
            let p_c4 = simd_mul(T_cw, simd_float4(p_w.x, p_w.y, p_w.z, 1.0))
            // camera: x right, y up, z back
            // labels: x left, y forward, z down
            // Mapping: x = -x_cam, y = -z_cam, z = -y_cam
            // Add 0.02 offset only on first frame 
            let yOffset: Float = (goalFrameCount == 0) ? 0.02 : 0.0
            let goalArr = [-p_c4.x, -p_c4.z + yOffset, -p_c4.y]
            goalFrameCount += 1
            return goalArr
        }
        // If model expects 2D goals, return nil since we only support 3D goals now
        return nil
    }
    
    // MARK: - AR Session Access
    weak var arViewContainer: ARViewModel?
    
    private func getARSession() -> ARSession? {
        // Get ARSession from the connected ARViewContainer
        return arViewContainer?.getARSession()
    }
    
    func setARViewContainer(_ container: ARViewModel) {
        self.arViewContainer = container
    }
    
    // MARK: - Proximity Handler
    private func handleProximityReached() {
        print("[ML] Goal Reached (Proximity Trigger Received)")
        guard !isInferencePending else {
            print("[MLInference] Proximity reached but inference already pending - skipping")
            return
        }
        proximityReached = true
        print("[MLInference] Proximity reached - inference will trigger with next frame (firstInference: \(hasRunFirstInference))")
    }
    
    // MARK: - Frequency-based Inference Helper
    private func shouldRunBasedOnFrequency(_ timestamp: CFTimeInterval) -> Bool {
        let interval = inferenceFrequency.interval
        if interval == 0.0 {
            return true // High frequency - every frame
        }
        return (timestamp - lastInferenceTime) >= interval
    }

    // MARK: - Inference Methods (Using existing frame processing patterns)
    func performInference(on pixelBuffer: CVPixelBuffer, arFrame: ARFrame?, timestamp: CFTimeInterval = CACurrentMediaTime()) {
        // Update device pose for visualization (optional)
        if let frame = arFrame {
            arVisualizationManager?.updateActualDevicePose(from: frame)
        }
        
        performInference(on: pixelBuffer, timestamp: timestamp)
    }
    
    func performInference(on pixelBuffer: CVPixelBuffer, timestamp: CFTimeInterval = CACurrentMediaTime()) {
        guard isInferenceEnabled,
              let metadata = modelMetadata else {
            return
        }

        // Check if goal point is required but not set
        if metadata.requiresGoalPoint && currentGoalPoint == nil {
            return // Skip until goal point is set
        }

        // Process current frame for potential action storage
        do {
            let processedFrame = try processFrame(pixelBuffer, targetSize: CGSize(width: 224, height: 224), debugPrefix: "current")
            let goalPointArray = metadata.requiresGoalPoint ? getGoalPointForModel() : nil
            currentFrameEntry = FrameBufferEntry(mlArray: processedFrame, goalPoint: goalPointArray)
        } catch {
            print("ERROR: Failed to process current frame: \(error)")
            return
        }

        // Store current frame entry for buffering
        guard let currentEntry = currentFrameEntry else {
            print("ERROR: No current frame entry available")
            return
        }

        let isFirstInference = !hasRunFirstInference
        let shouldRunInference: Bool

        if isUSBStreamingActive {
            // USB ON: Continuously add frames to buffer (rolling 3-frame window)
            frameBuffer.append(currentEntry)
            if frameBuffer.count > maxBufferSize {
                frameBuffer.removeFirst()
            }
            print("[MLInference] USB Mode: Frame added to rolling buffer (\(frameBuffer.count)/\(maxBufferSize))")

            // Run inference based on frequency setting or first inference
            shouldRunInference = isFirstInference || shouldRunBasedOnFrequency(timestamp)
        } else {
            // USB OFF: Proximity-triggered buffering for recording mode
            let isProximityTriggered = proximityReached && !isInferencePending
            shouldRunInference = isFirstInference || isProximityTriggered

            guard shouldRunInference else {
                return // Don't add to buffer unless inference is triggered
            }

            frameBuffer.append(currentEntry)
            if frameBuffer.count > maxBufferSize {
                frameBuffer.removeFirst(frameBuffer.count - maxBufferSize)
            }
            print("[MLInference] Recording Mode: Action frame stored (\(frameBuffer.count) action trigger frames)")
        }

        guard shouldRunInference else {
            return
        }

        // Temporal models pad with repeated frames if needed
        
        // Ensure we have a model loaded
        guard let model = model else {
            print("ERROR: No model loaded for inference")
            return
        }
        
        // Mark inference as pending
        isInferencePending = true
        isInferencePendingUI = true
        proximityReached = false  // Reset proximity flag
        
        if debugLoggingEnabled {
            print("[MLInference] Running inference - firstTime: \(!hasRunFirstInference), buffer: \(frameBuffer.count)")
        }
        
        // Prepare input using buffered frames
        let modelInput: MLFeatureProvider
        do {
            modelInput = try prepareModelInputFromBuffer(metadata: metadata)
        } catch {
            print("ERROR: Failed to prepare model input: \(error)")
            isInferencePending = false
            isInferencePendingUI = false
            return
        }
        
        inferenceQueue.async { [weak self, modelInput, model] in
            guard let self = self else { return }
            
            let startTime = CACurrentMediaTime()
            
            autoreleasepool {
                do {
                    print("DEBUG: Running model prediction with buffered frames...")
                    let output = try model.prediction(from: modelInput)
                    print("DEBUG: Model prediction succeeded")
                    
                    let inferenceTime = CACurrentMediaTime() - startTime
                    self.processInferenceResults(output, inferenceTime: inferenceTime)
                    
                    // Reset pending flag and mark first inference complete
                    DispatchQueue.main.async {
                        self.isInferencePending = false
                        self.isInferencePendingUI = false
                        self.lastInferenceTime = CACurrentMediaTime() // Update for frequency tracking
                        if !self.hasRunFirstInference {
                            self.hasRunFirstInference = true
                            print("[MLInference] First inference complete - target cube should now be visible")
                        }
                    }
                } catch {
                    print("ERROR: Model inference failed: \(error)")
                    DispatchQueue.main.async {
                        self.isInferencePending = false
                        self.isInferencePendingUI = false
                    }
                }
            }
        }
    }
    
    // MARK: - Action Frame Buffer Input Preparation
    private func prepareModelInputFromBuffer(metadata: ModelMetadata) throws -> MLFeatureProvider {
        print("DEBUG: Preparing input from action frame buffer for point-conditioned model")

        guard !frameBuffer.isEmpty else {
            throw NSError(domain: "MLInferenceManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No action frames stored yet"])
        }

        return try prepareVQBeTInputFromBuffer(metadata: metadata)
    }
    
    // MARK: - MLMultiArray Copying Helper
    /// Copy a single channel from source MLMultiArray to target MLMultiArray
    /// - Parameters:
    ///   - source: Source MLMultiArray with shape [1, 3, H, W]
    ///   - target: Target MLMultiArray to copy into
    ///   - targetTimestep: Target timestep index
    ///   - targetChannel: Target channel index
    ///   - sourceChannel: Source channel index
    private func copyMLMultiArrayChannel(source: MLMultiArray, target: MLMultiArray, targetTimestep: Int, targetChannel: Int, sourceChannel: Int) {
        for h in 0..<224 {
            for w in 0..<224 {
                let value = source[[0, NSNumber(value: sourceChannel), NSNumber(value: h), NSNumber(value: w)]]
                target[[0, NSNumber(value: targetTimestep), NSNumber(value: targetChannel), NSNumber(value: h), NSNumber(value: w)]] = value
            }
        }
    }
    
    // MARK: - Action Frame Buffer Input Preparation Methods
    private func prepareVQBeTInputFromBuffer(metadata: ModelMetadata) throws -> MLFeatureProvider {
        let goalPointArray = frameBuffer.last?.goalPoint ?? getGoalPointForModel()
        guard let goalPointArray = goalPointArray else {
            throw NSError(domain: "MLInferenceManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Goal point required"])
        }
        
        let imageInputName = metadata.getImageInputName() ?? "camera_image"
        let goalInputName = metadata.getGoalInputName() ?? "goal_point"
        let temporalFrames = metadata.temporalFrames
        
        // Determine expected rank from model
        let expectedRank: Int = {
            if let d = model?.modelDescription.inputDescriptionsByName[imageInputName],
               d.type == .multiArray,
               let shape = d.multiArrayConstraint?.shape {
                return shape.count
            }
            return 4
        }()
        
        print("DEBUG: Using buffered action frames - temporalFrames: \(temporalFrames), actionFramesAvailable: \(frameBuffer.count)")

        // Build image array from buffer
        let imageArray: MLMultiArray
        if temporalFrames > 1 {
            // Temporal model: use available action frames, pad with repetition if needed
            let framesToUse = min(temporalFrames, frameBuffer.count)
            let paddingNeeded = max(0, temporalFrames - framesToUse)

            // Create temporal frame array (can't reuse since it's used in model input)
            imageArray = try MLMultiArray(shape: [1, NSNumber(value: temporalFrames), 3, 224, 224], dataType: .float32)

            guard frameBuffer.count > 0 else {
                throw NSError(domain: "MLInferenceManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No action frames available"])
            }

            // Pad with repeated first action frame if needed
            if paddingNeeded > 0 {
                let firstActionFrame = frameBuffer[0].mlArray
                for t in 0..<paddingNeeded {
                    for c in 0..<3 {
                        copyMLMultiArrayChannel(source: firstActionFrame, target: imageArray, targetTimestep: t, targetChannel: c, sourceChannel: c)
                    }
                }
                print("DEBUG: Padded \(paddingNeeded) frames with first action frame")
            }
            
            // Copy actual frames from buffer
            for (idx, entry) in frameBuffer.suffix(framesToUse).enumerated() {
                let t = paddingNeeded + idx
                let srcFrame = entry.mlArray
                for c in 0..<3 {
                    copyMLMultiArrayChannel(source: srcFrame, target: imageArray, targetTimestep: t, targetChannel: c, sourceChannel: c)
                }
            }
        } else {
            // Single-frame: use latest from buffer
            let latestFrame = frameBuffer.last!.mlArray
            
            if expectedRank == 5 {
                imageArray = try MLMultiArray(shape: [1, 1, 3, 224, 224], dataType: .float32)
                for c in 0..<3 {
                    copyMLMultiArrayChannel(source: latestFrame, target: imageArray, targetTimestep: 0, targetChannel: c, sourceChannel: c)
                }
            } else {
                imageArray = latestFrame
            }
        }
        
        // Prepare goal array
        let goalArray: MLMultiArray = {
            guard let d = model?.modelDescription.inputDescriptionsByName[goalInputName],
                  d.type == .multiArray,
                  let shape = d.multiArrayConstraint?.shape else {
                // Default shape: [1, 3]
                let arr = try! MLMultiArray(shape: [1, 3], dataType: .float32)
                for i in 0..<3 { arr[[0, i] as [NSNumber]] = NSNumber(value: goalPointArray[i]) }
                return arr
            }
            
            let dims = shape.map { $0.intValue }
            guard let arr = try? MLMultiArray(shape: shape, dataType: .float32) else {
                // Fallback to default shape
                let arr = try! MLMultiArray(shape: [1, 3], dataType: .float32)
                for i in 0..<3 { arr[[0, i] as [NSNumber]] = NSNumber(value: goalPointArray[i]) }
                return arr
            }
            
            // Handle different shape patterns
            if dims.count == 3 && dims[1] > 1 && dims[2] == 3 {
                // Temporal goal: [1, T, 3]
                for t in 0..<dims[1] {
                    for i in 0..<3 { arr[[0, NSNumber(value: t), NSNumber(value: i)]] = NSNumber(value: goalPointArray[i]) }
                }
            } else if dims.count == 3 && dims[2] == 3 {
                // [1, 1, 3] or similar
                for i in 0..<3 { arr[[0, 0, i] as [NSNumber]] = NSNumber(value: goalPointArray[i]) }
            } else if dims.count == 2 && dims == [1, 3] {
                // [1, 3]
                for i in 0..<3 { arr[[0, i] as [NSNumber]] = NSNumber(value: goalPointArray[i]) }
            } else {
                // Unknown shape, try to fill first 3 elements
                for i in 0..<min(3, arr.count) { arr[i] = NSNumber(value: goalPointArray[i]) }
            }
            
            return arr
        }()
        
        return try MLDictionaryFeatureProvider(dictionary: [
            imageInputName: MLFeatureValue(multiArray: imageArray),
            goalInputName: MLFeatureValue(multiArray: goalArray)
        ])
    }
    
    // MARK: - Unified Frame Processing
    private func processFrame(_ pixelBuffer: CVPixelBuffer, targetSize: CGSize, debugPrefix: String) throws -> MLMultiArray {
        let width = Int(targetSize.width)
        let height = Int(targetSize.height)
        
        // Use shared output pixel buffer or create if needed
        if sharedOutputPixelBuffer == nil {
            initializeSharedBuffers()
        }
        
        guard let outputBuffer = sharedOutputPixelBuffer else {
            throw NSError(domain: "MLInferenceManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get shared output pixel buffer"])
        }
        
        // Process image - use Accelerate for scaling when possible, fallback to Core Image for complex transforms
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(outputBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(outputBuffer, [])
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        
        let inputImageSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let scaleX = targetSize.width / inputImageSize.width
        let scaleY = targetSize.height / inputImageSize.height
        
        // Use vImage for simple scaling (no rotation/orientation), Core Image for complex transforms
        if !applyServerImageOrientation && abs(scaleX - scaleY) < 0.01 {
            // Simple uniform scaling - use vImage for better performance
            if processFrameWithVImage(pixelBuffer: pixelBuffer, outputBuffer: outputBuffer, scale: Float(scaleX)) {
                // vImage scaling succeeded, now apply gripper overlay if needed
                let scaledCIImage = CIImage(cvPixelBuffer: outputBuffer)
                var finalImage = scaledCIImage
                
                if shouldApplyGripperOverlay(), let gripperOverlay = getCurrentGripperOverlay() {
                    finalImage = applyGripperOverlayCoreImage(to: scaledCIImage, overlay: gripperOverlay)
                }
                
                // Render final image to output buffer
                let cropRect = CGRect(origin: .zero, size: targetSize)
                ciContext.render(finalImage, to: outputBuffer, bounds: cropRect, colorSpace: CGColorSpaceCreateDeviceRGB())
            } else {
                // Fallback to Core Image pipeline
                let inputImage = CIImage(cvPixelBuffer: pixelBuffer)
                var scaledImage = inputImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                
                // Save original scaled image for debugging
                saveDebugFrame(scaledImage, prefix: "\(debugPrefix)_original")
                
                // Apply gripper overlay when USB streaming is off (virtual gripper proxy)
                scaledImage = applyGripperOverlay(to: scaledImage)
                saveDebugFrame(scaledImage, prefix: "\(debugPrefix)_with_overlay")
                
                let cropRect = CGRect(origin: .zero, size: targetSize)
                ciContext.render(scaledImage, to: outputBuffer, bounds: cropRect, colorSpace: CGColorSpaceCreateDeviceRGB())
            }
        } else {
            // Complex transform (rotation/orientation) - use Core Image
            let inputImage = CIImage(cvPixelBuffer: pixelBuffer)
            var scaledImage = inputImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            if applyServerImageOrientation {
                scaledImage = scaledImage.oriented(.down)
            }
            
            // Save original scaled image for debugging
            saveDebugFrame(scaledImage, prefix: "\(debugPrefix)_original")
            
            // Apply gripper overlay when USB streaming is off (virtual gripper proxy)
            scaledImage = applyGripperOverlay(to: scaledImage)
            saveDebugFrame(scaledImage, prefix: "\(debugPrefix)_with_overlay")
            
            let cropRect = CGRect(origin: .zero, size: targetSize)
            ciContext.render(scaledImage, to: outputBuffer, bounds: cropRect, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        
        // Convert to MLMultiArray as single frame [1,3,H,W] for buffering
        return try convertPixelBufferToMLMultiArray(outputBuffer, width: width, height: height)
    }
    
    // MARK: - Unified Pixel Buffer to MLMultiArray Conversion (Accelerate Optimized)
    private func convertPixelBufferToMLMultiArray(_ pixelBuffer: CVPixelBuffer, width: Int, height: Int) throws -> MLMultiArray {
        // Use shared buffer if available, otherwise create new one
        let inputArray: MLMultiArray
        if let sharedBuffer = sharedMLMultiArrayBuffer {
            inputArray = sharedBuffer
            // Clear the buffer by zeroing it out efficiently
            memset(inputArray.dataPointer, 0, inputArray.count * MemoryLayout<Float>.size)
        } else {
            // Fallback: create new MLMultiArray
            inputArray = try MLMultiArray(shape: [1, 3, NSNumber(value: height), NSNumber(value: width)], dataType: .float32)
        }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw NSError(domain: "MLInferenceManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get pixel buffer base address"])
        }
        
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let totalPixels = width * height
        
        // Use Accelerate for faster conversion
        let rPtr = inputArray.dataPointer.assumingMemoryBound(to: Float.self)
        let gPtr = rPtr.advanced(by: totalPixels)
        let bPtr = gPtr.advanced(by: totalPixels)
        
        // Use vDSP for efficient channel extraction and conversion
        // ARGB format: [A, R, G, B, A, R, G, B, ...]
        // We need to extract R (offset 1), G (offset 2), B (offset 3) from each 4-byte pixel
        
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)
        let tempBufferSize = totalPixels * MemoryLayout<UInt8>.size
        guard let tempR = malloc(tempBufferSize),
              let tempG = malloc(tempBufferSize),
              let tempB = malloc(tempBufferSize) else {
            // Fallback to manual conversion if memory allocation fails
            return try convertPixelBufferToMLMultiArrayManual(pixelBuffer: pixelBuffer, inputArray: inputArray, width: width, height: height)
        }
        defer {
            free(tempR)
            free(tempG)
            free(tempB)
        }
        
        // Extract channels using optimized stride-based approach
        var pixelIndex = 0
        for y in 0..<height {
            let rowStart = y * bytesPerRow
            for x in 0..<width {
                let offset = rowStart + x * 4
                tempR.assumingMemoryBound(to: UInt8.self)[pixelIndex] = buffer[offset + 1]  // R
                tempG.assumingMemoryBound(to: UInt8.self)[pixelIndex] = buffer[offset + 2]  // G
                tempB.assumingMemoryBound(to: UInt8.self)[pixelIndex] = buffer[offset + 3]  // B
                pixelIndex += 1
            }
        }
        
        // Convert UInt8 to Float and normalize using vDSP (much faster than manual loops)
        var scale: Float = 1.0 / 255.0
        vDSP_vfltu8(tempR.assumingMemoryBound(to: UInt8.self), 1, rPtr, 1, vDSP_Length(totalPixels))
        vDSP_vsmul(rPtr, 1, &scale, rPtr, 1, vDSP_Length(totalPixels))
        
        vDSP_vfltu8(tempG.assumingMemoryBound(to: UInt8.self), 1, gPtr, 1, vDSP_Length(totalPixels))
        vDSP_vsmul(gPtr, 1, &scale, gPtr, 1, vDSP_Length(totalPixels))
        
        vDSP_vfltu8(tempB.assumingMemoryBound(to: UInt8.self), 1, bPtr, 1, vDSP_Length(totalPixels))
        vDSP_vsmul(bPtr, 1, &scale, bPtr, 1, vDSP_Length(totalPixels))

        // Return a copy of the shared buffer to avoid conflicts when stored in frameBuffer
        if inputArray === sharedMLMultiArrayBuffer {
            let copyArray = try MLMultiArray(shape: [1, 3, NSNumber(value: height), NSNumber(value: width)], dataType: .float32)
            memcpy(copyArray.dataPointer, inputArray.dataPointer, inputArray.count * MemoryLayout<Float>.size)
            return copyArray
        }

        return inputArray
    }
    
    // Fallback manual conversion method
    private func convertPixelBufferToMLMultiArrayManual(pixelBuffer: CVPixelBuffer, inputArray: MLMultiArray, width: Int, height: Int) throws -> MLMultiArray {
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw NSError(domain: "MLInferenceManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get pixel buffer base address"])
        }
        
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let totalPixels = width * height
        
        let rPtr = inputArray.dataPointer.assumingMemoryBound(to: Float.self)
        let gPtr = rPtr.advanced(by: totalPixels)
        let bPtr = gPtr.advanced(by: totalPixels)
        
        var pixelIndex = 0
        for y in 0..<height {
            let rowStart = y * bytesPerRow
            for x in 0..<width {
                let offset = rowStart + x * 4
                rPtr[pixelIndex] = Float(buffer[offset + 1]) / 255.0
                gPtr[pixelIndex] = Float(buffer[offset + 2]) / 255.0
                bPtr[pixelIndex] = Float(buffer[offset + 3]) / 255.0
                pixelIndex += 1
            }
        }
        
        return inputArray
    }
    
    // MARK: - vImage Scaling (Accelerate Optimized)
    /// Scale pixel buffer using vImage for better performance (simple scaling only)
    private func processFrameWithVImage(pixelBuffer: CVPixelBuffer, outputBuffer: CVPixelBuffer, scale: Float) -> Bool {
        guard let inputBase = CVPixelBufferGetBaseAddress(pixelBuffer),
              let outputBase = CVPixelBufferGetBaseAddress(outputBuffer) else {
            return false
        }
        
        let inputWidth = CVPixelBufferGetWidth(pixelBuffer)
        let inputHeight = CVPixelBufferGetHeight(pixelBuffer)
        let outputWidth = CVPixelBufferGetWidth(outputBuffer)
        let outputHeight = CVPixelBufferGetHeight(outputBuffer)
        let inputBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let outputBytesPerRow = CVPixelBufferGetBytesPerRow(outputBuffer)
        
        var sourceBuffer = vImage_Buffer(
            data: inputBase,
            height: vImagePixelCount(inputHeight),
            width: vImagePixelCount(inputWidth),
            rowBytes: inputBytesPerRow
        )
        
        var destBuffer = vImage_Buffer(
            data: outputBase,
            height: vImagePixelCount(outputHeight),
            width: vImagePixelCount(outputWidth),
            rowBytes: outputBytesPerRow
        )
        
        // Use vImageScale_ARGB8888 for fast scaling
        let error = vImageScale_ARGB8888(&sourceBuffer, &destBuffer, nil, vImage_Flags(kvImageHighQualityResampling))
        return error == kvImageNoError
    }
    
    // MARK: - Result Processing
    
    /// Extract joint positions from model output, handling both single-step and multi-step outputs
    private func extractJointPositions(from resultArray: MLMultiArray) -> [Float] {
        let shape = resultArray.shape.map { $0.intValue }
        
        // Check if this is a multi-step temporal output: [T,1,7] or similar
        if shape.count == 3 && shape[0] > 1 && shape[2] >= 7 {
            // Multi-step output: extract last timestep [T-1, 0, 0...6]
            let lastTimestep = shape[0] - 1
            let jointPositions = (0..<7).map { i in
                resultArray[[NSNumber(value: lastTimestep), 0, NSNumber(value: i)]].floatValue
            }
            print("Multi-step output detected: shape \(shape), using last timestep [\(lastTimestep)]")
            return jointPositions
        } else {
            // Single-step output: extract directly
            let outputCount = min(resultArray.count, 10)
            return (0..<outputCount).map { resultArray[$0].floatValue }
        }
    }
    
    private func processInferenceResults(_ output: MLFeatureProvider, inferenceTime: TimeInterval) {
        guard let metadata = modelMetadata else {
            return
        }
        
        // Point-conditioned models only
        let outputFeatureName = metadata.primaryOutputName ?? output.featureNames.first
        
        guard let outputFeatureName = outputFeatureName,
              let resultArray = output.featureValue(for: outputFeatureName)?.multiArrayValue else {
            return
        }
        
        // Extract values (handles both single-step and multi-step outputs)
        let jointPositions = extractJointPositions(from: resultArray)

        // Update gripper value for overlay switching (7th element, index 6)
        if jointPositions.count >= 7 {
            currentGripperValue = jointPositions[6]
            let isGripperClosed = currentGripperValue < 0.7
            print("[ML] PointCond - Gripper Value: \(String(format: "%.3f", currentGripperValue)) | State: \(isGripperClosed ? "CLOSED" : "OPEN")")
            
            Task { @MainActor [weak self] in
                self?.updateGripperOverlayDisplay()
                // Update AR visualization manager gripper state to stop visualization when closed
                self?.arVisualizationManager?.setGripperState(isClosed: isGripperClosed)
            }
        }

        let result = InferenceResult(
            jointPositions: jointPositions,
            inferenceTime: inferenceTime
        )
        
        // Update UI on main thread
        DispatchQueue.main.async { [weak self] in
            self?.latestResult = result
            self?.lastResult = result
            
            // Only enable visualization when NOT in USB streaming mode (recording mode only)
            if let arManager = self?.arVisualizationManager, jointPositions.count >= 6, self?.isUSBStreamingActive != true {
                arManager.ensureVisualizationReady()
                arManager.updatePoseFromMLOutput(jointPositions, timestamp: self?.lastInferenceTime ?? CACurrentMediaTime())
            }
            
            // Joint actions are automatically sent via USB stream (transform to robot frame)
            if jointPositions.count >= 7 {
                let src = Array(jointPositions.prefix(7))
                if self?.enableTransformDebug == true {
                     let report = ActionTransformUtils.debugTransformReport(src, rotationUnit: self?.rotationUnit ?? .eulerXYZ)
                     print("Coordinate Transform:\n\(report)")
                }
            }
        }
    }
    
    // MARK: - Control Methods
    func enableInference() {
        isInferenceEnabled = true
        let modelName = modelManager.activeModel?.name ?? "No model"
        print("Inference enabled: \(modelName)")
        if enableTransformDebug {
            print("Transform debug enabled (\(rotationUnit))")
        }

        // Update gripper overlay to show inference status
        Task { @MainActor in
            updateGripperOverlayDisplay()
        }
    }

    func disableInference() {
        isInferenceEnabled = false
        latestResult = nil
        // Preserve lastResult so UI can continue showing the previous inference output while idle
        isInferencePending = false
        isInferencePendingUI = false
        print("Inference disabled")

        // Update gripper overlay to hide inference status
        Task { @MainActor in
            updateGripperOverlayDisplay()
        }
    }
    
    func resetInferenceState() {
        hasRunFirstInference = false
        proximityReached = false
        isInferencePending = false
        isInferencePendingUI = false
        frameBuffer.removeAll()
        currentFrameEntry = nil
        goalFrameCount = 0  // Reset goal frame count
        print("Inference state reset - ready for new recording")
    }
    
    // MARK: - Manual Inference Trigger
    func triggerInferenceManually() {
        guard isInferenceEnabled,
              let metadata = modelMetadata else {
            print("[MLInference] Cannot trigger manually - inference disabled or no model")
            return
        }
        
        // Check if goal point is required but not set
        if metadata.requiresGoalPoint && currentGoalPoint == nil {
            print("[MLInference] Cannot trigger manually - goal point required but not set")
            return
        }
        
        // Ensure we have a model loaded
        guard let model = model else {
            print("[MLInference] Cannot trigger manually - no model loaded")
            return
        }
        
        // Skip if inference already pending
        guard !isInferencePending else {
            print("[MLInference] Cannot trigger manually - inference already pending")
            return
        }
        
        // Store current frame for manual trigger
        guard let currentEntry = currentFrameEntry else {
            print("[MLInference] Cannot trigger manually - no current frame available")
            return
        }

        // Add frame to buffer following same logic as automatic inference
        if isUSBStreamingActive {
            frameBuffer.append(currentEntry)
            if frameBuffer.count > maxBufferSize {
                frameBuffer.removeFirst()
            }
            print("[MLInference] Manual trigger - USB mode: Frame added to rolling buffer (\(frameBuffer.count))")
        } else {
            frameBuffer.append(currentEntry)
            if frameBuffer.count > maxBufferSize {
                frameBuffer.removeFirst(frameBuffer.count - maxBufferSize)
            }
            print("[MLInference] Manual trigger - Recording mode: Action frame stored (\(frameBuffer.count))")
        }

        // Mark inference as pending
        isInferencePending = true
        
        // Prepare input using buffered frames
        let modelInput: MLFeatureProvider
        do {
            modelInput = try prepareModelInputFromBuffer(metadata: metadata)
        } catch {
            print("ERROR: Failed to prepare model input for manual trigger: \(error)")
            isInferencePending = false
            return
        }
        
        inferenceQueue.async { [weak self, modelInput, model] in
            guard let self = self else { return }
            
            let startTime = CACurrentMediaTime()
            
            autoreleasepool {
                do {
                    print("DEBUG: Running manual model prediction with buffered frames...")
                    let output = try model.prediction(from: modelInput)
                    print("DEBUG: Manual model prediction succeeded")
                    
                    let inferenceTime = CACurrentMediaTime() - startTime
                    self.processInferenceResults(output, inferenceTime: inferenceTime)
                    
                    // Reset pending flag and mark first inference complete
                    DispatchQueue.main.async {
                        self.isInferencePending = false
                        self.lastInferenceTime = CACurrentMediaTime() // Update for frequency tracking
                        if !self.hasRunFirstInference {
                            self.hasRunFirstInference = true
                            print("[MLInference] First inference complete (manual) - target cube should now be visible")
                        } else {
                            // For manual triggers after first inference, transition current target to fading
                            // This allows the new target to appear immediately
                            self.arVisualizationManager?.forceTargetTransition()
                        }
                    }
                } catch {
                    print("ERROR: Manual model inference failed: \(error)")
                    DispatchQueue.main.async {
                        self.isInferencePending = false
                    }
                }
            }
        }
    }
    
    func setInferenceFrequency(_ frequency: InferenceFrequency) {
        inferenceFrequency = frequency
        print("Inference frequency: \(frequency.displayName)")
    }
    
    // MARK: - Frequency Synchronization
    func synchronizeFrequencyWithVisualization() {
        // Convert MLInferenceManager frequency to ARVisualizationManager frequency
        let correspondingVisualizationFrequency: VisualizationFrequency
        switch inferenceFrequency {
        case .high:
            correspondingVisualizationFrequency = .high
        case .medium:
            correspondingVisualizationFrequency = .medium
        case .low:
            correspondingVisualizationFrequency = .low
        case .minute:
            correspondingVisualizationFrequency = .minute
        }
        
        arVisualizationManager?.setVisualizationFrequency(correspondingVisualizationFrequency)
        print("Synchronized frequencies: \(inferenceFrequency.displayName)")
    }
    
} 
