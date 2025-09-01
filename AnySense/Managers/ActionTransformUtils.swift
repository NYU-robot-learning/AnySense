import Foundation
import simd

struct ActionTransformUtils {
    enum RotationUnit {
        case eulerXYZ   // rx, ry, rz (radians)
        case axisAngle  // rotation vector (axis * angle)
    }
    // Server-defined transforms (record3d → personal camera) and +90° about Z
    private static let P: simd_float4x4 = {
        let c0 = SIMD4<Float>(-1,  0,  0, 0)
        let c1 = SIMD4<Float>( 0,  0, -1, 0)
        let c2 = SIMD4<Float>( 0, -1,  0, 0)
        let c3 = SIMD4<Float>( 0,  0,  0, 1)
        return simd_float4x4(columns: (c0, c1, c2, c3))
    }()
    
    private static let Z90: simd_float4x4 = {
        let c0 = SIMD4<Float>( 0,  1, 0, 0)
        let c1 = SIMD4<Float>(-1,  0, 0, 0)
        let c2 = SIMD4<Float>( 0,  0, 1, 0)
        let c3 = SIMD4<Float>( 0,  0, 0, 1)
        return simd_float4x4(columns: (c0, c1, c2, c3))
    }()
    
    // MARK: - Public Entry
    // The policy produces an action tensor in its own convention. We first map it into the
    // iPhone CAMERA frame (policy→camera), then convert CAMERA→ROBOT to match server logic.
    // Input: policy action [tx, ty, tz, r1, r2, r3, gripper]
    // Output: robot-frame [tx, ty, tz, rx, ry, rz, gripper] (Euler xyz)
    static func toRobotActions(_ policyAction7: [Float], rotationUnit: RotationUnit = .eulerXYZ) -> [Float] {
        guard policyAction7.count >= 7 else { return policyAction7 }
        let camEulerAction = policyToCameraEulerAction(policyAction7, rotationUnit: rotationUnit)
        let gr = camEulerAction[6]
        
        // 1) CAMERA action → 4x4
        let T_c = buildTransform(translation: SIMD3<Float>(camEulerAction[0], camEulerAction[1], camEulerAction[2]), eulerXYZ: SIMD3<Float>(camEulerAction[3], camEulerAction[4], camEulerAction[5]))
        
        // 2) Camera → Robot: T_r = Z90 @ (P.T @ T_c @ P) @ Z90.T (parity with server)
        let Pt = simd_transpose(P)
        let Zt = simd_transpose(Z90)
        let T_perm = Pt * T_c * P
        let T_r = Z90 * T_perm * Zt
        
        // 3) 4x4 → robot action (Euler xyz)
        let rxyz = eulerXYZ(from: T_r)
        let t = translation(from: T_r)
        
        return [t.x, t.y, t.z, rxyz.x, rxyz.y, rxyz.z, gr]
    }

    // Policy → CAMERA mapping in a single place so viz and robot stay consistent.
    // Convention used here mirrors ARVisualizationManager's historical mapping with a corrected Z sign:
    //  - policy: [down, right, backward]
    //  - camera: x=right, y=up, z forward is -Z in ARKit conventions → use z = -backward
    static func policyToCameraEulerAction(_ policyAction7: [Float], rotationUnit: RotationUnit = .eulerXYZ, quarterTurns: Int = 0) -> [Float] {
        guard policyAction7.count >= 7 else { return policyAction7 }
        let ml_x = policyAction7[0]  // down
        let ml_y = policyAction7[1]  // right
        let ml_z = policyAction7[2]  // backward
        let r1 = policyAction7[3]
        let r2 = policyAction7[4]
        let r3 = policyAction7[5]
        let gr = policyAction7[6]
        
        // Translation mapping
        var cam_t = SIMD3<Float>(ml_y, -ml_x, -ml_z)
        if quarterTurns % 4 != 0 {
            cam_t = rotateXY(cam_t, quarterTurns: quarterTurns)
        }
        
        // Rotation mapping → always return Euler xyz in CAMERA frame
        var cam_euler: SIMD3<Float>
        switch rotationUnit {
        case .eulerXYZ:
            cam_euler = SIMD3<Float>(r1, r2, r3)
        case .axisAngle:
            let R_cam = rotationMatrixFromAxisAngle(axisAngle: SIMD3<Float>(r1, r2, r3))
            cam_euler = eulerXYZ(from: matrixFromRotationAndTranslation(R_cam, t: SIMD3<Float>(0,0,0)))
        }
        if quarterTurns % 4 != 0 {
            // Adjust yaw by quarter turns around camera Z
            let k = Float(quarterTurns % 4)
            cam_euler.z += k * (.pi / 2)
        }
        
        return [cam_t.x, cam_t.y, cam_t.z, cam_euler.x, cam_euler.y, cam_euler.z, gr]
    }
    
