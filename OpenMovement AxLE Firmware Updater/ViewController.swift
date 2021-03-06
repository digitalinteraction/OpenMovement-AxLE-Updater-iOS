//
//  ViewController.swift
//  OpenMovement AxLE Firmware Updater
//
//  Created by Gerard Wilkinson (PGR) on 08/06/2018.
//  Copyright © 2018 Gerard Wilkinson. All rights reserved.
//

import UIKit
import CoreBluetooth
import iOSDFULibrary
import SVProgressHUD

class ViewController: UITableViewController, CBCentralManagerDelegate, CBPeripheralDelegate, LoggerDelegate, DFUServiceDelegate, DFUProgressDelegate {
    let AxLEDeviceName = "axLE-Band"
    let AxLEBootloaderDeviceName = "i5-DFU"
    
    let UartServiceUuid = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    let UartRxCharacUuid = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    let UartTxCharacUuid = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    let DeviceInformationServiceUuid = CBUUID(string: "0000180A-0000-1000-8000-00805f9b34fb")
    let SerialNumberCharacUuid = CBUUID(string: "00002A25-0000-1000-8000-00805f9b34fb")
    let FirmwareCharacUuid = CBUUID(string: "00002A26-0000-1000-8000-00805f9b34fb")
    
    var axleCentralManger:CBCentralManager?
    
    var devices:[Device]
    var dfuQueue:[UUID]
    var dfuIgnore:[UUID]
    
    var dfuInProgress:Bool
    
    let firmware:DFUFirmware
    
    var dfuTimeout:Timer?
    var currentController:DFUServiceController?
    
