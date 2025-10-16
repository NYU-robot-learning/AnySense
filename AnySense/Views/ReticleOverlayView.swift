//
//  ReticleOverlayView.swift
//  AnySense
//
//  Created by AI Assistant on 2025/10/16.
//

import SwiftUI

/// A fixed center reticle overlay that represents the current phone pose/direction
/// Designed to mimic flight simulator HUD aesthetics
struct ReticleOverlayView: View {
    let size: CGFloat = 40  // Diameter of the reticle
    let lineLength: CGFloat = 15  // Length of crosshair lines
    let lineWidth: CGFloat = 2  // Width of lines
    let color: Color = .cyan
    let opacity: Double = 0.7
    
    var body: some View {
        ZStack {
            // Center circle
            Circle()
                .stroke(color, lineWidth: lineWidth)
                .frame(width: size, height: size)
            
            // Center dot
            Circle()
                .fill(color)
                .frame(width: 4, height: 4)
            
            // Top line
            Rectangle()
                .fill(color)
                .frame(width: lineWidth, height: lineLength)
                .offset(y: -(size/2 + lineLength/2 + 2))
            
            // Bottom line
            Rectangle()
                .fill(color)
                .frame(width: lineWidth, height: lineLength)
                .offset(y: (size/2 + lineLength/2 + 2))
            
            // Left line
            Rectangle()
                .fill(color)
                .frame(width: lineLength, height: lineWidth)
                .offset(x: -(size/2 + lineLength/2 + 2))
            
            // Right line
            Rectangle()
                .fill(color)
                .frame(width: lineLength, height: lineWidth)
                .offset(x: (size/2 + lineLength/2 + 2))
            
            // Corner brackets for enhanced visibility
            ForEach(0..<4) { i in
                ReticleCornerBracket()
                    .rotation3DEffect(.degrees(Double(i) * 90), axis: (x: 0, y: 0, z: 1))
                    .offset(x: size/2 + 8, y: size/2 + 8)
            }
        }
        .opacity(opacity)
    }
}

/// Small corner bracket for the reticle
struct ReticleCornerBracket: View {
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 8, y: 0))
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 0, y: 8))
        }
        .stroke(Color.cyan, lineWidth: 1.5)
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        ReticleOverlayView()
    }
}

