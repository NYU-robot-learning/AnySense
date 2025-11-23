import Foundation
import CoreML

// MARK: - MLModel Extensions
extension MLModel {
    
    /// Compile a .mlmodel file to .mlmodelc with progress tracking
    static func compileModel(at sourceURL: URL, 
                           progressHandler: @escaping (Double) -> Void) async throws -> URL {
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    // Start compilation
                    progressHandler(0.1)
                    
                    let compiledURL = try MLModel.compileModel(at: sourceURL)
                    
                    // Simulate progress updates during compilation
                    let progressSteps = [0.3, 0.5, 0.7, 0.9]
                    for progress in progressSteps {
                        progressHandler(progress)
                        Thread.sleep(forTimeInterval: 0.5) // Small delay for visual feedback
                    }
                    
                    progressHandler(1.0)
                    continuation.resume(returning: compiledURL)
                    
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Validate model compatibility and extract metadata
    static func validateModel(at url: URL) throws -> ModelMetadata {
        let model = try MLModel(contentsOf: url)
        return try ModelMetadata(from: model)
    }
    
    /// Get model file size
    static func getModelSize(at url: URL) -> Int64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return attributes[.size] as? Int64 ?? 0
        } catch {
            return 0
        }
    }
}

// MARK: - Model Metadata
struct ModelMetadata {
    let inputDescription: MLFeatureDescription?
    let outputDescription: MLFeatureDescription?
    let modelDescription: String
    let isCompatible: Bool
    let requiredInputShape: [Int]?
    let expectedOutputCount: Int?
    let outputFeatureNames: [String]
    let primaryOutputName: String?
    private let allInputsByName: [String: MLFeatureDescription]
    
    init(from model: MLModel) throws {
        let modelDescription = model.modelDescription
        
        // Cache all inputs (local first to avoid using self during init)
        let inputsByName = modelDescription.inputDescriptionsByName
        
        // Get first input description (legacy use)
        self.inputDescription = inputsByName.values.first
        
        // Get output description
        self.outputDescription = modelDescription.outputDescriptionsByName.values.first
        
        self.modelDescription = modelDescription.metadata[.description] as? String ?? "No description"
        
        // Extract input shape if available (try to infer from first image or 4D array)
        func localFirstImageLikeInput(_ inputs: [String: MLFeatureDescription]) -> (String, MLFeatureDescription)? {
            if let d = inputs["camera_image"] { return ("camera_image", d) }
            for (key, desc) in inputs {
                switch desc.type {
                case .image: return (key, desc)
                case .multiArray:
                    if let shape = desc.multiArrayConstraint?.shape, shape.count >= 4 { return (key, desc) }
                default: continue
                }
            }
            return nil
        }
        if let (_, desc) = localFirstImageLikeInput(inputsByName) {
            switch desc.type {
            case .image:
                if let c = desc.imageConstraint {
                    self.requiredInputShape = [Int(c.pixelsHigh), Int(c.pixelsWide), 3]
                } else {
                    self.requiredInputShape = [224, 224, 3]
                }
            case .multiArray:
                if let shape = desc.multiArrayConstraint?.shape, shape.count >= 4 {
                    let h = shape[shape.count-2].intValue
                    let w = shape[shape.count-1].intValue
                    self.requiredInputShape = [h, w, 3]
                } else {
                    self.requiredInputShape = [224, 224, 3]
                }
            default:
                self.requiredInputShape = [224, 224, 3]
            }
        } else {
            self.requiredInputShape = nil
        }
        
        // Expected output count (7 joint actions for our use case)
        self.expectedOutputCount = modelDescription.outputDescriptionsByName.count
        
        // Extract output feature names for dynamic handling
        self.outputFeatureNames = Array(modelDescription.outputDescriptionsByName.keys).sorted()
        self.primaryOutputName = self.outputFeatureNames.first

        // Check compatibility inline - avoid calling helpers before initialization complete
        self.isCompatible = !modelDescription.inputDescriptionsByName.isEmpty && 
                           !modelDescription.outputDescriptionsByName.isEmpty &&
                           modelDescription.inputDescriptionsByName.values.contains { desc in
                               switch desc.type {
                               case .image, .multiArray: return true
                               default: return false
                               }
                           } &&
                           modelDescription.outputDescriptionsByName.values.contains { desc in
                               switch desc.type {
                               case .multiArray: return true
                               default: return false
                               }
                           }
        
        // Now that init values are ready, set cached inputs map
        self.allInputsByName = inputsByName
    }
    
    // MARK: - Dynamic helpers used by MLInferenceManager
    enum ModelType {
        case pointConditioned
        
        var displayName: String {
            return "Point-Conditioned"
        }
    }
    
    var modelType: ModelType {
        return .pointConditioned
    }
    
    var temporalFrames: Int {
        // Detect temporal dimension in image input shape
        // [1,3,3,224,224] → 3 frames, [1,3,224,224] → 1 frame
        guard let (_, desc) = firstImageLikeInput() else { return 1 }
        
        if desc.type == .multiArray, let shape = desc.multiArrayConstraint?.shape {
            let dims = shape.map { $0.intValue }
            // Check if this is a temporal model: [B, T, C, H, W] where T > 1
            if dims.count == 5 && dims[1] > 1 && dims[2] == 3 {
                return dims[1]  // Return temporal dimension
            }
        }
        return 1  // Default to single frame
    }
    
