//
//  EdgeTAMVisualizationOverlay.swift
//  AnySense
//
//  Real-time EdgeTAM visualization overlay with full segmentation pipeline
//

import SwiftUI

struct EdgeTAMVisualizationOverlay: View {
    @ObservedObject var edgeTAMManager: EdgeTAMManager
    let disablePromptMode: Bool
    @State private var showVisualization: Bool = false
    @State private var overlayOpacity: Double = 0.7
    @State private var isPromptMode: Bool = false
    
    init(edgeTAMManager: EdgeTAMManager, disablePromptMode: Bool = false) {
        self.edgeTAMManager = edgeTAMManager
        self.disablePromptMode = disablePromptMode
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // EdgeTAM segmentation mask overlay
                if showVisualization && !edgeTAMManager.currentPrompt.points.isEmpty {
                    if let segmentationMask = edgeTAMManager.latestSegmentationMask {
                        Image(uiImage: segmentationMask)
                            .interpolation(.none)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .opacity(overlayOpacity)
                            .animation(.easeInOut(duration: 0.3), value: edgeTAMManager.latestSegmentationMask)
                    }
                }
                
                // Tap gesture overlay for adding prompts (disabled when VQ-BeT is in tap mode)
                if isPromptMode && !disablePromptMode {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            addPromptPoint(at: location, in: geometry)
                        }
                }
                
                // Show prompt points overlay
                if edgeTAMManager.isBoundaryTracking {
                    // Show original green points (user input, never move)
                    ForEach(0..<edgeTAMManager.originalPoints.count, id: \.self) { index in
                        let point = edgeTAMManager.originalPoints[index]
                        let screenPoint = convertModelPointToScreen(point, in: geometry)
                        Circle()
                            .fill(Color.green)
                            .frame(width: 12, height: 12)
                            .position(screenPoint)
                            .overlay(
                                Circle()
                                    .stroke(Color.white, lineWidth: 2)
                                    .frame(width: 16, height: 16)
                            )
                    }
                    
                    // Show red tracking points (updated every 8 frames)
                    ForEach(0..<edgeTAMManager.displayTrackingPoints.count, id: \.self) { index in
                        let point = edgeTAMManager.displayTrackingPoints[index]
                        let screenPoint = convertModelPointToScreen(point, in: geometry)
                        Circle()
                            .fill(Color.red)
                            .frame(width: 10, height: 10)
                            .position(screenPoint)
                            .overlay(
                                Circle()
                                    .stroke(Color.white, lineWidth: 2)
                                    .frame(width: 14, height: 14)
                            )
                    }
                } else if !edgeTAMManager.currentPrompt.points.isEmpty {
                    // Show initial prompt points (before tracking starts) - only positive points
                    ForEach(0..<edgeTAMManager.currentPrompt.points.count, id: \.self) { index in
                        let point = edgeTAMManager.currentPrompt.points[index]
                        let screenPoint = convertTuplePointToScreen(point, in: geometry)
                        Circle()
                            .fill(Color.green)
                            .frame(width: 12, height: 12)
                            .position(screenPoint)
                            .overlay(
                                Circle()
                                    .stroke(Color.white, lineWidth: 2)
                                    .frame(width: 16, height: 16)
                            )
                    }
                }
                