    // MARK: - Builders
    private static func buildTransform(translation t: SIMD3<Float>, eulerXYZ r: SIMD3<Float>) -> simd_float4x4 {
        let R = rotationMatrixXYZ(rx: r.x, ry: r.y, rz: r.z)
        var T = matrix_identity_float4x4
        T.columns.0 = SIMD4<Float>(R.columns.0.x, R.columns.0.y, R.columns.0.z, 0)
        T.columns.1 = SIMD4<Float>(R.columns.1.x, R.columns.1.y, R.columns.1.z, 0)
        T.columns.2 = SIMD4<Float>(R.columns.2.x, R.columns.2.y, R.columns.2.z, 0)
        T.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
        return T
    }
    
    private static func matrixFromRotationAndTranslation(_ R: simd_float3x3, t: SIMD3<Float>) -> simd_float4x4 {
        var T = matrix_identity_float4x4
        T.columns.0 = SIMD4<Float>(R.columns.0.x, R.columns.0.y, R.columns.0.z, 0)
        T.columns.1 = SIMD4<Float>(R.columns.1.x, R.columns.1.y, R.columns.1.z, 0)
        T.columns.2 = SIMD4<Float>(R.columns.2.x, R.columns.2.y, R.columns.2.z, 0)
        T.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
        return T
    }
    
    // Rotation matrix for Euler 'xyz' (radians)
    // Using standard formula:
    // R = [[ cy*cz, -cy*sz,  sy ],
    //      [ cx*sz + cz*sx*sy,  cx*cz - sx*sy*sz,  -cy*sx ],
    //      [ sx*sz - cx*cz*sy,  cz*sx + cx*sy*sz,  cx*cy ]]
    private static func rotationMatrixXYZ(rx: Float, ry: Float, rz: Float) -> simd_float3x3 {
        let cx = cos(rx), sx = sin(rx)
        let cy = cos(ry), sy = sin(ry)
        let cz = cos(rz), sz = sin(rz)
        
        let r00 =  cy * cz
        let r01 = -cy * sz
        let r02 =  sy
        
        let r10 =  cx * sz + cz * sx * sy
        let r11 =  cx * cz - sx * sy * sz
        let r12 = -cy * sx
        
        let r20 =  sx * sz - cx * cz * sy
        let r21 =  cz * sx + cx * sy * sz
        let r22 =  cx * cy
        
        let c0 = SIMD3<Float>(r00, r10, r20)
        let c1 = SIMD3<Float>(r01, r11, r21)
        let c2 = SIMD3<Float>(r02, r12, r22)
        return simd_float3x3(columns: (c0, c1, c2))
    }
    
    // Axis-angle (rotation vector) → rotation matrix via Rodrigues' formula
    private static func rotationMatrixFromAxisAngle(axisAngle v: SIMD3<Float>) -> simd_float3x3 {
        let theta = sqrt(v.x*v.x + v.y*v.y + v.z*v.z)
        let eps: Float = 1e-8
        if theta < eps {
            return simd_float3x3(diagonal: SIMD3<Float>(1,1,1))
        }
        let k = SIMD3<Float>(v.x/theta, v.y/theta, v.z/theta)
        let K = simd_float3x3(rows: [
            SIMD3<Float>(   0, -k.z,  k.y),
            SIMD3<Float>( k.z,    0, -k.x),
            SIMD3<Float>(-k.y,  k.x,    0)
        ])
        let I = simd_float3x3(diagonal: SIMD3<Float>(1,1,1))
        // R = I + sinθ K + (1 - cosθ) K^2
        let K2 = simd_mul(K, K)
        let R = I + sin(theta) * K + (1 - cos(theta)) * K2
        return R
    }

