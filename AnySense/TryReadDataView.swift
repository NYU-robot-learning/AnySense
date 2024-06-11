import SwiftUI
import ExternalAccessory

struct TryReadDataView: View {
    @State private var receivedData: String = ""

    var body: some View {
        VStack {
            Text("USB Communication App")
                .font(.title)
            
            Text("Received Data: \(receivedData)")
            
            Button(action: {
                self.readFromDevice()
            }) {
                Text("Read Data from Device")
            }
        }
        .padding()
    }

    func readFromDevice() {
        if let connectedAccessory = EAAccessoryManager.shared().connectedAccessories.first {
            let session = EASession(accessory: connectedAccessory, forProtocol: "DW_apb_i2c ")
            
            if let inputStream = session?.inputStream {
                inputStream.open()
                
                var buffer = [UInt8](repeating: 0, count: 1024)
                let bytesRead = inputStream.read(&buffer, maxLength: buffer.count)
                
                if bytesRead > 0 {
                    let data = Data(bytes: buffer, count: bytesRead)
                    if let receivedString = String(data: data, encoding: .utf8) {
                        self.receivedData = receivedString
                    }
                }
                
                inputStream.close()
            }
        } else {
            print("No connected accessory found.")
        }
    }
}

#Preview {
    TryReadDataView()
}

