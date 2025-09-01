import Foundation
import CoreML
import Combine

// MARK: - Model Manager
class ModelManager: ObservableObject {
    
    // MARK: - Published Properties
    @Published var availableModels: [ModelInfo] = []
    @Published var activeModel: ModelInfo?
    @Published var isCompiling: Bool = false
    @Published var compilationProgress: Double = 0.0
    @Published var compilationError: String?
    
    // MARK: - Private Properties
    private var modelRegistry: ModelRegistry
    private let registryURL: URL
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    init() {
        self.registryURL = ModelFileUtilities.modelsDirectory.appendingPathComponent("model_registry.json")
        self.modelRegistry = ModelRegistry()
        
        loadModelRegistry()
        setupBundledModel()
    }
    
    // MARK: - Public Properties
    var hasAvailableModel: Bool {
        return !compiledModels.isEmpty
    }
    
    var hasCompiledModel: Bool {
        return activeModel?.source == .uploaded && activeModel?.compilationStatus.isCompiled == true
    }
    
    var compiledModels: [ModelInfo] {
        return availableModels.filter { $0.compilationStatus.isCompiled }
    }
    
    var activeModelID: UUID? {
        get { activeModel?.id }
        set {
            if let newID = newValue {
                print("DEBUG: activeModelID setter called with: \(newID)")
                setActiveModel(id: newID)
            }
        }
    }
    
    // MARK: - Model Registry Management
    private func loadModelRegistry() {
        do {
            if FileManager.default.fileExists(atPath: registryURL.path) {
                let data = try Data(contentsOf: registryURL)
                modelRegistry = try JSONDecoder().decode(ModelRegistry.self, from: data)
                availableModels = modelRegistry.models
                activeModel = modelRegistry.activeModel
                print("Loaded model registry with \(modelRegistry.models.count) models")
                // Validate entries and fix stale active model pointing to removed files
                validateAndFixRegistry()
            }
        } catch {
            print("Failed to load model registry: \(error)")
            modelRegistry = ModelRegistry()
        }
    }

    // Remove models whose files no longer exist and fix an invalid active model
    private func validateAndFixRegistry() {
        // Prune missing files
        let original = availableModels
        availableModels = availableModels.filter { getModelURL(for: $0) != nil }
        if availableModels.count != original.count {
            print("Registry cleanup: removed \(original.count - availableModels.count) missing model entries")
        }
        // Fix active model if missing
        if let active = activeModel, getModelURL(for: active) == nil {
            print("Active model missing on disk: \(active.name). Selecting a valid model...")
            activeModel = nil
        }
        if activeModel == nil {
            if let next = availableModels.first, getModelURL(for: next) != nil {
                // Directly set without dispatching to avoid race during init
                for i in availableModels.indices { availableModels[i].isActive = availableModels[i].id == next.id }
                activeModel = next
                modelRegistry.setActiveModel(id: next.id)
                print("Switched active model to: \(next.name)")
            }
        }
        saveModelRegistry()
    }
    
    private func saveModelRegistry() {
        do {
            modelRegistry.models = availableModels
            modelRegistry.activeModelID = activeModel?.id
            
            let data = try JSONEncoder().encode(modelRegistry)
            try data.write(to: registryURL)
            print("Saved model registry")
        } catch {
            print("Failed to save model registry: \(error)")
        }
    }
    
    // MARK: - Bundled Model Setup
    private func setupBundledModel() {
        // Register both standard and point-conditioned bundled models if present
        let bundledNames = ["GeneralPickUpV1", "general-pick-up-goal-3-5k-demos"]
        var added: [ModelInfo] = []
        for name in bundledNames {
            let alreadyExists = availableModels.contains { $0.source == .bundled && $0.name == name }
            guard !alreadyExists else { continue }
            // Only add if the resource actually exists in the bundle with any supported extension
            let presentInBundle =
                Bundle.main.url(forResource: name, withExtension: "mlmodelc") != nil ||
                Bundle.main.url(forResource: name, withExtension: "mlpackage") != nil ||
                Bundle.main.url(forResource: name, withExtension: "mlmodel") != nil
            guard presentInBundle else { continue }
            var info = ModelInfo(
                name: name,
                fileName: "\(name).mlmodel",
                source: .bundled
            )
            info.compilationStatus = .compiled
            availableModels.append(info)
            added.append(info)
        }
        // Set a default active model if none is active yet
        if activeModel == nil {
            if let preferred = availableModels.first(where: { $0.source == .bundled && $0.name == "GeneralPickUpV1" }) ?? added.first {
                setActiveModel(id: preferred.id)
            }
        }
        if !added.isEmpty { saveModelRegistry() }
    }
    
