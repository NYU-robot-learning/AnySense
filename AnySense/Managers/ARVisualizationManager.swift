//
//  ARVisualizationManager.swift
//  AnySense
//
//  Created by Krish on 2025/2/1.
//

import Foundation
import RealityKit
import ARKit
import simd
import UIKit

// MARK: - Action State
enum ActionState {
    case waiting  // User is moving toward target
    case reached  // Proximity triggered
    
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
@MainActor
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
    var endOffsetMeters: Float = 0.05
    
    // MARK: - Wireframe & Target Visualization
    private var wireframeEntity: Entity?
    private var wireframeAnchor: AnchorEntity?
    private let wireframeSize: Float = 0.018
    private let wireframeOffsetMeters: Float = 0.05
    private var wireframeVisualPosition: SIMD3<Float>?
    private var activeTargetEntity: ModelEntity?
    private var activeTargetPosition: SIMD3<Float>?
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
        log("Setup completed - using wireframe seek-target visualization")
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
    
    // MARK: - Wireframe Management (Ego Visualization)
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
                // Ghost Arrow: Semi-transparent Blue
                let ghostColor = UIColor.systemBlue.withAlphaComponent(0.4)
                self.wireframeEntity = self.createArrowEntity(color: ghostColor)
                self.wireframeAnchor!.addChild(self.wireframeEntity!)
                