                // Controls overlay
                VStack {
                    Spacer()
                    
                    HStack {
                        Spacer()
                        
                        VStack(alignment: .trailing, spacing: 12) {
                            // Prompt mode toggle
                            if edgeTAMManager.isModelLoaded {
                                Button(action: {
                                    withAnimation {
                                        isPromptMode.toggle()
                                    }
                                }) {
                                    Image(systemName: isPromptMode ? "hand.point.up.left.fill" : "hand.point.up.left")
                                        .font(.title2)
                                        .foregroundColor(isPromptMode ? .yellow : .white)
                                        .padding(12)
                                        .background(Color.black.opacity(0.7))
                                        .clipShape(Circle())
                                }
                            }
                            
                            
                            // Boundary tracking toggle
                            if !edgeTAMManager.currentPrompt.points.isEmpty {
                                Button(action: {
                                    withAnimation {
                                        if edgeTAMManager.isBoundaryTracking {
                                            edgeTAMManager.stopBoundaryTracking()
                                        } else {
                                            edgeTAMManager.startBoundaryTracking()
                                        }
                                    }
                                }) {
                                    Image(systemName: edgeTAMManager.isBoundaryTracking ? "location.fill" : "location")
                                        .font(.title2)
                                        .foregroundColor(edgeTAMManager.isBoundaryTracking ? .green : .white)
                                        .padding(12)
                                        .background(Color.black.opacity(0.7))
                                        .clipShape(Circle())
                                }
                                .transition(.opacity.combined(with: .scale))
                            }
                            
                            // Clear prompts button (only when in prompt mode)
                            if isPromptMode && !edgeTAMManager.currentPrompt.points.isEmpty {
                                Button(action: {
                                    withAnimation {
                                        edgeTAMManager.clearPrompts()
                                        edgeTAMManager.stopBoundaryTracking()
                                    }
                                }) {
                                    Image(systemName: "trash.fill")
                                        .font(.title2)
                                        .foregroundColor(.red)
                                        .padding(12)
                                        .background(Color.black.opacity(0.7))
                                        .clipShape(Circle())
                                }
                                .transition(.opacity.combined(with: .scale))
                            }
                            
                            // Opacity slider (only when visualization is shown)
                            if showVisualization {
                                VStack(spacing: 4) {
                                    Text("Opacity")
                                        .font(.caption)
                                        .foregroundColor(.white)
                                    
                                    Slider(value: $overlayOpacity, in: 0.1...1.0, step: 0.1)
                                        .frame(width: 100)
                                        .accentColor(.white)
                                }
                                .padding(8)
                                .background(Color.black.opacity(0.7))
                                .cornerRadius(8)
                                .transition(.opacity.combined(with: .move(edge: .trailing)))
                            }
                            
                            // Status indicator
                            if edgeTAMManager.isProcessing {
                                HStack(spacing: 4) {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    
                                    Text("Processing")
                                        .font(.caption)
                                        .foregroundColor(.white)
                                }
                                .padding(8)
                                .background(Color.black.opacity(0.7))
                                .cornerRadius(8)
                            } else if showVisualization && edgeTAMManager.processedFrameCount > 0 {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("EdgeTAM")
                                        .font(.caption.bold())
                                        .foregroundColor(.white)
                                    
                                    Text("Segmentation")
                                        .font(.caption2)
                                        .foregroundColor(.white.opacity(0.8))
                                    
                                    Text("\(edgeTAMManager.processedFrameCount) frames")
                                        .font(.caption2)
                                        .foregroundColor(.white.opacity(0.8))
                                    
                                    Text("\(String(format: "%.0f", edgeTAMManager.processingTime * 1000))ms")
                                        .font(.caption2)
                                        .foregroundColor(.white.opacity(0.8))
                                    
                                    if !edgeTAMManager.currentPrompt.points.isEmpty {
                                        Text("\(edgeTAMManager.currentPrompt.points.count) points")
                                            .font(.caption2)
                                            .foregroundColor(.yellow.opacity(0.8))
                                    }
                                    
                                    if edgeTAMManager.isBoundaryTracking {
                                        Text("Boundary Tracking")
                                            .font(.caption2)
                                            .foregroundColor(.green.opacity(0.8))
                                    }
                                }
                                .padding(8)
                                .background(Color.black.opacity(0.7))
                                .cornerRadius(8)
                            }
                        }
                        .padding(.trailing, 20)
                        .padding(.bottom, 100) // Above other UI elements
                    }
                }
                
                // Prompt mode instructions
                if isPromptMode {
                    VStack {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Prompt Mode")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                
                                Text("Tap to add positive points")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.8))
                                
                                Text("Long press for negative points")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.8))
                            }
                            .padding(12)
                            .background(Color.black.opacity(0.8))
                            .cornerRadius(8)
                            
                            Spacer()
                        }
                        .padding(.top, 50)
                        .padding(.leading, 20)
                        
                        Spacer()
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }
    
    // MARK: - Helper Functions
    private func addPromptPoint(at location: CGPoint, in geometry: GeometryProxy) {
        // Convert screen coordinates to normalized coordinates (0-1)
        let normalizedPoint = CGPoint(
            x: location.x / geometry.size.width,
            y: location.y / geometry.size.height
        )
        
        // Try to add point with constraints - pass screen coordinates for distance checking
        let success = edgeTAMManager.addPromptPointWithConstraints(
            normalizedPoint, 
            screenPoint: location,
            screenSize: geometry.size
        )
        
        if !success {
            // Could add visual feedback here (shake animation, error message, etc.)
            print("⚠️ Point rejected: outside mask or too close to existing point")
        }
    }
    
    private func convertModelPointToScreen(_ modelPoint: CGPoint, in geometry: GeometryProxy) -> CGPoint {
        // Convert model coordinates (0-1024) back to screen coordinates
        let normalizedX = modelPoint.x / 1024.0
        let normalizedY = modelPoint.y / 1024.0
        
        return CGPoint(
            x: normalizedX * geometry.size.width,
            y: normalizedY * geometry.size.height
        )
    }
    
    private func convertTuplePointToScreen(_ tuplePoint: (CGPoint, Bool), in geometry: GeometryProxy) -> CGPoint {
        return convertModelPointToScreen(tuplePoint.0, in: geometry)
    }
}

// MARK: - Enhanced Controls
struct EdgeTAMVisualizationControls: View {
    @ObservedObject var edgeTAMManager: EdgeTAMManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("EdgeTAM Segmentation")
                .font(.headline)
            
            // Model status
            HStack {
                Image(systemName: edgeTAMManager.isModelLoaded ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(edgeTAMManager.isModelLoaded ? .green : .red)
                
                Text(edgeTAMManager.isModelLoaded ? "Models Loaded" : "Models Not Loaded")
                    .font(.caption)
            }
            
            // Segmentation controls
            if !edgeTAMManager.currentPrompt.points.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Active Segmentation")
                        .font(.subheadline.bold())
                    
                    HStack {
                        Button("Clear Prompts") {
                            edgeTAMManager.clearPrompts()
                        }
                        .buttonStyle(.bordered)
                        
                        Spacer()
                        
                        Text("\(edgeTAMManager.currentPrompt.points.count) points")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    if edgeTAMManager.latestSegmentationMask != nil {
                        Text("✓ Mask generated")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                }
                .padding(8)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
            } else {
                Text("Tap screen in prompt mode to add points")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            }
            
            // Processing info
            if edgeTAMManager.processedFrameCount > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Processing: \(edgeTAMManager.processedFrameCount) frames")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    Text("Last update: \(String(format: "%.1f", edgeTAMManager.processingTime * 1000))ms")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }
}
