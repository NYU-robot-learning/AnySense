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
                        usleep(500000) // Small delay for visual feedback (0.5 seconds)
                    }
                    
                    progressHandler(1.0)
                    continuation.resume(returning: compiledURL)
                    
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
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
