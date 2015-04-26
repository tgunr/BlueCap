//
//  Peripheral.swift
//  BlueCap
//
//  Created by Troy Stribling on 6/8/14.
//  Copyright (c) 2014 gnos.us. All rights reserved.
//

import Foundation
import CoreBluetooth

enum PeripheralConnectionError {
    case None
    case Timeout
}

///////////////////////////////////////////
// PeripheralImpl
public protocol PeripheralWrappable {
    
    typealias WrappedService
    
    var name            : String                {get}
    var state           : CBPeripheralState     {get}
    var services        : [WrappedService]      {get}
    
    func connect()
    func cancel()
    func disconnect()
    func discoverServices(services:[CBUUID]!)
    func didDiscoverServices()
}

public class PeripheralImpl<Wrapper where Wrapper:PeripheralWrappable,
                                          Wrapper.WrappedService:ServiceWrappable> {
    
    private var servicesDiscoveredPromise   = Promise<Wrapper>()
    
    private var readRSSIPromise             = Promise<Int>()
    
    private var connectionSequence          = 0
    private var currentError                = PeripheralConnectionError.None
    private var forcedDisconnect            = false
    
    private let defaultConnectionTimeout    = Double(10.0)
    
    private let _discoveredAt               = NSDate()

    private var _connectedAt                : NSDate?
    private var _disconnectedAt             : NSDate?
    private var _connectorator              : Connectorator?
    
    public var discoveredAt : NSDate {
        return self._discoveredAt
    }
    
    public var connectedAt : NSDate? {
        return self._connectedAt
    }
    
    public var disconnectedAt : NSDate? {
        return self._disconnectedAt
    }
    
    public var connectorator : Connectorator? {
        return self._connectorator
    }
    
    public init() {
    }
    
    // connect  (Called on User queue)
    public func reconnect(peripheral:Wrapper) {
        if peripheral.state == .Disconnected {
            Logger.debug(message:"reconnect peripheral \(peripheral.name)")
            peripheral.connect()
            self.forcedDisconnect = false
            ++self.connectionSequence
            self.timeoutConnection(peripheral, sequence:self.connectionSequence)
        }
    }
    
    public func connect(peripheral:Wrapper, connectorator:Connectorator) {
        CentralQueue.sync {
            self._connectorator = connectorator
        }
        Logger.debug(message:"connect peripheral \(peripheral.name)")
        self.reconnect(peripheral)
    }
    
    public func disconnect(peripheral:Wrapper) {
        self.forcedDisconnect = true
        if peripheral.state == .Connected {
            Logger.debug(message:"disconnect peripheral \(peripheral.name)")
            peripheral.cancel()
        } else {
            self.didDisconnectPeripheral(peripheral)
        }
    }
    
    public func terminate(peripheral:Wrapper) {
        self.disconnect(peripheral)
    }
    
    // service discovery (Called on Central queue)
    public func discoverAllServices(peripheral:Wrapper) -> Future<Wrapper> {
        Logger.debug(message:"peripheral name \(peripheral.name)")
        return self.discoverServices(peripheral, services:nil)
    }
    
    public func discoverServices(peripheral:Wrapper, services:[CBUUID]!) -> Future<Wrapper> {
        Logger.debug(message:" \(peripheral.name)")
        self.servicesDiscoveredPromise = Promise<Wrapper>()
        self.discoverIfConnected(peripheral, services:services)
        return self.servicesDiscoveredPromise.future
    }
    
    public func discoverAllPeripheralServices(peripheral:Wrapper) -> Future<Wrapper> {
        Logger.debug(message:"peripheral name \(peripheral.name)")
        return self.discoverPeripheralServices(peripheral, services:nil)
    }
    
    public func discoverPeripheralServices(peripheral:Wrapper, services:[CBUUID]!) -> Future<Wrapper> {
        let peripheralDiscoveredPromise = Promise<Wrapper>()
        Logger.debug(message:"peripheral name \(peripheral.name)")
        let servicesDiscoveredFuture = self.discoverServices(peripheral, services:services)
        servicesDiscoveredFuture.onSuccess {services in
            if peripheral.services.count > 1 {
                self.discoverService(peripheral,
                                     head:peripheral.services[0],
                                     tail:Array(peripheral.services[1..<peripheral.services.count]),
                                     promise:peripheralDiscoveredPromise)
            } else {
                let discoveryFuture = peripheral.services[0].discoverAllCharacteristics()
                discoveryFuture.onSuccess {_ in
                    peripheralDiscoveredPromise.success(peripheral)
                }
                discoveryFuture.onFailure {error in
                    peripheralDiscoveredPromise.failure(error)
                }
            }
        }
        servicesDiscoveredFuture.onFailure{(error) in
            peripheralDiscoveredPromise.failure(error)
        }
        return peripheralDiscoveredPromise.future
    }
    
    // RSSI
    public func readRSSI() -> Future<Int> {
        self.readRSSIPromise = Promise<Int>()
        return self.readRSSIPromise.future
    }
    
    // CBPeripheralDelegate
    // services
    public func didDiscoverServices(peripheral:Wrapper, error:NSError!) {
        Logger.debug(message:"peripheral name \(peripheral.name)")
        if let error = error {
            self.servicesDiscoveredPromise.failure(error)
        } else {
            peripheral.didDiscoverServices()
            self.servicesDiscoveredPromise.success(peripheral)
        }
    }
    
    public func didReadRSSI(RSSI:NSNumber!, error:NSError!) {
        if let error = error {
            self.readRSSIPromise.failure(error)
        } else {
            if let RSSI = RSSI {
                self.readRSSIPromise.success(RSSI.integerValue)
            } else {
                self.readRSSIPromise.success(RSSI.integerValue)
            }
        }
    }

    // utils
    private func timeoutConnection(peripheral:Wrapper, sequence:Int) {
        var timeout = self.defaultConnectionTimeout
        if let connectorator = self.connectorator {
            timeout = connectorator.connectionTimeout
        }
        Logger.debug(message:"sequence \(sequence), timeout:\(timeout)")
        CentralQueue.delay(timeout) {
            if peripheral.state != .Connected && sequence == self.connectionSequence && !self.forcedDisconnect {
                Logger.debug(message:"timing out sequence=\(sequence), current connectionSequence=\(self.connectionSequence)")
                self.currentError = .Timeout
                peripheral.cancel()
            } else {
                Logger.debug()
            }
        }
    }
    
    private func discoverIfConnected(peripheral:Wrapper, services:[CBUUID]!) {
        if peripheral.state == .Connected {
            peripheral.discoverServices(services)
        } else {
            self.servicesDiscoveredPromise.failure(BCError.peripheralDisconnected)
        }
    }
    
    public func didDisconnectPeripheral(peripheral:Wrapper) {
        Logger.debug()
        self._disconnectedAt = NSDate()
        if let connectorator = self.connectorator {
            if (self.forcedDisconnect) {
                self.forcedDisconnect = false
                Logger.debug(message:"forced disconnect")
                connectorator.didForceDisconnect()
            } else {
                switch(self.currentError) {
                case .None:
                    Logger.debug(message:"no errors disconnecting")
                    connectorator.didDisconnect()
                case .Timeout:
                    Logger.debug(message:"timeout reconnecting")
                    connectorator.didTimeout()
                }
            }
        }
    }
    
    public func didConnectPeripheral(peripheral:Wrapper) {
        Logger.debug()
        self._connectedAt = NSDate()
        self.connectorator?.didConnect()
    }
    
    public func didFailToConnectPeripheral(peripheral:Wrapper, error:NSError?) {
        Logger.debug()
        self.connectorator?.didFailConnect(error)
    }
    
    internal func discoverService(peripheral:Wrapper, head:Wrapper.WrappedService, tail:[Wrapper.WrappedService], promise:Promise<Wrapper>) {
        let discoveryFuture = head.discoverAllCharacteristics()
        Logger.debug(message:"service name \(head.name) count \(tail.count + 1)")
        if tail.count > 0 {
            discoveryFuture.onSuccess {_ in
                self.discoverService(peripheral, head:tail[0], tail:Array(tail[1..<tail.count]), promise:promise)
            }
        } else {
            discoveryFuture.onSuccess {_ in
                promise.success(peripheral)
            }
        }
        discoveryFuture.onFailure {error in
            promise.failure(error)
        }
    }

}
// PeripheralImpl
///////////////////////////////////////////

