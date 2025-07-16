import Foundation
import RealityKit
import ARKit
import simd
import UIKit

// MARK: - Directional Arrow Data
struct DirectionalArrow {
    let entity: Entity
    let anchor: AnchorEntity
    let timestamp: TimeInterval
    let magnitude: Float
}

// MARK: - Visualization Frequency (Matching MLInferenceManager)
enum VisualizationFrequency: CaseIterable {
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

// MARK: - AR Visualization Manager
class ARVisualizationManager: ObservableObject {
    
    // MARK: - Published Properties
    @Published var isVisualizationEnabled: Bool = false
    @Published var showMovementArrows: Bool = true
    @Published var maxArrows: Int = 10
    @Published var visualizationFrequency: VisualizationFrequency = .medium
    
    // MARK: - Private Properties  
    private var arView: ARView?
    private var worldOriginAnchor: AnchorEntity?
    private var movementArrows: [DirectionalArrow] = []
    private var lastVisualizationTime: CFTimeInterval = 0
    
    // Movement tracking
    private var worldOrigin: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
    private var currentWorldPosition: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
    private var previousWorldPosition: SIMD3<Float>?
    private var hasEstablishedOrigin: Bool = false
    
    // Arrow visual configuration
    private let arrowBaseLength: Float = 0.15      // Base length in meters
    private let arrowThickness: Float = 0.008      // Arrow shaft thickness
    private let arrowHeadRatio: Float = 0.25       // Head vs shaft ratio
    private let arrowHeadWidth: Float = 0.025      // Arrow head width
    private let axisLength: Float = 0.08           // Coordinate axes length
    private let axisThickness: Float = 0.005       // Coordinate axes thickness
    
    // Arrow lifecycle
    private let arrowLifetime: TimeInterval = 3.0  // Arrows fade after 3 seconds
    
    // MARK: - Initialization 
    init() {
        print("ARVisualizationManager initialized with delta-based movement arrows")
    }
    
    // MARK: - Setup Methods
    func setupVisualization(with arView: ARView) {
        self.arView = arView
        print("AR Visualization setup completed - using camera-relative directional arrows")
    }
    
    // MARK: - Recording Control Methods
    func startRecordingVisualization() {
        print("startRecordingVisualization called")
        
        guard let arView = arView else { 
            print("ARView not available for visualization")
            return 
        }
        
        print("Establishing world origin for movement tracking...")
        establishWorldOrigin()
        enableVisualization()
        
        print("Started movement visualization - enabled=\(isVisualizationEnabled)")
    }
    
    func stopRecordingVisualization() {
        disableVisualization()
        clearAllVisualization()
        resetMovementTracking()
        print("Stopped movement visualization and reset tracking")
    }
    
    // MARK: - World Origin & Movement Tracking
    private func getCurrentCameraTransform() -> float4x4 {
        return arView?.session.currentFrame?.camera.transform ?? matrix_identity_float4x4
    }
    
    private func getCurrentCameraPosition() -> SIMD3<Float> {
        let transform = getCurrentCameraTransform()
        return SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
    }
    
    private func establishWorldOrigin() {
        guard let arView = arView else { return }
        guard !hasEstablishedOrigin else {
            print("World origin already established")
            return
        }
        
        // Set world origin at current camera position
        worldOrigin = getCurrentCameraPosition()
        currentWorldPosition = SIMD3<Float>(0, 0, 0) // Start at origin
        previousWorldPosition = nil
        hasEstablishedOrigin = true
        
        // Create anchor at world origin
        worldOriginAnchor = AnchorEntity(world: worldOrigin)
        arView.scene.addAnchor(worldOriginAnchor!)
        
        print("🌍 World origin established at: \(worldOrigin)")
    }
    
