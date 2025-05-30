//
//  MLInferenceResultsView.swift
//  AnySense
//
//  Created by AI Assistant on 2025/2/1.
//

import SwiftUI

struct MLInferenceResultsView: View {
    @ObservedObject var mlManager: MLInferenceManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "brain.head.profile")
                    .foregroundColor(.white)
                    .font(.headline)
                Text("AI Classification")
                    .foregroundColor(.white)
                    .font(.headline)
                    .fontWeight(.semibold)
            }
            
            if let result = mlManager.latestResult {
                VStack(alignment: .leading, spacing: 4) {
                    // Top prediction
                    HStack {
                        Text(result.topPrediction)
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
                    
                    // Confidence bar
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color.gray.opacity(0.3))
                                .frame(height: 4)
                                .cornerRadius(2)
                            
                            Rectangle()
                                .fill(Color.green)
                                .frame(width: geometry.size.width * CGFloat(result.confidence), height: 4)
                                .cornerRadius(2)
                        }
                    }
                    .frame(height: 4)
                    
                    // Additional top predictions (compact)
                    if result.allPredictions.count > 1 {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(result.allPredictions.dropFirst().prefix(2)), id: \.0) { prediction in
                                HStack {
                                    Text(prediction.0)
                                        .foregroundColor(.white.opacity(0.8))
                                        .font(.caption)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(Int(prediction.1 * 100))%")
                                        .foregroundColor(.gray)
                                        .font(.caption2)
                                }
                            }
                        }
                    }
                    
                    // Performance info
                    HStack {
                        Text("⚡")
                        Text("\(Int(result.inferenceTime * 1000))ms")
                            .foregroundColor(.yellow)
                            .font(.caption2)
                        Spacer()
                        Text("🧠")
                        Text(mlManager.inferenceFrequency.displayName.split(separator: " ").last.map(String.init) ?? "")
                            .foregroundColor(.blue)
                            .font(.caption2)
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

#Preview {
    let mlManager = MLInferenceManager()
    mlManager.latestResult = InferenceResult(
        topPrediction: "golden_retriever",
        confidence: 0.89,
        allPredictions: [
            ("golden_retriever", 0.89),
            ("labrador_retriever", 0.05),
            ("nova_scotia_duck_tolling_retriever", 0.03)
        ],
        inferenceTime: 0.045
    )
    
    return MLInferenceResultsView(mlManager: mlManager)
        .preferredColorScheme(.dark)
} 
