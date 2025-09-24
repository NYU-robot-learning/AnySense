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
    private var gripperOverlayBuffer: vImage_Buffer?
    private var isUSBStreamingActive: Bool = false
    private var currentGripperValue: Float = 1.0  // Track latest gripper value
    @Published var enableGripperOverlay: Bool = true  // Default enabled
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
            print("Open gripper overlay loaded: \(gripperOpenCIImage?.extent ?? .zero)")
        } else {
            print("Warning: Could not load gripper_overlay (open) image from assets")
        }

        // Load closed gripper
        if let closedImage = UIImage(named: "gripper_closed") {
            gripperClosedCIImage = CIImage(image: closedImage)
            print("Closed gripper overlay loaded: \(gripperClosedCIImage?.extent ?? .zero)")
        } else {
            print("Warning: Could not load gripper_closed image from assets")
        }

        // Setup vImage buffer with open gripper as default
        if let openImage = UIImage(named: "gripper_overlay") {
            setupGripperOverlayBuffer(from: openImage)
        }
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

        // Fallback to Core Image if vImage buffer not available
        guard let _ = gripperOverlayBuffer else {
            return applyGripperOverlayCoreImage(to: image)
        }

        // For now, use Core Image fallback while we implement vImage compositing
        // The main performance improvement will come from avoiding the overlay entirely when not needed
        return applyGripperOverlayCoreImage(to: image)
    }

    private func applyGripperOverlayCoreImage(to image: CIImage) -> CIImage {
        guard let gripperOverlay = getCurrentGripperOverlay() else {
            return image
        }

        // Scale gripper overlay to match model input size
        let imageSize = image.extent.size
        let overlaySize = gripperOverlay.extent.size

        let scaleX = imageSize.width / overlaySize.width
        let scaleY = imageSize.height / overlaySize.height
        let scale = min(scaleX, scaleY) // Maintain aspect ratio

        let scaledOverlay = gripperOverlay.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // Position gripper at bottom with no offset (0,0 positioning)
        let positionedOverlay = scaledOverlay

        // Composite using source-over to preserve alpha transparency
        guard let compositeFilter = CIFilter(name: "CISourceOverCompositing") else {
            print("Warning: Could not create composite filter")
            return image
        }

        compositeFilter.setValue(positionedOverlay, forKey: kCIInputImageKey)
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
            return
        }
        
        do {
            let loadedModel = try modelManager.loadModel(for: activeModel)
            model = loadedModel
            
            // Extract model metadata for type detection
            modelMetadata = try ModelMetadata(from: loadedModel)
            
            // 224x224 input for all models
            modelInputSize = CGSize(width: 224, height: 224)
            setupModelInputTransform()
            
            // Force 3D goal conditioning
            goalDimension = 3
            
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
            // We add 0.05 to the z coordinate since training data is shifted forward a bit.
            return [-p_c4.x, -p_c4.z + 0.05, -p_c4.y] 
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
            inputSize: CGSize(width: 224, height: 224),
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

        // Save original scaled image for debugging
        saveDebugFrame(scaledImage, prefix: "vqbet_original")

        // Apply gripper overlay if enabled and USB streaming is off
        if shouldShowGripperOverlay() {
            scaledImage = applyGripperOverlay(to: scaledImage)
            // Save image with overlay for debugging
            saveDebugFrame(scaledImage, prefix: "vqbet_with_overlay")
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

        // Save original scaled image for debugging
        saveDebugFrame(scaledImage, prefix: "standard_original")

        // Apply gripper overlay if enabled and USB streaming is off
        if shouldShowGripperOverlay() {
            scaledImage = applyGripperOverlay(to: scaledImage)
            // Save image with overlay for debugging
            saveDebugFrame(scaledImage, prefix: "standard_with_overlay")
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
        // Explicitly index as [B=1, T=1, C=3, H=modelInputSize.height, W=modelInputSize.width]
        let height = Int(modelInputSize.height)
        let width = Int(modelInputSize.width)
        let inputArray = try MLMultiArray(
            shape: [1, 1, 3, NSNumber(value: height), NSNumber(value: width)],
            dataType: .float32
        )
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw NSError(domain: "MLInferenceManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get pixel buffer base address"])
        }
        
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytesPerPixel = 4 // ARGB format
        
        // Since we're using Core Image processing, we have consistent ARGB format
        for y in 0..<height {
            for x in 0..<width {
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

            // Update gripper value for overlay switching (7th element, index 6)
            if jointPositions.count >= 7 {
                currentGripperValue = jointPositions[6]
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
            // Point-conditioned models - use existing complex logic
            let outputFeatureName = metadata.primaryOutputName ?? output.featureNames.first
            
            guard let outputFeatureName = outputFeatureName,
                  let resultArray = output.featureValue(for: outputFeatureName)?.multiArrayValue else {
                return
            }
            
            // Extract values dynamically based on what the model outputs
            let outputCount = min(resultArray.count, 10)
            let jointPositions = (0..<outputCount).map { resultArray[$0].floatValue }

            // Update gripper value for overlay switching (7th element, index 6)
            if jointPositions.count >= 7 {
                currentGripperValue = jointPositions[6]
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
