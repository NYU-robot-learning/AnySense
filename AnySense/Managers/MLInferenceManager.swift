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
    
    // MARK: - Private Properties
    private var model: MLModel?
    private var lastInferenceTime: CFTimeInterval = 0
    private var inferenceQueue = DispatchQueue(label: "MLInferenceQueue", qos: .userInitiated)
    
    // MARK: - Model Management
    private var modelManager: ModelManager
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - AR Visualization Integration
    weak var arVisualizationManager: ARVisualizationManager?
    
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
            model = try modelManager.loadModel(for: activeModel)
            setupModelInputTransform()
            print("Successfully loaded model: \(activeModel.name)")
        } catch {
            print("Failed to load active model: \(error)")
            model = nil
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
    
    var activeModelName: String? {
        return modelManager.activeModel?.name
    }
    
    var isUsingUploadedModel: Bool {
        return modelManager.hasCompiledModel
    }
    
    // MARK: - Inference Methods (Using existing frame processing patterns)
    func performInference(on pixelBuffer: CVPixelBuffer, timestamp: CFTimeInterval = CACurrentMediaTime()) {
        guard isInferenceEnabled,
              let model = model else { return }
        
        if timestamp - lastInferenceTime < inferenceFrequency.interval {
            return
        }
        
        lastInferenceTime = timestamp
        
        inferenceQueue.async { [weak self] in
            guard let self = self else { return }
            
            let startTime = CACurrentMediaTime()
            
            autoreleasepool {
                do {
                    let inputArray = try self.processFrameForInference(pixelBuffer)
                    let input = try MLDictionaryFeatureProvider(dictionary: ["x_1": inputArray])
                    let output = try model.prediction(from: input)
                    
                    let inferenceTime = CACurrentMediaTime() - startTime
                    self.processInferenceResults(output, inferenceTime: inferenceTime)
                } catch {
                    print("Failed to perform inference: \(error)")
                }
            }
        }
    }
    
    // MARK: - Frame Processing (Leveraging ARViewContainer patterns)
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
        
        let scaledImage = inputImage.transformed(by: scaleTransform)
        let cropRect = CGRect(origin: .zero, size: modelInputSize)
        
        // Render using the same CIContext approach as ARViewContainer
        ciContext.render(scaledImage, to: outputBuffer, bounds: cropRect, colorSpace: CGColorSpaceCreateDeviceRGB())
        
        // Convert to MLMultiArray (simplified since we now have consistently formatted data)
        return try convertProcessedPixelBufferToMLMultiArray(outputBuffer)
    }
    
    // MARK: - Simplified Pixel Buffer to MLMultiArray Conversion
    private func convertProcessedPixelBufferToMLMultiArray(_ pixelBuffer: CVPixelBuffer) throws -> MLMultiArray {
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
                
                // ARGB format
                let r = Float(buffer[offset + 1]) / 255.0
                let g = Float(buffer[offset + 2]) / 255.0  
                let b = Float(buffer[offset + 3]) / 255.0
                
                // Store in MLMultiArray format: [batch, channel, rgb, height, width]
                let baseIndex = y * 256 + x
                inputArray[baseIndex] = NSNumber(value: r) // R channel
                inputArray[baseIndex + 256 * 256] = NSNumber(value: g) // G channel  
                inputArray[baseIndex + 256 * 256 * 2] = NSNumber(value: b) // B channel
            }
        }
        
        return inputArray
    }
    
    // MARK: - Result Processing
    private func processInferenceResults(_ output: MLFeatureProvider, inferenceTime: TimeInterval) {
        // Get the active model's metadata to understand its outputs
        guard let metadata = modelManager.getActiveModelMetadata() else {
            print("Failed to get model metadata for output processing")
            return
        }
        
        // Try to get the output using the primary output name, or fall back to any available output
        let outputFeatureName = metadata.primaryOutputName ?? metadata.outputFeatureNames.first
        
        guard let outputFeatureName = outputFeatureName,
              let resultArray = output.featureValue(for: outputFeatureName)?.multiArrayValue else {
            print("Failed to get model output. Available outputs: \(output.featureNames)")
            print("Expected output: \(metadata.outputFeatureNames)")
            return
        }
        
        // Extract values dynamically based on what the model outputs
        let outputCount = min(resultArray.count, 10) // Cap at 10 to avoid huge arrays
        let jointPositions = (0..<outputCount).map { resultArray[$0].floatValue }
        
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
        print("Model Output [\(modelName)] (\(outputFeatureName)): [\(positionString)] - \(String(format: "%.1f", inferenceTime * 1000))ms")
    }
    
    // MARK: - Control Methods
    func enableInference() {
        isInferenceEnabled = true
        let modelName = modelManager.activeModel?.name ?? "No model"
        print("Pick Up Policy enabled with model: \(modelName)")
    }
    
    func disableInference() {
        isInferenceEnabled = false
        latestResult = nil
        print("Pick Up Policy disabled")
    }
    
    func setInferenceFrequency(_ frequency: InferenceFrequency) {
        inferenceFrequency = frequency
        print("Pick Up Policy frequency set to: \(frequency.displayName)")
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
        print("Synchronized ML inference (\(inferenceFrequency.displayName)) with AR visualization (\(correspondingVisualizationFrequency.displayName))")
    }
} 