    private func resetMovementTracking() {
        hasEstablishedOrigin = false
        worldOrigin = SIMD3<Float>(0, 0, 0)
        currentWorldPosition = SIMD3<Float>(0, 0, 0)
        previousWorldPosition = nil
        
        worldOriginAnchor?.removeFromParent()
        worldOriginAnchor = nil
    }
    

    
    // MARK: - Control Methods
    func enableVisualization() {
        isVisualizationEnabled = true
    }
    
    func disableVisualization() {
        isVisualizationEnabled = false
        clearAllVisualization()
    }
    
    private func clearAllVisualization() {
        // Remove all movement arrows
        for arrow in movementArrows {
            arrow.anchor.removeFromParent()
        }
        movementArrows.removeAll()
    }
    
    func toggleMovementArrows() {
        showMovementArrows.toggle()
        if !showMovementArrows {
            // Remove all movement arrows
            for arrow in movementArrows {
                arrow.anchor.removeFromParent()
            }
            movementArrows.removeAll()
        }
    }
    
    func setMaxArrows(_ count: Int) {
        maxArrows = max(1, min(20, count))
        // Trim existing arrows if needed
        while movementArrows.count > maxArrows {
            let oldArrow = movementArrows.removeFirst()
            oldArrow.anchor.removeFromParent()
        }
    }
    
    // MARK: - Frequency Control Methods
    func setVisualizationFrequency(_ frequency: VisualizationFrequency) {
        visualizationFrequency = frequency
        print("AR Visualization frequency set to: \(frequency.displayName)")
    }
    
    // MARK: - ML Integration Method
    func updatePoseFromMLOutput(_ jointActions: [Float], timestamp: CFTimeInterval = CACurrentMediaTime()) {
        // Apply frequency throttling
        if timestamp - lastVisualizationTime < visualizationFrequency.interval {
            return
        }
        
        lastVisualizationTime = timestamp
        
        guard isVisualizationEnabled, showMovementArrows else { return }
        guard hasEstablishedOrigin else {
            print("World origin not established - cannot track movement")
            return
        }
        guard jointActions.count >= 6 else {
            print("Invalid joint actions array - need at least 6 values, got \(jointActions.count)")
            return
        }
        
        // Interpret joint actions as movement deltas in ARKit coordinates
        let (deltaTranslation, _, confidence) = interpretMLDirections(jointActions)
        
        print("📱 ML input (x=down,y=right,z=back): (\(String(format: "%.3f", jointActions[0])), \(String(format: "%.3f", jointActions[1])), \(String(format: "%.3f", jointActions[2])))")
        print("📲 Delta movement (x=right,y=up,z=forward): (\(String(format: "%.3f", deltaTranslation.x)), \(String(format: "%.3f", deltaTranslation.y)), \(String(format: "%.3f", deltaTranslation.z)))")
        print("🎯 Confidence: \(String(format: "%.2f", confidence))")
        
        // Update position tracking
        let previousPosition = currentWorldPosition
        currentWorldPosition = currentWorldPosition + deltaTranslation
        
        // Only create movement arrow if there's meaningful movement and we have a previous position
        let movementMagnitude = length(deltaTranslation)
        if movementMagnitude > 0.005 { // 5mm threshold for meaningful movement
            createMovementArrow(
                from: previousPosition,
                to: currentWorldPosition,
                confidence: confidence,
                timestamp: timestamp
            )
        }
        
        print("🎯 Position updated: \(String(format: "(%.3f,%.3f,%.3f)", currentWorldPosition.x, currentWorldPosition.y, currentWorldPosition.z)) → moved \(String(format: "%.3f", movementMagnitude))m")
    }
    
