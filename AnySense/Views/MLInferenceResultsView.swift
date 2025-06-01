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
                VStack(alignment: .leading, spacing: 4) {
                    // Joint Actions Header
                    Text("Joint Actions:")
                        .foregroundColor(.white.opacity(0.8))
                        .font(.caption)
                        .fontWeight(.semibold)
                    
                    // Joint action values
                    ForEach(Array(result.jointActions.enumerated()), id: \.offset) { index, value in
                        HStack {
                            Text("Joint \(index + 1):")
                                .foregroundColor(.white.opacity(0.7))
                                .font(.caption2)
                                .frame(width: 60, alignment: .leading)
                            
                            Text(String(format: "%.3f", value))
                                .foregroundColor(.cyan)
                                .font(.caption2)
                                .fontWeight(.medium)
                                .fontDesign(.monospaced)
                            
                            Spacer()
                        }
                    }
                    
                    // Performance info
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
        .frame(maxWidth: 240) // Slightly wider to accommodate joint values
    }
} 