public class Peripheral : NSObject, CBPeripheralDelegate, PeripheralWrappable {
    
    internal var impl = PeripheralImpl<Peripheral>()
    
    // PeripheralWrappable
    public var name : String {
        if let name = self.cbPeripheral.name {
            return name
        } else {
            return "Unknown"
        }
    }

    public var state : CBPeripheralState {
        return self.cbPeripheral.state
    }
    
    public var connectorator : Connectorator? {
        return self.impl._connectorator
    }

    public var services : [Service] {
        return self.discoveredServices.values.array
    }
    
    public func connect() {
        CentralManager.sharedInstance.connectPeripheral(self)
    }
    
    public func cancel() {
        CentralManager.sharedInstance.cancelPeripheralConnection(self)
    }
    
    public func disconnect() {
        CentralManager.sharedInstance.discoveredPeripherals.removeValueForKey(self.cbPeripheral)
        self.impl.disconnect(self)
    }
    
    public func discoverServices(services:[CBUUID]!) {
        self.cbPeripheral.discoverServices(services)
    }
    
    public func didDiscoverServices() {
        if let cbServices = self.cbPeripheral.services {
            for cbService : AnyObject in cbServices {
                if let cbService = cbService as? CBService {
                    let bcService = Service(cbService:cbService, peripheral:self)
                    self.discoveredServices[bcService.uuid] = bcService
                    Logger.debug(message:"uuid=\(bcService.uuid.UUIDString), name=\(bcService.name)")
                }
            }
        }
    }
    // PeripheralWrappable
    
