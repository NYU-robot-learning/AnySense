import Foundation
import simd

struct TransformDebug {
    static func runSamples(rotationUnit: ActionTransformUtils.RotationUnit = .eulerXYZ) {
        print("===== Transform Debug Samples (rotationUnit=\(rotationUnit)) =====")
        let samples: [[Float]] = [
            // [down, right, backward, r1, r2, r3, gripper]
            [0.0, 0.0,  0.10, 0.0, 0.0, 0.0, 0.5],   // backward (+z in policy)
            [0.0, 0.10, 0.00, 0.0, 0.0, 0.0, 0.5],   // right
            [0.10, 0.0, 0.00,  0.0, 0.0, 0.0, 0.5],  // down
            [0.0, 0.0, 0.00,  0.10, 0.0, 0.0, 0.5],  // roll (or rx axisAngle)
            [0.0, 0.0, 0.00,  0.0, 0.10, 0.0, 0.5],  // pitch (or ry)
            [0.0, 0.0, 0.00,  0.0, 0.0, 0.10, 0.5],  // yaw (or rz)
        ]
        for s in samples {
            let report = ActionTransformUtils.debugTransformReport(s, rotationUnit: rotationUnit)
            print(report)
            print("--------------------------------------------------")
        }
    }
}


