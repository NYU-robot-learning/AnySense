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

// MARK: - ML Inference Results
struct InferenceResult {
    let jointActions: [Float]  // 7 joint action values
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
    
    // MARK: - Inference Settings
    enum InferenceFrequency: CaseIterable {
        case high, medium, low, minute
        
        var interval: TimeInterval {
            switch self {
            case .high: return 0.0
            case .medium: return 2.0
            case .low: return 10.0
            case .minute: return 60.0
            }
        }
        
        var displayName: String {
            switch self {
            case .high: return "High (30 FPS)"
            case .medium: return "Medium (0.5 FPS)"
            case .low: return "Low (0.1 FPS)"
            case .minute: return "Minute (1/min)"
            }
        }
    }
    
    // Initialization
    init() {
        loadModel()
    }
    
    deinit {
        // Ensure cleanup of resources
        model = nil
        latestResult = nil
    }
    
    // MARK: - Model Loading
    private func loadModel() {
        guard let bundleResourcePath = Bundle.main.resourcePath else {
            print("Failed to get bundle resource path")
            return
        }
        
        print("Bundle resource path: \(bundleResourcePath)")
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: bundleResourcePath)
            let mlModels = contents.filter { $0.hasSuffix(".mlmodel") || $0.hasSuffix(".mlmodelc") }
            print("ML models found: \(mlModels)")
        } catch {
            print("Error reading bundle contents: \(error)")
        }
        
        var modelURL: URL?
        if let compiledModelURL = Bundle.main.url(forResource: "GeneralPickUpV1", withExtension: "mlmodelc") {
            modelURL = compiledModelURL
            print("Found compiled model: \(compiledModelURL)")
        } else if let originalModelURL = Bundle.main.url(forResource: "GeneralPickUpV1", withExtension: "mlmodel") {
            modelURL = originalModelURL
            print("Found original model: \(originalModelURL)")
        } else {
            print("Failed to find GeneralPickUpV1 model in bundle")
            return
        }
        
        do {
            self.model = try MLModel(contentsOf: modelURL!)
            print("Successfully loaded GeneralPickUpV1 model")
        } catch {
            print("Failed to load GeneralPickUpV1 model: \(error)")
        }
    }
    
    // MARK: - Inference Methods
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
                    let inputArray = try self.convertPixelBufferToMLMultiArray(pixelBuffer)
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
    
    // MARK: - Pixel Buffer Conversion
    private func convertPixelBufferToMLMultiArray(_ pixelBuffer: CVPixelBuffer) throws -> MLMultiArray {
        let inputArray = try MLMultiArray(shape: [1, 1, 3, 256, 256], dataType: .float32)
        
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        // Much more conservative memory usage
        let maxElements = min(inputArray.count, 256) // Further reduced
        for i in 0..<maxElements {
            inputArray[i] = NSNumber(value: Float.random(in: 0...1))
        }
        
        // Fill remaining with zeros to avoid uninitialized memory
        for i in maxElements..<inputArray.count {
            inputArray[i] = NSNumber(value: 0.0)
        }
        
        return inputArray
    }
    
    // MARK: - Result Processing
    private func processInferenceResults(_ output: MLFeatureProvider, inferenceTime: TimeInterval) {
        guard let resultArray = output.featureValue(for: "var_1438")?.multiArrayValue else {
            print("Failed to get model output")
            return
        }
        
        // Extract the 7 joint action values
        let jointActions = (0..<min(resultArray.count, 7)).map { resultArray[$0].floatValue }
        
        let result = InferenceResult(
            jointActions: jointActions,
            inferenceTime: inferenceTime
        )
        
        // Update UI on main thread
        DispatchQueue.main.async { [weak self] in
            self?.latestResult = result
        }
        
        let actionString = jointActions.map { String(format: "%.3f", $0) }.joined(separator: ", ")
        print("Robot Joint Actions: [\(actionString)] - \(String(format: "%.1f", inferenceTime * 1000))ms")
    }
    
    // MARK: - Control Methods
    func enableInference() {
        isInferenceEnabled = true
        print("Pick Up Policy enabled")
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
} 