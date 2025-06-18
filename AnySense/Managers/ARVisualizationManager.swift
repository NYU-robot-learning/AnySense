import Foundation
import RealityKit
import ARKit
import simd
import UIKit

// MARK: - Pose Data Structure
struct PoseData {
    let translation: SIMD3<Float>  // x, y, z in meters
    let rotation: SIMD3<Float>     // roll, pitch, yaw in radians
    let timestamp: TimeInterval
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
    @Published var showCoordinateAxes: Bool = true
    @Published var showTrail: Bool = true
    @Published var trailLength: Int = 10
    @Published var visualizationFrequency: VisualizationFrequency = .medium
    
    // MARK: - Private Properties  
    private var arView: ARView?
    private var poseAnchor: AnchorEntity?
    private var coordinateAxesEntity: Entity?
    private var trailEntity: Entity?
    private var trailPoints: [SIMD3<Float>] = []
    private var lastVisualizationTime: CFTimeInterval = 0
    
    // Visual configuration (scaled down for less dominance in AR view)
    private let axisLength: Float = 0.1     
    private let axisThickness: Float = 0.003
    private let trailPointSize: Float = 0.015 
    
    private var accumulatedTransform: float4x4 = matrix_identity_float4x4
    
    // World reference frame set at the start of the recording
    private var fixedWorldOrigin: float4x4 = matrix_identity_float4x4
    private var hasEstablishedOrigin: Bool = false
    
    // MARK: - Initialization 
    init() {
        print("ARVisualizationManager initialized")
    }
    
    // MARK: - Setup Methods
    func setupVisualization(with arView: ARView) {
        self.arView = arView
        
        print("AR Visualization setup completed - using incremental delta mode only")
    }
    
    // MARK: - Recording Control Methods
    func startRecordingVisualization() {
        print("startRecordingVisualization called")
        
        guard let arView = arView else { 
            print("ARView not available for visualization")
            return 
        }
        
        print("Setting origin at current camera position...")
        // Set origin at current camera position when recording starts
        setOriginAtCurrentCamera()
        
        print("Enabling visualization...")
        enableVisualization()
        
        print("Started recording visualization - enabled=\(isVisualizationEnabled), hasAxes=\(coordinateAxesEntity != nil)")
    }
    
    func stopRecordingVisualization() {
        disableVisualization()
        clearVisualization()
        poseAnchor?.removeFromParent()
        poseAnchor = nil
        
        // Reset stable origin for next recording session
        fixedWorldOrigin = matrix_identity_float4x4
        hasEstablishedOrigin = false
        
        print("Stopped recording visualization and cleared origin")
    }
    
    private func setOriginAtCurrentCamera() {
        guard let arView = arView else { return }
        
        // Establish STABLE world origin that NEVER changes
        guard !hasEstablishedOrigin else {
            print("World origin already established - ignoring duplicate call")
            return
        }
        
        // Get current camera transform ONCE and store as fixed reference
        fixedWorldOrigin = arView.session.currentFrame?.camera.transform ?? matrix_identity_float4x4
        hasEstablishedOrigin = true
        
        let originPosition = SIMD3<Float>(fixedWorldOrigin.columns.3.x, fixedWorldOrigin.columns.3.y, fixedWorldOrigin.columns.3.z)
        
        // Place anchor at fixed world origin (not moving with camera)
        poseAnchor = AnchorEntity(world: originPosition)
        arView.scene.addAnchor(poseAnchor!)
        
        // Create coordinate axes and trail
        if showCoordinateAxes {
            createCoordinateAxes()
        }
        if showTrail {
            createTrailEntity()
        }
        
        print("FIXED world origin established at: (\(originPosition.x), \(originPosition.y), \(originPosition.z))")
    }
    
    private func createCoordinateAxes() {
        guard let anchor = poseAnchor else { return }
        coordinateAxesEntity = Entity()
        
        let xAxis = createAxisEntity(direction: [1,0,0], color: .red,   length: axisLength)
        let yAxis = createAxisEntity(direction: [0,1,0], color: .green, length: axisLength)
        let zAxis = createAxisEntity(direction: [0,0,1], color: .blue,  length: axisLength)
        
        [xAxis, yAxis, zAxis].forEach { coordinateAxesEntity?.addChild($0) }
        anchor.addChild(coordinateAxesEntity!)
        
        accumulatedTransform = matrix_identity_float4x4
    }
    
