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
    let movementVector: SIMD3<Float>  // Store the actual movement vector for color updates
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
    @Published var maxArrows: Int = 1  // Only show one arrow at a time
    @Published var visualizationFrequency: VisualizationFrequency = .medium
    
    // MARK: - Private Properties  
    private var arView: ARView?
    private var worldOriginAnchor: AnchorEntity?
    private var movementArrows: [DirectionalArrow] = []
    private var lastVisualizationTime: CFTimeInterval = 0
    
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
    
    // Movement detection to prevent overlapping arrows
    private var lastArrowPosition: SIMD3<Float>?
    private var movementThreshold: Float = 0.01  // 1cm minimum movement between arrows
    
    // Trajectory deviation tracking
    private var expectedTrajectory: [SIMD3<Float>] = []  // Expected movement trajectory
    private var trajectoryDeviationThreshold: Float = 0.02  // 2cm deviation threshold for green/red
    
    // Arrow visual configuration
    private let arrowBaseLength: Float = 0.25      // Base length in meters (increased for visibility)
    private let arrowThickness: Float = 0.012      // Arrow shaft thickness (increased for visibility)
    private let arrowHeadRatio: Float = 0.3        // Head vs shaft ratio (increased for visibility)
    private let arrowHeadWidth: Float = 0.035      // Arrow head width (increased for visibility)
    private let axisLength: Float = 0.08           // Coordinate axes length
    private let axisThickness: Float = 0.005       // Coordinate axes thickness
    
    // Arrow lifecycle
    private let arrowLifetime: TimeInterval = 3.0  // Arrows fade after 3 seconds
    
    // Debug controls
    var debugLoggingEnabled: Bool = true
    var debugAlwaysDrawArrow: Bool = false
    var debugForceColorVariation: Bool = false  // When true, forces different colors for testing
    // Visualization adjustments
    var applyEndOffset: Bool = true            // apply labels-forward (+Y_label) → -Z_camera offset
    var endOffsetMeters: Float = 0.05          // meters; matches training shift used in labels.json mapping
    var useMagnitudeConfidence: Bool = true    // if true, scale color by delta magnitude; otherwise constant
    
    // Enhanced visibility controls
    var enhancedVisibilityMode: Bool = false   // When true, makes arrows more prominent for tracking
    var visibilityOffsetDistance: Float = -0.1  // Distance to offset arrows from camera for visibility
    
    // Gripper state control
    var isGripperClosed: Bool = false  // When true, stops visualization
    
    // Virtual gripper setting
    var useVirtualGripper: Bool = false  // When true, uses gripper_overlay.png; when false, passes image to policy
    
    // MARK: - Initialization 
    init() {
        log("Initialized with delta-based movement arrows")
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
        lastArrowPosition = nil  // Reset arrow position tracking
        expectedTrajectory = []  // Reset expected trajectory
        
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
        
        // Remove all movement arrows
        for arrow in movementArrows {
            arrow.anchor.removeFromParent()
        }
        movementArrows.removeAll()
    }

    // MARK: - Initialization helper
    func ensureVisualizationReady() {
        if !hasEstablishedOrigin { establishWorldOrigin() }
        if !isVisualizationEnabled { enableVisualization() }
        if debugLoggingEnabled {
            print("[Viz] ensureVisualizationReady → enabled=\(isVisualizationEnabled), origin=\(hasEstablishedOrigin)")
        }
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
    
    // MARK: - Enhanced Visibility Methods
    func enableEnhancedVisibility() {
        enhancedVisibilityMode = true
        visibilityOffsetDistance = 0.15  // Increase offset for better visibility
        log("Enhanced visibility enabled - arrows will be more prominent")
    }
    
    func disableEnhancedVisibility() {
        enhancedVisibilityMode = false
        visibilityOffsetDistance = 0.1  // Reset to default offset
        log("Enhanced visibility disabled")
    }
    
    func setVisibilityOffset(_ distance: Float) {
        visibilityOffsetDistance = max(0.05, min(0.3, distance))  // Clamp between 5cm and 30cm
        log("Visibility offset: \(visibilityOffsetDistance)m")
    }
    
    func setMovementThreshold(_ threshold: Float) {
        movementThreshold = max(0.005, min(0.05, threshold))  // Clamp between 5mm and 5cm
        log("Movement threshold: \(movementThreshold)m")
    }
    
    func toggleConfidenceMode() {
        useMagnitudeConfidence.toggle()
        print("Confidence mode: \(useMagnitudeConfidence ? "Magnitude-based" : "Direction-based")")
    }
    
    // MARK: - Gripper State Control
    func setGripperState(isClosed: Bool) {
        isGripperClosed = isClosed
        if isClosed {
            print("Gripper closed - visualization will be disabled")
        } else {
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
    
    func enableDebugColorVariation() {
        debugForceColorVariation = true
        print("Debug color variation enabled - arrows will cycle through colors")
    }
    
    func disableDebugColorVariation() {
        debugForceColorVariation = false
        print("Debug color variation disabled")
    }
    
    // MARK: - Trajectory Deviation Control
    func setExpectedTrajectory(_ trajectory: [SIMD3<Float>]) {
        expectedTrajectory = trajectory
        print("Expected trajectory set with \(trajectory.count) points")
    }
    
    func setDeviationThreshold(_ threshold: Float) {
        trajectoryDeviationThreshold = max(0.005, min(0.1, threshold))  // Clamp between 5mm and 10cm
        print("Deviation threshold set to: \(trajectoryDeviationThreshold)m")
    }
    
    func updateArrowColors() {
        // Update colors of all existing arrows based on current trajectory deviation
        for arrow in movementArrows {
            // Calculate new confidence based on current trajectory
            let arrowMovement = extractMovementFromArrow(arrow)
            let newConfidence = calculateTrajectoryDeviationConfidence(actualMovement: arrowMovement)
            updateArrowColor(arrow: arrow, confidence: newConfidence)
        }
        print("Updated colors for \(movementArrows.count) existing arrows")
    }
    
    // MARK: - Device Pose Integration
    func updateActualDevicePose(from arFrame: ARFrame) {
        let t = arFrame.camera.transform
        actualDevicePose = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
    }
    
    func setTargetPose(_ worldPoint: SIMD3<Float>) {
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
        // Apply frequency throttling
        if timestamp - lastVisualizationTime < visualizationFrequency.interval {
            if debugLoggingEnabled {
                // Visualization throttled
            }
            return
        }
        
        lastVisualizationTime = timestamp
        
        guard isVisualizationEnabled, showMovementArrows else { return }
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
        let (cameraDeltaTranslation, _, confidence) = interpretMLDirections(jointActions, timestamp: timestamp)
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
            print("[Viz] Δcam \(fmt3(cameraDeltaTranslation)) → Δworld \(fmt3(deltaTranslation)) | confidence: \(fmt(confidence))")
        }
        
        // ML coordinate transform applied
        
        // Get current camera position relative to world origin
        let currentCameraPosition = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        ) - worldOrigin

        // Show ML policy arrow from current camera position, not accumulated position
        // Position arrows further out for better visibility (configurable offset distance)
        let cameraForward = SIMD3<Float>(cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z)
        let offsetPosition = currentCameraPosition + cameraForward * visibilityOffsetDistance
        let targetPosition = offsetPosition + deltaTranslation

        // Only create movement arrow if there's meaningful movement AND sufficient distance from last arrow
        let movementMagnitude = length(deltaTranslation)
        let shouldCreateArrow: Bool
        
        if let lastPos = lastArrowPosition {
            let distanceFromLastArrow = length(offsetPosition - lastPos)
            shouldCreateArrow = (movementMagnitude > 0.002 || debugAlwaysDrawArrow) && distanceFromLastArrow > movementThreshold
        } else {
            shouldCreateArrow = movementMagnitude > 0.002 || debugAlwaysDrawArrow
        }
        
        if shouldCreateArrow {
            createMovementArrow(
                from: offsetPosition,
                to: targetPosition,
                confidence: confidence,
                timestamp: timestamp
            )
            lastArrowPosition = offsetPosition  // Update last arrow position
        } else {
            // Update colors of existing arrows based on current trajectory deviation
            updateArrowColors()
        }

        // Update tracking position to current camera position (not accumulated)
        currentWorldPosition = currentCameraPosition
        
        // Position updated with movement delta
    }
    
    private func interpretMLDirections(_ jointActions: [Float], timestamp: CFTimeInterval = CACurrentMediaTime()) -> (translation: SIMD3<Float>, rotation: simd_quatf, confidence: Float) {
        // Map policy action → CAMERA frame (translation and Euler rotation)
        let action7 = Array(jointActions.prefix(7))
        // Determine device interface orientation → quarter turns around camera Z
        // var quarterTurns: Int = 0
        // if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
        //     switch windowScene.interfaceOrientation {
        //     case .landscapeLeft:
        //         quarterTurns = 1
        //     case .landscapeRight:
        //         quarterTurns = -1
        //     case .portraitUpsideDown:
        //         quarterTurns = 2
        //     default:
        //         quarterTurns = 0
        //     }
        // }
        let mapped = ActionTransformUtils.policyToCameraEulerAction(action7, rotationUnit: .eulerXYZ)
        var translationCamera = SIMD3<Float>(mapped[0], mapped[1], mapped[2])
        // Optional end-offset in CAMERA frame: labels forward (+Y_label) == -Z_camera
        if applyEndOffset {
            translationCamera += SIMD3<Float>(0, 0, -endOffsetMeters)
        }
        let rotationCamera = eulerToQuaternion(roll: mapped[3], pitch: mapped[4], yaw: mapped[5])

        // Confidence: based on trajectory deviation (green = close to expected, red = far from expected)
        let movementMagnitude = length(translationCamera)
        let confidence: Float
        
        if debugForceColorVariation {
            // Force color variation for testing - cycle through colors
            let timeBasedConfidence = Float((timestamp.truncatingRemainder(dividingBy: 3.0)) / 3.0)
            confidence = timeBasedConfidence
        } else {
            // Calculate trajectory deviation-based confidence
            confidence = calculateTrajectoryDeviationConfidence(actualMovement: translationCamera)
        }

        // Return CAMERA-frame delta; caller will rotate to WORLD frame using current camera pose
        return (translationCamera, rotationCamera, confidence)
    }
    
    // MARK: - Trajectory Deviation Calculation
    private func calculateTrajectoryDeviationConfidence(actualMovement: SIMD3<Float>) -> Float {
        // If no expected trajectory is set, use movement magnitude as fallback
        guard !expectedTrajectory.isEmpty else {
            let magnitude = length(actualMovement)
            return min(1.0, max(0.0, magnitude * 20.0))  // Scale magnitude to 0-1
        }
        
        // Find the closest expected movement in the trajectory
        let actualMagnitude = length(actualMovement)
        var minDeviation: Float = Float.greatestFiniteMagnitude
        
        for expectedMovement in expectedTrajectory {
            let expectedMagnitude = length(expectedMovement)
            let magnitudeDeviation = abs(actualMagnitude - expectedMagnitude)
            
            // Calculate directional deviation (angle between vectors)
            let angleDeviation: Float
            if actualMagnitude > 0.001 && expectedMagnitude > 0.001 {
                let dotProduct = dot(normalize(actualMovement), normalize(expectedMovement))
                let clampedDot = max(-1.0, min(1.0, dotProduct))  // Clamp for acos
                angleDeviation = acos(clampedDot) * 180.0 / Float.pi  // Convert to degrees
            } else {
                angleDeviation = 0.0
            }
            
            // Combined deviation (magnitude + direction)
            let combinedDeviation = magnitudeDeviation + (angleDeviation / 180.0) * 0.1  // Scale angle deviation
            minDeviation = min(minDeviation, combinedDeviation)
        }
        
        // Convert deviation to confidence (low deviation = high confidence = green)
        // Deviation below threshold = green (confidence > 0.5)
        // Deviation above threshold = red (confidence < 0.5)
        let normalizedDeviation = minDeviation / trajectoryDeviationThreshold
        let confidence = max(0.0, min(1.0, 1.0 - normalizedDeviation))
        
        return confidence
    }
    
    // MARK: - Arrow Color Update Helpers
    private func extractMovementFromArrow(_ arrow: DirectionalArrow) -> SIMD3<Float> {
        // Use the stored movement vector for accurate color updates
        return arrow.movementVector
    }
    
    private func updateArrowColor(arrow: DirectionalArrow, confidence: Float) {
        DispatchQueue.main.async {
            // Get the arrow color based on confidence
            let newColor = self.confidenceToColor(confidence, enhanced: self.enhancedVisibilityMode)
            
            // Update the arrow entity's material color
            if let arrowEntity = arrow.entity as? ModelEntity {
                let newMaterial = SimpleMaterial(color: newColor, isMetallic: false)
                arrowEntity.model?.materials = [newMaterial]
            } else {
                // If it's a container entity, update child entities
                for child in arrow.entity.children {
                    if let childEntity = child as? ModelEntity {
                        let newMaterial = SimpleMaterial(color: newColor, isMetallic: false)
                        childEntity.model?.materials = [newMaterial]
                    }
                }
            }
        }
    }
    
    private func createMovementArrow(from: SIMD3<Float>, to: SIMD3<Float>, confidence: Float, timestamp: TimeInterval) {
        guard let worldOriginAnchor = worldOriginAnchor else { return }
        
        DispatchQueue.main.async { [weak self, worldOriginAnchor] in
            guard let self = self else { return }
            
            // Calculate movement vector
            let movement = to - from
            let movementMagnitude = length(movement)
            
            // Skip tiny movements (lowered threshold for better visibility)
            guard movementMagnitude > 0.0005 else { return }
            
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
                magnitude: movementMagnitude,
                movementVector: movement
            )
            
            // Remove existing arrow immediately (we only want one arrow at a time)
            if let existingArrow = self.movementArrows.first {
                existingArrow.entity.removeFromParent()
            }
            
            // Replace with new arrow
            self.movementArrows = [movementArrow]
            
            // Movement arrow created
        }
    }
    
    private func createMovementArrowEntity(fromPosition: SIMD3<Float>, toPosition: SIMD3<Float>, movement: SIMD3<Float>, confidence: Float) -> Entity {
        let arrowContainer = Entity()
        
        // Calculate arrow dimensions based on movement magnitude
        let movementMagnitude = length(movement)
        let minLength: Float = enhancedVisibilityMode ? 0.08 : 0.05  // Larger minimum in enhanced mode
        let scaledLength = max(movementMagnitude, minLength)
        let shaftLength = scaledLength * (1.0 - arrowHeadRatio)
        let headLength = scaledLength * arrowHeadRatio
        
        // Create arrow shaft (cylinder) 
        let shaftMesh = MeshResource.generateBox(
            width: arrowThickness,
            height: arrowThickness,
            depth: shaftLength
        )
        
        // Color based on confidence: red (low) -> yellow (medium) -> green (high)
        // Enhanced visibility mode makes colors more vibrant
        let shaftColor = confidenceToColor(confidence, enhanced: enhancedVisibilityMode)
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
    
    private func confidenceToColor(_ confidence: Float, enhanced: Bool = false) -> UIColor {
        let clampedConfidence = max(0.0, min(1.0, confidence))
        let alpha: CGFloat = enhanced ? 1.0 : 0.9
        
        if clampedConfidence < 0.5 {
            let factor = clampedConfidence * 2.0
            return UIColor(red: 1.0, green: CGFloat(factor), blue: 0.0, alpha: alpha)
        } else {
            let factor = (clampedConfidence - 0.5) * 2.0
            return UIColor(red: CGFloat(1.0 - factor), green: 1.0, blue: 0.0, alpha: alpha)
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
        
        // Clean up expired arrows
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
            print(" Cannot create goal visualization - targetPose: \(targetPose?.debugDescription ?? "nil"), anchor: \(worldOriginAnchor != nil), origin: \(hasEstablishedOrigin)")
            goalPointEntity?.removeFromParent()
            goalPointEntity = nil
            return 
        }
        
        // Remove existing goal point visualization
        goalPointEntity?.removeFromParent()
        goalPointEntity = nil
        
        // Create a visible sphere 
        let sphereMesh = MeshResource.generateSphere(radius: 0.01)
        let goalMaterial = SimpleMaterial(color: .systemRed, isMetallic: false) 
        goalPointEntity = ModelEntity(mesh: sphereMesh, materials: [goalMaterial])
        
        // Position the sphere at the target pose (relative to world origin)
        let relativePosition = targetPose - worldOrigin
        goalPointEntity?.position = relativePosition
        worldOriginAnchor.addChild(goalPointEntity!)
        
        print("Goal point visualization created:")
        print("   Target pose (world): \(targetPose)")
        print("   World origin: \(worldOrigin)")
        print("   Relative position: \(relativePosition)")
        print("   Distance from origin: \(length(relativePosition))m")
    }

    // MARK: - Anchor-based goal visualization
    func attachGoalAnchor(_ arAnchor: ARAnchor) {
        if debugLoggingEnabled {
            print("[Viz] attachGoalAnchor deprecated; use setTargetPose(world)")
        }
    }
}