    private func interpretMLDirections(_ jointActions: [Float]) -> (translation: SIMD3<Float>, rotation: simd_quatf, confidence: Float) {
        
        // Interpret as directional vectors (not absolute positions)
        // Transform from ML coordinate system to ARKit camera-relative coordinates
        let ml_x = jointActions[0]  // down
        let ml_y = jointActions[1]  // right  
        let ml_z = jointActions[2]  // backward (into phone)
        let ml_roll = jointActions[3]
        let ml_pitch = jointActions[4]
        let ml_yaw = jointActions[5]
        
        // COORDINATE SYSTEM TRANSFORMATION:
        // Phone ML: x=down, y=right, z=backward → ARKit: x=right, y=up, z=forward
        // 
        // ML x (down)     → ARKit y (up)      → negate: -ml_x
        // ML y (right)    → ARKit x (right)   → direct: ml_y  
        // ML z (backward) → ARKit z (forward) → negate: -ml_z
        let translation = SIMD3<Float>(
            ml_y,          // ML y (right) → ARKit x (right)
            -ml_x,         // ML x (down) → ARKit y (up), so -x
            ml_z          // ML z (backward) → ARKit z (forward), so -z
        )
        
        // Transform rotation
        let rotation = eulerToQuaternion(
            roll: ml_pitch,    // Transform coordinate system
            pitch: -ml_roll,
            yaw: ml_yaw
        )
        
        // Calculate confidence based on magnitude
        let translationMagnitude = length(translation)
        let rotationMagnitude = sqrt(ml_roll * ml_roll + ml_pitch * ml_pitch + ml_yaw * ml_yaw)
        let confidence = min(1.0, (translationMagnitude * 10 + rotationMagnitude) / 2.0) // Scale for reasonable confidence
        
        return (translation, rotation, confidence)
    }
    
    private func createMovementArrow(from: SIMD3<Float>, to: SIMD3<Float>, confidence: Float, timestamp: TimeInterval) {
        guard let arView = arView, let worldOriginAnchor = worldOriginAnchor else { return }
        
        DispatchQueue.main.async { [weak self, arView, worldOriginAnchor] in
            guard let self = self else { return }
            
            // Calculate movement vector
            let movement = to - from
            let movementMagnitude = length(movement)
            
            // Skip tiny movements
            guard movementMagnitude > 0.001 else { return }
            
            // Convert positions to world coordinates (relative to world origin)
            let worldFromPosition = self.worldOrigin + from
            let worldToPosition = self.worldOrigin + to
            
            // Create arrow entity showing movement from previous to current position
            let arrowEntity = self.createMovementArrowEntity(
                fromPosition: from,
                toPosition: to,
                movement: movement,
                confidence: confidence
            )
            
            // Position arrow at the start position (in world origin's coordinate system)
            arrowEntity.position = from
            worldOriginAnchor.addChild(arrowEntity)
            
            // Store arrow with metadata
            let movementArrow = DirectionalArrow(
                entity: arrowEntity,
                anchor: worldOriginAnchor,
                timestamp: timestamp,
                magnitude: movementMagnitude
            )
            
            self.movementArrows.append(movementArrow)
            
            // Clean up old arrows
            self.cleanupOldArrows(currentTime: timestamp)
            
            // Limit number of arrows
            while self.movementArrows.count > self.maxArrows {
                let oldArrow = self.movementArrows.removeFirst()
                oldArrow.entity.removeFromParent()
            }
            
            print("🏹 Movement arrow: from=\(String(format: "(%.3f,%.3f,%.3f)", from.x, from.y, from.z)) to=\(String(format: "(%.3f,%.3f,%.3f)", to.x, to.y, to.z)) move=\(String(format: "%.3f", movementMagnitude))m")
        }
    }
    
