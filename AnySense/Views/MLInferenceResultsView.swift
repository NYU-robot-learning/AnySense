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
                    // Main prediction
                    HStack {
                        Text(result.prediction)
                            .foregroundColor(.white)
                            .font(.body)
                            .fontWeight(.bold)
                            .lineLimit(1)
                        Spacer()
                        Text("\(Int(result.confidence * 100))%")
                            .foregroundColor(.green)
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    
                    // Performance info
                    HStack {
                        Text("ms:")
                        Text("\(Int(result.inferenceTime * 1000))ms")
                            .foregroundColor(.yellow)
                            .font(.caption2)
                        Spacer()
                    }
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
        .frame(maxWidth: 220)
    }
} 
