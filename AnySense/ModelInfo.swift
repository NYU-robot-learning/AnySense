import Foundation

// MARK: - Model Information
struct ModelInfo: Identifiable, Codable, Equatable {
    let id: UUID
    let name: String
    let fileName: String
    let source: ModelSource
    var compilationStatus: CompilationStatus
    let fileSize: Int64
    let uploadDate: Date
    var isActive: Bool
    
    init(name: String, fileName: String, source: ModelSource, fileSize: Int64 = 0, uploadDate: Date? = nil) {
        self.id = UUID()
        self.name = name
        self.fileName = fileName
        self.source = source
        self.compilationStatus = source == .bundled ? .compiled : .notCompiled
        self.fileSize = fileSize
        self.uploadDate = uploadDate ?? Date()
        self.isActive = false
    }
    
    var displayName: String {
        switch source {
        case .bundled:
            return "\(name) (Built-in)"
        case .uploaded:
            return name
        }
    }
    
    var statusDescription: String {
        switch compilationStatus {
        case .notCompiled:
            return "Not compiled"
        case .compiling(let progress):
            return "Compiling (\(Int(progress * 100))%)"
        case .compiled:
            return "Ready"
        case .failed(let error):
            return "Failed: \(error)"
        }
    }
}

// MARK: - Model Source
enum ModelSource: String, Codable, CaseIterable {
    case bundled
    case uploaded
    
    var displayName: String {
        switch self {
        case .bundled:
            return "Built-in"
        case .uploaded:
            return "Uploaded"
        }
    }
}

// MARK: - Compilation Status
enum CompilationStatus: Codable, Equatable {
    case notCompiled
    case compiling(progress: Double)
    case compiled
    case failed(error: String)
    
    var isCompiled: Bool {
        if case .compiled = self {
            return true
        }
        return false
    }
    
    var isCompiling: Bool {
        if case .compiling = self {
            return true
        }
        return false
    }
    
    var progress: Double {
        if case .compiling(let progress) = self {
            return progress
        }
        return 0.0
    }
}

// MARK: - Model Registry
struct ModelRegistry: Codable {
    var models: [ModelInfo]
    var activeModelID: UUID?
    var version: String
    
    init() {
        self.models = []
        self.activeModelID = nil
        self.version = "1.0"
    }
    
    mutating func addModel(_ model: ModelInfo) {
        models.append(model)
    }
    
    mutating func updateModel(_ model: ModelInfo) {
        if let index = models.firstIndex(where: { $0.id == model.id }) {
            models[index] = model
        }
    }
    
    mutating func removeModel(id: UUID) {
        models.removeAll { $0.id == id }
        if activeModelID == id {
            activeModelID = models.first?.id
        }
    }
    
    mutating func setActiveModel(id: UUID) {
        for i in models.indices {
            models[i].isActive = models[i].id == id
        }
        activeModelID = id
    }
    
    var activeModel: ModelInfo? {
        return models.first { $0.isActive }
    }
    
    var compiledModels: [ModelInfo] {
        return models.filter { $0.compilationStatus.isCompiled }
    }
} 
