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
    private var goalPointQueue = DispatchQueue(label: "GoalPointQueue", qos: .userInitiated)
    
    // Goal conditioning mode (matching Python goal_dim)
    private var goalDimension: Int = 2  // Default to 2D mode, can be 3 for 3D mode
    
    // MARK: - Model Management
    private var modelManager: ModelManager
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - AR Visualization Integration
    weak var arVisualizationManager: ARVisualizationManager?
    
    // MARK: - Odometry Point Tracking
    @Published var odometryTracker = OdometryPointTracker()
    @Published var enableOdometryTracking: Bool = true
    
    // MARK: - Frame Processing (Taken from ARViewContainer)
    private let ciContext: CIContext
    private let modelInputSize = CGSize(width: 256, height: 256)
    private var modelInputTransform: CGAffineTransform?
    
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
    // Apply server-style image orientation (Record3D publisher does rotations/mirrors)
    var applyServerImageOrientation: Bool = true
    
    // Initialization
    init(modelManager: ModelManager) {
        self.modelManager = modelManager
        self.ciContext = CIContext()
        loadActiveModel()
        
        // Listen for active model changes
        modelManager.$activeModel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (activeModel: ModelInfo?) in
                self?.loadActiveModel()
            }
            .store(in: &cancellables)
    }
    
    deinit {
        // Ensure cleanup of resources
        model = nil
        latestResult = nil
        cancellables.removeAll()
    }
    
    // MARK: - Model Loading
    private func loadActiveModel() {
        guard let activeModel = modelManager.activeModel,
              activeModel.compilationStatus.isCompiled else {
            // No active compiled model available
            model = nil
            modelMetadata = nil
            return
        }
        
        do {
            let loadedModel = try modelManager.loadModel(for: activeModel)
            model = loadedModel
            
            // Extract model metadata for type detection
            modelMetadata = try ModelMetadata(from: loadedModel)
            
            setupModelInputTransform()
            
            // Set goal dimension based on model type
            if modelMetadata?.modelType == .pointConditioned {
                goalDimension = 3  // VQ-BeT models expect 3D coordinates
            } else {
                goalDimension = 2  // Standard models use 2D
            }
            
            // Clear goal point if switching to non-point-conditioned model
            if modelMetadata?.requiresGoalPoint == false {
                currentGoalPoint = nil
            }
        } catch {
            model = nil
            modelMetadata = nil
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
    func setGoalPoint(_ point: simd_float3) {
        // Set goal point synchronously since UI needs immediate feedback
        self.currentGoalPoint = point
    }
    
    func clearGoalPoint() {
        currentGoalPoint = nil
        odometryTracker.resetTracking()
    }
    
    // MARK: - Odometry Integration Methods
    
    /// Start odometry tracking with screen point (matching Python workflow)
    func startOdometryTrackingWithScreenPoint(
        screenPoint: CGPoint,
        in view: UIView,
        arFrame: ARFrame,
        depthMap: CVPixelBuffer?
    ) -> Bool {
        guard enableOdometryTracking else {
            return false
        }
        
        guard let session = getARSession() else {
            return false
        }
        
        let success = odometryTracker.startTracking(
            screenPoint: screenPoint,
            in: view,
            arFrame: arFrame,
            session: session,
            depthMap: depthMap
        )
        
        // Odometry tracking started
        
        return success
    }
    
    /// Update odometry tracking (step_n > 0 equivalent)
    func updateOdometryTracking(arFrame: ARFrame) {
        // Always update actual device pose for non-point-conditioned model deviation tracking
        arVisualizationManager?.updateActualDevicePose(from: arFrame)
        
        guard enableOdometryTracking,
              odometryTracker.trackingState == .tracking else {
            return
        }
        
        // Get updated odometry result and pass to visualization
        if let odometryResult = odometryTracker.updateTracking(currentFrame: arFrame) {
            // Update visualization with new target position from odometry
            arVisualizationManager?.updateTargetFromOdometry(odometryResult)
        }
    }
    
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
            // Prefer odometry-tracked world point; else use static world point if set
            let worldPoint: simd_float3?
            if enableOdometryTracking, let result = odometryTracker.currentResult {
                worldPoint = result.world3DPoint
            } else {
                worldPoint = currentGoalPoint
            }
            guard let p_w = worldPoint else { return nil }
            // World (ARKit) → Camera
            let T_wc = frame.camera.transform
            let T_cw = simd_inverse(T_wc)
            let p_c4 = simd_mul(T_cw, simd_float4(p_w.x, p_w.y, p_w.z, 1.0))
            // labels.json mapping from camera frame
            return [-p_c4.x, p_c4.z, p_c4.y]
        }
        // 2D goals: use odometry normalized 2D if available; else fallback to center
        if enableOdometryTracking, let result = odometryTracker.currentResult {
            return [Float(result.normalized2DPoint.x), Float(result.normalized2DPoint.y)]
        } else {
            return [0.5, 0.5]
        }
    }
    
    func convertScreenToWorld(_ screenPoint: CGPoint, in view: UIView, arSession: ARSession? = nil, depthMap: CVPixelBuffer? = nil) -> simd_float3? {
        guard let session = arSession ?? getARSession(),
              let currentFrame = session.currentFrame else {
            return nil
        }
        
        // Method 1: Try hit testing first (most accurate for surfaces)
        let normalizedPoint = CGPoint(
            x: screenPoint.x / view.bounds.width,
            y: screenPoint.y / view.bounds.height
        )
        
        // Create hit test query for existing planes or surfaces
        let query = currentFrame.raycastQuery(from: normalizedPoint, allowing: .existingPlaneGeometry, alignment: .any)
        let results = session.raycast(query)
        if let result = results.first {
            let worldTransform = result.worldTransform
            return simd_float3(worldTransform.columns.3.x, worldTransform.columns.3.y, worldTransform.columns.3.z)
        }
        
        // Method 2: Use depth map if available
        if let depth = depthMap ?? currentFrame.sceneDepth?.depthMap {
            if let worldPoint = convertScreenToWorldUsingDepth(screenPoint, in: view, frame: currentFrame, depthMap: depth) {
                return worldPoint
            }
        }
        
        // Method 3: Fallback to estimated depth
        return convertScreenToWorldEstimated(screenPoint, in: view, frame: currentFrame, estimatedDepth: 1.0)
    }
    
    private func convertScreenToWorldUsingDepth(_ screenPoint: CGPoint, in view: UIView, frame: ARFrame, depthMap: CVPixelBuffer) -> simd_float3? {
        // Convert screen point to depth map coordinates
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        
        let normalizedX = screenPoint.x / view.bounds.width
        let normalizedY = screenPoint.y / view.bounds.height
        
        let depthX = Int(normalizedX * CGFloat(depthWidth))
        let depthY = Int(normalizedY * CGFloat(depthHeight))
        
        // Ensure coordinates are within bounds
        guard depthX >= 0, depthX < depthWidth, depthY >= 0, depthY < depthHeight else {
            return nil
        }
        
        // Read depth value
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let depthPointer = baseAddress.assumingMemoryBound(to: Float32.self)
        
        let pixelOffset = depthY * (bytesPerRow / MemoryLayout<Float32>.stride) + depthX
        let depth = depthPointer[pixelOffset]
        
        guard depth > 0.1 && depth < 10.0 else { // Valid depth range
            return nil
        }
        
        return convertScreenToWorldEstimated(screenPoint, in: view, frame: frame, estimatedDepth: depth)
    }
    
    private func convertScreenToWorldEstimated(_ screenPoint: CGPoint, in view: UIView, frame: ARFrame, estimatedDepth: Float) -> simd_float3? {
        let cameraIntrinsics = frame.camera.intrinsics
        let cameraTransform = frame.camera.transform
        
        // Convert screen coordinates to normalized coordinates
        let normalizedX = (screenPoint.x / view.bounds.width) * 2.0 - 1.0
        let normalizedY = 1.0 - (screenPoint.y / view.bounds.height) * 2.0
        
        // Convert to camera space using inverse intrinsics
        let fx = cameraIntrinsics.columns.0.x
        let fy = cameraIntrinsics.columns.1.y
        let cx = cameraIntrinsics.columns.2.x
        let cy = cameraIntrinsics.columns.2.y
        
        let imageWidth = Float(view.bounds.width)
        let imageHeight = Float(view.bounds.height)
        
        let cameraX = (Float(screenPoint.x) - cx) / fx * estimatedDepth
        let cameraY = (Float(screenPoint.y) - cy) / fy * estimatedDepth
        let cameraZ = -estimatedDepth // Negative Z in camera coordinates
        
        let cameraPoint = simd_float4(cameraX, cameraY, cameraZ, 1.0)
        
        // Transform to world coordinates
        let worldPoint = simd_mul(cameraTransform, cameraPoint)
        
        return simd_float3(worldPoint.x, worldPoint.y, worldPoint.z)
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
    
    // MARK: - Inference Methods (Using existing frame processing patterns)
    func performInference(on pixelBuffer: CVPixelBuffer, arFrame: ARFrame?, timestamp: CFTimeInterval = CACurrentMediaTime()) {
        // Update odometry tracking to have consistent goal point for model input preparation
        if let frame = arFrame {
            updateOdometryTracking(arFrame: frame)
        }
        
        performInference(on: pixelBuffer, timestamp: timestamp)
    }
    
    func performInference(on pixelBuffer: CVPixelBuffer, timestamp: CFTimeInterval = CACurrentMediaTime()) {
        guard isInferenceEnabled,
              let model = model,
              let metadata = modelMetadata else { return }
        
        // Check if goal point is required but not set
        if metadata.requiresGoalPoint && currentGoalPoint == nil {
            return // Skip inference until goal point is set
        }
        
        if timestamp - lastInferenceTime < inferenceFrequency.interval {
            return
        }
        
        lastInferenceTime = timestamp
        
        // Prepare input synchronously to avoid capturing non-sendable CVPixelBuffer
        let modelInput: MLFeatureProvider
        do {
            modelInput = try prepareModelInput(pixelBuffer, metadata: metadata)
        } catch {
            return
        }
        
        inferenceQueue.async { [weak self, modelInput, model] in
            guard let self = self else { return }
            
            let startTime = CACurrentMediaTime()
            
            autoreleasepool {
                do {
                    let output = try model.prediction(from: modelInput)
                    
                    let inferenceTime = CACurrentMediaTime() - startTime
                    self.processInferenceResults(output, inferenceTime: inferenceTime)
                } catch {
                    // Inference failed - continue processing
                }
            }
        }
    }
    
    // MARK: - Dynamic Input Preparation
    private func prepareModelInput(_ pixelBuffer: CVPixelBuffer, metadata: ModelMetadata) throws -> MLFeatureProvider {
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
        
        // Determine expected image input rank from the actual model description (fallback to 4)
        let expectedImageRank: Int = {
            if let d = model?.modelDescription.inputDescriptionsByName[imageInputName],
               d.type == .multiArray,
               let shape = d.multiArrayConstraint?.shape {
                return shape.count
            }
            return 4
        }()
        
        // Process image to match expected rank (support 4D [1,3,H,W] and 5D [1,1,3,H,W])
        let imageArray = try processFrameForVQBeT(
            pixelBuffer,
            inputSize: metadata.imageInputSize ?? CGSize(width: 256, height: 256),
            expectedRank: expectedImageRank
        )
        
        // Prepare goal array to match model's expected shape when available
        let goalArray: MLMultiArray = {
            if let d = model?.modelDescription.inputDescriptionsByName[goalInputName],
               d.type == .multiArray,
               let shape = d.multiArrayConstraint?.shape {
                let dims = shape.map { $0.intValue }
                if dims.count == 3, let last = dims.last, last == 3 {
                    // Shape [1,1,3]
                    let arr = try? MLMultiArray(shape: shape, dataType: .float32)
                    if let arr = arr {
                        for i in 0..<3 { arr[[0, 0, i] as [NSNumber]] = NSNumber(value: goalPointArray[i]) }
                        return arr
                    }
                } else if dims.count == 2, dims == [1,3] {
                    let arr = try? MLMultiArray(shape: shape, dataType: .float32)
                    if let arr = arr {
                        for i in 0..<3 { arr[[0, i] as [NSNumber]] = NSNumber(value: goalPointArray[i]) }
                        return arr
                    }
                } else if dims.count == 1, dims.first == 3 {
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
        // Simple approach matching old working code - no coordinate transformations
        let inputArray = try processFrameForInference(pixelBuffer)
        // Prefer metadata-driven input name if available
        let inputName = metadata.getImageInputName() ?? "x_1"
        return try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: inputArray)])
    }
    
    // MARK: - VQ-BeT Frame Processing
    private func processFrameForVQBeT(_ pixelBuffer: CVPixelBuffer, inputSize: CGSize, expectedRank: Int) throws -> MLMultiArray {
        let width = Int(inputSize.width)
        let height = Int(inputSize.height)
        
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
        let scaleX = inputSize.width / inputImageSize.width
        let scaleY = inputSize.height / inputImageSize.height
        let scaleTransform = CGAffineTransform(scaleX: scaleX, y: scaleY)
        
        var scaledImage = inputImage.transformed(by: scaleTransform)
        if applyServerImageOrientation {
            // Server path rotates images by 180° overall; replicate using EXIF .down
            scaledImage = scaledImage.oriented(.down)
        }
        let cropRect = CGRect(origin: .zero, size: inputSize)
        
        ciContext.render(scaledImage, to: outputBuffer, bounds: cropRect, colorSpace: CGColorSpaceCreateDeviceRGB())
        print("Image processed for VQ-BeT: \(inputSize)")
        
        // Convert to MLMultiArray for VQ-BeT format
        // Support 4D [1,3,H,W] and 5D [1,1,3,H,W]
        return try convertPixelBufferToVQBeTArray(outputBuffer, width: width, height: height, expectedRank: expectedRank)
    }
    
    private func convertPixelBufferToVQBeTArray(_ pixelBuffer: CVPixelBuffer, width: Int, height: Int, expectedRank: Int) throws -> MLMultiArray {
        let shape: [NSNumber]
        let fiveD = (expectedRank >= 5)
        if fiveD {
            shape = [1, 1, 3, NSNumber(value: height), NSNumber(value: width)]
        } else {
            shape = [1, 3, NSNumber(value: height), NSNumber(value: width)]
        }
        let inputArray = try MLMultiArray(shape: shape, dataType: .float32)
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw NSError(domain: "MLInferenceManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get pixel buffer base address"])
        }
        
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytesPerPixel = 4
        
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                
                let r = Float(buffer[offset + 1]) / 255.0
                let g = Float(buffer[offset + 2]) / 255.0
                let b = Float(buffer[offset + 3]) / 255.0
                
                // VQ-BeT format: either [B, C, H, W] or [B, T, C, H, W] with T=1
                let rIndex = fiveD ? [NSNumber(value: 0), NSNumber(value: 0), NSNumber(value: 0), NSNumber(value: y), NSNumber(value: x)]
                                   : [NSNumber(value: 0), NSNumber(value: 0), NSNumber(value: y), NSNumber(value: x)]
                let gIndex = fiveD ? [NSNumber(value: 0), NSNumber(value: 0), NSNumber(value: 1), NSNumber(value: y), NSNumber(value: x)]
                                   : [NSNumber(value: 0), NSNumber(value: 1), NSNumber(value: y), NSNumber(value: x)]
                let bIndex = fiveD ? [NSNumber(value: 0), NSNumber(value: 0), NSNumber(value: 2), NSNumber(value: y), NSNumber(value: x)]
                                   : [NSNumber(value: 0), NSNumber(value: 2), NSNumber(value: y), NSNumber(value: x)]
                
                inputArray[rIndex] = NSNumber(value: r)
                inputArray[gIndex] = NSNumber(value: g)
                inputArray[bIndex] = NSNumber(value: b)
            }
        }
        
        return inputArray
    }
    
    // MARK: - Legacy Frame Processing (Leveraging ARViewContainer patterns)
    private func processFrameForInference(_ pixelBuffer: CVPixelBuffer) throws -> MLMultiArray {
        // Create output pixel buffer for model input size
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: Int(modelInputSize.width),
            kCVPixelBufferHeightKey as String: Int(modelInputSize.height)
        ]
        
        var outputPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(modelInputSize.width),
            Int(modelInputSize.height),
            kCVPixelFormatType_32ARGB,
            attributes as CFDictionary,
            &outputPixelBuffer
        )
        
        guard status == kCVReturnSuccess, let outputBuffer = outputPixelBuffer else {
            throw NSError(domain: "MLInferenceManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create output pixel buffer"])
        }
        
        // Use Core Image processing (same approach as ARViewContainer)
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(outputBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(outputBuffer, [])
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        
        let inputImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        // Scale to model input size
        let inputSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let scaleX = modelInputSize.width / inputSize.width
        let scaleY = modelInputSize.height / inputSize.height
        let scaleTransform = CGAffineTransform(scaleX: scaleX, y: scaleY)
        
        var scaledImage = inputImage.transformed(by: scaleTransform)
        if applyServerImageOrientation {
            scaledImage = scaledImage.oriented(.down)
        }
        let cropRect = CGRect(origin: .zero, size: modelInputSize)
        
        // Render using the same CIContext approach as ARViewContainer
        ciContext.render(scaledImage, to: outputBuffer, bounds: cropRect, colorSpace: CGColorSpaceCreateDeviceRGB())
        print("Image processed for inference: \(modelInputSize)")
        
        // Convert to MLMultiArray (simplified since we now have consistently formatted data)
        return try convertProcessedPixelBufferToMLMultiArray(outputBuffer)
    }
    
    // MARK: - Simplified Pixel Buffer to MLMultiArray Conversion
    private func convertProcessedPixelBufferToMLMultiArray(_ pixelBuffer: CVPixelBuffer) throws -> MLMultiArray {
        // Explicitly index as [B=1, T=1, C=3, H=256, W=256]
        let inputArray = try MLMultiArray(shape: [1, 1, 3, 256, 256], dataType: .float32)
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw NSError(domain: "MLInferenceManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get pixel buffer base address"])
        }
        
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytesPerPixel = 4 // ARGB format
        
        // Since we're using Core Image processing, we have consistent ARGB format
        for y in 0..<256 {
            for x in 0..<256 {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let r = Float(buffer[offset + 1]) / 255.0
                let g = Float(buffer[offset + 2]) / 255.0
                let b = Float(buffer[offset + 3]) / 255.0
                inputArray[[0, 0, 0, NSNumber(value: y), NSNumber(value: x)]] = NSNumber(value: r)
                inputArray[[0, 0, 1, NSNumber(value: y), NSNumber(value: x)]] = NSNumber(value: g)
                inputArray[[0, 0, 2, NSNumber(value: y), NSNumber(value: x)]] = NSNumber(value: b)
            }
        }
        
        return inputArray
    }
    
    // MARK: - Result Processing
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
            
            // Extract values directly (matching old code)
            let outputCount = min(resultArray.count, 10)
            let jointPositions = (0..<outputCount).map { resultArray[$0].floatValue }
            
            let result = InferenceResult(
                jointPositions: jointPositions,
                inferenceTime: inferenceTime
            )
            
            // Update UI on main thread
            DispatchQueue.main.async { [weak self] in
                self?.latestResult = result
                
                // Ensure visualization is ready and feed pose
                if let arManager = self?.arVisualizationManager, jointPositions.count >= 6 {
                    arManager.prepareVisualizationIfNeeded()
                    arManager.updatePoseFromMLOutput(jointPositions, timestamp: self?.lastInferenceTime ?? CACurrentMediaTime())
                }
                
                // Joint actions are automatically sent via USB stream (transform to robot frame)
                if jointPositions.count >= 7 {
                    let src = Array(jointPositions.prefix(7))
                    if self?.enableTransformDebug == true {
                        let report = ActionTransformUtils.debugTransformReport(src, rotationUnit: self?.rotationUnit ?? .eulerXYZ)
                        print("Coordinate Transform: \(report)")
                    }
                    var robot = ActionTransformUtils.toRobotActions(src, rotationUnit: self?.rotationUnit ?? .eulerXYZ)
                    // Clamp gripper to [0,1]
                    if robot.count >= 7 {
                        robot[6] = max(0.0, min(1.0, robot[6]))
                    }
                    print("Robot actions: [\(robot.map { String(format: "%.3f", $0) }.joined(separator: ", "))]")
                    // Joint actions are now sent embedded in the main USB stream
                }
            }
            
            let positionString = jointPositions.map { String(format: "%.3f", $0) }.joined(separator: ", ")
            let modelName = modelManager.activeModel?.name ?? "Unknown"
            print("[\(modelName)] Standard: [\(positionString)] (\(String(format: "%.1f", inferenceTime * 1000))ms)")
            
        } else {
            // Point-conditioned models - use existing complex logic
            let outputFeatureName = metadata.primaryOutputName ?? output.featureNames.first
            
            guard let outputFeatureName = outputFeatureName,
                  let resultArray = output.featureValue(for: outputFeatureName)?.multiArrayValue else {
                return
            }
            
            // Extract values dynamically based on what the model outputs
            let outputCount = min(resultArray.count, 10)
            let jointPositions = (0..<outputCount).map { resultArray[$0].floatValue }
            
            let result = InferenceResult(
                jointPositions: jointPositions,
                inferenceTime: inferenceTime
            )
            
            // Update UI on main thread
            DispatchQueue.main.async { [weak self] in
                self?.latestResult = result
                
                // Ensure visualization is ready and feed pose
                if let arManager = self?.arVisualizationManager, jointPositions.count >= 6 {
                    arManager.prepareVisualizationIfNeeded()
                    arManager.updatePoseFromMLOutput(jointPositions, timestamp: self?.lastInferenceTime ?? CACurrentMediaTime())
                }
                
                // Joint actions are automatically sent via USB stream (transform to robot frame)
                if jointPositions.count >= 7 {
                    let src = Array(jointPositions.prefix(7))
                    var robot = ActionTransformUtils.toRobotActions(src)
                    if robot.count >= 7 {
                        robot[6] = max(0.0, min(1.0, robot[6]))
                    }
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
    
    // MARK: - Odometry Integration Validation
    func validateOdometryIntegration() -> Bool {
        // Check if odometry tracking is properly set up
        let hasTracker = odometryTracker != nil
        let isEnabled = enableOdometryTracking
        let hasARConnection = arViewContainer != nil
        let hasVisualizationConnection = arVisualizationManager != nil
        
        let isValid = hasTracker && hasARConnection && hasVisualizationConnection
        
        print("Odometry validation: \(isValid ? "OK" : "Failed")")
        if !isValid {
            print("Issues: tracker=\(hasTracker), AR=\(hasARConnection), viz=\(hasVisualizationConnection)")
        }
        
        return isValid
    }
} 
