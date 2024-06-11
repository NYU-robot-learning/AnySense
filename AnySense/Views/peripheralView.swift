//
//  peripheralView.swift
//  Anysense
//
//  Created by Michael on 2024/7/29.
//

import SwiftUI
import CoreBluetooth

struct singleBLEPeripheral: View {
    @EnvironmentObject var bluetoothManager: BluetoothManager
    @EnvironmentObject var appStatus: AppInformation
    @State private var isConnected = false
    let name: String
    let uuid: UUID

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
                Text(name)
                    .font(.headline)
                Spacer()
            if(!appStatus.ifBluetoothConnected || isConnected){
                Button(action: toggleConnection) {
                    Text(isConnected ? "Disconnect" : "Connect")
                        .foregroundColor(isConnected ? .red : .blue)
                }
                .padding(.leading, 50.0)
                .buttonStyle(.bordered)
//                .alert(isPresented: $bluetoothManager.showRxWarning) {
//                    Alert(
//                        title: Text("Warning: Rx Characteristic Not Found"),
//                        message: Text("Connected device does not have any published Rx characteristics. Recorded bluetooth data file will be empty."),
//                        dismissButton: .default(Text("OK"))
//                    )
//                }
            }
        }
    }
    
    private func toggleConnection() {
        UIImpactFeedbackGenerator(style: appStatus.hapticFeedbackLevel).impactOccurred()
        
        if !isConnected{
            bluetoothManager.connectToPeripheral(withUUID: uuid) { result in
                switch result {
                case .success(let connectedPeripheral):
                    print("Successfully connected to: \(connectedPeripheral.name ?? "Unknown Device")")
                case .failure(let error):
                    print("Connection failed: \(error.localizedDescription)")
                }
            }
            appStatus.ifBluetoothConnected = true
        } else {
            appStatus.ifBluetoothConnected = false
            bluetoothManager.disconnectFromDevice()
        }
        
        isConnected = !isConnected
    }
}

struct PeripheralView: View {
    @EnvironmentObject var appStatus : AppInformation
    @EnvironmentObject var bluetoothManager: BluetoothManager
    var body: some View {
        VStack{
            Text("Devices Detected")
                .font(.body)
                .frame(width: 500.0, height: 50)
                .ignoresSafeArea()
                .foregroundStyle(.deviceWord)
                .background(.deviceTop)
                .padding(.top, 5)
            List(Array(bluetoothManager.discoveredPeripherals.keys), id: \.self) { uuid in
                if let peripheral = bluetoothManager.discoveredPeripherals[uuid] {
                    singleBLEPeripheral(
                        name: peripheral.name ?? "Unknown Device",
                        uuid: peripheral.identifier
                    )
                }
            }
        }
    }
}

#Preview {
    PeripheralView().environmentObject(AppInformation())
}