    private func createMovementArrowEntity(fromPosition: SIMD3<Float>, toPosition: SIMD3<Float>, movement: SIMD3<Float>, confidence: Float) -> Entity {
        let arrowContainer = Entity()
        
        // Calculate arrow dimensions based on movement magnitude
        let movementMagnitude = length(movement)
        let scaledLength = max(movementMagnitude, 0.02) // Minimum 2cm for visibility
        let shaftLength = scaledLength * (1.0 - arrowHeadRatio)
        let headLength = scaledLength * arrowHeadRatio
        
        // Create arrow shaft (cylinder) 
        let shaftMesh = MeshResource.generateBox(
            width: arrowThickness,
            height: arrowThickness,
            depth: shaftLength
        )
        
        // Color based on confidence: red (low) -> yellow (medium) -> green (high)
        let shaftColor = confidenceToColor(confidence)
        let shaftEntity = ModelEntity(
            mesh: shaftMesh,
            materials: [SimpleMaterial(color: shaftColor, isMetallic: false)]
        )
        
        // Create arrow head (pointing toward destination)
        let headMesh = MeshResource.generateBox(
            width: arrowHeadWidth,
            height: arrowHeadWidth,
            depth: headLength
        )
        
        let headEntity = ModelEntity(
            mesh: headMesh,
            materials: [SimpleMaterial(color: shaftColor.withAlphaComponent(0.9), isMetallic: false)]
        )
        
        // Position shaft and head along the movement vector
        shaftEntity.position = SIMD3<Float>(0, 0, shaftLength / 2)
        headEntity.position = SIMD3<Float>(0, 0, shaftLength + headLength / 2)
        
        // Orient arrow in direction of movement
        if movementMagnitude > 0.001 {
            let normalizedMovement = normalize(movement)
            let forward = SIMD3<Float>(0, 0, 1)
            let rotationQuat = simd_quatf(from: forward, to: normalizedMovement)
            
            arrowContainer.orientation = rotationQuat
        }
        
        arrowContainer.addChild(shaftEntity)
        arrowContainer.addChild(headEntity)
        
        return arrowContainer
    }
    
    private func confidenceToColor(_ confidence: Float) -> UIColor {
        // Red (low confidence) -> Yellow (medium) -> Green (high confidence)
        let clampedConfidence = max(0.0, min(1.0, confidence))
        
        if clampedConfidence < 0.5 {
            // Red to Yellow
            let factor = clampedConfidence * 2.0
            return UIColor(red: 1.0, green: CGFloat(factor), blue: 0.0, alpha: 0.8)
        } else {
            // Yellow to Green
            let factor = (clampedConfidence - 0.5) * 2.0
            return UIColor(red: CGFloat(1.0 - factor), green: 1.0, blue: 0.0, alpha: 0.8)
        }
    }
    
    private func cleanupOldArrows(currentTime: TimeInterval) {
        let expiredArrows = movementArrows.filter { currentTime - $0.timestamp > arrowLifetime }
        
        for expiredArrow in expiredArrows {
            expiredArrow.entity.removeFromParent()
            if let index = movementArrows.firstIndex(where: { $0.timestamp == expiredArrow.timestamp }) {
                movementArrows.remove(at: index)
            }
        }
        
        if !expiredArrows.isEmpty {
            print("Cleaned up \(expiredArrows.count) expired movement arrows")
        }
    }
    
    private func eulerToQuaternion(roll: Float, pitch: Float, yaw: Float) -> simd_quatf {
        let phi_2 = roll / 2.0    
        let theta_2 = pitch / 2.0 
        let psi_2 = yaw / 2.0     
        
        let cos_phi_2 = cos(phi_2)
        let sin_phi_2 = sin(phi_2)
        let cos_theta_2 = cos(theta_2)
        let sin_theta_2 = sin(theta_2)
        let cos_psi_2 = cos(psi_2)
        let sin_psi_2 = sin(psi_2)
        
        let w = cos_phi_2 * cos_theta_2 * cos_psi_2 + sin_phi_2 * sin_theta_2 * sin_psi_2
        let x = sin_phi_2 * cos_theta_2 * cos_psi_2 - cos_phi_2 * sin_theta_2 * sin_psi_2
        let y = cos_phi_2 * sin_theta_2 * cos_psi_2 + sin_phi_2 * cos_theta_2 * sin_psi_2
        let z = cos_phi_2 * cos_theta_2 * sin_psi_2 - sin_phi_2 * sin_theta_2 * cos_psi_2
        
        return simd_quatf(ix: x, iy: y, iz: z, r: w)
    }
}
