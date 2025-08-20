import Foundation
import CoreML

// MARK: - Enhanced Model Metadata
struct ModelMetadata {
    let modelType: ModelType
    let inputSpecifications: [InputSpecification]
    let outputSpecifications: [OutputSpecification]
    let inputFeatureNames: [String]
    let outputFeatureNames: [String]
    let primaryOutputName: String?
    let isCompatible: Bool
    
    enum ModelType: String, CaseIterable {
        case legacy = "Legacy"              // Original GeneralPickUpV1 model
        case vqbet = "VQ-BeT"              // Point-conditioned policy
        case edgetam = "EdgeTAM"           // Vision segmentation
        case unknown = "Unknown"
        
        var displayName: String {
            return self.rawValue
        }
        
        var requiresGoalInput: Bool {
            switch self {
            case .vqbet:
                return true
            default:
                return false
            }
        }
    }
    
    struct InputSpecification {
        let name: String
        let type: InputType
        let shape: [Int]
        let normalizedSize: CGSize?
        let scalingRequirements: ScalingRequirements?
        
        enum InputType {
            case image
            case multiArray
            case dictionary
        }
        
        struct ScalingRequirements {
            let targetSize: CGSize
            let normalization: Normalization
            
            enum Normalization {
                case zeroToOne          // [0, 1]
                case minusOneToOne     // [-1, 1]
                case imageNet          // ImageNet normalization
                case none
            }
        }
    }
    
    struct OutputSpecification {
        let name: String
        let shape: [Int]
        let interpretation: OutputInterpretation
        
        enum OutputInterpretation {
            case jointPositions(count: Int)  // Robot actions/joint positions are the same
            case segmentationMask
            case features
            case unknown
        }
    }
    
    // MARK: - Model Type Detection
    static func detectModelType(from mlModel: MLModel) -> ModelType {
        let inputNames = Set(mlModel.modelDescription.inputDescriptionsByName.keys)
        let outputNames = Set(mlModel.modelDescription.outputDescriptionsByName.keys)
        
        print("🔍 Model type detection:")
        print("   Input names: \(inputNames)")
        print("   Output names: \(outputNames)")
        
        // VQ-BeT model detection
        if inputNames.contains("camera_image") && inputNames.contains("goal_point") && outputNames.contains("robot_actions") {
            print("   ✅ Detected VQ-BeT model")
            return .vqbet
        }
        
        // Check for VQ-BeT by name (backup detection for simple model)
        if inputNames.count == 2 && outputNames.contains("robot_actions") {
            print("   ✅ Detected VQ-BeT model (simple version)")
            return .vqbet
        }
        
        // EdgeTAM model detection  
        if inputNames.contains("image") && outputNames.contains("vision_features") {
            return .edgetam
        }
        
        // Legacy model detection (single input x_1)
        if inputNames.contains("x_1") && inputNames.count == 1 {
            return .legacy
        }
        
        return .unknown
    }
    
    // MARK: - Metadata Creation
    init(from mlModel: MLModel) throws {
        let modelDescription = mlModel.modelDescription
        self.modelType = Self.detectModelType(from: mlModel)
        
        self.inputFeatureNames = Array(modelDescription.inputDescriptionsByName.keys)
        self.outputFeatureNames = Array(modelDescription.outputDescriptionsByName.keys)
        self.primaryOutputName = outputFeatureNames.first
        
        // Create input specifications based on model type
        var inputSpecs: [InputSpecification] = []
        
        for (name, description) in modelDescription.inputDescriptionsByName {
            let inputSpec = try Self.createInputSpecification(
                name: name,
                description: description,
                modelType: self.modelType
            )
            inputSpecs.append(inputSpec)
        }
        
        self.inputSpecifications = inputSpecs
        
        // Create output specifications
        var outputSpecs: [OutputSpecification] = []
        
        for (name, description) in modelDescription.outputDescriptionsByName {
            let outputSpec = Self.createOutputSpecification(
                name: name,
                description: description,
                modelType: self.modelType
            )
            outputSpecs.append(outputSpec)
        }
        
        self.outputSpecifications = outputSpecs
        
        // Check compatibility
        self.isCompatible = Self.checkCompatibility(modelType: self.modelType, inputSpecs: inputSpecs, outputSpecs: outputSpecs)
    }
    