    private func createAxisEntity(direction: SIMD3<Float>,
                              color: UIColor,
                              length: Float) -> Entity {
        let axisEntity = Entity()
        
        // Create the shaft
        let shaftLength = length * 0.8
        let shaftMesh = MeshResource.generateBox(
            width: axisThickness,
            height: axisThickness, 
            depth: shaftLength
        )
        
        let shaft = ModelEntity(
            mesh: shaftMesh,
            materials: [SimpleMaterial(color: color, isMetallic: false)]
        )
        
        
        let arrowHeadLength = length * 0.5  
        let arrowHeadSize = axisThickness * 5
        let arrowHeadMesh = MeshResource.generateBox(
            width: arrowHeadSize,
            height: arrowHeadSize,
            depth: arrowHeadLength
        )
        
        let arrowHead = ModelEntity(
            mesh: arrowHeadMesh,
            materials: [SimpleMaterial(color: color, isMetallic: false)]
        )
        
        // Create 3D arrow
        let dirNorm = normalize(direction)
        let forward: SIMD3<Float> = [0, 0, 1] 
        
        let rotQuat = simd_quatf(from: forward, to: dirNorm)
        shaft.orientation = rotQuat
        arrowHead.orientation = rotQuat
        
        shaft.position = dirNorm * (shaftLength / 2)
        arrowHead.position = dirNorm * (shaftLength + arrowHeadLength / 2)
        
        axisEntity.addChild(shaft)
        axisEntity.addChild(arrowHead)
        return axisEntity
    }
    
    private func createTrailEntity() {
        guard let anchor = poseAnchor else { return }
        trailEntity = Entity()
        anchor.addChild(trailEntity!)
    }
    
    
    private func updateTrail(with position: SIMD3<Float>) {
        guard let trail = trailEntity else { return }
        trailPoints.append(position)
        if trailPoints.count > trailLength {
            trailPoints.removeFirst()
        }
        
        trail.children.removeAll()
        for (i, pt) in trailPoints.enumerated() {
            let alpha = Float(i) / Float(trailPoints.count)
            let dot = createTrailPoint(at: pt, alpha: alpha)
            trail.addChild(dot)
        }
    }
    
    private func createTrailPoint(at position: SIMD3<Float>, alpha: Float) -> Entity {
        let dot = ModelEntity(
            mesh: .generateSphere(radius: trailPointSize),
            materials: [SimpleMaterial(
                color: .orange,
                isMetallic: false
            )]
        )
        dot.position = position
        return dot
    }
    
    
    // MARK: - Control Methods
    func enableVisualization() {
        isVisualizationEnabled = true
    }
    
    func disableVisualization() {
        isVisualizationEnabled = false
        clearVisualization()
    }
    
    private func clearVisualization() {
        coordinateAxesEntity?.removeFromParent()
        trailEntity?.removeFromParent()
        trailPoints.removeAll()
    }
    
    func toggleCoordinateAxes() {
        showCoordinateAxes.toggle()
        if showCoordinateAxes {
            createCoordinateAxes()
        } else {
            coordinateAxesEntity?.removeFromParent()
            coordinateAxesEntity = nil
        }
    }
    
    func toggleTrail() {
        showTrail.toggle()
        if showTrail {
            createTrailEntity()
        } else {
            trailEntity?.removeFromParent()
            trailEntity = nil
            trailPoints.removeAll()
        }
    }
    
    func setTrailLength(_ length: Int) {
        trailLength = max(10, min(200, length))
        if trailPoints.count > trailLength {
            trailPoints = Array(trailPoints.suffix(trailLength))
        }
    }
    
    // MARK: - Frequency Control Methods (Matching MLInferenceManager)
    func setVisualizationFrequency(_ frequency: VisualizationFrequency) {
        visualizationFrequency = frequency
        print("AR Visualization frequency set to: \(frequency.displayName)")
    }
    
