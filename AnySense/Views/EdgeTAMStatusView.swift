//
//  EdgeTAMStatusView.swift
//  AnySense
//
//  UI component for displaying EdgeTAM processing status
//

import SwiftUI

struct EdgeTAMStatusView: View {
    @ObservedObject var edgeTAMManager: EdgeTAMManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                
                Text(edgeTAMManager.statusText)
                    .font(.caption)
                    .foregroundColor(.primary)
            }
            
            if edgeTAMManager.isModelLoaded && edgeTAMManager.processedFrameCount > 0 {
                HStack {
                    Text("Processing every 8th frame")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    if edgeTAMManager.isProcessing {
                        ProgressView()
                            .scaleEffect(0.5)
                    }
                }
            }
            
            if let features = edgeTAMManager.latestFeatures {
                Text("Features: \(features.shape.map { String(describing: $0) }.joined(separator: "x"))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            // Show segmentation status
            if !edgeTAMManager.currentPrompt.points.isEmpty {
                HStack {
                    Text("Segmentation:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    if edgeTAMManager.latestSegmentationMask != nil {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption2)
                            Text("Mask ready")
                                .font(.caption2)
                                .foregroundColor(.green)
                        }
                    } else {
                        HStack(spacing: 4) {
                            ProgressView()
                                .scaleEffect(0.5)
                            Text("Generating...")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }
    
    private var statusColor: Color {
        if !edgeTAMManager.isModelLoaded {
            return .red
        } else if edgeTAMManager.isProcessing {
            return .orange
        } else if edgeTAMManager.isActive {
            return .green
        } else {
            return .gray
        }
    }
}

struct EdgeTAMControlView: View {
    @ObservedObject var edgeTAMManager: EdgeTAMManager
    @State private var frameInterval: Double = 8
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("EdgeTAM Settings")
                .font(.headline)
            
            HStack {
                Text("Process every")
                Slider(value: $frameInterval, in: 1...30, step: 1)
                    .frame(width: 100)
                Text("\(Int(frameInterval)) frames")
                    .frame(width: 70)
            }
            .font(.caption)
            
            Button(action: {
                edgeTAMManager.setFrameInterval(Int(frameInterval))
            }) {
                Text("Update Interval")
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(6)
            }
            
            Button(action: {
                edgeTAMManager.reset()
            }) {
                Text("Reset")
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.8))
                    .foregroundColor(.white)
                    .cornerRadius(6)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }
}
