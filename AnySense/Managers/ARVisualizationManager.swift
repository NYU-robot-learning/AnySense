import Foundation
import RealityKit
import ARKit
import simd
import UIKit

// MARK: - Action State
enum ActionState {
    case waiting  // User is moving toward target
    case reached  // Cubes overlapped, inference triggered
    
    var displayName: String {
        switch self {
        case .waiting: return "waiting"
        case .reached: return "reached"
        }
    }
}

// MARK: - Target State
enum TargetState {
    case active  // Red target
    case reached  // Green target
}

// MARK: - Fading Target
struct FadingTarget {
    var entity: ModelEntity
    var position: SIMD3<Float>
    var fadeStartTime: CFTimeInterval
    var state: TargetState
}

// MARK: - Visualization Frequency
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
    @Published var actionState: ActionState = .waiting
    @Published var visualizationFrequency: VisualizationFrequency = .medium
    
    // MARK: - Private Properties  
    private var arView: ARView?
    private var worldOriginAnchor: AnchorEntity?
    private var targetPose: SIMD3<Float>?
    private var goalPointEntity: ModelEntity?
    private var worldOrigin: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
    private var hasEstablishedOrigin: Bool = false
    
    var debugLoggingEnabled: Bool = true
    var isGripperClosed: Bool = false
    var useVirtualGripper: Bool = false
    var applyEndOffset: Bool = true
    var endOffsetMeters: Float = 0.02
    
    // MARK: - Wireframe & Target Visualization
    private var wireframeEntity: Entity?
    private var wireframeAnchor: AnchorEntity?
    private let wireframeSize: Float = 0.018
    private let wireframeOffsetMeters: Float = 0.04
    private var wireframeVisualPosition: SIMD3<Float>?
    private var activeTargetEntity: ModelEntity?
    private var activeTargetPosition: SIMD3<Float>?
    private var fadingTargets: [FadingTarget] = []
    private var displayLink: CADisplayLink?
    private let fadeDuration: CFTimeInterval = 0.1
    private let targetSize: Float = 0.012
    private var lastWireframeUpdateTime: CFTimeInterval = 0
    private let wireframeUpdateInterval: CFTimeInterval = 0.033
    
    // MARK: - Initialization 
    init() {
        log("Initialized with wireframe seek-target visualization")
    }
    
    // MARK: - Logging Helper
    private func log(_ message: String) {
        print("[ARViz] \(message)")
    }
    
    // MARK: - Setup Methods
    func setupVisualization(with arView: ARView) {
        self.arView = arView
        setupFadeAnimation()
        log("Setup completed - using wireframe seek-target visualization")
    }
    
    // MARK: - Fade Animation Setup
    private func setupFadeAnimation() {
        displayLink = CADisplayLink(target: self, selector: #selector(updateFadingTargets))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        displayLink?.add(to: .main, forMode: .common)
    }
    
    @objc private func updateFadingTargets() {
        guard !fadingTargets.isEmpty else { return }
        
        let currentTime = CACurrentMediaTime()
        var targetsToRemove: [Int] = []
        
        for (index, fadingTarget) in fadingTargets.enumerated() {
            let elapsed = currentTime - fadingTarget.fadeStartTime
            let alpha = Float(max(0.0, 1.0 - elapsed / fadeDuration))
            
            if alpha <= 0.05 {
                fadingTarget.entity.removeFromParent()
                targetsToRemove.append(index)
                continue
            }
            
            let greenMaterial = SimpleMaterial(
                color: UIColor.systemGreen.withAlphaComponent(CGFloat(alpha)),
                isMetallic: false
            )
            fadingTarget.entity.model?.materials = [greenMaterial]
        }
        
        // Remove completed fades (reverse order to maintain indices)
        for index in targetsToRemove.reversed() {
            fadingTargets.remove(at: index)
        }
    }
    
    // MARK: - Recording Control Methods
    func startRecordingVisualization() {
        print("startRecordingVisualization called")
        
        guard arView != nil else { 
            print("ARView not available for visualization")
            return 
        }
        
        print("Establishing world origin for movement tracking...")
        establishWorldOrigin()
        enableVisualization()
        
        // Reset gripper state to allow visualization
        isGripperClosed = false
        
        print("Started movement visualization - enabled=\(isVisualizationEnabled)")
    }
    
    func stopRecordingVisualization() {
        disableVisualization()
        clearAllVisualization()
        resetMovementTracking()
        
        // Reset action state
        actionState = .waiting
        
        // Reset gripper state
        isGripperClosed = false
        
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
        guard let currentArView = arView else { return }
        guard !hasEstablishedOrigin else { return }
        
        worldOrigin = getCurrentCameraPosition()
        hasEstablishedOrigin = true

        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4<Float>(worldOrigin.x, worldOrigin.y, worldOrigin.z, 1)
        let anchor = AnchorEntity(world: t)
        currentArView.scene.addAnchor(anchor)
        worldOriginAnchor = anchor
        
        print("World origin set at: \(worldOrigin)")
    }
    
    private func resetMovementTracking() {
        hasEstablishedOrigin = false
        worldOrigin = SIMD3<Float>(0, 0, 0)
        goalPointEntity?.removeFromParent()
        goalPointEntity = nil
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
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            self.wireframeEntity?.removeFromParent()
            self.wireframeEntity = nil
            self.wireframeAnchor?.removeFromParent()
            self.wireframeAnchor = nil
            self.wireframeVisualPosition = nil
            self.activeTargetEntity?.removeFromParent()
            self.activeTargetEntity = nil
            self.activeTargetPosition = nil
            
            for fadingTarget in self.fadingTargets {
                fadingTarget.entity.removeFromParent()
            }
            self.fadingTargets.removeAll()
        }
    }

    // MARK: - Initialization helper
    func ensureVisualizationReady() {
        if !hasEstablishedOrigin { establishWorldOrigin() }
        if !isVisualizationEnabled { enableVisualization() }
        if targetPose != nil && goalPointEntity == nil && worldOriginAnchor != nil {
            updateGoalPointVisualization()
        }
    }
    
    // MARK: - Wireframe Management
    func updateWireframe(cameraRelativePosition: SIMD3<Float>) {
        guard isVisualizationEnabled, !isGripperClosed else { return }
        
        let currentTime = CACurrentMediaTime()
        guard currentTime - lastWireframeUpdateTime >= wireframeUpdateInterval else {
            wireframeVisualPosition = cameraRelativePosition
            checkProximityAndUpdateState()
            return
        }
        lastWireframeUpdateTime = currentTime
        
        wireframeVisualPosition = cameraRelativePosition
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let arView = self.arView else { return }
            
            if self.wireframeAnchor == nil {
                self.wireframeAnchor = AnchorEntity(.camera)
                arView.scene.addAnchor(self.wireframeAnchor!)
            }
            
            if self.wireframeEntity == nil {
                self.wireframeEntity = self.createWireframeBox()
                self.wireframeAnchor!.addChild(self.wireframeEntity!)
            }
            
            self.wireframeEntity?.position = SIMD3<Float>(0, 0, -self.wireframeOffsetMeters)
        }
        
        checkProximityAndUpdateState()
    }
    
    // MARK: - Wireframe Creation
    private func createWireframeBox() -> Entity {
        let wireframeGroup = Entity()
        let edgeThickness: Float = 0.001
        let half = wireframeSize / 2.0
        
        createWireframeEdge(from: SIMD3<Float>(-half, -half, -half),
                           to: SIMD3<Float>(half, -half, -half),
                           thickness: edgeThickness,
                           parent: wireframeGroup)
        createWireframeEdge(from: SIMD3<Float>(half, -half, -half),
                           to: SIMD3<Float>(half, half, -half),
                           thickness: edgeThickness,
                           parent: wireframeGroup)
        createWireframeEdge(from: SIMD3<Float>(half, half, -half),
                           to: SIMD3<Float>(-half, half, -half),
                           thickness: edgeThickness,
                           parent: wireframeGroup)
        createWireframeEdge(from: SIMD3<Float>(-half, half, -half),
                           to: SIMD3<Float>(-half, -half, -half),
                           thickness: edgeThickness,
                           parent: wireframeGroup)
        createWireframeEdge(from: SIMD3<Float>(-half, -half, half),
                           to: SIMD3<Float>(half, -half, half),
                           thickness: edgeThickness,
                           parent: wireframeGroup)
        createWireframeEdge(from: SIMD3<Float>(half, -half, half),
                           to: SIMD3<Float>(half, half, half),
                           thickness: edgeThickness,
                           parent: wireframeGroup)
        createWireframeEdge(from: SIMD3<Float>(half, half, half),
                           to: SIMD3<Float>(-half, half, half),
                           thickness: edgeThickness,
                           parent: wireframeGroup)
        createWireframeEdge(from: SIMD3<Float>(-half, half, half),
                           to: SIMD3<Float>(-half, -half, half),
                           thickness: edgeThickness,
                           parent: wireframeGroup)
        createWireframeEdge(from: SIMD3<Float>(-half, -half, -half),
                           to: SIMD3<Float>(-half, -half, half),
                           thickness: edgeThickness,
                           parent: wireframeGroup)
        createWireframeEdge(from: SIMD3<Float>(half, -half, -half),
                           to: SIMD3<Float>(half, -half, half),
                           thickness: edgeThickness,
                           parent: wireframeGroup)
        createWireframeEdge(from: SIMD3<Float>(-half, half, -half),
                           to: SIMD3<Float>(-half, half, half),
                           thickness: edgeThickness,
                           parent: wireframeGroup)
        createWireframeEdge(from: SIMD3<Float>(half, half, -half),
                           to: SIMD3<Float>(half, half, half),
                           thickness: edgeThickness,
                           parent: wireframeGroup)
        
        return wireframeGroup
    }
    
    private func createWireframeEdge(from: SIMD3<Float>, to: SIMD3<Float>, thickness: Float, parent: Entity) {
        let direction = to - from
        let edgeLength = length(direction)
        guard edgeLength > 1e-6 else { return }
        
        let center = (from + to) / 2.0
        let targetDir = direction / edgeLength
        let edgeMesh = MeshResource.generateBox(width: thickness, height: thickness, depth: edgeLength)
        let blueMaterial = SimpleMaterial(color: UIColor.systemBlue.withAlphaComponent(0.9), isMetallic: false)
        let edgeEntity = ModelEntity(mesh: edgeMesh, materials: [blueMaterial])
        edgeEntity.position = center
        
        let defaultDir = SIMD3<Float>(0, 0, 1)
        let dotProduct = dot(defaultDir, targetDir)
        
        if abs(dotProduct) > 0.999 {
            if dotProduct < 0 {
                edgeEntity.orientation = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
            }
        } else {
            let axis = cross(defaultDir, targetDir)
            let axisLength = length(axis)
            if axisLength > 1e-6 {
                let angle = acos(max(-1.0, min(1.0, dotProduct)))
                edgeEntity.orientation = simd_quatf(angle: angle, axis: axis / axisLength)
            }
        }
        
        parent.addChild(edgeEntity)
    }
    
    
    private var lastLoggedDistance: Float = -1.0
    
    private func checkProximityAndUpdateState() {
        guard !isGripperClosed,
              let wireframePos = wireframeVisualPosition,
              let targetPos = activeTargetPosition else { return }
        
        // Use distance-based proximity instead of strict overlap
        let distance = length(targetPos - wireframePos)

        // Proximity threshold: more generous threshold for easier interaction
        // targetSize=0.012m, wireframeSize=0.018m, so threshold = ~3cm
        let proximityThreshold: Float = 0.03  // 3cm threshold - much more forgiving

        let isNearby = distance <= proximityThreshold
        
        if debugLoggingEnabled {
            let distanceChanged = abs(distance - lastLoggedDistance) > 0.01
            if distanceChanged || isNearby {
                print("[Proximity] Distance: \(String(format: "%.3f", distance))m | Threshold: \(String(format: "%.3f", proximityThreshold))m | Nearby: \(isNearby)")
                lastLoggedDistance = distance
            }
        }

        if isNearby {
            if actionState != .reached {
                actionState = .reached
                transitionTargetToFading()
                NotificationCenter.default.post(name: NSNotification.Name("ProximityReached"), object: nil)
            }
        } else {
            if actionState != .waiting {
                actionState = .waiting
            }
        }
    }
    
    // MARK: - Target Transition
    private func transitionTargetToFading() {
        guard let activeEntity = activeTargetEntity,
              let activePos = activeTargetPosition else { return }
        
        let greenMaterial = SimpleMaterial(color: UIColor.systemGreen.withAlphaComponent(1.0), isMetallic: false)
        activeEntity.model?.materials = [greenMaterial]
        
        let fadingTarget = FadingTarget(
            entity: activeEntity,
            position: activePos,
            fadeStartTime: CACurrentMediaTime(),
            state: .reached
        )
        fadingTargets.append(fadingTarget)
        activeTargetEntity = nil
        activeTargetPosition = nil
    }
    
    // MARK: - Manual Trigger Support
    func forceTargetTransition() {
        activeTargetEntity?.removeFromParent()
        activeTargetEntity = nil
        activeTargetPosition = nil
        actionState = .waiting
    }
    
    // MARK: - Frequency Control Methods
    func setVisualizationFrequency(_ frequency: VisualizationFrequency) {
        visualizationFrequency = frequency
        print("AR Visualization frequency set to: \(frequency.displayName)")
    }
    
    // MARK: - Proximity Configuration
    func setProximityThreshold(_ threshold: Float) {
        // Allow adjusting the merge distance threshold if needed
        log("Proximity threshold: \(threshold)m")
    }
    
    // MARK: - Gripper State Control
    func setGripperState(isClosed: Bool) {
        let previousState = isGripperClosed
        isGripperClosed = isClosed
        
        if isClosed && !previousState {
            // Gripper just closed - hide all visualization
            print("Gripper closed - hiding all visualization")
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                // Remove wireframe
                self.wireframeEntity?.removeFromParent()
                self.wireframeEntity = nil
                
                // Remove active target
                self.activeTargetEntity?.removeFromParent()
                self.activeTargetEntity = nil
                self.activeTargetPosition = nil
                
                // Remove fading targets
                for fadingTarget in self.fadingTargets {
                    fadingTarget.entity.removeFromParent()
                }
                self.fadingTargets.removeAll()
                
                // Set action state to waiting
                self.actionState = .waiting
            }
        } else if !isClosed && previousState {
            print("Gripper opened - visualization enabled")
        }
    }
    
    // MARK: - Virtual Gripper Control
    func toggleVirtualGripper() {
        useVirtualGripper.toggle()
        print("Virtual gripper: \(useVirtualGripper ? "ON" : "OFF")")
    }
    
    func setVirtualGripper(enabled: Bool) {
        useVirtualGripper = enabled
        print("Virtual gripper: \(enabled ? "ON" : "OFF")")
    }
    
    // MARK: - USB Streaming Integration
    private var isUSBStreamingActive: Bool = false
    
    func setUSBStreamingState(isActive: Bool) {
        // This integrates with the existing USB streaming system
        // When USB streaming is active, virtual gripper is automatically disabled
        isUSBStreamingActive = isActive
        if isActive {
            print("USB streaming ON - Virtual gripper automatically disabled")
        } else {
            print("USB streaming OFF - Virtual gripper setting: \(useVirtualGripper ? "ON" : "OFF")")
        }
    }
    
    func shouldUseVirtualGripper() -> Bool {
        // Virtual gripper is only used when:
        // 1. useVirtualGripper is enabled AND
        // 2. USB streaming is not active
        return useVirtualGripper && !isUSBStreamingActive
    }
    
    
    // MARK: - Device Pose Integration
    func updateActualDevicePose(from arFrame: ARFrame) {
        if isVisualizationEnabled && hasEstablishedOrigin {
            let t = arFrame.camera.transform
            let currentCameraPosition = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z) - worldOrigin
            let cameraWorldPosition = currentCameraPosition + SIMD3<Float>(0, 0, -wireframeOffsetMeters)
            updateWireframe(cameraRelativePosition: cameraWorldPosition)
        }
    }
    
    func setTargetPose(_ worldPoint: SIMD3<Float>) {
        targetPose = worldPoint
        ensureVisualizationReady()
        updateGoalPointVisualization()
    }
    
    func clearTargetPose() {
        targetPose = nil
        goalPointEntity?.removeFromParent()
        goalPointEntity = nil
    }
    
    // MARK: - ML Integration Method
    func updatePoseFromMLOutput(_ jointActions: [Float], timestamp: CFTimeInterval = CACurrentMediaTime()) {
        guard isVisualizationEnabled && hasEstablishedOrigin && !isGripperClosed else { return }
        guard jointActions.count >= 6 else { return }
        
        let (cameraDeltaTranslation, _) = interpretMLDirections(jointActions, timestamp: timestamp)
        let cameraTransform = getCurrentCameraTransform()
        let rotationWorldFromCamera = simd_float3x3(
            columns: (
                SIMD3<Float>(cameraTransform.columns.0.x, cameraTransform.columns.0.y, cameraTransform.columns.0.z),
                SIMD3<Float>(cameraTransform.columns.1.x, cameraTransform.columns.1.y, cameraTransform.columns.1.z),
                SIMD3<Float>(cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z)
            )
        )
        let deltaTranslation = rotationWorldFromCamera * cameraDeltaTranslation
        let currentCameraPosition = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z) - worldOrigin
        let targetPosition = currentCameraPosition + deltaTranslation
        updateTarget(position: targetPosition)
    }
    
    private func interpretMLDirections(_ jointActions: [Float], timestamp: CFTimeInterval = CACurrentMediaTime()) -> (translation: SIMD3<Float>, rotation: simd_quatf) {
        let action7 = Array(jointActions.prefix(7))
        let mapped = ActionTransformUtils.policyToCameraEulerAction(action7, rotationUnit: .eulerXYZ)
        var translationCamera = SIMD3<Float>(mapped[0], mapped[1], mapped[2])
        
        if applyEndOffset {
            translationCamera += SIMD3<Float>(0, 0, -endOffsetMeters)
        }
        
        let rotationCamera = eulerToQuaternion(roll: mapped[3], pitch: mapped[4], yaw: mapped[5])
        return (translationCamera, rotationCamera)
    }
    
    func updateTargetCube(position: SIMD3<Float>) {
        updateTarget(position: position)
    }
    
    // MARK: - Target Management
    func updateTarget(position: SIMD3<Float>) {
        guard isVisualizationEnabled, !isGripperClosed else { return }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let worldOriginAnchor = self.worldOriginAnchor else { return }
            
            if self.activeTargetEntity == nil {
                let targetMesh = MeshResource.generateBox(size: self.targetSize)
                let redMaterial = SimpleMaterial(color: UIColor.systemRed.withAlphaComponent(1.0), isMetallic: false)
                let newTarget = ModelEntity(mesh: targetMesh, materials: [redMaterial])
                worldOriginAnchor.addChild(newTarget)
                self.activeTargetEntity = newTarget
                self.actionState = .waiting
                print("[Viz] ✅ New target created at (\(String(format: "%.3f", position.x)), \(String(format: "%.3f", position.y)), \(String(format: "%.3f", position.z)))")
            }
            
            self.activeTargetEntity?.position = position
            self.activeTargetPosition = position
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
    
    // MARK: - Goal Point Visualization
    private func updateGoalPointVisualization() {
        guard let targetPose = targetPose,
              let worldOriginAnchor = worldOriginAnchor,
              hasEstablishedOrigin else { 
            goalPointEntity?.removeFromParent()
            goalPointEntity = nil
            return 
        }
        
        goalPointEntity?.removeFromParent()
        goalPointEntity = nil
        
        let sphereMesh = MeshResource.generateSphere(radius: 0.02)
        let goalMaterial = SimpleMaterial(color: .systemRed, isMetallic: false) 
        goalPointEntity = ModelEntity(mesh: sphereMesh, materials: [goalMaterial])
        
        let relativePosition = targetPose - worldOrigin
        goalPointEntity?.position = relativePosition
        worldOriginAnchor.addChild(goalPointEntity!)
        print("✅ Goal point created at distance: \(length(relativePosition))m")
    }
}
