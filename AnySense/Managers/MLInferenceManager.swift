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
class MLInferenceManager: ObservableObject {
    
    // MARK: - Published Properties
    @Published var latestResult: InferenceResult?
    @Published var isInferenceEnabled: Bool = false
    @Published var inferenceFrequency: InferenceFrequency = .medium
    @Published var currentGoalPoint: simd_float3?
    @Published var modelMetadata: ModelMetadata?
    
    // MARK: - Private Properties
    private var model: MLModel?
    private var lastInferenceTime: CFTimeInterval = 0
    private var inferenceQueue = DispatchQueue(label: "MLInferenceQueue", qos: .userInitiated)
    
    // MARK: - Goal Point Management
    
    func setGoalPoint(_ point: simd_float3) {
        self.currentGoalPoint = point
        arVisualizationManager?.setTargetPose(point)
    }
    private var goalPointQueue = DispatchQueue(label: "GoalPointQueue", qos: .userInitiated)
    
    // Goal conditioning mode (point-conditioned models use 3D goals)
    private var goalDimension: Int = 3
    
    // MARK: - Frame Buffering for Temporal Models
    private struct FrameBufferEntry {
        let mlArray: MLMultiArray  // Pre-processed [1,3,H,W] frame
        let goalPoint: [Float]?     // Goal at time of capture
    }
    private var frameBuffer: [FrameBufferEntry] = []
    private var maxBufferSize: Int = 3  // Always maintain 3 frames for rolling buffer
    
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
    private var modelInputTransform: CGAffineTransform?

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
    
    deinit {
        // Ensure cleanup of resources
        model = nil
        latestResult = nil
        cancellables.removeAll()

        // Clean up vImage buffer
        if let buffer = gripperOverlayBuffer {
            free(buffer.data)
        }
    }

    // MARK: - Gripper Overlay Methods
    private func loadGripperOverlay() {
        // Load open gripper (default/original)
        if let openImage = UIImage(named: "gripper_overlay") {
            gripperOpenCIImage = CIImage(image: openImage)
            gripperOpenUIImage = openImage
            print("Open gripper overlay loaded: \(gripperOpenCIImage?.extent ?? .zero)")
        } else {
            print("Warning: Could not load gripper_overlay (open) image from assets")
        }

        // Load closed gripper
        if let closedImage = UIImage(named: "gripper_closed") {
            gripperClosedCIImage = CIImage(image: closedImage)
            gripperClosedUIImage = closedImage
            print("Closed gripper overlay loaded: \(gripperClosedCIImage?.extent ?? .zero)")
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
        guard showGripperOverlayOnScreen && !isUSBStreamingActive else {
            currentGripperOverlayImage = nil
            return
        }
        
        let isGripperClosed = currentGripperValue < 0.6
        let imageToShow = isGripperClosed ? gripperClosedUIImage : gripperOpenUIImage
        
        print("DEBUG: Updating gripper overlay - value: \(String(format: "%.3f", currentGripperValue)), closed: \(isGripperClosed)")
        
        // Update published property (automatically triggers objectWillChange)
        currentGripperOverlayImage = imageToShow
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
        print("USB streaming state: \(isActive ? "ON" : "OFF") - Gripper overlay: \(shouldShowGripperOverlay() ? "ENABLED" : "DISABLED")")
        Task { @MainActor in
            updateGripperOverlayDisplay()
        }
    }

    private func shouldShowGripperOverlay() -> Bool {
        return enableGripperOverlay && !isUSBStreamingActive
    }

    private func getCurrentGripperOverlay() -> CIImage? {
        // Use closed gripper when gripper value < 0.6, otherwise open gripper
        let isGripperClosed = currentGripperValue < 0.6
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
        guard shouldShowGripperOverlay() else {
            return image
        }
        
        guard let gripperOverlay = getCurrentGripperOverlay() else {
            return image
        }
        
        return applyGripperOverlayCoreImage(to: image, overlay: gripperOverlay)
    }

    private func applyGripperOverlayCoreImage(to image: CIImage, overlay gripperOverlay: CIImage) -> CIImage {
        let imageSize = image.extent.size
        let overlaySize = gripperOverlay.extent.size
        let scaleX = imageSize.width / overlaySize.width
        let scaleY = imageSize.height / overlaySize.height
        let scale = min(scaleX, scaleY)
        let scaledOverlay = gripperOverlay.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        
        guard let compositeFilter = CIFilter(name: "CISourceOverCompositing") else {
            return image
        }
        
        compositeFilter.setValue(scaledOverlay, forKey: kCIInputImageKey)
        compositeFilter.setValue(image, forKey: kCIInputBackgroundImageKey)
        return compositeFilter.outputImage ?? image
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
            // maxBufferSize stays at 3
            return
        }
        
        do {
            let loadedModel = try modelManager.loadModel(for: activeModel)
            model = loadedModel
            
            // Extract model metadata for type detection
            let metadata = try ModelMetadata(from: loadedModel)
            modelMetadata = metadata
            
            // Always maintain 3-frame rolling buffer (don't override with model's temporal requirement)
            // maxBufferSize stays at 3
            frameBuffer.removeAll()
            hasRunFirstInference = false  // Reset for new model
            
            print("Model loaded: \(activeModel.name)")
            print("  Temporal frames: \(metadata.temporalFrames)")
            print("  Goal conditioning: \(metadata.requiresGoalPoint)")
            print("  Buffer size: \(maxBufferSize)")
            
            // 224x224 input for all models
            modelInputSize = CGSize(width: 224, height: 224)
            setupModelInputTransform()
            
            // Force 3D goal conditioning
            goalDimension = 3
            
            // Clear goal point if switching to non-point-conditioned model
            if metadata.requiresGoalPoint == false {
                currentGoalPoint = nil
            }
        } catch {
            model = nil
            modelMetadata = nil
            frameBuffer.removeAll()
            hasRunFirstInference = false
            // maxBufferSize stays at 3
        }
    }
    