    // MARK: - Model Upload and Compilation
    func uploadAndCompileModel(from sourceURL: URL, withName customName: String? = nil) async throws {
        
        await MainActor.run {
            isCompiling = true
            compilationProgress = 0.0
            compilationError = nil
        }
        
        do {
            // Follow the best practices guide exactly
            let shouldStopAccessing = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if shouldStopAccessing {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }
            
            print("DEBUG: Processing file from: \(sourceURL.path)")
            
            // Generate model name
            let fileName = sourceURL.lastPathComponent
            let modelName = customName ?? fileName.replacingOccurrences(of: ".mlmodel", with: "")
            
            // Check for duplicate names
            if availableModels.contains(where: { $0.name == modelName }) {
                throw ModelError.duplicateName("A model with this name already exists")
            }
            
            // Copy to our app's permanent storage WHILE we have access
            let localModelURL = try ModelFileUtilities.copyUploadedModel(from: sourceURL, withName: modelName)
            print("DEBUG: Copied to local storage: \(localModelURL.path)")
            
            // Basic file validation (check extension and file exists)
            guard localModelURL.pathExtension.lowercased() == "mlmodel" else {
                throw ModelError.invalidFile("File must have .mlmodel extension")
            }
            
            guard FileManager.default.fileExists(atPath: localModelURL.path) else {
                throw ModelError.modelNotFound("Copied file does not exist")
            }
            
            let fileSize = MLModel.getModelSize(at: localModelURL)

            let modelUploadDate = Date() // Use current date as upload date
            
            // Create model info (we'll validate compatibility after compilation)
            let modelInfo = ModelInfo(
                name: modelName,
                fileName: fileName,
                source: .uploaded,
                fileSize: fileSize,
                uploadDate: modelUploadDate
            )
            
            // Add to registry
            await MainActor.run {
                availableModels.append(modelInfo)
                saveModelRegistry()
            }
            
            // Compile the local model (this will fail if model is invalid)
            let tempCompiledURL = try await MLModel.compileModel(at: localModelURL) { [weak self] progress in
                DispatchQueue.main.async {
                    self?.compilationProgress = progress
                }
            }
            
            print("DEBUG: Compiled to temp location: \(tempCompiledURL.path)")
            
            // Now validate the compiled model for compatibility
            do {
                let metadata = try MLModel.validateModel(at: tempCompiledURL)
                guard metadata.isCompatible else {
                    throw ModelError.incompatibleModel("Model format not compatible with app requirements")
                }
                print("DEBUG: Model validation passed")
            } catch {
                print("DEBUG: Model validation warning: \(error.localizedDescription)")
                // Continue anyway - some models might work even if validation reports issues
            }
            
            // Move compiled model to permanent location using best practices
            let finalCompiledURL = try ModelFileUtilities.replaceCompiledModel(
                compiledURL: tempCompiledURL,
                withName: modelName
            )
            
            print("DEBUG: Final compiled location: \(finalCompiledURL.path)")
            
            // Update model status
            let modelId = modelInfo.id
            
            await MainActor.run {
                if let index = availableModels.firstIndex(where: { $0.id == modelId }) {
                    availableModels[index].compilationStatus = .compiled
                }
                
                isCompiling = false
                compilationProgress = 1.0
                saveModelRegistry()
                
                // Automatically activate the newly uploaded model
                setActiveModel(id: modelId)
                
                print("Successfully compiled model: \(modelName)")
            }
            
        } catch {
            await MainActor.run {
                isCompiling = false
                compilationError = error.localizedDescription
                print("Failed to upload/compile model: \(error)")
            }
            throw error
        }
    }
    
