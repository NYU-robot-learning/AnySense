//
//  WebRTCManager.swift
//  Anysense
//
//  Created by Raunaq Bhirangi on 1/11/25.
//


import WebRTC

class WebRTCManager: NSObject {
    private var peerConnection: RTCPeerConnection?
    private var videoSource: RTCVideoSource?
    private var videoTrack: RTCVideoTrack?
    private var webSocket: URLSessionWebSocketTask?
    private let webSocketURL = URL(string: "ws://192.168.0.232:8080")! // Replace with your signaling server URL

    func setupConnection() {
        // Create WebSocket connection
        let urlSession = URLSession(configuration: .default)
        webSocket = urlSession.webSocketTask(with: webSocketURL)
        webSocket?.resume()

        // Listen for messages from the signaling server
        listenForMessages()

        // Set up WebRTC peer connection
        let config = RTCConfiguration()
        config.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        
        let factory = RTCPeerConnectionFactory()
        peerConnection = factory.peerConnection(with: config, constraints: constraints, delegate: nil)

        // Create video source and track
        videoSource = factory.videoSource()
        videoTrack = factory.videoTrack(with: videoSource!, trackId: "ARVideoTrack")

        // Add video track to the peer connection
        let stream = factory.mediaStream(withStreamId: "ARStream")
        stream.addVideoTrack(videoTrack!)
        peerConnection?.add(stream)

        // Create SDP offer
        createSDPOffer()
    }
    
    private func createSDPOffer() {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        peerConnection?.offer(for: constraints) { [weak self] sdp, error in
            guard let sdp = sdp else {
                print("Failed to create SDP offer: \(String(describing: error))")
                return
            }

            self?.peerConnection?.setLocalDescription(sdp) { error in
                if let error = error {
                    print("Failed to set local description: \(error)")
                }
            }

            // Send SDP offer to signaling server
            self?.sendSDPToSignalingServer(sdp: sdp)
        }
    }

    private func sendSDPToSignalingServer(sdp: RTCSessionDescription) {
        let message = [
            "sdp": [
                "type": sdp.type.rawValue, // Should be "offer" or "answer"
                "sdp": sdp.sdp
            ]
        ]
        if let jsonData = try? JSONSerialization.data(withJSONObject: message, options: []) {
            webSocket?.send(.data(jsonData)) { error in
                if let error = error {
                    print("Failed to send SDP: \(error)")
                } else {
                    print("SDP sent: \(message)")
                }
            }
        }
    }

    private func listenForMessages() {
        webSocket?.receive { [weak self] result in
            switch result {
            case .failure(let error):
                print("WebSocket error: \(error)")
            case .success(let message):
                switch message {
                case .data(let data):
                    self?.handleSignalingMessage(data: data)
                case .string(let text):
                    if let data = text.data(using: .utf8) {
                        self?.handleSignalingMessage(data: data)
                    }
                @unknown default:
                    print("Unknown WebSocket message type")
                }
            }

            // Continue listening for more messages
            self?.listenForMessages()
        }
    }

    private func handleSignalingMessage(data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let message = json as? [String: Any] else {
            print("Failed to parse signaling message")
            return
        }

        if let sdp = message["sdp"] as? [String: Any],
           let typeString = sdp["type"] as? String,
           let sdpString = sdp["sdp"] as? String {
            // Map string to RTCSdpType
            let sdpType: RTCSdpType
            switch typeString {
                case "offer":
                    sdpType = .offer
                case "answer":
                    sdpType = .answer
                default:
                    print("Invalid SDP type: \(typeString)")
                    return
            }

            // Create and set the RTCSessionDescription
            let sessionDescription = RTCSessionDescription(type: sdpType, sdp: sdpString)
            peerConnection?.setRemoteDescription(sessionDescription) { error in
                if let error = error {
                    print("Failed to set remote description: \(error)")
                }
            }
        }

        if let candidate = message["candidate"] as? [String: Any],
           let sdpMid = candidate["sdpMid"] as? String,
           let sdpMLineIndex = candidate["sdpMLineIndex"] as? Int32,
           let candidateString = candidate["candidate"] as? String {
            let iceCandidate = RTCIceCandidate(
                sdp: candidateString,
                sdpMLineIndex: sdpMLineIndex,
                sdpMid: sdpMid
            )
            peerConnection?.add(iceCandidate)
        }
    }

//    func sendData(_ data: Data) {
//        guard let dataChannel = dataChannel, dataChannel.readyState == .open else {
//            print("Data channel is not ready")
//            return
//        }
//        let buffer = RTCDataBuffer(data: data, isBinary: true)
//        dataChannel.sendData(buffer)
//    }
    
    func sendFrame(pixelBuffer: CVPixelBuffer) {
        guard let videoSource = videoSource else { return }
        print("Sending frame")
        // Send the frame to the video source
        let rtcPixelBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let videoFrame = RTCVideoFrame(buffer: rtcPixelBuffer, rotation: ._0, timeStampNs: Int64(Date().timeIntervalSince1970 * 1_000_000_000))
        print("Sending video frame at timestamp: \(videoFrame.timeStampNs)")
        // Send the frame to the video source
        videoSource.capturer(RTCVideoCapturer(), didCapture: videoFrame)
    }
}

extension WebRTCManager: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        print("ICE connection state changed: \(newState.rawValue)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        
    }
    
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange state: RTCSignalingState) {
        print("Signaling state changed: \(state.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        print("Generated ICE candidate: \(candidate)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        print("ICE connection state changed: \(newState.rawValue)")
    }
}

extension WebRTCManager: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        print("Data channel state changed: \(dataChannel.readyState.rawValue)")
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        print("Received message: \(buffer.data)")
    }
}
