//
//  EdgeTAMManager.swift
//  AnySense
//
//  Updated EdgeTAM model integration with full segmentation pipeline
//

import Foundation
@preconcurrency import CoreML
import Vision
import CoreVideo
import CoreImage
import UIKit

// MARK: - Prompt Types
struct EdgeTAMPrompt {
    var points: [(CGPoint, Bool)] = [] // (point, isPositive)
    var boxes: [CGRect] = []
    var maskInput: UIImage?
}

class EdgeTAMManager: ObservableObject {
    // MARK: - Properties
    private var imageEncoder: MLModel?
    private var promptEncoder: MLModel?
    private var maskDecoder: MLModel?
    private let ciContext = CIContext()
    private var frameCounter: Int = 0
    private let frameInterval: Int = 30 // Process every 30th frame
    
    @Published var isEnabled: Bool = true
    @Published var isProcessing: Bool = false
    @Published var latestFeatures: MLMultiArray?
    @Published var latestHighResFeats: (MLMultiArray?, MLMultiArray?) = (nil, nil)
    @Published var processingTime: TimeInterval = 0
    @Published var processedFrameCount: Int = 0
    @Published var isModelLoaded: Bool = false
    @Published var latestSegmentationMask: UIImage?
    @Published var currentPrompt: EdgeTAMPrompt = EdgeTAMPrompt()
    
    // Multi-point tracking: Green points (original) and Red points (tracked)
    @Published var originalPoints: [CGPoint] = []  // Green points - user input, never move
    
    // Boundary tracking integration
    private var boundaryTrackingManager = BoundaryTrackingManager()
    
    // Model input requirements
    private let modelInputSize = CGSize(width: 1024, height: 1024)
    
    // Processing queue
    private let processingQueue = DispatchQueue(label: "EdgeTAMProcessingQueue", qos: .userInitiated)
    
    // MARK: - Initialization
    init() {
        loadEdgeTAMModel()
    }
    
    // MARK: - Model Loading
    private func loadEdgeTAMModel() {
        loadAllModels()
    }
    
    private func loadAllModels() {
        var modelsLoaded = 0
        let totalModels = 3
        
        // Load Image Encoder
        if let imageEncoderURL = Bundle.main.url(forResource: "edgetam_image_encoder", withExtension: "mlmodelc") {
            do {
                imageEncoder = try MLModel(contentsOf: imageEncoderURL)
                print("EdgeTAM Image Encoder loaded")
                modelsLoaded += 1
            } catch {
                print("Failed to load EdgeTAM Image Encoder: \(error)")
            }
        } else {
            print("EdgeTAM Image Encoder not found")
        }
        
        // Load Prompt Encoder
        if let promptEncoderURL = Bundle.main.url(forResource: "edgetam_prompt_encoder", withExtension: "mlmodelc") {
            do {
                promptEncoder = try MLModel(contentsOf: promptEncoderURL)
                print("EdgeTAM Prompt Encoder loaded")
                modelsLoaded += 1
            } catch {
                print("Failed to load EdgeTAM Prompt Encoder: \(error)")
            }
        } else {
            print("EdgeTAM Prompt Encoder not found")
        }
        
        // Load Mask Decoder
        if let maskDecoderURL = Bundle.main.url(forResource: "edgetam_mask_decoder", withExtension: "mlmodelc") {
            do {
                maskDecoder = try MLModel(contentsOf: maskDecoderURL)
                print("EdgeTAM Mask Decoder loaded")
                modelsLoaded += 1
            } catch {
                print("Failed to load EdgeTAM Mask Decoder: \(error)")
            }
        } else {
            print("EdgeTAM Mask Decoder not found")
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isModelLoaded = (modelsLoaded == totalModels)
            if self.isModelLoaded {
                print("All EdgeTAM models loaded successfully")
            } else {
                print("Warning: Only \(modelsLoaded)/\(totalModels) EdgeTAM models loaded")
            }
        }
    }
    
    // MARK: - Frame Processing
    func processFrameIfNeeded(_ pixelBuffer: CVPixelBuffer, timestamp: CFTimeInterval) {
        // Skip processing if EdgeTAM is disabled
        guard isEnabled else { return }
        
        frameCounter += 1
        
        // Only process every nth frame
        guard frameCounter % frameInterval == 0 else { return }
        
        // Skip if already processing
        guard !isProcessing else { return }
        
        processingQueue.async { [weak self] in
            self?.processFrame(pixelBuffer, timestamp: timestamp)
        }
    }
    