    // MARK: - Transform Setup (Similar to ARViewContainer approach)
    private func setupModelInputTransform() {
        let normalizeTransform = CGAffineTransform(scaleX: 1.0, y: 1.0)
        let scaleTransform = CGAffineTransform(scaleX: modelInputSize.width, y: modelInputSize.height)
        
        modelInputTransform = normalizeTransform.concatenating(scaleTransform)
    }
    
    // MARK: - Model Management Integration
    var hasAvailableModel: Bool {
        return modelManager.hasAvailableModel && model != nil
    }
    
    var requiresGoalPoint: Bool {
        return modelMetadata?.requiresGoalPoint ?? false
    }
    
    var isPointConditioned: Bool {
        return modelMetadata?.modelType == .pointConditioned
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
            // Current logic
            // camera: x right, y up, z back
            // labels: x left, y forward, z down
            // Mapping: x = -x_cam, y = -z_cam, z = -y_cam
            // We add 0.02 to the y coordinate since training data is shifted forward a bit.
            return [-p_c4.x, -p_c4.z + 0.02, -p_c4.y] 
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
        guard !isInferencePending else {
            print("[MLInference] Proximity reached but inference already pending - skipping")
            return
        }
        proximityReached = true
        print("[MLInference] Proximity reached - inference will trigger with next frame (firstInference: \(hasRunFirstInference))")
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
        
        // ALWAYS buffer frames (rolling 3-frame buffer)
        do {
            let processedFrame = try processFrame(pixelBuffer, targetSize: CGSize(width: 224, height: 224), debugPrefix: "buffered")
            let goalPointArray = metadata.requiresGoalPoint ? getGoalPointForModel() : nil
            let bufferEntry = FrameBufferEntry(mlArray: processedFrame, goalPoint: goalPointArray)
            
            frameBuffer.append(bufferEntry)
            
            // Maintain rolling buffer of 3 frames
            if frameBuffer.count > maxBufferSize {
                frameBuffer.removeFirst(frameBuffer.count - maxBufferSize)
            }
        } catch {
            print("ERROR: Failed to buffer frame: \(error)")
            return
        }
        
        // Run inference if:
        // 1. This is the first inference (to create initial target cube), OR
        // 2. Proximity is reached AND we haven't just run inference
        let isFirstInference = !hasRunFirstInference && frameBuffer.count >= maxBufferSize
        let isProximityTriggered = proximityReached && !isInferencePending
        let shouldRunInference = isFirstInference || isProximityTriggered
        
        if debugLoggingEnabled && frameBuffer.count == maxBufferSize && !shouldRunInference {
            print("[MLInference] Buffer full (\(frameBuffer.count)) but not triggering: firstInference=\(hasRunFirstInference), proximity=\(proximityReached), pending=\(isInferencePending)")
        }
        
        guard shouldRunInference else {
            return
        }
        
        // Ensure we have a model loaded
        guard let model = model else {
            print("ERROR: No model loaded for inference")
            return
        }
        
        // Mark inference as pending
        isInferencePending = true
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
                        if !self.hasRunFirstInference {
                            self.hasRunFirstInference = true
                            print("[MLInference] First inference complete - target cube should now be visible")
                        }
                    }
                } catch {
                    print("ERROR: Model inference failed: \(error)")
                    DispatchQueue.main.async {
                        self.isInferencePending = false
                    }
                }
            }
        }
    }
    
    // MARK: - Dynamic Input Preparation
    private func prepareModelInputFromBuffer(metadata: ModelMetadata) throws -> MLFeatureProvider {
        print("DEBUG: Preparing input from buffer for \(metadata.modelType.displayName) model")
        
        guard !frameBuffer.isEmpty else {
            throw NSError(domain: "MLInferenceManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Frame buffer is empty"])
        }
        
        switch metadata.modelType {
        case .pointConditioned:
            return try prepareVQBeTInputFromBuffer(metadata: metadata)
        case .standard:
            return try prepareLegacyInputFromBuffer(metadata: metadata)
        }
    }
    
    private func prepareModelInput(_ pixelBuffer: CVPixelBuffer, metadata: ModelMetadata) throws -> MLFeatureProvider {
        print("DEBUG: Preparing input for \(metadata.modelType.displayName) model")
        switch metadata.modelType {
        case .pointConditioned:
            return try prepareVQBeTInput(pixelBuffer, metadata: metadata)
        case .standard:
            return try prepareLegacyInput(pixelBuffer, metadata: metadata)
        }
    }
    
    private func prepareVQBeTInput(_ pixelBuffer: CVPixelBuffer, metadata: ModelMetadata) throws -> MLFeatureProvider {
        guard let goalPointArray = getGoalPointForModel() else {
            throw NSError(domain: "MLInferenceManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Goal point required for point-conditioned model"])
        }
        
        // Get input names from metadata
        let imageInputName = metadata.getImageInputName() ?? "camera_image"
        let goalInputName = metadata.getGoalInputName() ?? "goal_point"
        
        // Process current frame and add to buffer
        let processedFrame = try processFrame(pixelBuffer, targetSize: CGSize(width: 224, height: 224), debugPrefix: "point_conditioned")
        let bufferEntry = FrameBufferEntry(mlArray: processedFrame, goalPoint: goalPointArray)
        frameBuffer.append(bufferEntry)
        
        // Trim buffer to maxBufferSize
        if frameBuffer.count > maxBufferSize {
            frameBuffer.removeFirst(frameBuffer.count - maxBufferSize)
        }
        
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
        
        print("DEBUG: Point-conditioned model - temporalFrames: \(temporalFrames), expectedRank: \(expectedRank), bufferSize: \(frameBuffer.count)")
        
        // Build image array based on temporal requirements
        let imageArray: MLMultiArray
        if temporalFrames > 1 {
            // Temporal model: stack frames into [1,T,3,H,W]
            let framesToUse = min(temporalFrames, frameBuffer.count)
            let paddingNeeded = temporalFrames - framesToUse
            
            imageArray = try MLMultiArray(shape: [1, NSNumber(value: temporalFrames), 3, 224, 224], dataType: .float32)
            
            // Pad with repeated first frame if needed
            for t in 0..<paddingNeeded {
                let srcFrame = frameBuffer[0].mlArray
                for c in 0..<3 {
                    for h in 0..<224 {
                        for w in 0..<224 {
                            let value = srcFrame[[0, NSNumber(value: c), NSNumber(value: h), NSNumber(value: w)]]
                            imageArray[[0, NSNumber(value: t), NSNumber(value: c), NSNumber(value: h), NSNumber(value: w)]] = value
                        }
                    }
                }
            }
            
            // Copy actual frames
            for (idx, entry) in frameBuffer.suffix(framesToUse).enumerated() {
                let t = paddingNeeded + idx
                let srcFrame = entry.mlArray
                for c in 0..<3 {
                    for h in 0..<224 {
                        for w in 0..<224 {
                            let value = srcFrame[[0, NSNumber(value: c), NSNumber(value: h), NSNumber(value: w)]]
                            imageArray[[0, NSNumber(value: t), NSNumber(value: c), NSNumber(value: h), NSNumber(value: w)]] = value
                        }
                    }
                }
            }
        } else {
            // Single-frame model: check if we need to add temporal dimension
            let latestFrame = frameBuffer.last!.mlArray
            
            if expectedRank == 5 {
                // Model expects [1,1,3,H,W] - add temporal dimension
                imageArray = try MLMultiArray(shape: [1, 1, 3, 224, 224], dataType: .float32)
                for c in 0..<3 {
                    for h in 0..<224 {
                        for w in 0..<224 {
                            let value = latestFrame[[0, NSNumber(value: c), NSNumber(value: h), NSNumber(value: w)]]
                            imageArray[[0, 0, NSNumber(value: c), NSNumber(value: h), NSNumber(value: w)]] = value
                        }
                    }
                }
            } else {
                // Model expects [1,3,H,W] - use directly
                imageArray = latestFrame
            }
        }
        
        // Prepare goal array based on model's expected shape
        let goalArray: MLMultiArray = {
            if let d = model?.modelDescription.inputDescriptionsByName[goalInputName],
               d.type == .multiArray,
               let shape = d.multiArrayConstraint?.shape {
                let dims = shape.map { $0.intValue }
                
                // Temporal goal: [1,T,3]
                if dims.count == 3 && dims[1] > 1 && dims[2] == 3 {
                    let arr = try? MLMultiArray(shape: shape, dataType: .float32)
                    if let arr = arr {
                        let framesToUse = min(dims[1], frameBuffer.count)
                        let paddingNeeded = dims[1] - framesToUse
                        
                        // Pad with repeated first goal if needed
                        for t in 0..<paddingNeeded {
                            if let firstGoal = frameBuffer.first?.goalPoint {
                                for i in 0..<3 { arr[[0, NSNumber(value: t), NSNumber(value: i)]] = NSNumber(value: firstGoal[i]) }
                            }
                        }
                        
                        // Copy actual goals
                        for (idx, entry) in frameBuffer.suffix(framesToUse).enumerated() {
                            let t = paddingNeeded + idx
                            if let goal = entry.goalPoint {
                                for i in 0..<3 { arr[[0, NSNumber(value: t), NSNumber(value: i)]] = NSNumber(value: goal[i]) }
                            }
                        }
                        return arr
                    }
                } else if dims.count == 3 && dims[2] == 3 {
                    // Shape [1,1,3]
                    let arr = try? MLMultiArray(shape: shape, dataType: .float32)
                    if let arr = arr {
                        for i in 0..<3 { arr[[0, 0, i] as [NSNumber]] = NSNumber(value: goalPointArray[i]) }
                        return arr
                    }
                } else if dims.count == 2 && dims == [1,3] {
                    let arr = try? MLMultiArray(shape: shape, dataType: .float32)
                    if let arr = arr {
                        for i in 0..<3 { arr[[0, i] as [NSNumber]] = NSNumber(value: goalPointArray[i]) }
                        return arr
                    }
                } else if dims.count == 1 && dims.first == 3 {
                    let arr = try? MLMultiArray(shape: shape, dataType: .float32)
                    if let arr = arr {
                        for i in 0..<3 { arr[[i] as [NSNumber]] = NSNumber(value: goalPointArray[i]) }
                        return arr
                    }
                }
            }
            // Fallback: [1,3]
            let arr = try? MLMultiArray(shape: [1, 3], dataType: .float32)
            if let arr = arr {
                for i in 0..<3 { arr[[0, i] as [NSNumber]] = NSNumber(value: goalPointArray[i]) }
                return arr
            }
            // As last resort, create [3]
            let arr3 = try! MLMultiArray(shape: [3], dataType: .float32)
            for i in 0..<3 { arr3[[i] as [NSNumber]] = NSNumber(value: goalPointArray[i]) }
            return arr3
        }()
        
        return try MLDictionaryFeatureProvider(dictionary: [
            imageInputName: MLFeatureValue(multiArray: imageArray),
            goalInputName: MLFeatureValue(multiArray: goalArray)
        ])
    }
    
    private func prepareLegacyInput(_ pixelBuffer: CVPixelBuffer, metadata: ModelMetadata) throws -> MLFeatureProvider {
        print("DEBUG: prepareLegacyInput called")
        
        // Process frame using unified method
        let processedFrame = try processFrame(pixelBuffer, targetSize: modelInputSize, debugPrefix: "standard")
        print("DEBUG: Frame processed, shape: \(processedFrame.shape)")
        
        // For legacy models, determine if we need to add temporal dimension [1,1,3,H,W]
        let inputName = metadata.getImageInputName() ?? "x_1"
        let inputArray: MLMultiArray
        
        if let d = model?.modelDescription.inputDescriptionsByName[inputName],
           d.type == .multiArray,
           let shape = d.multiArrayConstraint?.shape {
            print("DEBUG: Model expects shape: \(shape), rank: \(shape.count)")
            
            if shape.count == 5 {
                // Model expects 5D [1,1,3,H,W]
                let height = Int(modelInputSize.height)
                let width = Int(modelInputSize.width)
                inputArray = try MLMultiArray(shape: [1, 1, 3, NSNumber(value: height), NSNumber(value: width)], dataType: .float32)
                
                print("DEBUG: Converting [1,3,H,W] to [1,1,3,H,W]")
                
                // Copy from [1,3,H,W] to [1,1,3,H,W]
                for c in 0..<3 {
                    for h in 0..<height {
                        for w in 0..<width {
                            let value = processedFrame[[0, NSNumber(value: c), NSNumber(value: h), NSNumber(value: w)]]
                            inputArray[[0, 0, NSNumber(value: c), NSNumber(value: h), NSNumber(value: w)]] = value
                        }
                    }
                }
            } else {
                // Model expects 4D [1,3,H,W] - use directly
                print("DEBUG: Using [1,3,H,W] directly")
                inputArray = processedFrame
            }
        } else {
            print("DEBUG: Could not determine model shape, using [1,3,H,W]")
            inputArray = processedFrame
        }
        
        print("DEBUG: Creating feature provider with input name: \(inputName)")
        return try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: inputArray)])
    }
    
    // MARK: - Buffer-based Input Preparation Methods
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
        
        print("DEBUG: Using buffered frames - temporalFrames: \(temporalFrames), bufferSize: \(frameBuffer.count)")
        
        // Build image array from buffer
        let imageArray: MLMultiArray
        if temporalFrames > 1 {
            // Temporal model: use last N frames from buffer
            let framesToUse = min(temporalFrames, frameBuffer.count)
            let paddingNeeded = temporalFrames - framesToUse
            
            imageArray = try MLMultiArray(shape: [1, NSNumber(value: temporalFrames), 3, 224, 224], dataType: .float32)
            
            // Pad with repeated first frame if needed
            if paddingNeeded > 0 {
                let srcFrame = frameBuffer[0].mlArray
                for t in 0..<paddingNeeded {
                    for c in 0..<3 {
                        for h in 0..<224 {
                            for w in 0..<224 {
                                let value = srcFrame[[0, NSNumber(value: c), NSNumber(value: h), NSNumber(value: w)]]
                                imageArray[[0, NSNumber(value: t), NSNumber(value: c), NSNumber(value: h), NSNumber(value: w)]] = value
                            }
                        }
                    }
                }
            }
            
            // Copy actual frames from buffer
            for (idx, entry) in frameBuffer.suffix(framesToUse).enumerated() {
                let t = paddingNeeded + idx
                let srcFrame = entry.mlArray
                for c in 0..<3 {
                    for h in 0..<224 {
                        for w in 0..<224 {
                            let value = srcFrame[[0, NSNumber(value: c), NSNumber(value: h), NSNumber(value: w)]]
                            imageArray[[0, NSNumber(value: t), NSNumber(value: c), NSNumber(value: h), NSNumber(value: w)]] = value
                        }
                    }
                }
            }
        } else {
            // Single-frame: use latest from buffer
            let latestFrame = frameBuffer.last!.mlArray
            
            if expectedRank == 5 {
                imageArray = try MLMultiArray(shape: [1, 1, 3, 224, 224], dataType: .float32)
                for c in 0..<3 {
                    for h in 0..<224 {
                        for w in 0..<224 {
                            let value = latestFrame[[0, NSNumber(value: c), NSNumber(value: h), NSNumber(value: w)]]
                            imageArray[[0, 0, NSNumber(value: c), NSNumber(value: h), NSNumber(value: w)]] = value
                        }
                    }
                }
            } else {
                imageArray = latestFrame
            }
        }
        
        // Prepare goal array
        let goalArray: MLMultiArray = {
            if let d = model?.modelDescription.inputDescriptionsByName[goalInputName],
               d.type == .multiArray,
               let shape = d.multiArrayConstraint?.shape {
                let dims = shape.map { $0.intValue }
                
                if dims.count == 3 && dims[1] > 1 && dims[2] == 3 {
                    let arr = try? MLMultiArray(shape: shape, dataType: .float32)
                    if let arr = arr {
                        for t in 0..<dims[1] {
                            for i in 0..<3 { arr[[0, NSNumber(value: t), NSNumber(value: i)]] = NSNumber(value: goalPointArray[i]) }
                        }
                        return arr
                    }
                } else if dims.count == 3 && dims[2] == 3 {
                    let arr = try? MLMultiArray(shape: shape, dataType: .float32)
                    if let arr = arr {
                        for i in 0..<3 { arr[[0, 0, i] as [NSNumber]] = NSNumber(value: goalPointArray[i]) }
                        return arr
                    }
                } else if dims.count == 2 && dims == [1,3] {
                    let arr = try? MLMultiArray(shape: shape, dataType: .float32)
                    if let arr = arr {
                        for i in 0..<3 { arr[[0, i] as [NSNumber]] = NSNumber(value: goalPointArray[i]) }
                        return arr
                    }
                }
            }
            let arr = try! MLMultiArray(shape: [1, 3], dataType: .float32)
            for i in 0..<3 { arr[[0, i] as [NSNumber]] = NSNumber(value: goalPointArray[i]) }
            return arr
        }()
        
        return try MLDictionaryFeatureProvider(dictionary: [
            imageInputName: MLFeatureValue(multiArray: imageArray),
            goalInputName: MLFeatureValue(multiArray: goalArray)
        ])
    }
    
    private func prepareLegacyInputFromBuffer(metadata: ModelMetadata) throws -> MLFeatureProvider {
        let inputName = metadata.getImageInputName() ?? "x_1"
        let latestFrame = frameBuffer.last!.mlArray
        let inputArray: MLMultiArray
        
        if let d = model?.modelDescription.inputDescriptionsByName[inputName],
           d.type == .multiArray,
           let shape = d.multiArrayConstraint?.shape {
            
            if shape.count == 5 {
                let height = 224
                let width = 224
                inputArray = try MLMultiArray(shape: [1, 1, 3, NSNumber(value: height), NSNumber(value: width)], dataType: .float32)
                
                for c in 0..<3 {
                    for h in 0..<height {
                        for w in 0..<width {
                            let value = latestFrame[[0, NSNumber(value: c), NSNumber(value: h), NSNumber(value: w)]]
                            inputArray[[0, 0, NSNumber(value: c), NSNumber(value: h), NSNumber(value: w)]] = value
                        }
                    }
                }
            } else {
                inputArray = latestFrame
            }
        } else {
            inputArray = latestFrame
        }
        
        return try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: inputArray)])
    }
    
    // MARK: - Unified Frame Processing
    private func processFrame(_ pixelBuffer: CVPixelBuffer, targetSize: CGSize, debugPrefix: String) throws -> MLMultiArray {
        let width = Int(targetSize.width)
        let height = Int(targetSize.height)
        
        // Create output pixel buffer
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        
        var outputPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_32ARGB,
            attributes as CFDictionary,
            &outputPixelBuffer
        )
        
        guard status == kCVReturnSuccess, let outputBuffer = outputPixelBuffer else {
            throw NSError(domain: "MLInferenceManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create output pixel buffer"])
        }
        
        // Process image
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(outputBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(outputBuffer, [])
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        
        let inputImage = CIImage(cvPixelBuffer: pixelBuffer)
        let inputImageSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let scaleX = targetSize.width / inputImageSize.width
        let scaleY = targetSize.height / inputImageSize.height
        let scaleTransform = CGAffineTransform(scaleX: scaleX, y: scaleY)
        
        var scaledImage = inputImage.transformed(by: scaleTransform)
        if applyServerImageOrientation {
            scaledImage = scaledImage.oriented(.down)
        }

        // Save original scaled image for debugging
        saveDebugFrame(scaledImage, prefix: "\(debugPrefix)_original")

        // Apply gripper overlay if enabled and USB streaming is off
        if shouldShowGripperOverlay() {
            scaledImage = applyGripperOverlay(to: scaledImage)
            saveDebugFrame(scaledImage, prefix: "\(debugPrefix)_with_overlay")
        }

        let cropRect = CGRect(origin: .zero, size: targetSize)
        ciContext.render(scaledImage, to: outputBuffer, bounds: cropRect, colorSpace: CGColorSpaceCreateDeviceRGB())
        
        // Convert to MLMultiArray as single frame [1,3,H,W] for buffering
        return try convertPixelBufferToMLMultiArray(outputBuffer, width: width, height: height)
    }
    
    // MARK: - Unified Pixel Buffer to MLMultiArray Conversion (Accelerate Optimized)
    private func convertPixelBufferToMLMultiArray(_ pixelBuffer: CVPixelBuffer, width: Int, height: Int) throws -> MLMultiArray {
        let inputArray = try MLMultiArray(shape: [1, 3, NSNumber(value: height), NSNumber(value: width)], dataType: .float32)
        
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
        
        // Simple approach for non-point conditioned models - match old working code
        if metadata.modelType == .standard {
            // Prefer primary output name when available
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
                let isGripperClosed = currentGripperValue < 0.6
                
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
                
                // Ensure visualization is ready and feed pose
                if let arManager = self?.arVisualizationManager, jointPositions.count >= 6 {
                    arManager.ensureVisualizationReady()
                    arManager.updatePoseFromMLOutput(jointPositions, timestamp: self?.lastInferenceTime ?? CACurrentMediaTime())
                }
                
                // Joint actions are automatically sent via USB stream (transform to robot frame)
                if jointPositions.count >= 7 {
                    let src = Array(jointPositions.prefix(7))
                    if self?.enableTransformDebug == true {
                        let report = ActionTransformUtils.debugTransformReport(src, rotationUnit: self?.rotationUnit ?? .eulerXYZ)
                        print("Coordinate Transform: \(report)")
                    }
                    let robot = ActionTransformUtils.toRobotActions(src, rotationUnit: self?.rotationUnit ?? .eulerXYZ)
                    print("Robot actions: [\(robot.map { String(format: "%.3f", $0) }.joined(separator: ", "))]")
                    // Joint actions are now sent embedded in the main USB stream
                }
            }
            
            let positionString = jointPositions.map { String(format: "%.3f", $0) }.joined(separator: ", ")
            let modelName = modelManager.activeModel?.name ?? "Unknown"
            print("[\(modelName)] Standard: [\(positionString)] (\(String(format: "%.1f", inferenceTime * 1000))ms)")
            
        } else {
            // Point-conditioned models
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
                let isGripperClosed = currentGripperValue < 0.6
                
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
                
                // Ensure visualization is ready and feed pose
                if let arManager = self?.arVisualizationManager, jointPositions.count >= 6 {
                    arManager.ensureVisualizationReady()
                    arManager.updatePoseFromMLOutput(jointPositions, timestamp: self?.lastInferenceTime ?? CACurrentMediaTime())
                }
                
                // Joint actions are automatically sent via USB stream (transform to robot frame)
                if jointPositions.count >= 7 {
                    let src = Array(jointPositions.prefix(7))
                    let robot = ActionTransformUtils.toRobotActions(src, rotationUnit: self?.rotationUnit ?? .eulerXYZ)
                    print("Robot actions: [\(robot.map { String(format: "%.3f", $0) }.joined(separator: ", "))]")
                    // Joint actions are now sent embedded in the main USB stream
                }
            }
            
            let positionString = jointPositions.map { String(format: "%.3f", $0) }.joined(separator: ", ")
            let modelName = modelManager.activeModel?.name ?? "Unknown"
            let modelTypeStr = metadata.modelType.displayName
            print("[\(modelName)] \(modelTypeStr): [\(positionString)] (\(String(format: "%.1f", inferenceTime * 1000))ms)")
            
            // Log goal point status for point-conditioned models
            if metadata.requiresGoalPoint, let goalPoint = currentGoalPoint {
                print("Goal: [\(String(format: "%.3f", goalPoint.x)), \(String(format: "%.3f", goalPoint.y)), \(String(format: "%.3f", goalPoint.z))]")
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
    }
    
    func disableInference() {
        isInferenceEnabled = false
        latestResult = nil
        print("Inference disabled")
    }
    
    func resetInferenceState() {
        hasRunFirstInference = false
        proximityReached = false
        isInferencePending = false
        frameBuffer.removeAll()
        print("Inference state reset - ready for new recording")
    }
    
    // MARK: - Manual Inference Trigger
    func triggerInferenceManually() {
        guard isInferenceEnabled,
              let metadata = modelMetadata,
              frameBuffer.count >= maxBufferSize else {
            print("[MLInference] Cannot trigger manually - buffer incomplete (\(frameBuffer.count)/\(maxBufferSize)) or inference disabled")
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
        
        // Mark inference as pending
        isInferencePending = true
        
        print("[MLInference] Manual trigger - running inference with buffered frames (\(frameBuffer.count))")
        
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
