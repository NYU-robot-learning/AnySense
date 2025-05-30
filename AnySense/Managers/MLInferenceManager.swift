//
//  MLInferenceManager.swift
//  AnySense
//
//  Created by Krish on 2025/2/1.
//

import Foundation
import CoreML
import Vision
import UIKit
import CoreVideo

// MARK: - ML Inference Results
struct InferenceResult {
    let topPrediction: String
    let confidence: Float
    let allPredictions: [(String, Float)]
    let inferenceTime: TimeInterval
}

// MARK: - ML Inference Manager
class MLInferenceManager: ObservableObject {
    
    // MARK: - Published Properties
    @Published var latestResult: InferenceResult?
    @Published var isInferenceEnabled: Bool = false
    @Published var inferenceFrequency: InferenceFrequency = .medium
    
    // MARK: - Private Properties
    private var model: VNCoreMLModel?
    private var lastInferenceTime: CFTimeInterval = 0
    private var inferenceQueue = DispatchQueue(label: "MLInferenceQueue", qos: .userInitiated)
    
    // MARK: - Inference Settings
    enum InferenceFrequency: CaseIterable {
        case high    // Every frame
        case medium  // Every 0.5 seconds
        case low     // Every 2 seconds
        
        var interval: TimeInterval {
            switch self {
            case .high: return 0.0      // Every frame
            case .medium: return 0.5    // 2 FPS
            case .low: return 2.0       // 0.5 FPS
            }
        }
        
        var displayName: String {
            switch self {
            case .high: return "High (30 FPS)"
            case .medium: return "Medium (2 FPS)"
            case .low: return "Low (0.5 FPS)"
            }
        }
    }
    
    // MARK: - Initialization
    init() {
        loadModel()
    }
    
    // MARK: - Model Loading
    private func loadModel() {
        // Debug: List all bundle resources
        if let bundleResourcePath = Bundle.main.resourcePath {
            print("📦 Bundle resource path: \(bundleResourcePath)")
            do {
                let contents = try FileManager.default.contentsOfDirectory(atPath: bundleResourcePath)
                print("📦 Bundle contents: \(contents)")
                
                // Look specifically for .mlmodel and .mlmodelc files
                let mlModels = contents.filter { $0.hasSuffix(".mlmodel") || $0.hasSuffix(".mlmodelc") }
                print("🧠 ML models found: \(mlModels)")
            } catch {
                print("❌ Error reading bundle contents: \(error)")
            }
        }
        
        // First try to find the compiled model (.mlmodelc)
        var modelURL: URL?
        
        if let compiledModelURL = Bundle.main.url(forResource: "Resnet50FP16", withExtension: "mlmodelc") {
            modelURL = compiledModelURL
            print("✅ Found compiled model: \(compiledModelURL)")
        } else if let originalModelURL = Bundle.main.url(forResource: "Resnet50FP16", withExtension: "mlmodel") {
            modelURL = originalModelURL
            print("✅ Found original model: \(originalModelURL)")
        } else {
            print("❌ Failed to find Resnet50FP16 model in bundle (tried both .mlmodel and .mlmodelc)")
            return
        }
        
        do {
            let mlModel = try MLModel(contentsOf: modelURL!)
            self.model = try VNCoreMLModel(for: mlModel)
            print("✅ Successfully loaded ResNet50 model")
        } catch {
            print("❌ Failed to load ResNet50 model: \(error)")
        }
    }
    
    // MARK: - Inference Methods
    func performInference(on pixelBuffer: CVPixelBuffer, timestamp: CFTimeInterval = CACurrentMediaTime()) {
        guard isInferenceEnabled,
              let model = model else { return }
        
        // Check if enough time has passed for the next inference
        if timestamp - lastInferenceTime < inferenceFrequency.interval {
            return
        }
        
        lastInferenceTime = timestamp
        
        inferenceQueue.async {
            let startTime = CACurrentMediaTime()
            
            let request = VNCoreMLRequest(model: model) { [weak self] request, error in
                guard let self = self else { return }
                
                if let error = error {
                    print("❌ Inference error: \(error)")
                    return
                }
                
                let inferenceTime = CACurrentMediaTime() - startTime
                self.processInferenceResults(request.results, inferenceTime: inferenceTime)
            }
            
            // Configure request
            request.imageCropAndScaleOption = .centerCrop
            
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            
            do {
                try handler.perform([request])
            } catch {
                print("❌ Failed to perform inference: \(error)")
            }
        }
    }
    
    // MARK: - Result Processing
    private func processInferenceResults(_ results: [VNObservation]?, inferenceTime: TimeInterval) {
        guard let results = results as? [VNClassificationObservation],
              !results.isEmpty else {
            print("❌ No classification results")
            return
        }
        
        // Sort by confidence
        let sortedResults = results.sorted { $0.confidence > $1.confidence }
        
        // Get top prediction
        let topResult = sortedResults.first!
        let topPrediction = topResult.identifier
        let topConfidence = topResult.confidence
        
        // Get top 5 predictions
        let topFive = Array(sortedResults.prefix(5))
            .map { ($0.identifier, $0.confidence) }
        
        let result = InferenceResult(
            topPrediction: topPrediction,
            confidence: topConfidence,
            allPredictions: topFive,
            inferenceTime: inferenceTime
        )
        
        // Update on main thread
        DispatchQueue.main.async {
            self.latestResult = result
        }
        
        print("🧠 ML Inference: \(topPrediction) (\(String(format: "%.1f", topConfidence * 100))%) - \(String(format: "%.1f", inferenceTime * 1000))ms")
    }
    
    // MARK: - Control Methods
    func enableInference() {
        isInferenceEnabled = true
        print("🧠 ML Inference enabled")
    }
    
    func disableInference() {
        isInferenceEnabled = false
        latestResult = nil
        print("🧠 ML Inference disabled")
    }
    
    func setInferenceFrequency(_ frequency: InferenceFrequency) {
        inferenceFrequency = frequency
        print("🧠 ML Inference frequency set to: \(frequency.displayName)")
    }
} 