    private var discoveredServices          = [CBUUID:Service]()
    private var discoveredCharacteristics   = [CBCharacteristic:Characteristic]()
    
    internal let cbPeripheral   : CBPeripheral

    public let advertisements   : [String: String]
    public let rssi             : Int
    
    public var discoveredAt : NSDate {
        return self.impl.discoveredAt
    }
    
    public var connectedAt : NSDate? {
        return self.impl.connectedAt
    }

    public var disconnectedAt : NSDate? {
        return self.impl.disconnectedAt
    }

    public var identifier : NSUUID! {
        return self.cbPeripheral.identifier
    }
    
    
    internal init(cbPeripheral:CBPeripheral, advertisements:[String:String], rssi:Int) {
        self.cbPeripheral = cbPeripheral
        self.advertisements = advertisements
        self.rssi = rssi
        super.init()
        self.cbPeripheral.delegate = self
    }
    
    // rssi
    func readRSSI() -> Future<Int> {
        self.cbPeripheral.readRSSI()
        return self.impl.readRSSI()
    }
    
    // connect
    public func reconnect() {
        self.impl.reconnect(self)
    }
     
    public func connect(connectorator:Connectorator) {
        self.impl.connect(self, connectorator:connectorator)
    }
    
    public func terminate() {
        self.disconnect()
    }

    // service discovery
    public func discoverAllServices() -> Future<Peripheral> {
        return self.impl.discoverAllServices(self)
    }

    public func discoverServices(services:[CBUUID]!) -> Future<Peripheral> {
        return self.impl.discoverServices(self, services:services)
    }

    public func discoverAllPeripheralServices() -> Future<Peripheral> {
        return self.impl.discoverAllPeripheralServices(self)
    }

    public func discoverPeripheralServices(services:[CBUUID]!) -> Future<Peripheral> {
        return self.impl.discoverPeripheralServices(self, services:services)
    }

    // CBPeripheralDelegate
    // peripheral
    public func peripheralDidUpdateName(_:CBPeripheral!) {
        Logger.debug()
    }
    