    private func processFrame(_ pixelBuffer: CVPixelBuffer, timestamp: CFTimeInterval) {
        guard let imageEncoderModel = imageEncoder else {
            print("EdgeTAM image encoder not loaded")
            return
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.isProcessing = true
        }
        
        let startTime = CACurrentMediaTime()
        
        do {
            // Prepare the pixel buffer for the model
            let preparedPixelBuffer = try preparePixelBufferForModel(pixelBuffer)
            
            // Create input for the image encoder
            let input = try MLDictionaryFeatureProvider(dictionary: ["image": preparedPixelBuffer])
            
            // Run image encoder inference
            let output = try imageEncoderModel.prediction(from: input)
            
            // Extract features
            let visionFeatures = output.featureValue(for: "vision_features")?.multiArrayValue
            let highResFeat0 = output.featureValue(for: "high_res_feat_0")?.multiArrayValue
            let highResFeat1 = output.featureValue(for: "high_res_feat_1")?.multiArrayValue
            
            let processingTime = CACurrentMediaTime() - startTime
            
            // Generate segmentation mask if we have prompts
            var segmentationMask: UIImage?
            
            if !currentPrompt.points.isEmpty {
                // Run full segmentation pipeline
                segmentationMask = runSegmentationPipeline(
                    visionFeatures: visionFeatures,
                    highResFeat0: highResFeat0,
                    highResFeat1: highResFeat1,
                    prompt: currentPrompt
                )
                
                // Update boundary tracking if we have a mask
                // Since this runs every 8 frames, update display as well
                if let mask = segmentationMask {
                    updateBoundaryTracking(with: mask, shouldUpdateDisplay: true)
                }
            }
            
            DispatchQueue.main.async { [weak self] in
                self?.latestFeatures = visionFeatures
                self?.latestHighResFeats = (highResFeat0, highResFeat1)
                self?.processingTime = processingTime
                self?.isProcessing = false
                self?.processedFrameCount += 1
                self?.latestSegmentationMask = segmentationMask
            }
            
            print("EdgeTAM processed frame \(self.frameCounter) - Time: \(String(format: "%.1f", processingTime * 1000))ms")
            
        } catch {
            print("EdgeTAM processing error: \(error)")
            DispatchQueue.main.async { [weak self] in
                self?.isProcessing = false
            }
        }
    }
    
    // MARK: - Segmentation Pipeline
    private func runSegmentationPipeline(
        visionFeatures: MLMultiArray?,
        highResFeat0: MLMultiArray?,
        highResFeat1: MLMultiArray?,
        prompt: EdgeTAMPrompt
    ) -> UIImage? {
        print("Starting segmentation pipeline...")
        print("   Prompt points: \(prompt.points.count)")
        print("   Prompt boxes: \(prompt.boxes.count)")
        
        guard let promptEncoderModel = promptEncoder,
              let maskDecoderModel = maskDecoder,
              let visionFeatures = visionFeatures,
              let highResFeat0 = highResFeat0,
              let highResFeat1 = highResFeat1 else {
            print("Segmentation pipeline: Missing models or features")
            print("   promptEncoder: \(promptEncoder != nil)")
            print("   maskDecoder: \(maskDecoder != nil)")
            print("   visionFeatures: \(visionFeatures != nil)")
            print("   highResFeat0: \(highResFeat0 != nil)")
            print("   highResFeat1: \(highResFeat1 != nil)")
            return nil
        }
        
        print("All models and features available")
        
        do {
            // Prepare prompt inputs
            print("Preparing prompt inputs...")
            let promptInputs = try preparePromptInputs(prompt: prompt)
            
            // Run prompt encoder
            print("Running prompt encoder...")
            let promptEncoderOutput = try promptEncoderModel.prediction(from: promptInputs)
            
            guard let sparseEmbeddings = promptEncoderOutput.featureValue(for: "sparse_embeddings")?.multiArrayValue,
                  let denseEmbeddings = promptEncoderOutput.featureValue(for: "dense_embeddings")?.multiArrayValue else {
                print("Failed to get prompt embeddings")
                print("   Available outputs: \(promptEncoderOutput.featureNames)")
                return nil
            }
            
            print("Got prompt embeddings - sparse: \(sparseEmbeddings.shape), dense: \(denseEmbeddings.shape)")
            
            // Create positional encoding (simplified - zeros for now)
            let imagePE = try createZeroArray(shape: visionFeatures.shape)
            
            // Prepare mask decoder inputs
            print("Preparing mask decoder inputs...")
            let maskDecoderInputs = try MLDictionaryFeatureProvider(dictionary: [
                "image_embeddings": visionFeatures,
                "image_pe": imagePE,
                "sparse_prompt_embeddings": sparseEmbeddings,
                "dense_prompt_embeddings": denseEmbeddings,
                "high_res_feat_0": highResFeat0,
                "high_res_feat_1": highResFeat1,
                "multimask_output": try createSingleValueArray(value: 1.0) // true
            ])
            
            // Run mask decoder
            print("Running mask decoder...")
            let maskDecoderOutput = try maskDecoderModel.prediction(from: maskDecoderInputs)
            
            print("Mask decoder completed")
            print("   Available outputs: \(maskDecoderOutput.featureNames)")
            
            if let masks = maskDecoderOutput.featureValue(for: "masks")?.multiArrayValue,
               let iouScores = maskDecoderOutput.featureValue(for: "iou_pred")?.multiArrayValue {
                print("Got masks and IoU scores")
                // Get best mask based on IoU score
                return createSegmentationMask(from: masks, iouScores: iouScores)
            } else {
                print("Failed to extract masks or IoU scores from decoder output")
            }
            
        } catch {
            print("Segmentation pipeline error: \(error)")
        }
        
        print("Segmentation pipeline failed - returning nil")
        return nil
    }
    