    // MARK: - Helper Methods
    private static func createInputSpecification(
        name: String,
        description: MLFeatureDescription,
        modelType: ModelType
    ) throws -> InputSpecification {
        
        switch description.type {
        case .image:
            let shape = [Int(description.imageConstraint?.pixelsWide ?? 224), Int(description.imageConstraint?.pixelsHigh ?? 224)]
            let targetSize = CGSize(width: shape[0], height: shape[1])
            
            let scaling = InputSpecification.ScalingRequirements(
                targetSize: targetSize,
                normalization: modelType == .vqbet ? .zeroToOne : .minusOneToOne
            )
            
            return InputSpecification(
                name: name,
                type: .image,
                shape: [3] + shape, // Add channel dimension
                normalizedSize: targetSize,
                scalingRequirements: scaling
            )
            
        case .multiArray:
            if let constraint = description.multiArrayConstraint {
                let shape = constraint.shape.map { $0.intValue }
                return InputSpecification(
                    name: name,
                    type: .multiArray,
                    shape: shape,
                    normalizedSize: nil,
                    scalingRequirements: nil
                )
            }
            fallthrough
            
        default:
            throw NSError(domain: "ModelMetadata", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported input type for \(name)"])
        }
    }
    
    private static func createOutputSpecification(
        name: String,
        description: MLFeatureDescription,
        modelType: ModelType
    ) -> OutputSpecification {
        
        let shape: [Int]
        let interpretation: OutputSpecification.OutputInterpretation
        
        switch description.type {
        case .multiArray:
            if let constraint = description.multiArrayConstraint {
                shape = constraint.shape.map { $0.intValue }
                
                // Determine interpretation based on model type and shape
                switch modelType {
                case .vqbet:
                    if shape.last == 7 {
                        interpretation = .jointPositions(count: 7)  // 7D robot actions
                    } else {
                        interpretation = .unknown
                    }
                case .legacy:
                    interpretation = .jointPositions(count: shape.last ?? 0)
                case .edgetam:
                    interpretation = .features
                default:
                    interpretation = .unknown
                }
            } else {
                shape = []
                interpretation = .unknown
            }
            
        default:
            shape = []
            interpretation = .unknown
        }
        
        return OutputSpecification(
            name: name,
            shape: shape,
            interpretation: interpretation
        )
    }
    
    private static func checkCompatibility(
        modelType: ModelType,
        inputSpecs: [InputSpecification],
        outputSpecs: [OutputSpecification]
    ) -> Bool {
        
        switch modelType {
        case .vqbet:
            // Check for required inputs: camera_image and goal_point
            let hasImageInput = inputSpecs.contains { $0.name == "camera_image" && $0.type == .image }
            let hasGoalInput = inputSpecs.contains { $0.name == "goal_point" && $0.type == .multiArray }
            let hasJointOutput = outputSpecs.contains { 
                $0.name == "robot_actions" && 
                $0.shape.last == 7 
            }
            
            return hasImageInput && hasGoalInput && hasJointOutput
            
        case .legacy:
            // Check for single image input and multi-array output
            let hasSingleImageInput = inputSpecs.count == 1 && inputSpecs.first?.name == "x_1"
            let hasMultiArrayOutput = !outputSpecs.isEmpty
            
            return hasSingleImageInput && hasMultiArrayOutput
            
        case .edgetam:
            // Check for image input and feature output
            let hasImageInput = inputSpecs.contains { $0.type == .image }
            let hasFeatureOutput = !outputSpecs.isEmpty
            
            return hasImageInput && hasFeatureOutput
            
        case .unknown:
            return false
        }
    }
    
    // MARK: - Convenience Methods
    var requiresGoalPoint: Bool {
        return modelType.requiresGoalInput
    }
    
    var imageInputSize: CGSize? {
        return inputSpecifications.first { $0.type == .image }?.normalizedSize
    }
    
    var expectedOutputDimensions: Int? {
        for spec in outputSpecifications {
            switch spec.interpretation {
            case .jointPositions(let count):
                return count
            default:
                continue
            }
        }
        return nil
    }
    
    func getImageInputName() -> String? {
        return inputSpecifications.first { $0.type == .image }?.name
    }
    
    func getGoalInputName() -> String? {
        return inputSpecifications.first { $0.name == "goal_point" }?.name
    }
    
    func getScalingRequirements(for inputName: String) -> InputSpecification.ScalingRequirements? {
        return inputSpecifications.first { $0.name == inputName }?.scalingRequirements
    }
}

// MARK: - Model Validation Extension
extension MLModel {
    static func validateModel(at url: URL) throws -> ModelMetadata {
        let model = try MLModel(contentsOf: url)
        return try ModelMetadata(from: model)
    }
}