    required init?(coder aDecoder: NSCoder) {
        devices = []
        dfuQueue = []
        dfuIgnore = []
        
        dfuInProgress = false
        
        firmware = DFUFirmware(urlToZipFile: URL(fileURLWithPath: Bundle.main.path(forResource: "update-2.6", ofType: "zip")!))!
        
        super.init(coder: aDecoder)
        axleCentralManger = CBCentralManager(delegate: self, queue: nil)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        SVProgressHUD.setDefaultMaskType(.black)
        tableView.rowHeight = 44;
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
    
    @IBAction func rescan(_ sender: Any) {
        devices = []
        dfuQueue = []
        dfuIgnore = []
        
        tableView.reloadData()
    }
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            axleCentralManger?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            break
        default:
            break
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if peripheral.name == AxLEDeviceName && !devices.contains(where: { (device) -> Bool in
            return device.peripheral.identifier == peripheral.identifier
        })
        {
            devices.append(Device(peripheral: peripheral))
            central.connect(peripheral, options: nil)
        }
        else if !dfuInProgress && peripheral.name == AxLEBootloaderDeviceName && !dfuIgnore.contains(peripheral.identifier)
        {
            dfuInProgress = true
            dfuTimeout?.invalidate()
            SVProgressHUD.dismiss()
            
            let alert = UIAlertController(title: "DFU Device Found!", message: "A device has been found in DFU mode. On iOS we cannot identify individual devices. Would you like to begin updating it?", preferredStyle: .alert)
            
            alert.addAction(UIAlertAction(title: "Update", style: .destructive, handler: { (a) in
                let initiator = DFUServiceInitiator(centralManager: self.axleCentralManger!, target: peripheral).with(firmware: self.firmware)
                initiator.logger = self
                initiator.delegate = self
                initiator.progressDelegate = self
                self.currentController = initiator.start()
            }))
            
            alert.addAction(UIAlertAction(title: "Ignore", style: .cancel, handler: { (a) in
                self.dfuIgnore.append(peripheral.identifier)
                self.dfuInProgress = false
            }))
            
            present(alert, animated: true)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if peripheral.name == AxLEDeviceName
        {
            peripheral.delegate = self
            peripheral.discoverServices([DeviceInformationServiceUuid, UartServiceUuid])
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if !(error != nil)
        {
            if peripheral.name == AxLEBootloaderDeviceName
            {
                return
            }
            
            let infoService = peripheral.services?.first(where: { (s) -> Bool in return s.uuid == DeviceInformationServiceUuid })
            let uartService = peripheral.services?.first(where: { (s) -> Bool in return s.uuid == UartServiceUuid })
            
            if let si = infoService, let su = uartService
            {
                peripheral.discoverCharacteristics([SerialNumberCharacUuid, FirmwareCharacUuid], for: si)
                peripheral.discoverCharacteristics([UartRxCharacUuid, UartTxCharacUuid], for: su)
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if !(error != nil)
        {
            if peripheral.name == AxLEBootloaderDeviceName
            {
                return
            }
            
            let device = devices.first { (d) -> Bool in
                return d.peripheral.identifier == peripheral.identifier
            }
            
            if service.uuid == UartServiceUuid
            {
                device?.txUart = service.characteristics?.first(where: { (c) -> Bool in return c.uuid == UartTxCharacUuid })
                device?.rxUart = service.characteristics?.first(where: { (c) -> Bool in return c.uuid == UartRxCharacUuid })
            }
            
            if dfuQueue.contains(peripheral.identifier)
            {
                dfuTimeout?.invalidate()
                device?.peripheral.setNotifyValue(true, for: device!.rxUart!)
                device?.peripheral.writeValue("U\(device!.mac!.suffix(6))".data(using: .utf8)!, for: device!.txUart!, type: .withoutResponse)
                SVProgressHUD.show(withStatus: "Authenticating with Device...")
                dfuTimeout?.invalidate()
                dfuTimeout = Timer.scheduledTimer(withTimeInterval: 5, repeats: false, block: { (timer) in
                    self.askForPass(device: device!)
                })
            }
            else if service.uuid == DeviceInformationServiceUuid
            {
                let sn = service.characteristics?.first(where: { (c) -> Bool in return c.uuid == SerialNumberCharacUuid })
                let fw = service.characteristics?.first(where: { (c) -> Bool in return c.uuid == FirmwareCharacUuid })
                peripheral.readValue(for: sn!)
                peripheral.readValue(for: fw!)
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if !(error != nil)
        {
            if peripheral.name == AxLEBootloaderDeviceName
            {
                return
            }
            
            let device = devices.first { (d) -> Bool in
                return d.peripheral.identifier == peripheral.identifier
            }
            
            if characteristic.uuid == UartRxCharacUuid && dfuQueue.contains(peripheral.identifier)
            {
                let response = String(data: characteristic.value!, encoding: .utf8)!
                print("RX -- \(response)")
                if response.range(of: "Authenticated") != nil
                {
                    dfuTimeout?.invalidate()
                    startDfu(device: device!)
                }
            }
            
            if characteristic.uuid == FirmwareCharacUuid
            {
                device?.version = String(bytes: characteristic.value!, encoding: .utf8)!
            }
            
            if characteristic.uuid == SerialNumberCharacUuid
            {
                device?.mac = String(bytes: characteristic.value!, encoding: .utf8)!
            }
            
            if !dfuQueue.contains(peripheral.identifier)
                && ((device?.mac) != nil) && ((device?.version) != nil)
            {
                axleCentralManger?.cancelPeripheralConnection(peripheral)
            }
            
            tableView.reloadData()
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if (characteristic.isNotifying)
        {
            peripheral.readValue(for: characteristic)
        }
    }
    
    func startDfu(device:Device)
    {
        device.peripheral.writeValue("M".data(using: .utf8)!, for: device.txUart!, type: .withoutResponse)
        device.peripheral.writeValue("2".data(using: .utf8)!, for: device.txUart!, type: .withoutResponse)
        device.peripheral.writeValue("M".data(using: .utf8)!, for: device.txUart!, type: .withoutResponse)
        device.peripheral.writeValue("2".data(using: .utf8)!, for: device.txUart!, type: .withoutResponse)
        device.peripheral.writeValue("M".data(using: .utf8)!, for: device.txUart!, type: .withoutResponse)
        device.peripheral.writeValue("2".data(using: .utf8)!, for: device.txUart!, type: .withoutResponse)
        
        let alert = UIAlertController(title: "WARNING", message: "You are about to update an AxLE. The device should have vibrated and flashed.", preferredStyle: .alert)
        
        alert.addAction(UIAlertAction(title: "Update", style: .destructive, handler: { (a) in
            device.peripheral.writeValue("XB".data(using: .utf8)!, for: device.txUart!, type: .withoutResponse)
            
            if let di = self.devices.firstIndex(where: { (d) -> Bool in
                return d.peripheral.identifier == device.peripheral.identifier
            })
            {
                self.devices.remove(at: di)
                self.tableView.reloadData()
            }
            
            SVProgressHUD.show(withStatus: "Placing in DFU mode... \n(this may take up to 45 seconds)")
            self.dfuTimeout?.invalidate()
            self.dfuTimeout = Timer.scheduledTimer(withTimeInterval: 45, repeats: false, block: { (timer) in
                SVProgressHUD.showError(withStatus: "Unable to put device in DFU mode!")
            })
            
            self.dfuQueue.remove(at: self.dfuQueue.firstIndex(of: device.peripheral.identifier)!)
        }))
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { (a) in
            self.axleCentralManger?.cancelPeripheralConnection(device.peripheral)
        }))
        
        SVProgressHUD.dismiss()
        present(alert, animated: true)
    }
    
    func askForPass(device:Device)
    {
        let alert = UIAlertController(title: "Failed to Authenticate!", message: "Please enter the devices password or reset the device.", preferredStyle: .alert)
        
        alert.addAction(UIAlertAction(title: "Ok", style: .default, handler: { (action) in
            let textField = alert.textFields![0] as UITextField
            device.peripheral.writeValue("U\(textField.text!)".data(using: .utf8)!, for: device.txUart!, type: .withoutResponse)
            SVProgressHUD.show(withStatus: "Authenticating with Device...")
            self.dfuTimeout?.invalidate()
            self.dfuTimeout = Timer.scheduledTimer(withTimeInterval: 5, repeats: false, block: { (timer) in
                self.askForPass(device: device)
            })
        }))
        
        alert.addTextField(configurationHandler: { (textField) in
            textField.placeholder = String(device.mac!.suffix(6))
        })
        
        alert.addAction(UIAlertAction(title: "Reset", style: .destructive, handler: { (action) in
            device.peripheral.writeValue("E\(device.mac!.suffix(6))".data(using: .utf8)!, for: device.txUart!, type: .withoutResponse)
            self.startDfu(device: device)
        }))
        
        SVProgressHUD.dismiss()
        self.present(alert, animated: true)
    }
    
    func dfuProgressDidChange(for part: Int, outOf totalParts: Int, to progress: Int, currentSpeedBytesPerSecond: Double, avgSpeedBytesPerSecond: Double) {
        print("DFU PROGRESS -- \(progress)")
        SVProgressHUD.showProgress(Float(progress) / Float(100), status: "Uploading to device...")
        dfuTimeout?.invalidate()
        dfuTimeout = Timer.scheduledTimer(withTimeInterval: 10, repeats: false, block: { (timer) in
            self.currentController?.abort()
            SVProgressHUD.showError(withStatus: "Failed during update process! Ensure device is kept nearby.")
        })
    }
    
    func dfuStateDidChange(to state: DFUState) {
        print("DFU STATE -- \(state.rawValue)")
        switch state {
        case .completed:
            SVProgressHUD.showSuccess(withStatus: "Device successfully updated!")
            dfuInProgress = false
            axleCentralManger?.delegate = self
            axleCentralManger?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        case .connecting:
            SVProgressHUD.show(withStatus: "Connecting to DFU Device...")
            dfuTimeout = Timer.scheduledTimer(withTimeInterval: 10, repeats: false, block: { (timer) in
                SVProgressHUD.showError(withStatus: "Failed to connect to DFU Device...")
                self.dfuInProgress = false
                self.axleCentralManger?.delegate = self
                self.axleCentralManger?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            })
        case .starting:
            break
        case .enablingDfuMode:
            break
        case .uploading:
            dfuTimeout?.invalidate()
            break
        case .validating:
            dfuTimeout?.invalidate()
            SVProgressHUD.show(withStatus: "Validating firmware file...")
        case .disconnecting:
            SVProgressHUD.show(withStatus: "Disconnecting...")
        case .aborted:
            dfuTimeout?.invalidate()
            SVProgressHUD.showError(withStatus: "Failed to update Device...")
            dfuInProgress = false
            axleCentralManger?.delegate = self
            axleCentralManger?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }
    
    func dfuError(_ error: DFUError, didOccurWithMessage message: String) {
        print("DFU ERROR -- \(error) -- \(message)")
    }
    
    func logWith(_ level: LogLevel, message: String) {
        print("DFU LOG -- \(level) -- \(message)")
    }
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return devices.count
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Device")!
        
        (cell.viewWithTag(1) as! UILabel).text = devices[indexPath.row].peripheral.name
        (cell.viewWithTag(2) as! UILabel).text = devices[indexPath.row].mac
        (cell.viewWithTag(3) as! UILabel).text = devices[indexPath.row].version
        
        return cell
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        SVProgressHUD.show(withStatus: "Connecting to Device...")
        tableView.deselectRow(at: indexPath, animated: true)
        let device = devices[indexPath.row]
        
        dfuQueue.append(device.peripheral.identifier)
        
        axleCentralManger?.connect(device.peripheral, options: nil)
        self.dfuTimeout?.invalidate()
        self.dfuTimeout = Timer.scheduledTimer(withTimeInterval: 10, repeats: false, block: { (timer) in
            SVProgressHUD.showError(withStatus: "Unable to connect to device!")
        })
    }
}