    // MARK: - ML Integration Method
    // TODO: Fix visualization - logic is not correct
    func updatePoseFromMLOutput(_ jointActions: [Float], timestamp: CFTimeInterval = CACurrentMediaTime()) {
        // Apply frequency throttling (same as MLInferenceManager)
        if timestamp - lastVisualizationTime < visualizationFrequency.interval {
            return
        }
        
        lastVisualizationTime = timestamp
        
        print("AR Visualization update at \(visualizationFrequency.displayName) frequency")
        print("ML Pose Input: \(jointActions.prefix(6).map { String(format: "%.3f", $0) })")
        
        guard jointActions.count >= 6 else {
            print("Invalid joint actions array - need at least 6 values, got \(jointActions.count)")
            return
        }
        
        // Apply coordinate system transformation from PickUp Policy to ARKit
        // Pickup Policy: x=down, y=right, z=backward → ARKit: x=right, y=up, z=forward
        let ml_x = jointActions[0]  
        let ml_y = jointActions[1]  
        let ml_z = jointActions[2]  
        let ml_roll = jointActions[3]
        let ml_pitch = jointActions[4]
        let ml_yaw = jointActions[5]
        
        let arkit_x = ml_y          
        let arkit_y = -ml_x         
        let arkit_z = -ml_z         
        
        let arkit_roll = ml_pitch  
        let arkit_pitch = -ml_roll  
        let arkit_yaw = -ml_yaw     
        
        print("ML→ARKit transform: t=(\(String(format: "%.3f", arkit_x)), \(String(format: "%.3f", arkit_y)), \(String(format: "%.3f", arkit_z))), r=(\(String(format: "%.3f", arkit_roll)), \(String(format: "%.3f", arkit_pitch)), \(String(format: "%.3f", arkit_yaw)))")
        
        let quaternion = eulerToQuaternion(roll: arkit_roll, pitch: arkit_pitch, yaw: arkit_yaw)
        
        applyIncrementalPose(deltaTranslation: SIMD3(arkit_x, arkit_y, arkit_z), deltaQuaternion: quaternion)
        
        print("ML Pose processed and sent to visualization")
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
    
    // Accumulate deltas in the local end-effector frame with stable origin
    private func applyIncrementalPose(deltaTranslation: SIMD3<Float>, deltaQuaternion: simd_quatf) {
        print("Applying incremental pose delta: t=(\(String(format: "%.3f", deltaTranslation.x)), \(String(format: "%.3f", deltaTranslation.y)), \(String(format: "%.3f", deltaTranslation.z)))")
        
        guard isVisualizationEnabled else { 
            print("Visualization not enabled")
            return 
        }
        guard hasEstablishedOrigin else {
            print("World origin not established - cannot apply incremental pose")
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard let axes = self.coordinateAxesEntity else { 
                print("No coordinate axes entity available")
                return 
            }

            // Build delta 4x4 matrix from quaternion + translation
            var deltaMatrix = float4x4(deltaQuaternion)
            deltaMatrix.columns.3 = SIMD4<Float>(deltaTranslation.x, deltaTranslation.y, deltaTranslation.z, 1)

            // Accumulate delta: current_pose = current_pose * delta_pose
            self.accumulatedTransform = self.accumulatedTransform * deltaMatrix

            // Transform accumulated pose relative to fixed world origin
            let originPosition = SIMD3<Float>(self.fixedWorldOrigin.columns.3.x, 
                                            self.fixedWorldOrigin.columns.3.y, 
                                            self.fixedWorldOrigin.columns.3.z)
            let originQuat = simd_quatf(self.fixedWorldOrigin)
            
            // Compose with world origin
            let worldTransform = self.fixedWorldOrigin * self.accumulatedTransform
            
            // Apply the final transform to coordinate axes
            axes.transform = Transform(matrix: worldTransform)

            // Update trail with world position
            let worldPosition = SIMD3<Float>(worldTransform.columns.3.x,
                                           worldTransform.columns.3.y,
                                           worldTransform.columns.3.z)
            if self.showTrail {
                self.updateTrail(with: worldPosition)
            }
            
            print("Incremental pose applied: accumulated=(\(String(format: "%.2f", self.accumulatedTransform.columns.3.x)), \(String(format: "%.2f", self.accumulatedTransform.columns.3.y)), \(String(format: "%.2f", self.accumulatedTransform.columns.3.z))), world=(\(String(format: "%.2f", worldPosition.x)), \(String(format: "%.2f", worldPosition.y)), \(String(format: "%.2f", worldPosition.z)))")
        }
    }
    
}
