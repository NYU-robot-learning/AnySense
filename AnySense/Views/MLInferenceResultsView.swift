//
//  MLInferenceResultsView.swift
//  AnySense
//
//  Created by Krish on 2025/2/1.
//

import SwiftUI

struct MLInferenceResultsView: View {
    @ObservedObject var mlManager: MLInferenceManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Gripper State")
                .foregroundColor(.white)
                .font(.subheadline)
                .fontWeight(.semibold)

            if let result = mlManager.latestResult {
                GripperBlock(result: result)
            } else {
                Text("Analyzing...")
                    .foregroundColor(.white.opacity(0.7))
                    .font(.caption)
                    .italic()
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.75))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
        )
        .frame(maxWidth: 160)
    }
}

// MARK: - Gripper Subview
private struct GripperBlock: View {
    let result: InferenceResult

    private var gripperValue: Float {
        return result.jointPositions.count >= 7 ? result.jointPositions[6] : 0.0
    }

    private var gripperState: String {
        return gripperValue < 0.7 ? "CLOSED" : "OPEN"
    }

    private var stateColor: Color {
        return gripperValue < 0.7 ? .red : .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Value:")
                    .foregroundColor(.white.opacity(0.7))
                    .font(.caption)
                Text(String(format: "%.3f", gripperValue))
                    .foregroundColor(.orange)
                    .font(.caption)
                    .fontWeight(.medium)
                    .fontDesign(.monospaced)
                Spacer()
            }

            HStack {
                Text("State:")
                    .foregroundColor(.white.opacity(0.7))
                    .font(.caption)
                Text(gripperState)
                    .foregroundColor(stateColor)
                    .font(.caption)
                    .fontWeight(.bold)
                Spacer()
            }
        }
    }
} 