    private func preparePromptInputs(prompt: EdgeTAMPrompt) throws -> MLDictionaryFeatureProvider {
        // Create arrays for prompt inputs
        let maxPoints = 4
        let pointCoords = try MLMultiArray(shape: [1, NSNumber(value: maxPoints), 2], dataType: .float32)
        let pointLabels = try MLMultiArray(shape: [1, NSNumber(value: maxPoints)], dataType: .float32)
        let boxes = try MLMultiArray(shape: [1, 4], dataType: .float32)
        let maskInput = try MLMultiArray(shape: [1, 1, 256, 256], dataType: .float32)
        
        // Initialize with default values
        for i in 0..<maxPoints {
            pointCoords[[0, NSNumber(value: i), 0]] = 0
            pointCoords[[0, NSNumber(value: i), 1]] = 0
            pointLabels[[0, NSNumber(value: i)]] = -1 // Invalid by default
        }
        
        // Fill in actual prompt points
        for (index, (point, isPositive)) in prompt.points.enumerated() {
            guard index < maxPoints else { break }
            // Convert to model coordinates (0-1024 range)
            pointCoords[[0, NSNumber(value: index), 0]] = NSNumber(value: Float(point.x))
            pointCoords[[0, NSNumber(value: index), 1]] = NSNumber(value: Float(point.y))
            pointLabels[[0, NSNumber(value: index)]] = NSNumber(value: isPositive ? 1.0 : 0.0)
        }
        
        // Initialize boxes and mask input as zeros for now
        for i in 0..<4 {
            boxes[[0, NSNumber(value: i)]] = 0
        }
        
        return try MLDictionaryFeatureProvider(dictionary: [
            "point_coords": pointCoords,
            "point_labels": pointLabels,
            "boxes": boxes,
            "mask_input": maskInput
        ])
    }
    