    // MARK: - Model Management
    func setActiveModel(id: UUID) {
        print("DEBUG: setActiveModel called with id: \(id)")
        print("DEBUG: Available models: \(availableModels.map { "\($0.name) (\($0.id))" })")
        
        // Ensure all UI updates happen on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Trigger UI update before making changes
            self.objectWillChange.send()
            
            // Deactivate all models
            for i in self.availableModels.indices {
                self.availableModels[i].isActive = false
            }
            
            // Activate selected model
            if let index = self.availableModels.firstIndex(where: { $0.id == id }) {
                self.availableModels[index].isActive = true
                self.activeModel = self.availableModels[index]
                self.modelRegistry.setActiveModel(id: id)
                self.saveModelRegistry()
                
                print("DEBUG: Switched to model: \(self.activeModel?.name ?? "Unknown")")
                print("DEBUG: hasAvailableModel: \(self.hasAvailableModel)")
                print("DEBUG: hasCompiledModel: \(self.hasCompiledModel)")
            } else {
                print("DEBUG: Model with id \(id) not found!")
            }
        }
    }
    
    func deleteModel(id: UUID) throws {
        guard let modelInfo = availableModels.first(where: { $0.id == id }) else {
            throw ModelError.modelNotFound("Model not found")
        }
        
        // Can't delete bundled models
        guard modelInfo.source == .uploaded else {
            throw ModelError.cannotDeleteBundled("Cannot delete built-in models")
        }
        
        // Delete files
        try ModelFileUtilities.deleteModel(fileName: modelInfo.fileName, isUploaded: modelInfo.source == .uploaded)
        
        // Remove from registry
        availableModels.removeAll { $0.id == id }
        
        // If this was the active model, switch to bundled model
        if activeModel?.id == id {
            if let bundledModel = availableModels.first(where: { $0.source == .bundled }) {
                setActiveModel(id: bundledModel.id)
            } else {
                activeModel = nil
            }
        }
        
        saveModelRegistry()
        print("Deleted model: \(modelInfo.name)")
    }
    
    // MARK: - Model Loading
    func getModelURL(for modelInfo: ModelInfo) -> URL? {
        switch modelInfo.source {
        case .bundled:
            // Try to get from bundle first
            if let url = Bundle.main.url(forResource: modelInfo.name, withExtension: "mlmodelc") ??
                       Bundle.main.url(forResource: modelInfo.name, withExtension: "mlpackage") ??
                       Bundle.main.url(forResource: modelInfo.name, withExtension: "mlmodel") {
                return url
            }
            return nil
            
        case .uploaded:
            // Prefer compiled .mlmodelc if present
            let compiledURL = ModelFileUtilities.uploadedModelsDirectory
                .appendingPathComponent("\(modelInfo.name).mlmodelc")
            if FileManager.default.fileExists(atPath: compiledURL.path) { return compiledURL }

            // Support .mlpackage in uploaded directory
            let packageURL = ModelFileUtilities.uploadedModelsDirectory
                .appendingPathComponent("\(modelInfo.name).mlpackage")
            if FileManager.default.fileExists(atPath: packageURL.path) { return packageURL }

            // Fallback to .mlmodel
            let uploadedURL = ModelFileUtilities.uploadedModelsDirectory
                .appendingPathComponent("\(modelInfo.name).mlmodel")
            if FileManager.default.fileExists(atPath: uploadedURL.path) { return uploadedURL }

            return nil
        }
    }
    
    func loadModel(for modelInfo: ModelInfo) throws -> MLModel {
        guard let modelURL = getModelURL(for: modelInfo) else {
            throw ModelError.modelNotFound("Model file not found: \(modelInfo.name)")
        }
        
        return try MLModel(contentsOf: modelURL)
    }
    
    func getActiveModelMetadata() -> ModelMetadata? {
        guard let activeModel = activeModel,
              let modelURL = getModelURL(for: activeModel) else {
            return nil
        }
        
        do {
            let model = try MLModel(contentsOf: modelURL)
            return try ModelMetadata(from: model)
        } catch {
            print("Failed to get model metadata: \(error)")
            return nil
        }
    }
}

// MARK: - Model Errors
enum ModelError: LocalizedError {
    case modelNotFound(String)
    case compilationFailed(String)
    case incompatibleModel(String)
    case duplicateName(String)
    case cannotDeleteBundled(String)
    case invalidFile(String)
    
    var errorDescription: String? {
        switch self {
        case .modelNotFound(let message),
             .compilationFailed(let message),
             .incompatibleModel(let message),
             .duplicateName(let message),
             .cannotDeleteBundled(let message),
             .invalidFile(let message):
            return message
        }
    }
} 
