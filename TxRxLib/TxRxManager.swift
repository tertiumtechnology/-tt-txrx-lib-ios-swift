/*
 * The MIT License
 *
 * Copyright 2017 Tertium Technology.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */
import UIKit
import CoreBluetooth
import Foundation

/// TxRxManager library TxRxManager class
///
/// TxRxManager class is TxRxManager library main class
///
/// TxRxManager eases programmer life by dealing with CoreBluetooth internals
///
/// NOTE: Implements CBCentralManagerDelegate and CBPeripheralDelegate protocols
///
/// Methods are ordered chronologically
public class TxRxManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    let TERTIUM_COMMAND_END_CRLF = "\r\n"
    let TERTIUM_COMMAND_END_CR = "\r"
    let TERITUM_COMMAND_END_LF = "\n"
    
    ///
    /// Queue to which TxRxManager internals dispatch asyncronous calls. Change if you want the class to work in a thread with its GCD queue
    ///
    /// DEFAULT: main thread queue
    private var _dispatchQueue: DispatchQueue
    
    /// Dispatch queue to which delegate callbacks will be issued.
    ///
    /// DEFAULT: main thread queue
    private var _callbackQueue: DispatchQueue
    
    /// Delegate for scanning devices. Delegate methods will be called on device events (refer to TxRxDeviceScanProtocol.swift)
    public var _delegate: TxRxDeviceScanProtocol?
    
    /// Property telling if the class is currently in scanning devices phase
    public internal(set) var _isScanning = false
    
    /// The MAXIMUM time the class and BLE hardware have to connect to a BLE device
    ///
    /// Check setTimeOutDefaults method to see the default value
    private var _connectTimeout: Double = 0
    
    /// The MAXIMUM time a Tertium BLE device has to send the first response packet to an issued command
    ///
    /// Check setTimeOutDefaults method to see the default value
    private var _receiveFirstPacketTimeout: Double = 0
    
    /// The MAXIMUM time a Tertium BLE device has to send the after having sent the first response packet to an issued command (commands and data are sent in FRAGMENTS)
    ///
    /// Check setTimeOutDefaults method to see the default value
    private var _receivePacketsTimeout: Double = 0
    
    /// The MAXIMUM time a Tertium BLE device has to notify when a write operation on a device is issued by sendData method
    ///
    /// Check setTimeOutDefaults method to see the default value
    private var _writePacketTimeout: Double = 0
    
    /// Tells if CoreBluetooth is ready to operate
    private var _blueToothPoweredOn = false
    
    /// CoreBluetooth manager class reference
    private var _centralManager: CBCentralManager!
    
    /// Array of supported Tertium BLE Devices (please refer to init method for details)
    private var _txRxSupportedDevices = [TxRxDeviceProfile]()
    
    /// Array of scannned devices found by startScan. Used for input parameter validation and internal cleanup
    private var _scannedDevices = [TxRxDevice]()
    
    /// Array of connecting devices. Used for input parameter validation
    private var _connectingDevices = [TxRxDevice]()
    
    /// Array of disconnecting devices. Used for input parameter validation
    private var _disconnectingDevices = [TxRxDevice]()
    
    /// Array of connected devices. Used for input parameter validation
    private var _connectedDevices = [TxRxDevice]()
    
    // TxRxManager singleton
    private static let _sharedInstance = TxRxManager()
    
    /// Gets the singleton instance of the class
    ///
    /// NOTE: CLASS Method
    ///
    /// - returns: The singleton instance of TxRxManager class
    public class func getInstance() -> TxRxManager {
        return _sharedInstance;
    }
    
    override init() {
        _callbackQueue = DispatchQueue.main
        _dispatchQueue = _callbackQueue
        super.init()
        
        //
        setTimeOutDefaults()
        
        // Array of supported devices. Add new devices here !
        
        // TERTIUM RFID READER
        _txRxSupportedDevices.append(TxRxDeviceProfile(inServiceUUID: "175f8f23-a570-49bd-9627-815a6a27de2a",
                                                   withRxUUID: "1cce1ea8-bd34-4813-a00a-c76e028fadcb",
                                                   withTxUUID: "cacc07ff-ffff-4c48-8fae-a9ef71b75e26",
                                                   withCommandEnd: TERTIUM_COMMAND_END_CRLF,
                                                   withMaxPacketSize: 20))
        
        // TERTIUM SENSOR READER
        _txRxSupportedDevices.append(TxRxDeviceProfile(inServiceUUID: "3CC33CDC-CB91-4947-BD12-80D2F0535A30",
                                                   withRxUUID: "3664D14A-08CB-4465-A98A-EBF84F29E943",
                                                   withTxUUID: "F3774638-1164-49BC-8F22-0AC34292C217",
                                                   withCommandEnd: TERTIUM_COMMAND_END_CRLF,
                                                   withMaxPacketSize: 128))
        
        // Initialize Ble API
        _centralManager = CBCentralManager(delegate: self, queue: _dispatchQueue)
    }
    
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
            case .unknown, .resetting, .unsupported, .unauthorized, .poweredOff:
                masterCleanUp()
                _blueToothPoweredOn = false
            
            case .poweredOn:
                _blueToothPoweredOn = true
        }
    }
    
    /// Begins scanning of BLE devices
    ///
    /// NOTE: You cannot connect, send data nor receive data from devices when in scan mode
    public func startScan() {
        // Verify BlueTooth is powered on
        guard _blueToothPoweredOn == true else {
            sendBlueToothNotReadyOrLost()
            return
        }
        
        // Verify we aren't scanning already
        guard _isScanning == false else {
            sendScanError(errorCode: TxRxManagerErrors.ErrorCodes.ERROR_DEVICE_SCAN_ALREADY_STARTED, errorText: TxRxManagerErrors.S_ERROR_DEVICE_SCAN_ALREADY_STARTED)
            return
        }
        
        //
        _scannedDevices.removeAll()
        _isScanning = true
        
        // Initiate peripheral scan
        _centralManager.scanForPeripherals(withServices: nil, options: nil)
        
        // Inform delegate we began scanning
        if let delegate = _delegate {
            _callbackQueue.async{
                delegate.deviceScanBegan()
            }
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        
        //
        for device in _scannedDevices {
            if device.cbPeripheral.identifier == peripheral.identifier {
                //print("Duplicated peripheral identifier found. Filtered out")
                return
            }
        }
        
        // Instances a new TxRxDevice class keeping CoreBluetooth CBPeripheral class instance reference
        let newDevice: TxRxDevice = TxRxDevice(CBPeripheral: peripheral)
        
        // If peripheral name is supplied set it in the new device
        if let name = peripheral.name, name.isEmpty == false {
            newDevice.name = name
        }
        
        newDevice.indexedName = String(format: "%@_%lu", newDevice.name, _scannedDevices.count)
        
        //
        //print("Scanned device: ", peripheral)
        
        // Add the device to the array of scanned devices
        _scannedDevices.append(newDevice)
        
        // Dispatch call to delegate, we have found a BLE device
        if let delegate = _delegate {
            _callbackQueue.async{
                delegate.deviceFound(device: newDevice)
            }
        }
    }
    
    /// stopScan - Ends the scan of BLE devices
    ///
    /// NOTE: After scan ends you can connect to found devices
    public func stopScan() {
        // Verify BlueTooth is powered on
        guard _blueToothPoweredOn == true else {
            sendBlueToothNotReadyOrLost()
            return
        }
        
        // If we aren't scanning, report an error to the delegate
        guard _isScanning == true else {
            sendScanError(errorCode: TxRxManagerErrors.ErrorCodes.ERROR_DEVICE_SCAN_NOT_STARTED, errorText: TxRxManagerErrors.S_ERROR_DEVICE_SCAN_NOT_STARTED)
            return
        }
        
        // Stop bluetooth hardware from scanning devices
        _centralManager.stopScan()
        _isScanning = false
        
        // Inform delegate device scan ended. Its NOW possible to connect to devices
        if let delegate = _delegate {
            _callbackQueue.async{
                delegate.deviceScanEnded()
            }
        }
    }
    
    /// Tries to connect to a previously found (by startScan) BLE device
    ///
    /// NOTE: Connect is an asyncronous operation, delegate will be informed when and if connected
    ///
    /// NOTE: TxRxManager library will connect ONLY to Tertium BLE devices (service UUID and characteristic UUID will be matched)
    ///
    /// - parameter device: the TxRxDevice device to connect to, MUST be non null
    public func connectDevice(device: TxRxDevice) {
        // Verify BlueTooth is powered on
        guard _blueToothPoweredOn == true else {
            sendBlueToothNotReadyOrLost()
            return
        }

        // Verify we aren't scanning. Connect IS NOT supported while scanning for devices
        guard _isScanning == false else {
            sendUnabletoPerformDuringScan(device: device)
            return
        }
        
        // Verify we aren't already connecting to specified device
        guard _connectingDevices.contains(where: { $0 === device }) == false else {
            sendDeviceConnectError(device: device, errorCode: TxRxManagerErrors.ErrorCodes.ERROR_DEVICE_ALREADY_CONNECTING, errorText: TxRxManagerErrors.S_ERROR_DEVICE_ALREADY_CONNECTING)
            return
        }
        
        // Verify we aren't already connected to specified device
        guard _connectedDevices.contains(where: { $0 === device }) == false else {
            sendDeviceConnectError(device: device, errorCode: TxRxManagerErrors.ErrorCodes.ERROR_DEVICE_ALREADY_CONNECTED, errorText: TxRxManagerErrors.S_ERROR_DEVICE_ALREADY_CONNECTED)
            return
        }
        
        // Create connect watchdog timer
        device.scheduleWatchdogTimer(inPhase: TxRxManagerPhase.PHASE_CONNECTING, withTimeInterval: _connectTimeout, withTargetFunc: self.watchDogTimerForConnectTick)
        
        // Device is added to the list of connecting devices
        _connectingDevices.append(device)
        
        // Reset device states
        device.resetStates()
        
        // Inform CoreBluetooth we want to connect the specified peripheral. Answer will come via a callback
        _centralManager.connect(device.cbPeripheral, options: nil)
    }
    
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        var device: TxRxDevice?
        
        // Search for the TxRxDevice class instance by the CoreBlueTooth peripheral instance
        device = deviceFromConnectingPeripheral(peripheral)
        guard device != nil else {
            return
        }
        
        if let error = error {
            // An error happened discovering services, report to delegate. For us, it's still CONNECT phase
            if let delegate = device?.delegate {
                let nsError = NSError(domain: TxRxManagerErrors.S_TERTIUM_TXRX_ERROR_DOMAIN, code: TxRxManagerErrors.ErrorCodes.ERROR_IOS_ERROR.rawValue, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription])
                
                _callbackQueue.async{
                    delegate.deviceConnectError(device: device!, error: nsError)
                }
            }
            
            removeDeviceFromCollection(collection: &_connectingDevices, device: device!)
            return
        }
    }
    
    /// Handles the timeout when connecting to a device
    ///
    /// - parameter timer: the timer instance which ticked
    /// - parameter device: the device to which connect failed
    private func watchDogTimerForConnectTick(timer: TxRxWatchDogTimer, device: TxRxDevice) {
        _centralManager.cancelPeripheralConnection(device.cbPeripheral)
        
        removeDeviceFromCollection(collection: &_connectingDevices, device: device)
        removeDeviceFromCollection(collection: &_connectedDevices, device: device)
        
        device.resetStates()
        
        sendDeviceConnectError(device: device, errorCode: TxRxManagerErrors.ErrorCodes.ERROR_DEVICE_CONNECT_TIMED_OUT, errorText:  TxRxManagerErrors.S_ERROR_DEVICE_CONNECT_TIMED_OUT)
    }
    
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        var device: TxRxDevice?
        
        // Search for the TxRxDevice class instance by the CoreBlueTooth peripheral instance
        device = deviceFromConnectingPeripheral(peripheral)
        guard device != nil else {
            // We are connected to a unknown peripheral or a peripheral which connected past timeout time, disconnect from it
            _centralManager.cancelPeripheralConnection(peripheral)
            return
        }
        
        // Assign delegate of CoreBluetooth peripheral to our class
        peripheral.delegate = self
        device!.isConnected = true
        
        // Stop timeout watchdog timer
        device!.invalidateWatchDogTimer()
        
        // Device is connected, add it to the connected devices list and remove it from connecting devices list
        _connectedDevices.append(device!)
        removeDeviceFromCollection(collection: &_connectingDevices, device: device!)
        
        // Call delegate
        if let delegate = device?.delegate {
            _callbackQueue.async {
                delegate.deviceConnected(device: device!)
            }
        }
        
        // Ask CoreBluetooth to discover services for this peripheral
        peripheral.discoverServices(nil)
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        var device: TxRxDevice?
        var tertiumService: CBService?
        
        // Search for the TxRxDevice class instance by the CoreBlueTooth peripheral instance
        device = deviceFromConnectedPeripheral(peripheral)
        guard device != nil else {
            sendInternalError(errorCode: TxRxManagerErrors.ErrorCodes.ERROR_DEVICE_NOT_FOUND, errorText: TxRxManagerErrors.S_ERROR_DEVICE_NOT_FOUND)
            return
        }
        
        if let error = error {
            // An error happened discovering services, report to delegate. For us, it's still CONNECT phase
            if let delegate = device?.delegate {
                let nsError = NSError(domain: TxRxManagerErrors.S_TERTIUM_TXRX_ERROR_DOMAIN, code: TxRxManagerErrors.ErrorCodes.ERROR_IOS_ERROR.rawValue, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription])
                
                _callbackQueue.async{
                    delegate.deviceConnectError(device: device!, error: nsError)
                }
            }
            
            return
        }
        
        if let services = peripheral.services {
            // Search for device service UUIDs. We use service UUID to map device to a Tertium BLE device profile. See class TxRxDeviceProfile for details
            for service: CBService in services {
                if device?.deviceProfile == nil {
                    for deviceProfile: TxRxDeviceProfile in _txRxSupportedDevices {
                        if service.uuid.isEqual(CBUUID(string: deviceProfile.serviceUUID)) {
                            device?.deviceProfile = deviceProfile
                            tertiumService = service
                            break
                        }
                    }
                }
                
                if tertiumService != nil {
                    break
                }
            }
            
            if let tertiumService = tertiumService {
                // Instruct CoreBlueTooth to discover Tertium device service's characteristics
                //print("Discovering characteristic of service \(tertiumService.uuid.uuidString) of device \(String(describing: device?.name))")
                peripheral.discoverCharacteristics(nil, for: tertiumService)
            }
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        var device: TxRxDevice?
        //var maxWriteLen: Int
        
        // Look for Tertium BLE device transmit and receive characteristics
        device = deviceFromConnectedPeripheral(peripheral)
        if let device = device, let characteristics = service.characteristics {
            for characteristic: CBCharacteristic in characteristics {
                if let deviceProfile = device.deviceProfile {
                    if characteristic.uuid.isEqual(CBUUID(string: deviceProfile.txUUID)) {
                        peripheral.setNotifyValue(true, for: characteristic)
                        device.txChar = characteristic
                        /*
                            if #available(iOS 9.0, *) {
                                //print("Peripheral maximumWriteValueLength = \(peripheral.maximumWriteValueLength)")

                                maxWriteLen = peripheral.maximumWriteValueLength(for: CBCharacteristicWriteType.withResponse)
                                //print("maximumWriteValueLength for txChar is \(maxWriteLen)")
                                //device.deviceProfile?.maxSendPacketSize = maxWriteLen
                            }
                        */
                    } else if characteristic.uuid.isEqual(CBUUID(string: deviceProfile.rxUUID)) {
                        device.rxChar = characteristic
                    }
                }
                
                //print(String(format: "Discovered characteristic \(characteristic.uuid.uuidString) of service \(service.uuid.uuidString) of device \(String(describing: device.name)) option mask %08lx", characteristic.properties.rawValue))
            }
            
            if device.txChar != nil, device.rxChar != nil, let delegate = device.delegate {
                _callbackQueue.async {
                    delegate.deviceReady(device: device)
                }
            }
        }
    }
    
    /// Begins sending the Data byte buffer to a connected device.
    ///
    /// NOTE: you may ONLY send data to already connected devices
    ///
    /// NOTE: Data to device is sent in MTU fragments (refer to TxRxDeviceProfile maxSendPacketSize class attribute)
    ///
    /// - parameter device: the device to send the data (must be connected first!)
    /// - parameter data: Data class with contents of data to send
    public func sendData(device: TxRxDevice, data: Data) {
        // Verify BlueTooth is powered on
        guard _blueToothPoweredOn == true else {
            sendBlueToothNotReadyOrLost()
            return
        }
        
        // Verify we arent't scanning for devices, we cannot interact with a device while in scanning mode
        guard _isScanning == false else {
            sendUnabletoPerformDuringScan(device: device)
            return
        }
        
        // Verify supplied devices is connected, we may only send data to connected devices
        guard _connectedDevices.contains(where: { $0 === device}) else {
            sendNotConnectedError(device: device)
            return
        }
        
        // Verify we have discovered required characteristics
        guard device.txChar != nil, device.rxChar != nil else {
            sendDeviceConnectError(device: device, errorCode: TxRxManagerErrors.ErrorCodes.ERROR_DEVICE_SERVICE_OR_CHARACTERISTICS_NOT_DISCOVERED_YET, errorText: TxRxManagerErrors.S_ERROR_DEVICE_SERVICE_OR_CHARACTERISTICS_NOT_DISCOVERED_YET)
            return
        }
        
        // Verify if we aren't already sending data to the device
        guard device.sendingData == false else {
            sendDeviceWriteError(device: device, errorCode: TxRxManagerErrors.ErrorCodes.ERROR_DEVICE_SENDING_DATA_ALREADY, errorText: TxRxManagerErrors.S_ERROR_DEVICE_SENDING_DATA_ALREADY)

            // REMOVE
            //print("Unable to issue sendData, sending data already")
            return
        }
        
        guard device.waitingAnswer == false else {
            sendDeviceWriteError(device: device, errorCode: TxRxManagerErrors.ErrorCodes.ERROR_DEVICE_WAITING_COMMAND_ANSWER, errorText: TxRxManagerErrors.S_ERROR_DEVICE_WAITING_COMMAND_ANSWER)

            // REMOVE
            //print("Unable to issue sendData, waiting for answer")
            return
        }
        
        if let deviceProfile = device.deviceProfile {
            var dataToSend = Data()
            dataToSend.append(data)
            if let commandEnd = deviceProfile.commandEnd.data(using: String.Encoding.ascii) {
                // We need to append commandEnd to the data so BLE device will understand when the command ends
                dataToSend.append(commandEnd)
                device.setDataToSend(data: dataToSend)
                device.sendingData = true
                
                // REMOVE
                //print("Issuing senddata")

                // Commence data sending to device
                deviceSendDataPiece(device)
            }
        }
    }
    
    /// Sends a fragment of data to the device
    ///
    /// NOTE: This method is also called in response to CoreBlueTooth send data fragment acknowledgement to send data pieces to the device
    ///
    /// - parameter device: The device to send data to
    private func deviceSendDataPiece(_ device: TxRxDevice) {
        var packet: Data?
        var packetSize: Int
        
        guard _connectedDevices.contains(where: { $0 === device}) else {
            sendDeviceWriteError(device: device, errorCode: TxRxManagerErrors.ErrorCodes.ERROR_DEVICE_NOT_CONNECTED, errorText: TxRxManagerErrors.S_ERROR_DEVICE_NOT_CONNECTED)
            return;
        }
        
        guard device.sendingData == true else {
            sendInternalError(device: device, errorCode: TxRxManagerErrors.ErrorCodes.ERROR_DEVICE_NOT_SENDING_DATA, errorText: TxRxManagerErrors.S_ERROR_DEVICE_NOT_SENDING_DATA)

            // REMOVE
            //print("Unable to issue sendData, sending data already")
            return;
        }
        
        if device.totalBytesSent < device.bytesToSend {
            // We still have to send buffer pieces
            if let deviceProfile = device.deviceProfile {
                if let dataToSend = device.dataToSend {
                    // Determine max send packet size
                    if (deviceProfile.maxSendPacketSize + device.totalBytesSent < device.bytesToSend) {
                        packetSize = deviceProfile.maxSendPacketSize
                    } else {
                        packetSize = device.bytesToSend - device.totalBytesSent;
                    }
                    
                    //
                    //print("deviceSendDataPiece, totalBytesSent = \(device.totalBytesSent), bytesToSend = \(device.bytesToSend), calculated packetSize = \(packetSize)")
                    
                    // Create a data packet from the buffer supplied by the caller
                    packet = dataToSend.subdata(in: device.totalBytesSent ..< device.totalBytesSent+packetSize)
                    if let packet = packet, let rxChar = device.rxChar {
                        // Send data to device with bluetooth response feedback
                        device.cbPeripheral.writeValue(packet, for: rxChar, type: .withResponse)
                        device.bytesSent = packetSize
                        
                        // Enable recieve watchdog timer for send acknowledgement
                        var timeOut: Double
                        
                        if (device.totalBytesSent == 0) {
                            timeOut = _receiveFirstPacketTimeout
                        } else {
                            timeOut = _receivePacketsTimeout
                        }
                        
                        // REMOVE
                        //print("sending data piece")

                        device.scheduleWatchdogTimer(inPhase: TxRxManagerPhase.PHASE_WAITING_SEND_ACK, withTimeInterval: timeOut, withTargetFunc: self.watchDogTimerTickReceivingSendAck)
                    }
                }
            }
        } else {
            // REMOVE
            //print("sent all data, waiting answer")

            // All buffer contents have been sent
            device.sendingData = false
            device.dataToSend = nil
            
            // Enable recieve watchdog timer. Waiting for response from Tertium BLE device
            device.scheduleWatchdogTimer(inPhase: TxRxManagerPhase.PHASE_RECEIVING_DATA, withTimeInterval: _receiveFirstPacketTimeout, withTargetFunc: self.watchDogTimerTickReceivingData)
            
            //
            device.waitingAnswer = true
            return
        }
    }
    
    /// Handles receive bluetooth send feedback timeouts
    ///
    /// - parameter timer: the TxRxWatchDogTimer instance which handled the timeout
    /// - parameter device: the device to which connect failed
    private func watchDogTimerTickReceivingSendAck(timer: TxRxWatchDogTimer, device: TxRxDevice) {
        // REMOVE
        //print("SENDACK TIMEOUT")

        device.sendingData = false
        sendDeviceWriteError(device: device, errorCode: TxRxManagerErrors.ErrorCodes.ERROR_DEVICE_SENDING_DATA_TIMEOUT, errorText: TxRxManagerErrors.S_ERROR_DEVICE_SENDING_DATA_TIMEOUT)
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        var device: TxRxDevice?
        
        device = deviceFromConnectedPeripheral(peripheral)
        if let device = device {
            if let error = error {
                // There has been a write error
                device.sendingData = false
                let nsError = NSError(domain: TxRxManagerErrors.S_TERTIUM_TXRX_ERROR_DOMAIN, code: TxRxManagerErrors.ErrorCodes.ERROR_IOS_ERROR.rawValue, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription])
                if let delegate = device.delegate {
                    _callbackQueue.async {
                        delegate.deviceWriteError(device: device, error: nsError)
                    }
                }
                
                // REMOVE
                //print("SENDACK ERROR: " + error.localizedDescription)
                
                // There has been an error, invalidate WatchDog timer
                device.invalidateWatchDogTimer()
                return
            }
            
            // Send data acknowledgement arrived in time, stop the watchdog timer
            device.invalidateWatchDogTimer()
            
            // Update device's total bytes sent and try to send more data
            device.totalBytesSent += device.bytesSent
            _dispatchQueue.async {
                self.deviceSendDataPiece(device)
            }
        }
    }
    
    /// Watchdog for timeouts on BLE device answer to previously issued command
    ///
    /// - parameter timer: the timer instance which handled the timeout
    /// - parameter device: the device on which the read operation timed out
    private func watchDogTimerTickReceivingData(_ timer: TxRxWatchDogTimer, device: TxRxDevice) {
        // Verify what we have received
        var text: String
        
        //print("watchDogTimerTickReceivingData\n")
        
        // Verify terminator is ok, otherwise we may haven't received a whole response and there has been a receive error or receive timed out
        text = String(data: device.receivedData, encoding: String.Encoding.ascii) ?? ""
        if isTerminatorOK(device: device, text: text) {
            // REMOVE
            //print("COMMAND ANSWER RECEIVED, TERMINATOR OK")
            
            //
            device.waitingAnswer = false
            
            if let delegate = device.delegate {
                let dispatchData = Data(device.receivedData)
                device.resetReceivedData()
                _callbackQueue.async {
                    delegate.receivedData(device: device, data: dispatchData)
                }
            } else {
                device.resetReceivedData()
            }
        } else {
            // REMOVE
            //print("COMMAND ANSWER RECEIVED BUT TERMINATOR NOT OK. DATALEN: ", device.receivedData.count," DATA: ", String(data: device.receivedData, encoding: .ascii)!)
            
            //
            device.waitingAnswer = false
            
            device.resetReceivedData()
            sendDeviceReadError(device: device, errorCode: TxRxManagerErrors.ErrorCodes.ERROR_DEVICE_RECEIVING_DATA_TIMEOUT, errorText: TxRxManagerErrors.S_ERROR_DEVICE_RECEIVING_DATA_TIMEOUT)
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
		var device: TxRxDevice?
        
		device = deviceFromConnectedPeripheral(peripheral)
        if let device = device {
            //
            device.waitingAnswer = false
            
            // REMOVE
            //print("didUpdateValueFor, receiving data")

            if let error = error {
                // REMOVE
                //print("didUpdateValueFor error: ", error.localizedDescription)
                
                // There has been an error receiving data
                if let delegate = device.delegate {
                    let nsError = NSError(domain: TxRxManagerErrors.S_TERTIUM_TXRX_ERROR_DOMAIN, code: TxRxManagerErrors.ErrorCodes.ERROR_IOS_ERROR.rawValue, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription])
                    _callbackQueue.async {
                        delegate.deviceReadError(device: device, error: nsError)
                    }
                }
                
                // Device read error, stop WatchDogTimer
                device.invalidateWatchDogTimer()
                return
            }
            
            if characteristic == device.txChar {
                // We received data from peripheral
                if let value = characteristic.value {
                    let data: Data = Data(value)
                    
                    //
                    //print("didUpdateValueForCharacteristic, data received: ", String(data: data, encoding: .ascii)!)
                    
                    //
                    device.receivedData.append(data)
                    
                    //
                    //print("didUpdateValueForCharacteristic, data so far: ", String(data: device.receivedData, encoding: .ascii)!)
                    
                    if device.watchDogTimer == nil {
                        // Passive receive
                        if let delegate = device.delegate {
                            _callbackQueue.async {
                                delegate.receivedData(device: device, data: data)
                            }
                        }
                    } else {
                        // Schedule a new watchdog timer for receiving data packets
                        device.scheduleWatchdogTimer(inPhase: TxRxManagerPhase.PHASE_RECEIVING_DATA, withTimeInterval: _receivePacketsTimeout, withTargetFunc: self.watchDogTimerTickReceivingData)
                    }
                }
            }
        }
	}
    
    /// Disconnect a previously connected device
    ///
    /// - parameter device: The device to disconnect, MUST be non null
    public func disconnectDevice(device: TxRxDevice) {
        // Verify BlueTooth is powered on
        guard _blueToothPoweredOn == true else {
            sendBlueToothNotReadyOrLost()
            return
        }
        
        // We can't disconnect while scanning for devices
        guard _isScanning == false else {
            sendUnabletoPerformDuringScan(device: device)
            return
        }
        
        // Verify device is truly connected
        guard _connectedDevices.contains(where: { $0 === device}) == true else {
            sendNotConnectedError(device: device)
            return
        }
        
        // Verify we aren't disconnecting already from the device (we may be waiting for disconnect ack)
        guard _disconnectingDevices.contains(where: { $0 === device}) == false else {
            sendDeviceConnectError(device: device, errorCode: TxRxManagerErrors.ErrorCodes.ERROR_DEVICE_ALREADY_DISCONNECTING, errorText: TxRxManagerErrors.S_ERROR_ALREADY_DISCONNECTING)
            return
        }
        
        // Create a disconnect watchdog timer
        device.scheduleWatchdogTimer(inPhase: TxRxManagerPhase.PHASE_DISCONNECTING, withTimeInterval: _connectTimeout, withTargetFunc:  self.watchDogTimerForDisconnectTick)
        
        // Add the device to the list of disconnecting devices
        _disconnectingDevices.append(device);
        
        // Ask CoreBlueTooth to disconnect the device
        _centralManager.cancelPeripheralConnection(device.cbPeripheral)
    }
    
    /// Verifies disconnecting a device happens is in a timely fashion
    ///
    /// - parameter timer: the timer instance which fires the check function
    /// - parameter device: the device which didn't disconnect in time
    private func watchDogTimerForDisconnectTick(_ timer: TxRxWatchDogTimer, device: TxRxDevice) {
        // Disconnecting device timed out, we received no feedback. We consider the device disconnected anyway.
        removeDeviceFromCollection(collection: &_disconnectingDevices, device: device)
        removeDeviceFromCollection(collection: &_connectedDevices, device: device)
        removeDeviceFromCollection(collection: &_connectingDevices, device: device)
        
        //
        device.resetStates()
        
        // Inform delegate device disconnet timed out
        sendDeviceConnectError(device: device, errorCode: TxRxManagerErrors.ErrorCodes.ERROR_DEVICE_DISCONNECT_TIMED_OUT, errorText: TxRxManagerErrors.S_ERROR_DEVICE_DISCONNECT_TIMED_OUT)
    }
    
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        var device: TxRxDevice?
        
        device = deviceFromKnownPeripheral(peripheral)
        if let device = device {
            if let error = error {
                // There has been an error disconnecting the device
                if let delegate = device.delegate {
                    let nsError = NSError(domain: TxRxManagerErrors.S_TERTIUM_TXRX_ERROR_DOMAIN, code: TxRxManagerErrors.ErrorCodes.ERROR_IOS_ERROR.rawValue, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription])
                    _callbackQueue.async {
                        delegate.deviceConnectError(device: device, error: nsError)
                    }
                }
                
                // Consider the device disconnected anyway
            }
            
            // A peripheral has been disconnected. Remove device from internal validation arrays and inform delegate of the disconnection
            device.invalidateWatchDogTimer()
            device.resetStates()

            removeDeviceFromCollection(collection: &_connectedDevices, device: device)
            removeDeviceFromCollection(collection: &_connectingDevices, device: device)
            removeDeviceFromCollection(collection: &_disconnectingDevices, device: device)
            
            if let delegate = device.delegate {
                _callbackQueue.async {
                    delegate.deviceDisconnected(device: device)
                }
            }
        }
    }
    
    /// Verifies if the data received from BLE devices has the correct terminator (whether a command is finished)
    ///
    /// - parameter device: the device which received data
    /// - parameter text: the data received in ASCII format
    private func isTerminatorOK(device: TxRxDevice, text: String?) -> Bool {
        if (text == nil || text!.count == 0) {
            return false;
        }
        
        return text!.hasSuffix(device.deviceProfile!.commandEnd)
    }
    
    /// Retrieves the TxRxManagerDevice instance from CoreBlueTooth CBPeripheral class from connecting devices
    ///
    /// - parameter peripheral: the CoreBlueTooth peripheral
    private func deviceFromConnectingPeripheral(_ peripheral: CBPeripheral) -> TxRxDevice? {
        for device: (TxRxDevice) in _connectingDevices {
            if (device.cbPeripheral == peripheral) {
                return device;
            }
        }
        
        return nil;
    }
    
    /// Retrieves the TxRxManagerDevice instance from CoreBlueTooth CBPeripheral class from connected devices
    ///
    /// - parameter peripheral: the CoreBlueTooth peripheral
    private func deviceFromConnectedPeripheral(_ peripheral: CBPeripheral) -> TxRxDevice? {
        for device: (TxRxDevice) in _connectedDevices {
            if (device.cbPeripheral == peripheral) {
                return device;
            }
        }
        
        return nil;
    }
    
    /// Retrieves the TxRxManagerDevice instance from CoreBlueTooth CBPeripheral class from disconnecting devices
    ///
    /// - parameter peripheral: the CoreBlueTooth peripheral
    private func deviceFromDisconnectingPeripheral(_ peripheral: CBPeripheral) -> TxRxDevice? {
        for device: (TxRxDevice) in _connectedDevices {
            if (device.cbPeripheral == peripheral) {
                return device;
            }
        }
        
        return nil;
    }
    
    /// Retrieves the TxRxManagerDevice instance from CoreBlueTooth CBPeripheral class from connecting and connected collections
    ///
    /// - parameter peripheral: the CoreBlueTooth peripheral
    private func deviceFromKnownPeripheral(_ peripheral: CBPeripheral) -> TxRxDevice? {
        for device: (TxRxDevice) in _connectedDevices {
            if (device.cbPeripheral == peripheral) {
                return device;
            }
        }
        
        for device: (TxRxDevice) in _connectingDevices {
            if (device.cbPeripheral == peripheral) {
                return device;
            }
        }
        
        for device: (TxRxDevice) in _disconnectingDevices {
            if (device.cbPeripheral == peripheral) {
                return device;
            }
        }
        
        return nil;
    }

    /// Destroys every TxRxDevice instance, usually called when and if CoreBluetooth shuts down
    private func masterCleanUp() {
        for device: (TxRxDevice) in _scannedDevices {
            device.invalidateWatchDogTimer()
            device.resetStates()
        }
        _scannedDevices.removeAll()
        
        for device: (TxRxDevice) in _connectingDevices {
            device.invalidateWatchDogTimer()
            device.resetStates()
        }
        _connectingDevices.removeAll()
        
        for device: (TxRxDevice) in _connectedDevices {
            device.invalidateWatchDogTimer()
            device.resetStates()
        }
        _connectedDevices.removeAll()
        
        for device: (TxRxDevice) in _disconnectingDevices {
            device.invalidateWatchDogTimer()
            device.resetStates()
        }
        _disconnectingDevices.removeAll()
        
        _isScanning = false
        if _blueToothPoweredOn == true {
            sendBlueToothNotReadyOrLost()
        }
    }
    
    /// Safely remove a device from a collection
    private func removeDeviceFromCollection(collection: inout [TxRxDevice], device: TxRxDevice) {
        if let idx = collection.firstIndex(of: device) {
            collection.remove(at: idx)
        }
    }
    
    /// Informs the delegate CoreBluetooth or BlueTooth hardware is not ready or lost
    private func sendBlueToothNotReadyOrLost() {
        sendInternalError(errorCode: TxRxManagerErrors.ErrorCodes.ERROR_BLUETOOTH_NOT_READY_OR_LOST, errorText: TxRxManagerErrors.S_ERROR_BLUETOOTH_NOT_READY_OR_LOST)
    }

    /// Informs the delegate a device scanning error occoured
    ///
    /// - parameter errorCode: the errorcode
    /// - parameter errorText: a human readable error text
    private func sendScanError(errorCode: TxRxManagerErrors.ErrorCodes, errorText: String) {
        if let delegate = _delegate {
            let error = NSError(domain: TxRxManagerErrors.S_TERTIUM_TXRX_ERROR_DOMAIN, code: errorCode.rawValue, userInfo: [NSLocalizedDescriptionKey: errorText])
            _callbackQueue.async {
                delegate.deviceScanError(error: error)
            }
        }
    }

    /// Informs the delegate a device connect error occoured
    ///
    /// - parameter device: the device on which the error occoured
    /// - parameter errorCode: the errorcode
    /// - parameter errorText: a human readable error text
    private func sendDeviceConnectError(device: TxRxDevice, errorCode: TxRxManagerErrors.ErrorCodes, errorText: String) {
        if let delegate = device.delegate {
            let error = NSError(domain: TxRxManagerErrors.S_TERTIUM_TXRX_ERROR_DOMAIN, code: errorCode.rawValue, userInfo: [NSLocalizedDescriptionKey: errorText])
            _callbackQueue.async {
                delegate.deviceConnectError(device: device, error: error);
            }
        }
    }
    
    /// Informs the delegate a device write error occoured
    ///
    /// - parameter device: the device on which the error occoured
    /// - parameter errorCode: the errorcode
    /// - parameter errorText: a human readable error text
    private func sendDeviceWriteError(device: TxRxDevice, errorCode: TxRxManagerErrors.ErrorCodes, errorText: String) {
        if let delegate = device.delegate {
            let error = NSError(domain: TxRxManagerErrors.S_TERTIUM_TXRX_ERROR_DOMAIN, code: errorCode.rawValue, userInfo: [NSLocalizedDescriptionKey: errorText])
            _callbackQueue.async {
                delegate.deviceWriteError(device: device, error: error);
            }
        }
    }
    
    /// Informs the delegate an operation which needed the device to be connected has been called on a not connected device
    ///
    /// - parameter device: the device on which the error occoured
    private func sendNotConnectedError(device: TxRxDevice) {
        if let delegate = device.delegate {
            let error = NSError(domain: TxRxManagerErrors.S_TERTIUM_TXRX_ERROR_DOMAIN, code: TxRxManagerErrors.ErrorCodes.ERROR_DEVICE_NOT_CONNECTED.rawValue, userInfo: [NSLocalizedDescriptionKey: TxRxManagerErrors.S_ERROR_DEVICE_NOT_CONNECTED])
            _callbackQueue.async {
                delegate.deviceConnectError(device: device, error: error);
            }
        }
    }
    
    /// Informs the delegate an operation which is not possibile to be done under device scan has been requested
    ///
    /// - parameter device: the device on which the error occoured
    private func sendUnabletoPerformDuringScan(device: TxRxDevice) {
        if let delegate = device.delegate {
            let error = NSError(domain: TxRxManagerErrors.S_TERTIUM_TXRX_ERROR_DOMAIN, code: TxRxManagerErrors.ErrorCodes.ERROR_DEVICE_UNABLE_TO_PERFORM_DURING_SCAN.rawValue, userInfo: [NSLocalizedDescriptionKey: TxRxManagerErrors.S_ERROR_DEVICE_UNABLE_TO_PERFORM_DURING_SCAN])
            _callbackQueue.async {
                delegate.deviceConnectError(device: device, error: error);
            }
        }
    }
    
    /// Informs the delegate a device read error occoured
    ///
    /// - parameter device: the device on which the error occoured
    /// - parameter errorCode: the errorcode
    /// - parameter errorText: a human readable error text
    private func sendDeviceReadError(device: TxRxDevice, errorCode: TxRxManagerErrors.ErrorCodes, errorText: String) {
        if let delegate = device.delegate {
            let error = NSError(domain: TxRxManagerErrors.S_TERTIUM_TXRX_ERROR_DOMAIN, code: errorCode.rawValue, userInfo: [NSLocalizedDescriptionKey: errorText])
            _callbackQueue.async {
                delegate.deviceReadError(device: device, error: error);
            }
        }
    }
    
    /// Informs the delegate a critical error occoured
    ///
    /// - parameter errorCode: the errorcode
    /// - parameter errorText: a human readable error text
    private func sendInternalError(errorCode: TxRxManagerErrors.ErrorCodes, errorText: String) {
        if let delegate = _delegate {
            let error = NSError(domain: TxRxManagerErrors.S_TERTIUM_TXRX_ERROR_DOMAIN, code: errorCode.rawValue, userInfo: [NSLocalizedDescriptionKey: errorText])
            _callbackQueue.async {
                delegate.deviceScanError(error: error)
            }
        }
    }
    
    /// Informs the device delegate a critical error occoured on a device
    ///
    /// - parameter device: the device on which the error occoured
    /// - parameter errorCode: the errorcode
    /// - parameter errorText: a human readable error text
    private func sendInternalError(device: TxRxDevice, errorCode: TxRxManagerErrors.ErrorCodes, errorText: String) {
        if let delegate = device.delegate {
            let error = NSError(domain: TxRxManagerErrors.S_TERTIUM_TXRX_ERROR_DOMAIN, code: errorCode.rawValue, userInfo: [NSLocalizedDescriptionKey: errorText])
            _callbackQueue.async {
                delegate.deviceError(device:device, error: error)
            }
        }
    }
    
    /// Returns an instance of TxRxDevice from device's name
    ///
    /// - parameter device: the device name
    /// - returns: the device instance, if found, otherwise nil
    public func deviceFromDeviceName(name: String) -> TxRxDevice? {
        for device in _scannedDevices {
            if device.name.caseInsensitiveCompare(name) == ComparisonResult.orderedSame {
                return device
            }
        }
        
        return nil
    }
    
    /// Returns the device name from an instance of TxRxDevice
    ///
    /// - parameter device: the device instance
    /// - returns: the device name
    public func getDeviceName(device: TxRxDevice) -> String {
        return device.name;
    }
    
    // APACHE CORDOVA UTILITY METHODS
    
    /// Returns an instance of TxRxDevice from device's indexed name
    ///
    /// - parameter device: the device indexed name
    /// - returns: the device instance, if found, otherwise nil
    public func deviceFromIndexedName(name: String) -> TxRxDevice? {
        for device in _scannedDevices {
            if device.indexedName.caseInsensitiveCompare(name) == ComparisonResult.orderedSame {
                return device
            }
        }
        
        return nil
    }
    
    /// Returns an instance of TxRxDevice from device's indexed name
    ///
    /// - parameter device: the device to get indexed name from
    /// - returns: the device instance, if found, otherwise nil
    public func getDeviceIndexedName(device: TxRxDevice) -> String {
        return device.indexedName
    }
    
    /// Resets timeout values to default values
    public func setTimeOutDefaults() {
        _connectTimeout = 20.0
        _receiveFirstPacketTimeout = 1.5
        _receivePacketsTimeout = 0.2
        _writePacketTimeout = 0.2
    }
    
    /// Returns the timeout value for the specified timeout event
    ///
    /// - parameter timeOutType: the timeout event
    /// - returns: the event timeout value, in MILLISECONDS
    public func getTimeOutValue(timeOutType: String) -> UInt32 {
        switch (timeOutType) {
            case TxRxManagerTimeouts.S_TERTIUM_TIMEOUT_CONNECT:
                return UInt32(_connectTimeout * 1000.0)
            
            case TxRxManagerTimeouts.S_TERITUM_TIMEOUT_RECEIVE_FIRST_PACKET:
                return UInt32(_receiveFirstPacketTimeout * 1000.0)

            case TxRxManagerTimeouts.S_TERTIUM_TIMEOUT_RECEIVE_PACKETS:
                return UInt32(_receivePacketsTimeout * 1000.0)

            case TxRxManagerTimeouts.S_TERTIUM_TIMEOUT_SEND_PACKET:
                return UInt32(_writePacketTimeout * 1000.0)
            
            default:
                return 0
        }
    }
    
    /// Sets the current timeout value for the specified timeout event
    ///
    /// - parameter timeOutValue: the timeout value, in MILLISECONDS
    /// - parameter timeOutType: the timeout event
    public func setTimeOutValue(timeOutValue: UInt32, timeOutType: String) {
        switch (timeOutType) {
            case TxRxManagerTimeouts.S_TERTIUM_TIMEOUT_CONNECT:
                _connectTimeout = Double(timeOutValue) / 1000.0
            
            case TxRxManagerTimeouts.S_TERITUM_TIMEOUT_RECEIVE_FIRST_PACKET:
                _receiveFirstPacketTimeout = Double(timeOutValue) / 1000.0
            
            case TxRxManagerTimeouts.S_TERTIUM_TIMEOUT_RECEIVE_PACKETS:
                _receivePacketsTimeout = Double(timeOutValue) / 1000.0
            
            case TxRxManagerTimeouts.S_TERTIUM_TIMEOUT_SEND_PACKET:
                _writePacketTimeout = Double(timeOutValue) / 1000.0
            
            default:
                return
        }
    }
}