    private func createZeroArray(shape: [NSNumber]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape, dataType: .float32)
        let count = array.count
        let pointer = array.dataPointer.bindMemory(to: Float32.self, capacity: count)
        for i in 0..<count {
            pointer[i] = 0.0
        }
        return array
    }
    
    private func createSingleValueArray(value: Float) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1], dataType: .float32)
        array[0] = NSNumber(value: value)
        return array
    }
    
    private func createSegmentationMask(from masks: MLMultiArray, iouScores: MLMultiArray) -> UIImage? {
        // masks shape: [1, 3, 256, 256] (3 masks generated)
        // iouScores shape: [1, 3]
        
        print("Creating segmentation mask from MLMultiArray")
        print("   Masks shape: \(masks.shape)")
        print("   IoU scores shape: \(iouScores.shape)")
        
        // Find best mask based on IoU score
        var bestMaskIndex = 0
        var bestScore: Float = 0
        
        for i in 0..<3 {
            let score = iouScores[[0, NSNumber(value: i)]].floatValue
            print("   Mask \(i) IoU score: \(score)")
            if score > bestScore {
                bestScore = score
                bestMaskIndex = i
            }
        }
        
        print("   Selected mask \(bestMaskIndex) with score \(bestScore)")
        
        // Sample some mask values to understand the data
        var sampleValues: [Float] = []
        for i in 0..<min(10, 256) {
            for j in 0..<min(10, 256) {
                let value = masks[[0, NSNumber(value: bestMaskIndex), NSNumber(value: i), NSNumber(value: j)]].floatValue
                sampleValues.append(value)
            }
        }
        let minVal = sampleValues.min() ?? 0
        let maxVal = sampleValues.max() ?? 0
        let avgVal = sampleValues.reduce(0, +) / Float(sampleValues.count)
        print("   Mask value range: \(minVal) to \(maxVal), avg: \(avgVal)")
        
        // Extract the best mask
        let width = 256
        let height = 256
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        
        var pixelData = Array(repeating: UInt8(0), count: width * height * bytesPerPixel)
        var foregroundPixels = 0
        
        for y in 0..<height {
            for x in 0..<width {
                let maskValue = masks[[0, NSNumber(value: bestMaskIndex), NSNumber(value: y), NSNumber(value: x)]].floatValue
                let pixelIndex = (y * width + x) * bytesPerPixel
                
                // Apply sigmoid to get probability
                let probability = 1.0 / (1.0 + exp(-maskValue))
                
                if probability > 0.5 {
                    foregroundPixels += 1
                    // Foreground - bright cyan
                    pixelData[pixelIndex] = 0      // Red
                    pixelData[pixelIndex + 1] = 255 // Green
                    pixelData[pixelIndex + 2] = 255 // Blue
                    pixelData[pixelIndex + 3] = UInt8(min(255, Int(probability * 180))) // Alpha
                } else {
                    // Background - transparent
                    pixelData[pixelIndex] = 0
                    pixelData[pixelIndex + 1] = 0
                    pixelData[pixelIndex + 2] = 0
                    pixelData[pixelIndex + 3] = 0
                }
            }
        }
        
        print("   Generated mask: \(foregroundPixels)/\(width*height) foreground pixels (\(Int(Double(foregroundPixels)/Double(width*height)*100))%)")
        
        guard let dataProvider = CGDataProvider(data: Data(pixelData) as CFData),
              let cgImage = CGImage(width: width,
                                   height: height,
                                   bitsPerComponent: 8,
                                   bitsPerPixel: 32,
                                   bytesPerRow: bytesPerRow,
                                   space: colorSpace,
                                   bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)],
                                   provider: dataProvider,
                                   decode: nil,
                                   shouldInterpolate: false,
                                   intent: .defaultIntent) else {
            print("Failed to create CGImage from mask data")
            return nil
        }
        
        print("Successfully created segmentation mask UIImage")
        return UIImage(cgImage: cgImage)
    }
    
    // MARK: - Pixel Buffer Preparation  
    private func preparePixelBufferForModel(_ inputPixelBuffer: CVPixelBuffer) throws -> CVPixelBuffer {
        // Create output pixel buffer for model input size (1024x1024)
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: Int(modelInputSize.width),
            kCVPixelBufferHeightKey as String: Int(modelInputSize.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
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
            throw NSError(domain: "EdgeTAMManager", code: -1, 
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create output pixel buffer"])
        }
        
        // Use Core Image to resize and process the frame
        CVPixelBufferLockBaseAddress(inputPixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(outputBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(outputBuffer, [])
            CVPixelBufferUnlockBaseAddress(inputPixelBuffer, .readOnly)
        }
        
        let inputImage = CIImage(cvPixelBuffer: inputPixelBuffer)
        
        // Calculate scale to fit the model input size
        let inputSize = CGSize(
            width: CVPixelBufferGetWidth(inputPixelBuffer),
            height: CVPixelBufferGetHeight(inputPixelBuffer)
        )
        
        let scaleX = modelInputSize.width / inputSize.width
        let scaleY = modelInputSize.height / inputSize.height
        let scale = min(scaleX, scaleY) // Maintain aspect ratio
        
        // Create transform to scale and center the image
        let scaledWidth = inputSize.width * scale
        let scaledHeight = inputSize.height * scale
        let xOffset = (modelInputSize.width - scaledWidth) / 2
        let yOffset = (modelInputSize.height - scaledHeight) / 2
        
        let transform = CGAffineTransform(scaleX: scale, y: scale)
            .translatedBy(x: xOffset / scale, y: yOffset / scale)
        
        let scaledImage = inputImage.transformed(by: transform)
        
        // Render to output buffer
        ciContext.render(scaledImage, to: outputBuffer)
        
        return outputBuffer
    }
    
    
    // MARK: - Boundary Tracking Methods
    private func updateBoundaryTracking(with maskImage: UIImage, shouldUpdateDisplay: Bool = false) {
        // Start or restart tracking when we have points to track
        if !originalPoints.isEmpty {
            if !boundaryTrackingManager.isTracking {
                // Start tracking with multiple points
                boundaryTrackingManager.startMultiPointTracking(initialPoints: originalPoints, maskImage: maskImage)
            } else {
                // Update existing tracking
                boundaryTrackingManager.updateAllBoundaries(with: maskImage, shouldUpdateDisplay: shouldUpdateDisplay)
            }
            
            // Update current prompt with tracked points for next segmentation
            updatePromptWithTrackedPoints()
        }
    }
    
    private func updatePromptWithTrackedPoints() {
        let trackedPoints = boundaryTrackingManager.currentTrackingPoints
        
        if !trackedPoints.isEmpty {
            // Update the first point with the tracked position, keep others as positive
            currentPrompt.points = trackedPoints.enumerated().map { index, point in
                (point, true) // All tracked points are positive
            }
            
            print("Updated prompt with \(trackedPoints.count) tracked points")
        }
    }
    
    func startBoundaryTracking() {
        guard !currentPrompt.points.isEmpty else {
            print("Warning: Cannot start boundary tracking without prompt points")
            return
        }
        
        // Boundary tracking will start automatically on next segmentation
        print("Boundary tracking ready - will start on next segmentation")
    }
    
    func stopBoundaryTracking() {
        boundaryTrackingManager.stopTracking()
        print("Stopped boundary tracking")
    }
    
    var boundaryTrackingStatistics: String {
        return boundaryTrackingManager.trackingStatistics
    }
    
    var isBoundaryTracking: Bool {
        return boundaryTrackingManager.isTracking
    }
    
    // Get display points for UI (updated every 8 frames)
    var displayTrackingPoints: [CGPoint] {
        return boundaryTrackingManager.displayTrackingPoints
    }
    
    // MARK: - Public Methods
    func reset() {
        frameCounter = 0
        latestFeatures = nil
        latestHighResFeats = (nil, nil)
        processingTime = 0
        isProcessing = false
        processedFrameCount = 0
        latestSegmentationMask = nil
        currentPrompt = EdgeTAMPrompt()
        boundaryTrackingManager.stopTracking()
    }
    
    func generateMaskForTrackedObject(prompt: EdgeTAMPrompt) async -> UIImage? {
        guard let visionFeatures = latestFeatures,
              let highResFeat0 = latestHighResFeats.0,
              let highResFeat1 = latestHighResFeats.1 else {
            print("No features available for mask generation")
            return nil
        }
        
        return await withCheckedContinuation { continuation in
            processingQueue.async { [weak self] in
                let mask = self?.runSegmentationPipeline(
                    visionFeatures: visionFeatures,
                    highResFeat0: highResFeat0,
                    highResFeat1: highResFeat1,
                    prompt: prompt
                )
                continuation.resume(returning: mask)
            }
        }
    }
    
    func processFrameForTracking(_ pixelBuffer: CVPixelBuffer, timestamp: CFTimeInterval) {
        // Process frame and also notify object tracking manager
        processFrameIfNeeded(pixelBuffer, timestamp: timestamp)
        
        // Frame processing completed
    }
    
    private func pixelBufferToUIImage(_ pixelBuffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
    
    // MARK: - Prompt Handling
    func addPromptPoint(_ point: CGPoint, isPositive: Bool = true) {
        // Convert screen coordinates to model coordinates (1024x1024)
        let modelPoint = CGPoint(x: point.x * modelInputSize.width, y: point.y * modelInputSize.height)
        currentPrompt.points.append((modelPoint, isPositive))
        
        print("Added prompt point: (\(Int(modelPoint.x)), \(Int(modelPoint.y))) - \(isPositive ? "Positive" : "Negative")")
    }
    
    func addPromptPointWithConstraints(_ normalizedPoint: CGPoint, screenPoint: CGPoint, screenSize: CGSize) -> Bool {
        // Check constraint 1: Maximum 4 points
        guard currentPrompt.points.count < 4 else {
            print("Point rejected: Maximum 4 points allowed")
            return false
        }
        
        // Check constraint 2: Minimum distance of 0.5 screen units from existing points
        let minimumDistance: CGFloat = 0.5
        for existingPoint in originalPoints {
            let existingScreenPoint = convertModelPointToScreen(existingPoint, screenSize: screenSize)
            let distance = sqrt(pow(screenPoint.x - existingScreenPoint.x, 2) + pow(screenPoint.y - existingScreenPoint.y, 2))
            
            if distance < minimumDistance {
                print("Point rejected: Too close to existing point (distance: \(Int(distance)) < \(Int(minimumDistance)))")
                return false
            }
        }
        
        // Check constraint 3: Point must be within current segmentation mask (if one exists)
        if let maskImage = latestSegmentationMask {
            if !isPointWithinMask(normalizedPoint, mask: maskImage) {
                print("Point rejected: Outside current segmentation mask")
                return false
            }
        }
        
        // All constraints passed - add the point
        let modelPoint = CGPoint(x: normalizedPoint.x * modelInputSize.width, y: normalizedPoint.y * modelInputSize.height)
        
        // Only positive points allowed now
        currentPrompt.points.append((modelPoint, true))
        originalPoints.append(modelPoint)
        
        print("Added point: (\(Int(modelPoint.x)), \(Int(modelPoint.y))) - Total: \(currentPrompt.points.count)")
        
        return true
    }
    
    // Helper to convert model coordinates back to screen coordinates
    private func convertModelPointToScreen(_ modelPoint: CGPoint, screenSize: CGSize) -> CGPoint {
        let normalizedX = modelPoint.x / modelInputSize.width
        let normalizedY = modelPoint.y / modelInputSize.height
        return CGPoint(x: normalizedX * screenSize.width, y: normalizedY * screenSize.height)
    }
    
    // Helper to check if point is within segmentation mask
    private func isPointWithinMask(_ normalizedPoint: CGPoint, mask: UIImage) -> Bool {
        guard let cgImage = mask.cgImage else { return false }
        
        let width = cgImage.width
        let height = cgImage.height
        
        // Convert normalized point to mask coordinates
        let maskX = Int(normalizedPoint.x * CGFloat(width))
        let maskY = Int(normalizedPoint.y * CGFloat(height))
        
        // Ensure coordinates are within bounds
        guard maskX >= 0 && maskX < width && maskY >= 0 && maskY < height else { return false }
        
        // Get pixel data and check if the point is in a mask region
        guard let pixelData = getPixelData(from: cgImage) else { return false }
        
        let pixelIndex = maskY * width + maskX
        let pixelValue = pixelData[pixelIndex]
        
        // Consider point valid if pixel value is above threshold (indicating mask region)
        return pixelValue > 50  // Threshold for mask detection
    }
    
    // Helper to extract pixel data from image
    private func getPixelData(from cgImage: CGImage) -> [UInt8]? {
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let totalBytes = height * bytesPerRow
        
        var pixelData = [UInt8](repeating: 0, count: totalBytes)
        
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        // Convert RGBA to grayscale
        var grayscaleData = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let r = pixelData[i * 4]
            let g = pixelData[i * 4 + 1]
            let b = pixelData[i * 4 + 2]
            grayscaleData[i] = UInt8((Int(r) + Int(g) + Int(b)) / 3)
        }
        
        return grayscaleData
    }
    
    func addPromptBox(_ box: CGRect) {
        // Convert screen coordinates to model coordinates
        let modelBox = CGRect(
            x: box.origin.x * modelInputSize.width,
            y: box.origin.y * modelInputSize.height,
            width: box.size.width * modelInputSize.width,
            height: box.size.height * modelInputSize.height
        )
        currentPrompt.boxes.append(modelBox)
        
        print("Added prompt box: \(modelBox)")
    }
    
    func clearPrompts() {
        currentPrompt = EdgeTAMPrompt()
        originalPoints.removeAll()
        latestSegmentationMask = nil
        boundaryTrackingManager.stopTracking()
        print("Cleared all prompts and tracking")
    }
    
    func setFrameInterval(_ interval: Int) {
        guard interval > 0 else { return }
        frameCounter = 0
        print("EdgeTAM frame interval set to: \(interval)")
    }
    
    // MARK: - Status Properties
    var statusText: String {
        if !isModelLoaded {
            return "EdgeTAM: Models not loaded"
        }
        
        if processedFrameCount == 0 {
            return "EdgeTAM: Ready"
        }
        
        return "EdgeTAM: \(processedFrameCount) frames, \(String(format: "%.1f", processingTime * 1000))ms"
    }
    
    var isActive: Bool {
        return isModelLoaded && (processedFrameCount > 0 || isProcessing)
    }
}
