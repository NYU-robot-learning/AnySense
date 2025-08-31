import Foundation
import simd

struct ActionTransformUtils {
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
    // Input: [tx, ty, tz, rx, ry, rz, gripper] in iPhone camera frame (Euler xyz, radians)
    // Output: robot-frame [tx, ty, tz, rx, ry, rz, gripper]
    static func toRobotActions(_ action7: [Float]) -> [Float] {
        guard action7.count >= 7 else { return action7 }
        let tx = action7[0], ty = action7[1], tz = action7[2]
        let rx = action7[3], ry = action7[4], rz = action7[5]
        let gr = action7[6]
        
        // 1) iPhone action → 4x4
        let T_c = buildTransform(translation: SIMD3<Float>(tx, ty, tz), eulerXYZ: SIMD3<Float>(rx, ry, rz))
        
        // 2) Camera → Robot: T_r = Z90 @ (P.T @ T_c @ P) @ Z90.T
        let Pt = simd_transpose(P)
        let Zt = simd_transpose(Z90)
        let T_perm = Pt * T_c * P
        let T_r = Z90 * T_perm * Zt
        
        // 3) 4x4 → action (Euler xyz)
        let rxyz = eulerXYZ(from: T_r)
        let t = translation(from: T_r)
        
        return [t.x, t.y, t.z, rxyz.x, rxyz.y, rxyz.z, gr]
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
}


