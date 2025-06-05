import SwiftUI
import AVFoundation
import MediaPlayer
import Combine

class VolumeButtonManager: ObservableObject {
    private var volumeObserver: NSKeyValueObservation?
    private var volumeSetpoint: Float
    let buttonPressed = PassthroughSubject<Void, Never>()
    private var volumeView: MPVolumeView?
    private weak var volumeSlider: UISlider?

    init() {
        self.volumeSetpoint = 0.5
        setupVolumeObservation()
    }

    private func setupVolumeObservation() {
        DispatchQueue.main.async {
            self.volumeView = MPVolumeView(frame: .zero)
            self.volumeView?.isHidden = true
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let window = windowScene.windows.first {
                window.addSubview(self.volumeView!)
                self.volumeSlider = self.volumeView?.subviews.compactMap { $0 as? UISlider }.first
            }
        }
        try? AVAudioSession.sharedInstance().setActive(true, options: [])
        volumeObserver = AVAudioSession.sharedInstance().observe(\AVAudioSession.outputVolume) { [weak self] session, _ in
            guard let self = self else { return }
            let newVolume = session.outputVolume
            if newVolume != self.volumeSetpoint {
                DispatchQueue.main.async {
                    self.volumeSlider?.value = self.volumeSetpoint
                    self.buttonPressed.send()
                }
            }
        }
    }

    deinit {
        volumeObserver?.invalidate()
        if let volumeView = volumeView {
            volumeView.removeFromSuperview()
        }
    }
}
