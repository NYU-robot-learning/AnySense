import SwiftUI


@IBDesignable
class MessageLabel: UILabel {
    
    var ignoreMessages = false
		
	override func drawText(in rect: CGRect) {
		let insets = UIEdgeInsets(top: 0, left: 5, bottom: 0, right: 5)
		super.drawText(in: rect.inset(by: insets))
	}
    
    func displayMessage(_ text: String, duration: TimeInterval = 3.0) {
        guard !ignoreMessages else { return }
        guard !text.isEmpty else {
            DispatchQueue.main.async {
                self.isHidden = true
                self.text = ""
            }
            return
        }
        
        DispatchQueue.main.async {
            self.isHidden = false
            self.text = text
            
            // Use a tag to tell if the label has been updated.
            let tag = self.tag + 1
            self.tag = tag
            
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                // Do not hide if this method is called again before this block kicks in.
                if self.tag == tag {
                    self.isHidden = true
                }
            }
        }
    }
}


/// A SwiftUI wrapper around `MessageLabel` to show ephemeral messages.
struct MessageLabelView: UIViewRepresentable {
    /// The message text to display. Updating this value triggers a new display.
    @Binding var message: String

    /// How long the message should remain visible.
    var duration: TimeInterval = 3.0

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MessageLabel {
        let label = MessageLabel()
        label.isHidden = true
        label.numberOfLines = 0
        label.textAlignment = .center
        label.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        label.textColor = .white
        label.layer.cornerRadius = 8
        label.clipsToBounds = true
        return label
    }

    func updateUIView(_ uiView: MessageLabel, context: Context) {
        guard context.coordinator.lastMessage != message else { return }
        context.coordinator.lastMessage = message
        uiView.displayMessage(message, duration: duration)
    }

    class Coordinator {
        var lastMessage: String = ""
    }
}
