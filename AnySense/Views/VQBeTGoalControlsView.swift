//
//  VQBeTGoalControlsView.swift
//  AnySense
//
//  Created by Krish on 2025/1/8.
//

import SwiftUI
import simd

struct VQBeTGoalControlsView: View {
    @ObservedObject var mlManager: MLInferenceManager
    let arViewModel: ARViewModel
    @Binding var tapToSetMode: Bool
    let onTapToSet: (CGPoint, CGSize) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with model type and current goal
            VStack(alignment: .leading, spacing: 4) {
                Text(mlManager.modelTypeDisplayName)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.blue)
                
                Text("Goal: (\(String(format: "%.2f", mlManager.currentGoalPoint.x)), \(String(format: "%.2f", mlManager.currentGoalPoint.y)), \(String(format: "%.2f", mlManager.currentGoalPoint.z)))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospaced()
            }
            
            // Tap to Set Goal Mode Toggle
            VStack(alignment: .leading, spacing: 6) {
                Button(action: {
                    tapToSetMode.toggle()
                    print("🎯 VQ-BeT tap mode toggled to: \(tapToSetMode)")
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: tapToSetMode ? "hand.tap.fill" : "hand.tap")
                        Text(tapToSetMode ? "Tap Mode: ON" : "Enable Tap to Set")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .foregroundColor(tapToSetMode ? .white : .primary)
                .tint(tapToSetMode ? .green : .blue)
                
                if tapToSetMode {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("• Tap screen to set 3D goal point")
                            .font(.caption2)
                            .foregroundColor(.green)
                        Text("• EdgeTAM prompts disabled")
                            .font(.caption2)
                            .foregroundColor(.orange)
                        Text("• Visual marker shows goal location")
                            .font(.caption2)
                            .foregroundColor(.cyan)
                    }
                    .padding(.leading, 8)
                }
            }
            
            // Quick preset buttons (optional - can be removed if not needed)
            if tapToSetMode {
                Text("Quick Presets:")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                
                HStack(spacing: 8) {
                    Button("Origin") {
                        mlManager.setGoalPoint(simd_float3(0, 0, 0))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    
                    Button("Forward") {
                        mlManager.setGoalPoint(simd_float3(0, 0, -0.5))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    
                    Button("Clear") {
                        arViewModel.arVisualizationManager.removeGoalPointMarker()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .foregroundColor(.red)
                }
                .font(.caption2)
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.75))
        .cornerRadius(10)
    }
}

#Preview {
    // Create a mock MLInferenceManager for preview
    let mockModelManager = ModelManager()
    let mockMLManager = MLInferenceManager(modelManager: mockModelManager)
    let mockARViewModel = ARViewModel()
    
    VQBeTGoalControlsView(
        mlManager: mockMLManager, 
        arViewModel: mockARViewModel,
        tapToSetMode: .constant(false),
        onTapToSet: { _, _ in }
    )
    .frame(width: 300)
    .background(Color.gray.opacity(0.3))
}