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
    @Published var actionState: ActionState = .waiting
    @Published var visualizationFrequency: VisualizationFrequency = .medium
    
    // MARK: - Private Properties  
    private var arView: ARView?
    private var worldOriginAnchor: AnchorEntity?
    private var lastVisualizationTime: CFTimeInterval = 0
    
    // Cube visualization entities
    private var currentPoseCubeEntity: ModelEntity?
    private var targetCubeEntity: ModelEntity?
    private var targetCubeDisplayPosition: SIMD3<Float>?  // Where target cube is displayed (with offset)
    private var actualCameraPosition: SIMD3<Float>?  // Actual camera position for proximity
    private var targetCameraPosition: SIMD3<Float>?  // Target camera position for proximity (without offset)
    
    // Proximity detection
    private let proximityThreshold: Float = 0.15  // 15cm for "merged" state (increased for better detection)
    
    // Target/device pose state for point-conditioned flows
    private var targetPose: SIMD3<Float>?
    private var actualDevicePose: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
    private var goalPointEntity: ModelEntity?
    private var goalAnchorEntity: AnchorEntity?
    
    // Movement tracking
    private var worldOrigin: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
    private var currentWorldPosition: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
    private var previousWorldPosition: SIMD3<Float>?
    private var hasEstablishedOrigin: Bool = false
    
    // Cube visual configuration
    private let cubeSize: Float = 0.02  // 2cm cubes
    private let currentCubeForwardOffset: Float = -0.010  // -1cm offset (out of screen, towards camera)
    private let targetCubeForwardOffset: Float = 0.00  // No offset for target cube
    
    // Debug controls
    var debugLoggingEnabled: Bool = true
    
    // Gripper state control
    var isGripperClosed: Bool = false  // When true, stops visualization
    
    // Virtual gripper setting
    var useVirtualGripper: Bool = false  // When true, uses gripper_overlay.png; when false, passes image to policy
    
    // MARK: - Initialization 
    init() {
        log("Initialized with cube-based visualization")
    }
    
    // MARK: - Logging Helper
    private func log(_ message: String) {
        print("[ARViz] \(message)")
    }
    
    // MARK: - Setup Methods
    func setupVisualization(with arView: ARView) {
        self.arView = arView
        log("Setup completed - using camera-relative directional arrows")
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
        guard !hasEstablishedOrigin else {
            print("World origin already established")
            return
        }
        
        // Set world origin at current camera position
        worldOrigin = getCurrentCameraPosition()
        currentWorldPosition = SIMD3<Float>(0, 0, 0) // Start at origin
        previousWorldPosition = nil
        hasEstablishedOrigin = true

        // Create an anchor at the chosen world origin to host visualization entities
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4<Float>(worldOrigin.x, worldOrigin.y, worldOrigin.z, 1)
        let anchor = AnchorEntity(world: t)
        currentArView.scene.addAnchor(anchor)
        worldOriginAnchor = anchor
        
        print("World origin set at: \(worldOrigin) and anchor created")
    }
    
    private func resetMovementTracking() {
        hasEstablishedOrigin = false
        worldOrigin = SIMD3<Float>(0, 0, 0)
        currentWorldPosition = SIMD3<Float>(0, 0, 0)
        previousWorldPosition = nil
        
        // Remove goal point visualization
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
        // Remove goal point visualization
        goalPointEntity?.removeFromParent()
        goalPointEntity = nil
        
        // Remove cube visualizations
        currentPoseCubeEntity?.removeFromParent()
        currentPoseCubeEntity = nil
        
        targetCubeEntity?.removeFromParent()
        targetCubeEntity = nil
        targetCubeDisplayPosition = nil
        targetCameraPosition = nil
        actualCameraPosition = nil
    }

    // MARK: - Initialization helper
    func ensureVisualizationReady() {
        if !hasEstablishedOrigin { establishWorldOrigin() }
        if !isVisualizationEnabled { enableVisualization() }
        if debugLoggingEnabled {
            print("[Viz] ensureVisualizationReady → enabled=\(isVisualizationEnabled), origin=\(hasEstablishedOrigin)")
        }
    }
    
    // MARK: - Cube Management Methods
    func updateCurrentPoseCube(position: SIMD3<Float>) {
        guard isVisualizationEnabled, !isGripperClosed else { return }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let worldOriginAnchor = self.worldOriginAnchor else { 
                if self?.debugLoggingEnabled == true {
                    print("[Viz] Cannot update current cube - anchor not ready")
                }
                return 
            }
            
            // Create or update current pose cube
            if self.currentPoseCubeEntity == nil {
                let cubeMesh = MeshResource.generateBox(size: self.cubeSize)
                let blueMaterial = SimpleMaterial(color: UIColor.systemBlue.withAlphaComponent(0.7), isMetallic: false)
                self.currentPoseCubeEntity = ModelEntity(mesh: cubeMesh, materials: [blueMaterial])
                worldOriginAnchor.addChild(self.currentPoseCubeEntity!)
                
                if self.debugLoggingEnabled {
                    print("[Viz] Current pose cube created (blue, \(self.cubeSize)m)")
                }
            }
            
            // Update position
            self.currentPoseCubeEntity?.position = position
            
            // Check proximity if we have a target cube
            self.checkProximityAndUpdateState()
        }
    }
    
    private var lastLoggedDistance: Float = -1.0
    
    private func checkProximityAndUpdateState() {
        guard !isGripperClosed,
              let cameraPos = actualCameraPosition,
              let targetPos = targetCameraPosition else { return }
        
        let distance = length(cameraPos - targetPos)
        
        // Log only when close to threshold or when distance changes significantly
        let distanceChanged = abs(distance - lastLoggedDistance) > 0.02 // 2cm change
        let isClose = distance < proximityThreshold * 1.5  // Within 1.5x threshold
        if debugLoggingEnabled && (distanceChanged || isClose) {
            print("[Proximity] 📏 Distance: \(String(format: "%.4f", distance))m | Threshold: \(proximityThreshold)m | \(distance <= proximityThreshold ? "✅ WITHIN" : "⏳ Far")")
            lastLoggedDistance = distance
        }
        
        if distance <= proximityThreshold {
            // Camera reached target - signal inference trigger
            if actionState != .reached {
                actionState = .reached
                log("✅ Target reached - triggering inference (distance: \(String(format: "%.4f", distance))m)")
                
                // Notify observers that proximity was reached
                NotificationCenter.default.post(
                    name: NSNotification.Name("ProximityReached"),
                    object: nil
                )
            }
        } else {
            if actionState != .waiting {
                actionState = .waiting
                if debugLoggingEnabled {
                    log("⏳ State changed to waiting (distance: \(String(format: "%.4f", distance))m)")
                }
            }
        }
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
                // Remove cubes
                self?.currentPoseCubeEntity?.removeFromParent()
                self?.targetCubeEntity?.removeFromParent()
                self?.goalPointEntity?.removeFromParent()
                
                // Set action state to waiting
                self?.actionState = .waiting
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
        let t = arFrame.camera.transform
        actualDevicePose = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        
        // Update current pose cube position every frame to track camera
        if isVisualizationEnabled && hasEstablishedOrigin {
            let currentCameraPosition = SIMD3<Float>(
                t.columns.3.x,
                t.columns.3.y,
                t.columns.3.z
            ) - worldOrigin
            
            // Store actual camera position for proximity checking
            actualCameraPosition = currentCameraPosition
            
            // Position blue cube with -5cm forward offset (Z direction only)
            let cubePosition = currentCameraPosition + SIMD3<Float>(0, 0, currentCubeForwardOffset)
            
            updateCurrentPoseCube(position: cubePosition)
        }
    }
    
    func setTargetPose(_ worldPoint: SIMD3<Float>) {
        print("🎯 setTargetPose called with world point: \(worldPoint)")
        print("   hasEstablishedOrigin: \(hasEstablishedOrigin)")
        print("   worldOrigin: \(worldOrigin)")
        print("   isGripperClosed: \(isGripperClosed)")
        print("   isVisualizationEnabled: \(isVisualizationEnabled)")
        
        targetPose = worldPoint
        // Ensure visualization is ready before creating goal point
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
        guard isVisualizationEnabled else { return }
        guard hasEstablishedOrigin else {
            print("World origin not established - cannot track movement")
            return
        }
        guard !isGripperClosed else {
            if debugLoggingEnabled {
                print("[Viz] Visualization stopped - gripper is closed")
            }
            return
        }
        guard jointActions.count >= 6 else {
            print("Invalid joint actions array - need at least 6 values, got \(jointActions.count)")
            return
        }
        
        // Interpret joint actions as movement deltas in CAMERA coordinates, then rotate into world frame
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
        
        if debugLoggingEnabled {
            func fmt(_ f: Float) -> String { String(format: "%.3f", f) }
            func fmt3(_ v: SIMD3<Float>) -> String { "(\(fmt(v.x)), \(fmt(v.y)), \(fmt(v.z)))" }
            print("[Viz] Δcam \(fmt3(cameraDeltaTranslation)) → Δworld \(fmt3(deltaTranslation))")
        }
        
        // Get current camera position relative to world origin
        let currentCameraPosition = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        ) - worldOrigin

        // Calculate target position from actual camera position + action delta
        let targetCamPos = currentCameraPosition + deltaTranslation
        
        // Store target camera position for proximity checking
        targetCameraPosition = targetCamPos
        
        // Apply -5cm offset to green target cube for display (Z direction only)
        let targetCubePos = targetCamPos + SIMD3<Float>(0, 0, targetCubeForwardOffset)
        
        // Update target cube
        updateTargetCube(position: targetCubePos)
        
        // Update tracking position
        currentWorldPosition = currentCameraPosition
    }
    
    private func interpretMLDirections(_ jointActions: [Float], timestamp: CFTimeInterval = CACurrentMediaTime()) -> (translation: SIMD3<Float>, rotation: simd_quatf) {
        // Map policy action → CAMERA frame (translation and Euler rotation)
        let action7 = Array(jointActions.prefix(7))
        let mapped = ActionTransformUtils.policyToCameraEulerAction(action7, rotationUnit: .eulerXYZ)
        let translationCamera = SIMD3<Float>(mapped[0], mapped[1], mapped[2])
        let rotationCamera = eulerToQuaternion(roll: mapped[3], pitch: mapped[4], yaw: mapped[5])

        // Return CAMERA-frame delta; caller will rotate to WORLD frame using current camera pose
        return (translationCamera, rotationCamera)
    }
    
    func updateTargetCube(position: SIMD3<Float>) {
        guard isVisualizationEnabled, !isGripperClosed else { 
            if debugLoggingEnabled {
                print("[Viz] Cannot update target cube - visualization disabled or gripper closed")
            }
            return 
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let worldOriginAnchor = self.worldOriginAnchor else { 
                if self?.debugLoggingEnabled == true {
                    print("[Viz] Cannot update target cube - anchor not ready")
                }
                return 
            }
            
            // Create or update target cube
            if self.targetCubeEntity == nil {
                let cubeMesh = MeshResource.generateBox(size: self.cubeSize)
                let greenMaterial = SimpleMaterial(color: UIColor.systemGreen.withAlphaComponent(0.9), isMetallic: false)
                self.targetCubeEntity = ModelEntity(mesh: cubeMesh, materials: [greenMaterial])
                worldOriginAnchor.addChild(self.targetCubeEntity!)
                
                if self.debugLoggingEnabled {
                    print("[Viz] Target cube created (green, \(self.cubeSize)m)")
                }
            }
            
            // Update position
            self.targetCubeEntity?.position = position
            self.targetCubeDisplayPosition = position
            
            if self.debugLoggingEnabled {
                func fmt(_ f: Float) -> String { String(format: "%.3f", f) }
                print("[Viz] Target cube updated: (\(fmt(position.x)), \(fmt(position.y)), \(fmt(position.z)))")
            }
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
        guard !isGripperClosed,
              let targetPose = targetPose,
              let worldOriginAnchor = worldOriginAnchor,
              hasEstablishedOrigin else { 
            print("❌ Cannot create goal visualization:")
            print("   targetPose exists: \(targetPose != nil)")
            print("   worldOriginAnchor exists: \(worldOriginAnchor != nil)")
            print("   hasEstablishedOrigin: \(hasEstablishedOrigin)")
            print("   isGripperClosed: \(isGripperClosed)")
            goalPointEntity?.removeFromParent()
            goalPointEntity = nil
            return 
        }
        
        // Remove existing goal point visualization
        goalPointEntity?.removeFromParent()
        goalPointEntity = nil
        
        // Create a visible sphere 
        let sphereMesh = MeshResource.generateSphere(radius: 0.02) // 2cm radius for better visibility
        let goalMaterial = SimpleMaterial(color: .systemRed, isMetallic: false) 
        goalPointEntity = ModelEntity(mesh: sphereMesh, materials: [goalMaterial])
        
        // Position the sphere at the target pose (relative to world origin)
        // This matches the working version from commit 41abd7a
        let relativePosition = targetPose - worldOrigin
        goalPointEntity?.position = relativePosition
        worldOriginAnchor.addChild(goalPointEntity!)
        
        print("✅ Goal point visualization created:")
        print("   Target pose (world): \(targetPose)")
        print("   World origin: \(worldOrigin)")
        print("   Relative position: \(relativePosition)")
        print("   Distance from origin: \(length(relativePosition))m")
        
        // Check current camera position for reference
        let currentCamPos = getCurrentCameraPosition()
        let distanceFromCamera = length(targetPose - currentCamPos)
        print("   Distance from current camera: \(distanceFromCamera)m")
    }

    // MARK: - Anchor-based goal visualization
    func attachGoalAnchor(_ arAnchor: ARAnchor) {
        if debugLoggingEnabled {
            print("[Viz] attachGoalAnchor deprecated; use setTargetPose(world)")
        }
    }
}