                // Orient arrow to face forward (-Z) which is the default for our geometry
                self.wireframeEntity!.orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(1, 0, 0))
            }
            
            self.wireframeEntity?.position = SIMD3<Float>(0, 0, -self.wireframeOffsetMeters)
        }
        
        checkProximityAndUpdateState()
    }
    
    // MARK: - Proximity Check
    private var lastLoggedDistance: Float = -1.0

    private func checkProximityAndUpdateState() {
        guard !isGripperClosed,
              let wireframePos = wireframeVisualPosition,
              let activeTarget = activeTargetEntity else { return }

        // Fix: Use local position (relative to WorldOriginAnchor) to match wireframeVisualPosition coordinate space
        let targetPos = activeTarget.position

        // Use distance-based proximity
        let distance = length(targetPos - wireframePos)

        // Update target color based on proximity
        updateTargetColor(for: distance)

        // Debug print to verify distance
        if debugLoggingEnabled && distance < 0.2 {
             // throttling print to avoid spam could be good, but simple print is fine for now
             // print("Dist: \(distance)")
        }

        // Proximity threshold: Relaxed to 2.5cm for robust interaction
        let proximityThreshold: Float = 0.025

        let isNearby = distance <= proximityThreshold

        if isNearby {
            if actionState != .reached {
                print("Target Reached! (Dist: \(String(format: "%.3f", distance))m)")
                actionState = .reached
                // Remove the target to indicate success / clear the view
                activeTargetEntity?.removeFromParent()
                activeTargetEntity = nil
                activeTargetPosition = nil
                NotificationCenter.default.post(name: NSNotification.Name("ProximityReached"), object: nil)
            }
        } else {
            if actionState != .waiting {
                actionState = .waiting
            }
        }
    }

    // MARK: - Color Update Based on Proximity
    private func updateTargetColor(for distance: Float) {
        guard let activeTarget = activeTargetEntity else { return }

        // Color transition based on distance
        // Far: Red (distance > 0.12m)
        // Medium: Orange/Yellow (0.03m - 0.12m)
        // Close: Green (< 0.03m)

        let color: UIColor
        if distance > 0.12 {
            // Far - Red
            color = UIColor.systemRed
        } else if distance > 0.03 {
            // Medium distance - interpolate from red to green
            let progress = (0.12 - distance) / (0.12 - 0.03) // 0.0 to 1.0
            color = interpolateColor(from: UIColor.systemRed, to: UIColor.systemGreen, progress: progress)
        } else {
            // Close - Green
            color = UIColor.systemGreen
        }

        // Update the material on main thread - need to update all children of the arrow entity
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let newMaterial = SimpleMaterial(color: color, isMetallic: false)

            // Update all children of the arrow entity (shaft and head)
            for child in activeTarget.children {
                if let modelChild = child as? ModelEntity {
                    modelChild.model?.materials = [newMaterial]
                }
            }
        }
    }

    // MARK: - Color Interpolation Helper
    private func interpolateColor(from: UIColor, to: UIColor, progress: Float) -> UIColor {
        let clampedProgress = max(0.0, min(1.0, progress))

        var fromRed: CGFloat = 0, fromGreen: CGFloat = 0, fromBlue: CGFloat = 0, fromAlpha: CGFloat = 0
        var toRed: CGFloat = 0, toGreen: CGFloat = 0, toBlue: CGFloat = 0, toAlpha: CGFloat = 0

        from.getRed(&fromRed, green: &fromGreen, blue: &fromBlue, alpha: &fromAlpha)
        to.getRed(&toRed, green: &toGreen, blue: &toBlue, alpha: &toAlpha)

        let resultRed = fromRed + (toRed - fromRed) * CGFloat(clampedProgress)
        let resultGreen = fromGreen + (toGreen - fromGreen) * CGFloat(clampedProgress)
        let resultBlue = fromBlue + (toBlue - fromBlue) * CGFloat(clampedProgress)
        let resultAlpha = fromAlpha + (toAlpha - fromAlpha) * CGFloat(clampedProgress)

        return UIColor(red: resultRed, green: resultGreen, blue: resultBlue, alpha: resultAlpha)
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
            print("[Viz] Gripper CLOSED - Hiding visualization")
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                // Remove wireframe
                self.wireframeEntity?.removeFromParent()
                self.wireframeEntity = nil
                
                // Remove active target
                self.activeTargetEntity?.removeFromParent()
                self.activeTargetEntity = nil
                self.activeTargetPosition = nil
                
                // Set action state to waiting
                self.actionState = .waiting
            }
        } else if !isClosed && previousState {
            print("[Viz] Gripper OPENED - Visualization enabled")
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
            
            // Calculate wireframe position in World Frame
            // The wireframe is fixed at (0, 0, -wireframeOffsetMeters) in Camera Frame (Forward)
            // We need to rotate this offset by the camera's orientation to get it in World Frame
            
            // Camera Forward vector is -Z axis (column 2 is +Z/Backward)
            let cameraBackward = SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
            let offsetInWorld = -wireframeOffsetMeters * cameraBackward
            
            let cameraWorldPosition = currentCameraPosition + offsetInWorld
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
        
        let (cameraDeltaTranslation, cameraRotation) = interpretMLDirections(jointActions, timestamp: timestamp)
        let cameraTransform = getCurrentCameraTransform()
        let rotationWorldFromCamera = simd_float3x3(
            columns: (
                SIMD3<Float>(cameraTransform.columns.0.x, cameraTransform.columns.0.y, cameraTransform.columns.0.z),
                SIMD3<Float>(cameraTransform.columns.1.x, cameraTransform.columns.1.y, cameraTransform.columns.1.z),
                SIMD3<Float>(cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z)
            )
        )
        let deltaTranslation = rotationWorldFromCamera * cameraDeltaTranslation
        
        // Convert local rotation to world rotation: R_target = R_camera * R_delta
        let currentCameraRotation = simd_quatf(cameraTransform)
        let targetRotation = currentCameraRotation * cameraRotation
        
        let currentCameraPosition = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z) - worldOrigin
        let targetPosition = currentCameraPosition + deltaTranslation
        updateTarget(position: targetPosition, rotation: targetRotation)
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
         // Legacy support - default identity rotation
        updateTarget(position: position, rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)))
    }
    
    // MARK: - Target Management
    func updateTarget(position: SIMD3<Float>, rotation: simd_quatf) {
        guard isVisualizationEnabled, !isGripperClosed else { return }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let worldOriginAnchor = self.worldOriginAnchor else { return }
            
            if self.activeTargetEntity == nil {
                // Target Arrow: Solid Red
                let redColor = UIColor.systemRed.withAlphaComponent(1.0)
                let newTarget = self.createArrowEntity(color: redColor)
                worldOriginAnchor.addChild(newTarget)
                self.activeTargetEntity = newTarget
                self.actionState = .waiting
            }
            
            self.activeTargetEntity?.position = position
            self.activeTargetEntity?.orientation = rotation // Aligned with Camera Frame
            self.activeTargetPosition = position
            print("[Viz] Target Arrow Pos: (\(String(format: "%.3f", position.x)), \(String(format: "%.3f", position.y)), \(String(format: "%.3f", position.z)))")
        }
    }
    
    // Shared Arrow Creation (Used for both Ghost and Target)
    private func createArrowEntity(color: UIColor) -> ModelEntity {
        let arrowGroup = Entity()
        let material = SimpleMaterial(color: color, isMetallic: false)
        
        // Dimensions - Adjusted for visual clarity
        let length: Float = 0.025      // Shortened shaft (was 0.04)
        let shaftRadius: Float = 0.004 // Thicker shaft (was 0.003)
        let headRadius: Float = 0.012  // Wider head (was 0.01)
        let headLength: Float = 0.015  // Head length kept similar
        
        // Shaft
        let shaft = MeshResource.generateBox(width: shaftRadius*2, height: shaftRadius*2, depth: length)
        let shaftEntity = ModelEntity(mesh: shaft, materials: [material])
        shaftEntity.position = SIMD3<Float>(0, 0, -length/2)
        
        // Head (using Box for simplicity, but scaled to look broadly pointer-like)
        let head = MeshResource.generateBox(size: headRadius*2)
        let headEntity = ModelEntity(mesh: head, materials: [material])
        headEntity.position = SIMD3<Float>(0, 0, -length - headRadius/2) 
        // Note: Head position shifted to attach to shaft end
        
        // Combine
        let parent = ModelEntity()
        parent.addChild(shaftEntity)
        parent.addChild(headEntity)
        
        return parent
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
        print("[Viz] Sphere (Goal) Position: (\(String(format: "%.3f", relativePosition.x)), \(String(format: "%.3f", relativePosition.y)), \(String(format: "%.3f", relativePosition.z))) | Dist: \(length(relativePosition))m")
    }
}