    public func peripheral(_:CBPeripheral!, didModifyServices invalidatedServices:[AnyObject]!) {
        Logger.debug()
    }
    
    public func peripheral(_:CBPeripheral!, didReadRSSI RSSI:NSNumber!, error:NSError!) {
        Logger.debug()
        self.impl.didReadRSSI(RSSI, error:error)
    }
    
    // services
    public func peripheral(peripheral:CBPeripheral!, didDiscoverServices error:NSError!) {
        Logger.debug(message:"service name \(self.name)")
        self.clearAll()
        self.impl.didDiscoverServices(self, error:error)
    }
    
    public func peripheral(_:CBPeripheral!, didDiscoverIncludedServicesForService service:CBService!, error:NSError!) {
        Logger.debug(message:"service name \(self.name)")
    }
    
    // characteristics
    public func peripheral(_:CBPeripheral!, didDiscoverCharacteristicsForService service:CBService!, error:NSError!) {
        Logger.debug(message:"service name \(self.name)")
        if let service = service, bcService = self.discoveredServices[service.UUID], cbCharacteristics = service.characteristics {
            bcService.didDiscoverCharacteristics(error)
            if error == nil {
                for characteristic : AnyObject in cbCharacteristics {
                    if let cbCharacteristic = characteristic as? CBCharacteristic {
                        self.discoveredCharacteristics[cbCharacteristic] = bcService.discoveredCharacteristics[characteristic.UUID]
                    }
                }
            }
        }
    }
    
    public func peripheral(_:CBPeripheral!, didUpdateNotificationStateForCharacteristic characteristic:CBCharacteristic!, error:NSError!) {
        Logger.debug()
        if let characteristic = characteristic {
            if let bcCharacteristic = self.discoveredCharacteristics[characteristic] {
                Logger.debug(message:"uuid=\(bcCharacteristic.uuid.UUIDString), name=\(bcCharacteristic.name)")
                bcCharacteristic.didUpdateNotificationState(error)
            }
        }
    }

    public func peripheral(_:CBPeripheral!, didUpdateValueForCharacteristic characteristic:CBCharacteristic!, error:NSError!) {
        Logger.debug()
        if let characteristic = characteristic {
            if let bcCharacteristic = self.discoveredCharacteristics[characteristic] {
                Logger.debug(message:"uuid=\(bcCharacteristic.uuid.UUIDString), name=\(bcCharacteristic.name)")
                bcCharacteristic.didUpdate(error)
            }
        }
    }

    public func peripheral(_:CBPeripheral!, didWriteValueForCharacteristic characteristic:CBCharacteristic!, error: NSError!) {
        Logger.debug()
        if let characteristic = characteristic {
            if let bcCharacteristic = self.discoveredCharacteristics[characteristic] {
                Logger.debug(message:"uuid=\(bcCharacteristic.uuid.UUIDString), name=\(bcCharacteristic.name)")
                bcCharacteristic.didWrite(error)
            }
        }
    }
    
    // descriptors
    public func peripheral(_:CBPeripheral!, didDiscoverDescriptorsForCharacteristic characteristic:CBCharacteristic!, error:NSError!) {
        Logger.debug()
    }
    
    public func peripheral(_:CBPeripheral!, didUpdateValueForDescriptor descriptor:CBDescriptor!, error:NSError!) {
        Logger.debug()
    }
    
    public func peripheral(_:CBPeripheral!, didWriteValueForDescriptor descriptor:CBDescriptor!, error:NSError!) {
        Logger.debug()
    }
    
    // utils
    private func clearAll() {
        self.discoveredServices.removeAll()
        self.discoveredCharacteristics.removeAll()
    }
    
    internal func didDisconnectPeripheral() {
        self.impl.didDisconnectPeripheral(self)
    }

    internal func didConnectPeripheral() {
        self.impl.didConnectPeripheral(self)
    }
    
    internal func didFailToConnectPeripheral(error:NSError?) {
        self.impl.didFailToConnectPeripheral(self, error:error)
    }
    
}
