//
//  MLInferenceManager.swift
//  AnySense
//
//  Created by Krish on 2025/2/1.
//

import Foundation
import CoreML
import Vision
import CoreVideo
import QuartzCore
import Combine
import RealityKit
import CoreImage

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
    @Published var currentGoalPoint: simd_float3 = simd_float3(0, 0, 0)
    @Published var modelMetadata: ModelMetadata?
    
    // MARK: - Private Properties
    private var model: MLModel?
    private var lastInferenceTime: CFTimeInterval = -Double.infinity  // Start with negative infinity to ensure first inference runs
    private var inferenceQueue = DispatchQueue(label: "MLInferenceQueue", qos: .userInitiated)
    
    // MARK: - Model Management
    private var modelManager: ModelManager
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - AR Visualization Integration
    weak var arVisualizationManager: ARVisualizationManager?
    
    // MARK: - Frame Processing (Taken from ARViewContainer)
    private let ciContext: CIContext
    private var currentInputSize: CGSize = CGSize(width: 224, height: 224) // Dynamic based on model
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
            print("No active compiled model available")
            model = nil
            return
        }
        
        do {
            let loadedModel = try modelManager.loadModel(for: activeModel)
            let metadata = try ModelMetadata(from: loadedModel)
            
            DispatchQueue.main.async {
                self.model = loadedModel
                self.modelMetadata = metadata
                self.setupModelParameters(metadata: metadata)
                print("Successfully loaded model: \(activeModel.name) - Type: \(metadata.modelType.displayName)")
                print("🎯 Model requires goal input: \(metadata.requiresGoalPoint)")
                print("🎯 MLInferenceManager requiresGoalInput: \(self.requiresGoalInput)")
            }
        } catch {
            print("Failed to load active model: \(error)")
            model = nil
            modelMetadata = nil
        }
    }
    
    // MARK: - Model Parameter Setup
    private func setupModelParameters(metadata: ModelMetadata) {
        // Set input size based on model requirements
        if let imageSize = metadata.imageInputSize {
            currentInputSize = imageSize
            print("📏 Model input size: \(imageSize)")
        } else {
            // Check for multiArray inputs that might be images (VQ-BeT Simple)
            for spec in metadata.inputSpecifications {
                if spec.name == "camera_image" && spec.type == .multiArray && spec.shape.count >= 4 {
                    let height = spec.shape[2]
                    let width = spec.shape[3]
                    currentInputSize = CGSize(width: width, height: height)
                    print("📏 VQ-BeT multiArray image size: \(currentInputSize)")
                    break
                }
            }
        }
        
        // Setup transform
        let normalizeTransform = CGAffineTransform(scaleX: 1.0, y: 1.0)
        let scaleTransform = CGAffineTransform(scaleX: currentInputSize.width, y: currentInputSize.height)
        modelInputTransform = normalizeTransform.concatenating(scaleTransform)
        
        // Log model capabilities
        print("🤖 Model capabilities:")
        print("   - Type: \(metadata.modelType.displayName)")
        print("   - Requires goal: \(metadata.requiresGoalPoint)")
        print("   - Output dimensions: \(metadata.expectedOutputDimensions ?? 0)")
        print("   - Compatible: \(metadata.isCompatible)")
    }
    
    // MARK: - Model Management Integration
    var hasAvailableModel: Bool {
        return modelManager.hasAvailableModel && model != nil
    }
    
    var activeModelName: String? {
        return modelManager.activeModel?.name
    }
    
    var isUsingUploadedModel: Bool {
        return modelManager.hasCompiledModel
    }
    
    var requiresGoalInput: Bool {
        return modelMetadata?.requiresGoalPoint ?? false
    }
    
    var modelTypeDisplayName: String {
        return modelMetadata?.modelType.displayName ?? "Unknown"
    }
    
    // MARK: - Goal Point Management (for VQ-BeT models)
    func setGoalPoint(_ point: simd_float3) {
        print("🎯 MLInferenceManager.setGoalPoint called with: \(point)")
        currentGoalPoint = point
        
        // Create visual marker in AR space
        arVisualizationManager?.setGoalPointMarker(at: point)
        
        print("🎯 Goal point updated to: (\(point.x), \(point.y), \(point.z))")
        print("🎯 Current goal point is now: (\(currentGoalPoint.x), \(currentGoalPoint.y), \(currentGoalPoint.z))")
    }
    
    func setGoalPoint(x: Float, y: Float, z: Float) {
        setGoalPoint(simd_float3(x, y, z))
    }
    
    // MARK: - Inference Methods (Enhanced for multiple model types)
    func performInference(on pixelBuffer: CVPixelBuffer, timestamp: CFTimeInterval = CACurrentMediaTime()) {
        guard isInferenceEnabled,
              let model = model,
              let metadata = modelMetadata else { return }
        
        let timeSinceLastInference = timestamp - lastInferenceTime
        let requiredInterval = inferenceFrequency.interval
        
        if timeSinceLastInference < requiredInterval {
            return
        }
        
        lastInferenceTime = timestamp
        
        // Process frame synchronously to avoid CVPixelBuffer sendable issues
        let startTime = CACurrentMediaTime()
        
        autoreleasepool {
            do {
                let input = try prepareModelInput(pixelBuffer: pixelBuffer, metadata: metadata)
                
                // Move to background queue after processing CVPixelBuffer
                inferenceQueue.async { [weak self, input, model, metadata, startTime] in
                    guard let self = self else { return }
                    
                    do {
                        let output = try model.prediction(from: input)
                        let inferenceTime = CACurrentMediaTime() - startTime
                        self.processInferenceResults(output, metadata: metadata, inferenceTime: inferenceTime)
                    } catch {
                        print("Failed to perform ML inference: \(error)")
                    }
                }
            } catch {
                print("Failed to prepare model input: \(error)")
            }
        }
    }
    
    // MARK: - Input Preparation (Enhanced for multiple model types)
    private func prepareModelInput(pixelBuffer: CVPixelBuffer, metadata: ModelMetadata) throws -> MLFeatureProvider {
        switch metadata.modelType {
        case .vqbet:
            return try prepareVQBeTInput(pixelBuffer: pixelBuffer, metadata: metadata)
        case .legacy:
            return try prepareLegacyInput(pixelBuffer: pixelBuffer, metadata: metadata)
        default:
            throw NSError(domain: "MLInferenceManager", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Unsupported model type: \(metadata.modelType)"])
        }
    }
    
    private func prepareVQBeTInput(pixelBuffer: CVPixelBuffer, metadata: ModelMetadata) throws -> MLFeatureProvider {
        // Check if model expects image as pixelBuffer or multiArray
        let imageInputSpec = metadata.inputSpecifications.first { $0.name == "camera_image" }
        let usesPixelBuffer = imageInputSpec?.type == .image
        
        if usesPixelBuffer {
            // Original VQ-BeT model with pixelBuffer input
            let resizedBuffer = try resizePixelBuffer(pixelBuffer, to: currentInputSize)
            
            // Create goal point MLMultiArray
            let goalArray = try MLMultiArray(shape: [1, 3], dataType: .float32)
            goalArray[[0, 0] as [NSNumber]] = NSNumber(value: currentGoalPoint.x)
            goalArray[[0, 1] as [NSNumber]] = NSNumber(value: currentGoalPoint.y)
            goalArray[[0, 2] as [NSNumber]] = NSNumber(value: currentGoalPoint.z)
            
            let inputDict: [String: MLFeatureValue] = [
                "camera_image": MLFeatureValue(pixelBuffer: resizedBuffer),
                "goal_point": MLFeatureValue(multiArray: goalArray)
            ]
            
            return try MLDictionaryFeatureProvider(dictionary: inputDict)
            
        } else {
            // Simple VQ-BeT model with multiArray inputs
            let resizedBuffer = try resizePixelBuffer(pixelBuffer, to: currentInputSize)
            
            // Convert pixelBuffer to MLMultiArray for simple model
            let imageArray = try convertPixelBufferToMLMultiArray(resizedBuffer)
            
            // Create goal point MLMultiArray
            let goalArray = try MLMultiArray(shape: [1, 3], dataType: .float32)
            goalArray[[0, 0] as [NSNumber]] = NSNumber(value: currentGoalPoint.x)
            goalArray[[0, 1] as [NSNumber]] = NSNumber(value: currentGoalPoint.y)
            goalArray[[0, 2] as [NSNumber]] = NSNumber(value: currentGoalPoint.z)
            
            let inputDict: [String: MLFeatureValue] = [
                "camera_image": MLFeatureValue(multiArray: imageArray),
                "goal_point": MLFeatureValue(multiArray: goalArray)
            ]
            
            return try MLDictionaryFeatureProvider(dictionary: inputDict)
        }
    }
    
    private func prepareLegacyInput(pixelBuffer: CVPixelBuffer, metadata: ModelMetadata) throws -> MLFeatureProvider {
        let inputArray = try processFrameForLegacyModel(pixelBuffer)
        let inputDict = ["x_1": MLFeatureValue(multiArray: inputArray)]
        return try MLDictionaryFeatureProvider(dictionary: inputDict)
    }
    
    // MARK: - Legacy Frame Processing
    private func processFrameForLegacyModel(_ pixelBuffer: CVPixelBuffer) throws -> MLMultiArray {
        // Create output pixel buffer for model input size
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: Int(currentInputSize.width),
            kCVPixelBufferHeightKey as String: Int(currentInputSize.height)
        ]
        
        var outputPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(currentInputSize.width),
            Int(currentInputSize.height),
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
        let inputImageSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let scaleX = currentInputSize.width / inputImageSize.width
        let scaleY = currentInputSize.height / inputImageSize.height
        let scaleTransform = CGAffineTransform(scaleX: scaleX, y: scaleY)
        
        let scaledImage = inputImage.transformed(by: scaleTransform)
        let cropRect = CGRect(origin: .zero, size: currentInputSize)
        
        // Render using the same CIContext approach as ARViewContainer
        ciContext.render(scaledImage, to: outputBuffer, bounds: cropRect, colorSpace: CGColorSpaceCreateDeviceRGB())
        
        // Convert to MLMultiArray (simplified since we now have consistently formatted data)
        return try convertProcessedPixelBufferToMLMultiArray(outputBuffer)
    }
    
    // MARK: - Pixel Buffer Conversion (for Simple VQ-BeT)
    private func convertPixelBufferToMLMultiArray(_ pixelBuffer: CVPixelBuffer) throws -> MLMultiArray {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        // Create MLMultiArray with shape [1, 3, height, width]
        let imageArray = try MLMultiArray(shape: [1, 3, NSNumber(value: height), NSNumber(value: width)], dataType: .float32)
        
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw NSError(domain: "MLInferenceManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get pixel buffer base address"])
        }
        
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytesPerPixel = 4 // BGRA format
        
        // Convert BGRA to RGB and normalize to 0-1
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                
                // BGRA format: B, G, R, A
                let b = Float(buffer[offset]) / 255.0
                let g = Float(buffer[offset + 1]) / 255.0
                let r = Float(buffer[offset + 2]) / 255.0
                
                // Store in MLMultiArray format: [batch, channel, height, width]
                let baseIndex = y * width + x
                imageArray[baseIndex] = NSNumber(value: r) // R channel
                imageArray[baseIndex + width * height] = NSNumber(value: g) // G channel  
                imageArray[baseIndex + width * height * 2] = NSNumber(value: b) // B channel
            }
        }
        
        return imageArray
    }
    
    // MARK: - Pixel Buffer Resizing (for VQ-BeT)
    private func resizePixelBuffer(_ pixelBuffer: CVPixelBuffer, to size: CGSize) throws -> CVPixelBuffer {
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA
        ]
        
        var resizedPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &resizedPixelBuffer
        )
        
        guard status == kCVReturnSuccess, let outputBuffer = resizedPixelBuffer else {
            throw NSError(domain: "MLInferenceManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create resized pixel buffer"])
        }
        
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let scaleX = size.width / ciImage.extent.width
        let scaleY = size.height / ciImage.extent.height
        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        
        ciContext.render(scaledImage, to: outputBuffer, bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpaceCreateDeviceRGB())
        
        return outputBuffer
    }
    
    // MARK: - Legacy Pixel Buffer to MLMultiArray Conversion
    private func convertProcessedPixelBufferToMLMultiArray(_ pixelBuffer: CVPixelBuffer) throws -> MLMultiArray {
        let width = Int(currentInputSize.width)
        let height = Int(currentInputSize.height)
        let inputArray = try MLMultiArray(shape: [1, 1, 3, NSNumber(value: height), NSNumber(value: width)], dataType: .float32)
        
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
                
                // ARGB format
                let r = Float(buffer[offset + 1]) / 255.0
                let g = Float(buffer[offset + 2]) / 255.0  
                let b = Float(buffer[offset + 3]) / 255.0
                
                // Store in MLMultiArray format: [batch, channel, rgb, height, width]
                let baseIndex = y * width + x
                inputArray[baseIndex] = NSNumber(value: r) // R channel
                inputArray[baseIndex + width * height] = NSNumber(value: g) // G channel
                inputArray[baseIndex + width * height * 2] = NSNumber(value: b) // B channel
            }
        }
        
        return inputArray
    }
    
    // MARK: - Result Processing (Enhanced)
    private func processInferenceResults(_ output: MLFeatureProvider, metadata: ModelMetadata, inferenceTime: TimeInterval) {
        guard let outputSpec = metadata.outputSpecifications.first,
              let resultArray = output.featureValue(for: outputSpec.name)?.multiArrayValue else {
            print("Failed to get model output. Available outputs: \(output.featureNames)")
            return
        }
        
        // Extract joint positions based on expected dimensions
        let expectedCount = metadata.expectedOutputDimensions ?? resultArray.count
        let actualCount = min(resultArray.count, expectedCount)
        let jointPositions = (0..<actualCount).map { resultArray[$0].floatValue }
        
        let result = InferenceResult(
            jointPositions: jointPositions,
            inferenceTime: inferenceTime
        )
        
        // Update UI on main thread
        DispatchQueue.main.async { [weak self] in
            self?.latestResult = result
            
            // Feed pose data to AR visualization with synchronized timestamp
            if let arManager = self?.arVisualizationManager, jointPositions.count >= 6 {
                arManager.updatePoseFromMLOutput(jointPositions, timestamp: self?.lastInferenceTime ?? CACurrentMediaTime())
            }
        }
        
        let positionString = jointPositions.map { String(format: "%.3f", $0) }.joined(separator: ", ")
        let modelName = modelManager.activeModel?.name ?? "Unknown"
        let modelType = metadata.modelType.displayName
        
        print("ML [\(modelType)] [\(modelName)]: [\(positionString)] - \(String(format: "%.1f", inferenceTime * 1000))ms")
        
        if metadata.requiresGoalPoint {
            print("   Goal: (\(String(format: "%.3f", currentGoalPoint.x)), \(String(format: "%.3f", currentGoalPoint.y)), \(String(format: "%.3f", currentGoalPoint.z)))")
        }
        
        print("Joint actions ready for USB streaming: \(jointPositions.count) values")
    }
    
    // MARK: - Control Methods
    func enableInference() {
        isInferenceEnabled = true
        // Reset timing to ensure immediate inference when enabled
        lastInferenceTime = -Double.infinity
        let modelName = modelManager.activeModel?.name ?? "No model"
        let modelType = modelMetadata?.modelType.displayName ?? "Unknown"
        print("ML Inference enabled - Model: \(modelName) (\(modelType))")
    }
    
    func disableInference() {
        isInferenceEnabled = false
        latestResult = nil
        print("ML Inference disabled")
    }
    
    func setInferenceFrequency(_ frequency: InferenceFrequency) {
        let oldFrequency = inferenceFrequency
        inferenceFrequency = frequency
        // Reset lastInferenceTime to allow immediate inference at new frequency
        lastInferenceTime = -Double.infinity
        print("🎚️ Frequency changed from \(oldFrequency.displayName) to \(frequency.displayName) - Interval: \(frequency.interval)s")
        
        // Automatically synchronize with AR visualization
        synchronizeFrequencyWithVisualization()
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
        print("Synchronized ML inference (\(inferenceFrequency.displayName)) with AR arrow visualization (\(correspondingVisualizationFrequency.displayName))")
    }
} 
