//
//  USBManager.swift
//  Anysense
//
//  Created by Raunaq Bhirangi on 1/13/25.
//

import Network
import UIKit
import Compression


struct PeerTalkHeader {
    var a: UInt32
    var b: UInt32
    var c: UInt32
    var body_size: UInt32
}

struct Record3DHeader {
    var rgbWidth: UInt32
    var rgbHeight: UInt32
    var depthWidth: UInt32
    var depthHeight: UInt32 
    var confidenceWidth: UInt32
    var confidenceHeight: UInt32
    var rgbSize: UInt32
    var depthSize: UInt32
    var confidenceMapSize: UInt32
    var miscSize: UInt32
    var deviceType: UInt32
    // jointActions are always 28 bytes (7 floats), embedded in message body after RGB data
}

struct IntrinsicMatrixCoeffs {
    var fx: Float
    var fy: Float
    var tx: Float
    var ty: Float
}

struct CameraPose {
    // Quaternion coefficients
    var qx: Float
    var qy: Float
    var qz: Float
    var qw: Float
    
    var tx: Float
    var ty: Float
    var tz: Float
}

class USBManager {
    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private var intrinsicMat = IntrinsicMatrixCoeffs(fx:714.178, fy: 714.178, tx: 359.1699, ty:482.075)
    private var ptHeader = PeerTalkHeader(a:1, b:1, c:1, body_size: 0)
    func connect() {
        do {
            listener = try NWListener(using: .tcp, on: 1337) // Port 5000 matches libusbmuxd example
            listener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    break
                case .failed(let error):
                    break
                default:
                    break
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection: connection)
            }

            listener?.start(queue: .main)
        } catch {
            // Failed to start listener
        }
    }
    
    func disconnect() {
        // Cancel the listener if it exists
        if let listener = listener {
            listener.cancel()
        }
        listener = nil

        // Cancel the active connection if it exists
        if let connection = activeConnection {
            connection.cancel()
        }
        activeConnection = nil
    }
    
    private func handleConnection(connection: NWConnection) {
        self.activeConnection = connection
        connection.start(queue: .global())
    }
    
    func sendData(
        record3dHeaderData: Data,
        intrinsicMatData: Data,
        poseData: Data,
        rgbImageData: Data,
        jointActionsData: Data,  // Always exactly 28 bytes (7 floats)
        compressedDepthData: Data? = nil,
        compressedConfData: Data? = nil
    ) {
        guard let activeConnection = activeConnection else {
            return
        }
        var messageBody = record3dHeaderData + intrinsicMatData + poseData + rgbImageData + jointActionsData
        if let depthData = compressedDepthData {
            messageBody += depthData
        }
        if let depthConfData = compressedConfData {
            messageBody += depthConfData
        }

        self.ptHeader.body_size = UInt32(messageBody.count).bigEndian
        let ptHeaderData = Data(bytes: &self.ptHeader, count:MemoryLayout<PeerTalkHeader>.size)
        
        let completeMessage = ptHeaderData + messageBody
        
        print("USB data: \(completeMessage.count) bytes total")
        
        activeConnection.send(content:completeMessage, completion: .contentProcessed {error in
            if let error = error {
                // USB send failed
            }
        })
    }
    
    func sendData(connection: NWConnection, message: String) {
        let data = message.data(using: .utf8)!
        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                // Data send failed
            }
        })
    }
    
    func compressData(from pixelBuffer: CVPixelBuffer, isDepth: Bool) -> Data? {
        // Extract depth data
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Determine the element size based on the type of data
        let elementSize = isDepth ? MemoryLayout<Float>.size : MemoryLayout<UInt8>.size
        let dataSize = width * height * elementSize

        // Extract the raw data
        let data = Data(bytes: baseAddress, count: dataSize)

        // Allocate an output buffer for compressed data
        let compressedBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: dataSize)
        defer { compressedBuffer.deallocate() }

        let compressedSize = compression_encode_buffer(
            compressedBuffer,
            dataSize,
            [UInt8](data),
            data.count,
            nil,
            COMPRESSION_LZFSE
        )

        guard compressedSize > 0 else {
            return nil
        }

        // Return compressed depth data
        return Data(bytes: compressedBuffer, count: compressedSize)
    }
    
}
