//
//  BoundaryTrackingManager.swift
//  AnySense
//
//  Boundary-based point tracking for robust segmentation
//

import Foundation
import UIKit
import CoreImage
import Vision

// MARK: - Boundary Point
struct BoundaryPoint {
    let x: CGFloat
    let y: CGFloat
    let timestamp: Date
    
    init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
        self.timestamp = Date()
    }
    
    var cgPoint: CGPoint {
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Tracked Boundary
struct TrackedBoundary {
    let originalPoint: CGPoint
    var currentPoint: CGPoint
    var boundaryPoints: [BoundaryPoint]
    let creationTime: Date
    var lastUpdateTime: Date
    var updateCount: Int
    
    init(originalPoint: CGPoint) {
        self.originalPoint = originalPoint
        self.currentPoint = originalPoint
        self.boundaryPoints = []
        self.creationTime = Date()
        self.lastUpdateTime = Date()
        self.updateCount = 0
    }
    
    mutating func updateBoundary(points: [BoundaryPoint], newPoint: CGPoint) {
        self.boundaryPoints = points
        self.currentPoint = newPoint
        self.lastUpdateTime = Date()
        self.updateCount += 1
    }
}

// MARK: - Boundary Tracking Manager
class BoundaryTrackingManager: ObservableObject {
    
    @Published var trackedBoundaries: [TrackedBoundary] = []
    @Published var isTracking: Bool = false
    @Published var displayBoundaries: [TrackedBoundary] = [] // Only updated every 8 frames for display
    
    private let ciContext = CIContext()
    
    // MARK: - Boundary Extraction
    func extractBoundaryPoints(from maskImage: UIImage) -> [BoundaryPoint] {
        guard let cgImage = maskImage.cgImage else {
            print("Could not get CGImage from mask")
            return []
        }
        
        let width = cgImage.width
        let height = cgImage.height
        print("Mask image size: \(width)x\(height)")
        
        // EdgeTAM masks are 256x256 but model coordinates are 1024x1024
        // We need to scale boundary points by 4x to match model coordinate space
        let scaleX: CGFloat = 1024.0 / CGFloat(width)
        let scaleY: CGFloat = 1024.0 / CGFloat(height)
        
        // Convert image to grayscale pixel data
        guard let pixelData = getPixelData(from: cgImage) else {
            print("Could not extract pixel data")
            return []
        }
        
        // Debug: Check pixel value distribution
        let sampleSize = min(1000, pixelData.count)
        let samplePixels = Array(pixelData.prefix(sampleSize))
        let nonZeroPixels = samplePixels.filter { $0 > 0 }.count
        let maxPixel = samplePixels.max() ?? 0
        let minPixel = samplePixels.min() ?? 0
        print("Pixel analysis: \(nonZeroPixels)/\(sampleSize) non-zero, range: \(minPixel)-\(maxPixel)")
        
        var boundaryPoints: [BoundaryPoint] = []
        var maskPixelCount = 0
        
        // Use a lower threshold since the mask might have different values
        let threshold: UInt8 = 50
        
        // Scan for boundary pixels (edge detection)
        for y in 1..<(height-1) {
            for x in 1..<(width-1) {
                let currentIndex = y * width + x
                let currentPixel = pixelData[currentIndex]
                
                // Count mask pixels
                if currentPixel > threshold {
                    maskPixelCount += 1
                }
                
                // If current pixel is part of mask (above threshold)
                if currentPixel > threshold {
                    // Check if it's a boundary pixel by examining neighbors
                    let neighbors = [
                        pixelData[(y-1) * width + x],     // top
                        pixelData[(y+1) * width + x],     // bottom
                        pixelData[y * width + (x-1)],     // left
                        pixelData[y * width + (x+1)],     // right
                    ]
                    
                    // If any neighbor is background (below threshold), this is a boundary pixel
                    if neighbors.contains(where: { $0 <= threshold }) {
                        let boundaryPoint = BoundaryPoint(
                            x: CGFloat(x) * scaleX,  // Scale to model coordinate space
                            y: CGFloat(y) * scaleY
                        )
                        boundaryPoints.append(boundaryPoint)
                    }
                }
            }
        }
        
        print("Mask analysis: \(maskPixelCount) mask pixels, \(boundaryPoints.count) boundary points")
        
        // If we still have no boundary points, try a more aggressive approach
        if boundaryPoints.isEmpty && maskPixelCount > 0 {
            print("Warning: No boundaries found with threshold \(threshold), trying aggressive detection...")
            boundaryPoints = extractBoundaryPointsAggressive(from: pixelData, width: width, height: height, scaleX: scaleX, scaleY: scaleY)
        }
        
        return boundaryPoints
    }
    
    // More aggressive boundary detection
    private func extractBoundaryPointsAggressive(from pixelData: [UInt8], width: Int, height: Int, scaleX: CGFloat, scaleY: CGFloat) -> [BoundaryPoint] {
        var boundaryPoints: [BoundaryPoint] = []
        
        // Find any non-zero pixels and treat edges as boundaries
        for y in 1..<(height-1) {
            for x in 1..<(width-1) {
                let currentIndex = y * width + x
                let currentPixel = pixelData[currentIndex]
                
                // If current pixel has any value
                if currentPixel > 10 {
                    // Check 8-connected neighbors
                    let neighbors = [
                        pixelData[(y-1) * width + (x-1)], // top-left
                        pixelData[(y-1) * width + x],     // top
                        pixelData[(y-1) * width + (x+1)], // top-right
                        pixelData[y * width + (x-1)],     // left
                        pixelData[y * width + (x+1)],     // right
                        pixelData[(y+1) * width + (x-1)], // bottom-left
                        pixelData[(y+1) * width + x],     // bottom
                        pixelData[(y+1) * width + (x+1)]  // bottom-right
                    ]
                    
                    // If any neighbor is much different, this is a boundary
                    let avgNeighbor = neighbors.reduce(0, +) / UInt8(neighbors.count)
                    if abs(Int(currentPixel) - Int(avgNeighbor)) > 20 {
                        boundaryPoints.append(BoundaryPoint(
                            x: CGFloat(x) * scaleX,  // Scale to model coordinate space
                            y: CGFloat(y) * scaleY
                        ))
                    }
                }
            }
        }
        
        print("Aggressive extraction found \(boundaryPoints.count) boundary points")
        return boundaryPoints
    }
    
    // MARK: - Point Update Strategy
    func updateTrackingPoint(for boundary: TrackedBoundary) -> CGPoint {
        guard !boundary.boundaryPoints.isEmpty else {
            print("Warning: No boundary points available, keeping original point")
            return boundary.currentPoint
        }
        
        // Find the closest boundary points to the current tracking point
        let sortedByDistance = boundary.boundaryPoints.sorted { point1, point2 in
            let dist1 = distanceSquared(from: boundary.currentPoint, to: point1.cgPoint)
            let dist2 = distanceSquared(from: boundary.currentPoint, to: point2.cgPoint)
            return dist1 < dist2
        }
        
        // Sample up to 5 closest boundary points
        let sampleSize = min(5, sortedByDistance.count)
        let sampledPoints = Array(sortedByDistance.prefix(sampleSize))
        
        return sampleBoundaryPoints(from: sampledPoints)
    }
    
    // Helper function to calculate distance squared (faster than sqrt)
    private func distanceSquared(from point1: CGPoint, to point2: CGPoint) -> CGFloat {
        let dx = point1.x - point2.x
        let dy = point1.y - point2.y
        return dx * dx + dy * dy
    }
    
    private func sampleBoundaryPoints(from points: [BoundaryPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        
        // Calculate centroid of sampled boundary points
        let totalX = points.reduce(0) { $0 + $1.x }
        let totalY = points.reduce(0) { $0 + $1.y }
        
        let centroidX = totalX / CGFloat(points.count)
        let centroidY = totalY / CGFloat(points.count)
        
        print("Updated point from \(points.count) boundary samples to (\(Int(centroidX)), \(Int(centroidY)))")
        
        return CGPoint(x: centroidX, y: centroidY)
    }
    
    // MARK: - Tracking Management
    func startTracking(initialPoint: CGPoint, maskImage: UIImage) {
        var newBoundary = TrackedBoundary(originalPoint: initialPoint)
        
        // Debug: Save mask image to understand what we're working with
        saveMaskImageForDebugging(maskImage, prefix: "initial")
        
        // Extract initial boundary
        let boundaryPoints = extractBoundaryPoints(from: maskImage)
        newBoundary.updateBoundary(points: boundaryPoints, newPoint: initialPoint)
        
        trackedBoundaries.append(newBoundary)
        isTracking = true
        
        print("Started boundary tracking for point (\(Int(initialPoint.x)), \(Int(initialPoint.y)))")
    }
    
    func startMultiPointTracking(initialPoints: [CGPoint], maskImage: UIImage) {
        // Clear any existing tracking
        trackedBoundaries.removeAll()
        
        // Debug: Save mask image to understand what we're working with
        saveMaskImageForDebugging(maskImage, prefix: "multipoint_initial")
        
        // Extract boundary points once for all points to track
        let boundaryPoints = extractBoundaryPoints(from: maskImage)
        
        // Create a tracked boundary for each initial point
        for (index, initialPoint) in initialPoints.enumerated() {
            var newBoundary = TrackedBoundary(originalPoint: initialPoint)
            newBoundary.updateBoundary(points: boundaryPoints, newPoint: initialPoint)
            trackedBoundaries.append(newBoundary)
            
            print("Started tracking point \(index + 1): (\(Int(initialPoint.x)), \(Int(initialPoint.y)))")
        }
        
        isTracking = true
        print("Started multi-point boundary tracking for \(initialPoints.count) points")
    }
    
    // Debug helper to analyze mask images
    private func saveMaskImageForDebugging(_ image: UIImage, prefix: String) {
        print("\(prefix) mask image info: size=\(image.size), scale=\(image.scale)")
        
        // Analyze a small sample of the image
        if let cgImage = image.cgImage,
           let pixelData = getPixelData(from: cgImage) {
            
            let width = cgImage.width
            let height = cgImage.height
            let totalPixels = width * height
            
            // Count different pixel value ranges
            var zeroPixels = 0
            var lowPixels = 0    // 1-50
            var mediumPixels = 0 // 51-200
            var highPixels = 0   // 201-255
            
            for pixel in pixelData {
                switch pixel {
                case 0: zeroPixels += 1
                case 1...50: lowPixels += 1
                case 51...200: mediumPixels += 1
                case 201...255: highPixels += 1
                default: break
                }
            }
            
            print("\(prefix) pixel distribution:")
            print("   - Zero (0): \(zeroPixels)/\(totalPixels) (\(Int(Double(zeroPixels)/Double(totalPixels)*100))%)")
            print("   - Low (1-50): \(lowPixels)/\(totalPixels) (\(Int(Double(lowPixels)/Double(totalPixels)*100))%)")
            print("   - Medium (51-200): \(mediumPixels)/\(totalPixels) (\(Int(Double(mediumPixels)/Double(totalPixels)*100))%)")
            print("   - High (201-255): \(highPixels)/\(totalPixels) (\(Int(Double(highPixels)/Double(totalPixels)*100))%)")
        }
    }
    
    func updateAllBoundaries(with maskImage: UIImage, shouldUpdateDisplay: Bool = false) {
        guard isTracking && !trackedBoundaries.isEmpty else { return }
        
        // Extract new boundary points from current mask
        let newBoundaryPoints = extractBoundaryPoints(from: maskImage)
        
        for i in trackedBoundaries.indices {
            // Update boundary points
            trackedBoundaries[i].updateBoundary(
                points: newBoundaryPoints,
                newPoint: updateTrackingPoint(for: trackedBoundaries[i])
            )
        }
        
        // Only update display boundaries every 8 frames (when segmentation runs)
        if shouldUpdateDisplay {
            DispatchQueue.main.async { [weak self] in
                self?.displayBoundaries = self?.trackedBoundaries ?? []
            }
            print("Updated \(trackedBoundaries.count) tracked boundaries + display")
        } else {
            print("Updated \(trackedBoundaries.count) tracked boundaries (internal only)")
        }
    }
    
    func stopTracking() {
        isTracking = false
        trackedBoundaries.removeAll()
        displayBoundaries.removeAll()
        print("Stopped boundary tracking")
    }
    
    func clearAllBoundaries() {
        trackedBoundaries.removeAll()
        displayBoundaries.removeAll()
        print("Cleared all tracked boundaries")
    }
    
    // MARK: - Utility Functions
    private func getPixelData(from cgImage: CGImage) -> [UInt8]? {
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 1 // Grayscale
        let bytesPerRow = width * bytesPerPixel
        let totalBytes = height * bytesPerRow
        
        var pixelData = [UInt8](repeating: 0, count: totalBytes)
        
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
        
        guard let ctx = context else {
            print("Could not create CGContext")
            return nil
        }
        
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        return pixelData
    }
    
    // MARK: - Debug Information
    var trackingStatistics: String {
        if trackedBoundaries.isEmpty {
            return "No active boundaries"
        }
        
        let totalUpdates = trackedBoundaries.reduce(0) { $0 + $1.updateCount }
        let avgBoundaryPoints = trackedBoundaries.isEmpty ? 0 : 
            trackedBoundaries.reduce(0) { $0 + $1.boundaryPoints.count } / trackedBoundaries.count
        
        return """
        Boundaries: \(trackedBoundaries.count)
        Total Updates: \(totalUpdates)
        Avg Boundary Points: \(avgBoundaryPoints)
        """
    }
}

// MARK: - Extensions
extension BoundaryTrackingManager {
    
    // Get current tracking points for segmentation (internal, always up to date)
    var currentTrackingPoints: [CGPoint] {
        return trackedBoundaries.map { $0.currentPoint }
    }
    
    // Get display tracking points for UI (only updated every 8 frames)
    var displayTrackingPoints: [CGPoint] {
        return displayBoundaries.map { $0.currentPoint }
    }
    
    // Get the most recently updated boundary
    var latestBoundary: TrackedBoundary? {
        return trackedBoundaries.max { $0.lastUpdateTime < $1.lastUpdateTime }
    }
}