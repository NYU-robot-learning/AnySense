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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Pick Up Policy")
                    .foregroundColor(.white)
                    .font(.headline)
                    .fontWeight(.semibold)
            }
            
            if let result = mlManager.latestResult {
                ResultsBlock(result: result)
            } else {
                Text("Analyzing...")
                    .foregroundColor(.white.opacity(0.7))
                    .font(.caption)
                    .italic()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.75))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
        )
        .frame(maxWidth: 240)
    }
}

// MARK: - Subview
private struct ResultsBlock: View {
    let result: InferenceResult
    private let labels = ["x", "y", "z", "roll", "pitch", "yaw", "gripper"]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Joint Positions:")
                .foregroundColor(.white.opacity(0.8))
                .font(.caption)
                .fontWeight(.semibold)
            
            ForEach(result.jointPositions.indices, id: \.self) { idx in
                jointActionRow(for: idx)
            }
            
            HStack {
                Text("Inference:")
                    .foregroundColor(.white.opacity(0.7))
                    .font(.caption2)
                Text("\(Int(result.inferenceTime * 1000))ms")
                    .foregroundColor(.yellow)
                    .font(.caption2)
                    .fontWeight(.medium)
                Spacer()
            }
            .padding(.top, 2)
        }
    }
    
    private func jointActionRow(for idx: Int) -> some View {
        let labelText = idx < labels.count ? labels[idx] + ":" : "v\(idx):"
        let valueColor = idx == 6 ? Color.orange : Color.cyan
        
        return HStack {
            Text(labelText)
                .foregroundColor(.white.opacity(0.7))
                .font(.caption2)
                .frame(width: 50, alignment: .leading)
            
            Text(String(format: "%.3f", result.jointPositions[idx]))
                .foregroundColor(valueColor)
                .font(.caption2)
                .fontWeight(.medium)
                .fontDesign(.monospaced)
            
            Spacer()
        }
    }
} 