    var isTemporalModel: Bool {
        return temporalFrames > 1
    }
    
    var requiresGoalPoint: Bool {
        // Heuristic: presence of a second non-image input named "goal_point" or a small (1x3) array input
        if allInputsByName.keys.contains("goal_point") { return true }
        for (name, desc) in allInputsByName {
            if name == "camera_image" { continue }
            switch desc.type {
            case .multiArray:
                if let shape = desc.multiArrayConstraint?.shape {
                    // Accept 2D [1,3] or [3] or small shapes as goal vector
                    let dims = shape.map { $0.intValue }
                    if dims == [1,3] || dims == [3] || dims.suffix(1).first == 3 && dims.reduce(1,*) <= 16 {
                        return true
                    }
                }
            default: break
            }
        }
        return false
    }
    
    var imageInputSize: CGSize? {
        guard let (_, desc) = firstImageLikeInput() else { return nil }
        switch desc.type {
        case .image:
            if let c = desc.imageConstraint { return CGSize(width: Int(c.pixelsWide), height: Int(c.pixelsHigh)) }
        case .multiArray:
            if let shape = desc.multiArrayConstraint?.shape, shape.count >= 4 {
                let h = shape[shape.count-2].intValue
                let w = shape[shape.count-1].intValue
                return CGSize(width: w, height: h)
            }
        default: break
        }
        return nil
    }
    
    func getImageInputName() -> String? {
        if allInputsByName.keys.contains("camera_image") { return "camera_image" }
        if let (name, _) = firstImageLikeInput() { return name }
        return nil
    }
    
    func getGoalInputName() -> String? {
        if allInputsByName.keys.contains("goal_point") { return "goal_point" }
        for (name, desc) in allInputsByName where name != "camera_image" {
            if desc.type == .multiArray, let shape = desc.multiArrayConstraint?.shape {
                let dims = shape.map { $0.intValue }
                if dims == [1,3] || dims == [3] || dims.reduce(1,*) <= 16 { return name }
            }
        }
        return nil
    }
    
    // Find the first image-like input (image or 4D array)
    private func firstImageLikeInput() -> (String, MLFeatureDescription)? {
        if let d = allInputsByName["camera_image"] { return ("camera_image", d) }
        for (name, desc) in allInputsByName {
            switch desc.type {
            case .image: return (name, desc)
            case .multiArray:
                if let shape = desc.multiArrayConstraint?.shape, shape.count >= 4 { return (name, desc) }
            default: continue
            }
        }
        return nil
    }
}

// MARK: - Model File Utilities
struct ModelFileUtilities {
    
    /// Get the Application Support directory URL (better than Documents for internal app files)
    static var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }
    
    /// Get the models directory URL
    static var modelsDirectory: URL {
        let modelsDir = applicationSupportDirectory.appendingPathComponent("Models")
        
        // Create directory if it doesn't exist
        if !FileManager.default.fileExists(atPath: modelsDir.path) {
            try? FileManager.default.createDirectory(at: modelsDir, 
                                                   withIntermediateDirectories: true)
        }
        
        return modelsDir
    }
    
    /// Get the uploaded models directory
    static var uploadedModelsDirectory: URL {
        let uploadedDir = modelsDirectory.appendingPathComponent("Uploaded")
        
        if !FileManager.default.fileExists(atPath: uploadedDir.path) {
            try? FileManager.default.createDirectory(at: uploadedDir, 
                                                   withIntermediateDirectories: true)
        }
        
        return uploadedDir
    }
    
    /// Copy uploaded model to app directory
    static func copyUploadedModel(from sourceURL: URL, withName name: String) throws -> URL {
        let destinationURL = uploadedModelsDirectory.appendingPathComponent("\(name).mlmodel")
        
        // Remove existing file if it exists
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }
    
    /// Replace compiled model using the recommended approach
    static func replaceCompiledModel(compiledURL: URL, withName name: String) throws -> URL {
        let permanentCompiledURL = uploadedModelsDirectory
            .appendingPathComponent("\(name).mlmodel")
            .deletingPathExtension()
            .appendingPathExtension("mlmodelc")
        
        // Use replaceItemAt as recommended in the guide
        try? FileManager.default.replaceItem(at: permanentCompiledURL, 
                                           withItemAt: compiledURL, 
                                           backupItemName: nil, 
                                           options: [], 
                                           resultingItemURL: nil)
        
        return permanentCompiledURL
    }
    
    /// Delete model files
    static func deleteModel(fileName: String, isUploaded: Bool) throws {
        if isUploaded {
            // Delete both .mlmodel and .mlmodelc if they exist from uploaded directory
            let mlmodelURL = uploadedModelsDirectory.appendingPathComponent(fileName)
            let mlmodelcURL = uploadedModelsDirectory
                .appendingPathComponent(fileName)
                .deletingPathExtension()
                .appendingPathExtension("mlmodelc")
            
            if FileManager.default.fileExists(atPath: mlmodelURL.path) {
                try FileManager.default.removeItem(at: mlmodelURL)
            }
            
            if FileManager.default.fileExists(atPath: mlmodelcURL.path) {
                try FileManager.default.removeItem(at: mlmodelcURL)
            }
        }
    }
} 
