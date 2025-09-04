//
//  BluetoothManager.swift
//  Anysense
//
//  Created by Michael on 2024/6/8.
//

import SwiftUI
import CoreBluetooth

class BluetoothManager :  NSObject, ObservableObject{
    private var centralManager: CBCentralManager?
    private var matchedPeripheral: CBPeripheral!
    private var rxCharacteristic: CBCharacteristic!
    private var displayLink: CADisplayLink?
    private var BTFileHandle: FileHandle?
    @Published var ifConnected: Bool = false
    @Published var discoveredPeripherals: [UUID: CBPeripheral] = [:]

    override init() {
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: .main)
    }
    
    // Cleanup
    deinit {
        // Clean up CADisplayLink to prevent retain cycles
        displayLink?.invalidate()
        displayLink = nil
        
        // Clean up file handles
        try? BTFileHandle?.close()
        BTFileHandle = nil
        
        // Disconnect from any connected peripherals
        disconnectFromDevice()
        
        // Stop scanning
        centralManager?.stopScan()
        centralManager = nil
        
        // BluetoothManager deinitialized
    }
}

extension BluetoothManager: CBCentralManagerDelegate{
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
                  case .poweredOff:
                      break
                  case .poweredOn:
                      self.scan()
                  case .unsupported:
                      break
                  case .unauthorized:
                      break
                  case .unknown:
                      break
                  case .resetting:
                      break
                  @unknown default:
                      break
                  }
    }
    func scan() -> Void{
        centralManager?.scanForPeripherals(withServices: nil)
    }
    func disconnectFromDevice () {
        if let peripheral = matchedPeripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
            matchedPeripheral = nil
            ifConnected = false
        }
        /*
        if matchedPeripheral != nil {
        centralManager?.cancelPeripheralConnection(matchedPeripheral!)
        }
        ifConnected = false
         */
     }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber){
        guard peripheral.name != nil else { return }
        let peripheralUUID = peripheral.identifier
        
        if discoveredPeripherals[peripheralUUID] == nil {
            discoveredPeripherals[peripheralUUID] = peripheral
        }

    }
    
    func connectToPeripheral(withUUID uuid: UUID, completion: @escaping (Result<CBPeripheral, Error>) -> Void) {
        guard let central = centralManager else {
            completion(.failure(NSError(domain: "Bluetooth", code: 1, userInfo: [NSLocalizedDescriptionKey: "Central Manager is nil"])))
            return
        }
        
        // Retrieve known peripherals (helps avoid stale references)
        let knownPeripherals = central.retrievePeripherals(withIdentifiers: [uuid])
        
        guard let peripheral = knownPeripherals.first ?? discoveredPeripherals[uuid] else {
            completion(.failure(NSError(domain: "Bluetooth", code: 2, userInfo: [NSLocalizedDescriptionKey: "Peripheral not found"])))
            return
        }

        // Disconnect if already connected to another peripheral
        if let currentPeripheral = matchedPeripheral, currentPeripheral.identifier != peripheral.identifier {
            central.cancelPeripheralConnection(currentPeripheral)
        }
        
        matchedPeripheral = peripheral
        peripheral.delegate = self
        
        central.connect(peripheral, options: nil)
    }
    
    func connectToPeripheral(peripheral: CBPeripheral){
        if matchedPeripheral != nil && matchedPeripheral != peripheral {
            centralManager?.cancelPeripheralConnection(matchedPeripheral!)
        }
        matchedPeripheral = peripheral
        peripheral.delegate = self
        centralManager?.connect(peripheral, options: nil)
        /*
                           centralManager?.connect(peripheral, options: nil)
                           ifConnected = true
                           */
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
       //matchedPeripheral.discoverServices(nil)
       ifConnected = true
       matchedPeripheral.discoverServices(nil)
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        ifConnected = false
        matchedPeripheral = nil
    }
}

extension BluetoothManager: CBPeripheralDelegate{
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
            if ((error) != nil) {
                return
            }
            guard let services = peripheral.services else {
                return
            }
            //We need to discover the all characteristic
            for service in services {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else {
              return
          }

          for characteristic in characteristics {
              if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                  rxCharacteristic = characteristic
                  peripheral.setNotifyValue(true, for: rxCharacteristic!)
                  peripheral.readValue(for: characteristic)
                  break
              }
          }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            return
        }
    }
    
}

extension BluetoothManager: CBPeripheralManagerDelegate {

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            break
        case .unsupported:
            break
        case .unauthorized:
            break
        case .unknown:
            break
        case .resetting:
            break
        case .poweredOff:
            break
        @unknown default:
            break
        }
    }

    func startRecording(targetURL: URL, fps: Double) {
        do {
            self.BTFileHandle = try FileHandle(forWritingTo: targetURL)
//            defer {try? BTDataFileHandle.close()}
            try self.BTFileHandle?.seekToEnd()
            
        } catch {
            // Error opening BTFileHandle
        }
        
        displayLink = CADisplayLink(target: self, selector: #selector(recordSingleData))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: Float(fps), maximum: Float(fps), preferred: Float(fps))
        displayLink?.add(to: .main, forMode: .common)
    }
    
    func stopRecording() {
        displayLink?.invalidate()
        displayLink = nil
        do {
            try BTFileHandle?.close()
        } catch {
            // Error closing pose file
        }
    }
    
    @objc private func recordSingleData(link: CADisplayLink){
        if(ifConnected == true){
            guard let characteristic = rxCharacteristic else { return
            }
            characteristicPeripheralUpdate(characteristic: characteristic)
        }
    }
    
    private func characteristicPeripheralUpdate(characteristic: CBCharacteristic){
        let currentTimer = Date()
        var dataReadTimeStamp = Int64(currentTimer.timeIntervalSince1970 * 1000)
        let timeStampData = Data(bytes: &dataReadTimeStamp, count: MemoryLayout<Int64>.size)
        
        let crlfData = Data([0x0D, 0x0A])
        
        guard let characteristicValue = characteristic.value else {return}
        let writeData = timeStampData + characteristicValue + crlfData
        self.BTFileHandle!.write(writeData)
    }
}