    // Rotate a vector in camera XY plane by 90° increments (right-handed, +Z out of screen)
    private static func rotateXY(_ v: SIMD3<Float>, quarterTurns: Int) -> SIMD3<Float> {
        switch ((quarterTurns % 4) + 4) % 4 { // normalize to 0..3
        case 1: // +90° (counterclockwise): (x,y) -> (-y, x)
            return SIMD3<Float>(-v.y, v.x, v.z)
        case 2: // 180°
            return SIMD3<Float>(-v.x, -v.y, v.z)
        case 3: // -90° (clockwise): (x,y) -> (y, -x)
            return SIMD3<Float>(v.y, -v.x, v.z)
        default:
            return v
        }
    }
    
    // Extract Euler 'xyz' (radians) from 4x4
    private static func eulerXYZ(from T: simd_float4x4) -> SIMD3<Float> {
        // Reconstruct row-major elements from column-major storage
        let R00 = T.columns.0.x, R01 = T.columns.1.x, R02 = T.columns.2.x
        let R10 = T.columns.0.y, R11 = T.columns.1.y, R12 = T.columns.2.y
        let R20 = T.columns.0.z, R21 = T.columns.1.z, R22 = T.columns.2.z
        
        // For 'xyz':
        // y = asin(R02)
        // if |cos(y)| > eps:
        //   x = atan2(-R12, R22)
        //   z = atan2(-R01, R00)
        // else (gimbal lock):
        //   x = atan2(R21, R11)
        //   z = 0
        let y = asin(clamp(R02, -1.0, 1.0))
        let cy = cos(y)
        let eps: Float = 1e-6
        let x: Float
        let z: Float
        if abs(cy) > eps {
            x = atan2(-R12, R22)
            z = atan2(-R01, R00)
        } else {
            // Gimbal lock
            x = atan2(R21, R11)
            z = 0.0
        }
        return SIMD3<Float>(x, y, z)
    }
    
    private static func translation(from T: simd_float4x4) -> SIMD3<Float> {
        return SIMD3<Float>(T.columns.3.x, T.columns.3.y, T.columns.3.z)
    }
    
    private static func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float {
        return max(lo, min(hi, v))
    }
    
    // MARK: - Debug helpers
    static func debugTransformReport(_ policyAction7: [Float], rotationUnit: RotationUnit = .eulerXYZ) -> String {
        guard policyAction7.count >= 7 else { return "<invalid action>" }
        let cam = policyToCameraEulerAction(policyAction7, rotationUnit: rotationUnit)
        let T_c = buildTransform(translation: SIMD3<Float>(cam[0], cam[1], cam[2]), eulerXYZ: SIMD3<Float>(cam[3], cam[4], cam[5]))
        let Pt = simd_transpose(P)
        let Zt = simd_transpose(Z90)
        let T_perm = Pt * T_c * P
        let T_r = Z90 * T_perm * Zt
        let robotEuler = eulerXYZ(from: T_r)
        let robotT = translation(from: T_r)
        func fmt(_ f: Float) -> String { String(format: "%.4f", f) }
        func fmt3(_ v: SIMD3<Float>) -> String { "(\(fmt(v.x)),\(fmt(v.y)),\(fmt(v.z)))" }
        return [
            "policy      t,r: \(fmt3(SIMD3(policyAction7[0], policyAction7[1], policyAction7[2]))) \(fmt3(SIMD3(policyAction7[3], policyAction7[4], policyAction7[5])))",
            "camera (map) t,r_euler: \(fmt3(SIMD3(cam[0], cam[1], cam[2]))) \(fmt3(SIMD3(cam[3], cam[4], cam[5])))",
            "robot       t,r_euler: \(fmt3(robotT)) \(fmt3(robotEuler))",
        ].joined(separator: "\n")
    }
}


