import Foundation
import CoreBluetooth
import IOBluetooth

struct NearbyDevice: Equatable {
    let id: UUID
    let name: String
    let rssi: Int
    let match: Bool

    /// Signal in words, closest first (no dBm in the interface).
    var signal: String {
        rssi >= -60 ? "Very close" : rssi >= -75 ? "Nearby" : "Far, move closer"
    }
}

/// Bluetooth LE link to the printer. The public methods are synchronous and must
/// be called off the CoreBluetooth queue (for example from jobQueue).
final class BLEPrinter: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    // ISSC "transparent UART" service that MUNBYN Editor uses for the ITPP130B.
    static let serviceUUID = CBUUID(string: "49535343-FE7D-4AE5-8FA9-9FAFD205E455")
    static let writeUUID = CBUUID(string: "49535343-8841-43F4-A8D4-ECBE34729BB3")
    static let notifyUUID = CBUUID(string: "49535343-1E4D-4BD9-BA61-23C647249616")
    static let standardServices: Set<CBUUID> = [CBUUID(string: "1800"), CBUUID(string: "1801"),
                                                CBUUID(string: "180A"), CBUUID(string: "180F")]

    /// Whether macOS already lets the app use Bluetooth. Reading it never shows the prompt.
    static var isAuthorized: Bool { CBManager.authorization == .allowedAlways }
    static var isDenied: Bool { CBManager.authorization == .denied || CBManager.authorization == .restricted }

    private let queue = DispatchQueue(label: "munbyn-bt.ble")
    private var central: CBCentralManager!
    private let names: [String]

    /// Called on the main queue when Bluetooth is turned on or off, or the permission changes.
    var onStateChange: ((CBManagerState) -> Void)?

    // State read and written only on `queue`.
    private var discovered: CBPeripheral?
    private var discoveredName: String?
    private var seen: [UUID: (name: String, rssi: Int)] = [:]
    private var isConnected = false
    private var connectError: Error?
    private var servicesLeft = -1
    private var characteristics: [CBCharacteristic] = []
    private var acks = 0
    private var writeError: Error?

    private var peripheral: CBPeripheral?
    private var writer: CBCharacteristic?

    init(names: [String]) {
        self.names = names.map { $0.uppercased() }
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    private func onQueue<T>(_ body: () -> T) -> T { queue.sync(execute: body) }

    private func wait(_ seconds: TimeInterval, _ error: Error, until done: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !onQueue(done) {
            if Date() > deadline { throw error }
            usleep(5_000)
        }
    }

    func matches(_ name: String?) -> Bool {
        guard let n = name?.uppercased(), !n.isEmpty else { return false }
        return names.contains { n.hasPrefix($0) || n.contains($0) }
    }

    /// Name of a MUNBYN printer paired in System Settings › Bluetooth, if any.
    /// A classic pairing keeps the printer busy, so MunbynBT can't connect to it.
    func pairedInSettings() -> String? {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return paired.compactMap { $0.name }.first { matches($0) }
    }

    func ensurePoweredOn() throws {
        try wait(10, UserError.bluetoothNotReady) { central.state != .unknown && central.state != .resetting }
        switch onQueue({ central.state }) {
        case .poweredOn: return
        case .unauthorized: throw UserError.bluetoothDenied
        case .poweredOff: throw UserError.bluetoothOff
        case .unsupported: throw UserError.bluetoothUnsupported
        default: throw UserError.bluetoothNotReady
        }
    }

    private func nearbyList() -> [NearbyDevice] {
        seen.map { NearbyDevice(id: $0.key, name: $0.value.name, rssi: $0.value.rssi, match: matches($0.value.name)) }
            .sorted { ($0.match ? 1 : 0, $0.rssi) > ($1.match ? 1 : 0, $1.rssi) }
    }

    /// Scans for up to `seconds`, reporting what it sees about twice a second.
    /// Stops early when `stopWhen` returns true or `isCancelled` does.
    func scan(seconds: TimeInterval, onUpdate: (([NearbyDevice]) -> Void)? = nil,
              stopWhen: (([NearbyDevice]) -> Bool)? = nil, isCancelled: (() -> Bool)? = nil) throws -> [NearbyDevice] {
        try ensurePoweredOn()
        onQueue {
            seen = [:]
            central.scanForPeripherals(withServices: nil, options: nil)
        }
        defer { onQueue { central.stopScan() } }
        let deadline = Date().addingTimeInterval(seconds)
        var list: [NearbyDevice] = []
        while Date() < deadline {
            usleep(500_000)
            list = onQueue { nearbyList() }
            onUpdate?(list)
            if stopWhen?(list) == true || isCancelled?() == true { break }
        }
        return list
    }

    func scanAll(seconds: TimeInterval) throws -> [NearbyDevice] {
        try scan(seconds: seconds)
    }

    /// Connects to the printer: first the one used last time, then searches by name.
    @discardableResult
    func connect(savedID: UUID?, scanSeconds: TimeInterval = 20) throws -> (id: UUID, name: String) {
        try ensurePoweredOn()
        var candidates: [CBPeripheral] = []
        if let id = savedID { candidates += onQueue { central.retrievePeripherals(withIdentifiers: [id]) } }
        candidates += onQueue { central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID]).filter { matches($0.name) } }
        var lastError: Error?
        for p in candidates {
            do {
                try open(p)
                return (p.identifier, p.name ?? "printer")
            } catch {
                lastError = error
            }
        }

        onQueue {
            discovered = nil
            discoveredName = nil
            central.scanForPeripherals(withServices: nil, options: nil)
        }
        do {
            try wait(scanSeconds, UserError.printerNotFound) { discovered != nil }
        } catch {
            onQueue { central.stopScan() }
            if let name = pairedInSettings() { throw UserError.pairedInSettings(name) }
            if let e = lastError as? UserError, e.title != UserError.noResponse.title { throw e }
            throw error
        }
        let found = onQueue { () -> (CBPeripheral, String?) in
            central.stopScan()
            return (discovered!, discoveredName)
        }
        try open(found.0)
        return (found.0.identifier, found.1 ?? found.0.name ?? "printer")
    }

    private func open(_ p: CBPeripheral) throws {
        var lastError: Error = UserError.noResponse
        for attempt in 1...3 {
            onQueue {
                isConnected = false
                connectError = nil
                p.delegate = self
                central.connect(p, options: nil)
            }
            do {
                try wait(6, UserError.noResponse) { isConnected || connectError != nil }
                if let e = onQueue({ connectError }) { throw translate(e) }
                try discover(p)
                peripheral = p
                return
            } catch {
                lastError = error
                onQueue { central.cancelPeripheralConnection(p) }
                if let e = error as? UserError, e.recovery == .openBluetoothSettings { break }
                if attempt < 3 { usleep(400_000) }
            }
        }
        throw lastError
    }

    /// CoreBluetooth errors in plain words; the original stays in the details for the log.
    private func translate(_ error: Error) -> UserError {
        if let e = error as? UserError { return e }
        let ns = error as NSError
        if ns.domain == CBErrorDomain, ns.code == CBError.peerRemovedPairingInformation.rawValue
            || ns.code == CBError.encryptionTimedOut.rawValue {
            return UserError.pairedInSettings(pairedInSettings() ?? "ITPP130B").with(details: ns.localizedDescription)
        }
        return UserError.noResponse.with(details: ns.localizedDescription)
    }

    private func discover(_ p: CBPeripheral) throws {
        onQueue {
            characteristics = []
            servicesLeft = -1
            p.discoverServices(nil)
        }
        try wait(8, UserError.notAPrinter) { servicesLeft == 0 }
        let chars = onQueue { characteristics }
        let canWrite: (CBCharacteristic) -> Bool = {
            $0.properties.contains(.writeWithoutResponse) || $0.properties.contains(.write)
        }
        guard let w = chars.first(where: { $0.uuid == Self.writeUUID })
            ?? chars.first(where: { $0.service?.uuid == Self.serviceUUID && canWrite($0) })
            ?? chars.first(where: { canWrite($0) && !Self.standardServices.contains($0.service?.uuid ?? CBUUID(string: "1800")) })
        else { throw UserError.notAPrinter }
        writer = w
        if let n = chars.first(where: { $0.uuid == Self.notifyUUID })
            ?? chars.first(where: { $0.service == w.service && $0.properties.contains(.notify) }) {
            onQueue { p.setNotifyValue(true, for: n) }
        }
        say("Bluetooth channel: \(w.uuid.uuidString), \(onQueue { p.maximumWriteValueLength(for: .withoutResponse) }) bytes per write")
    }

    /// Sends the data in chunks, following CoreBluetooth's flow control and
    /// MUNBYN Editor's pacing (8 ms every 180 bytes on a Mac).
    func send(_ data: Data, chunk: Int, pacingMs: Double, progress: ((Double) -> Void)? = nil,
              isCancelled: (() -> Bool)? = nil) throws {
        guard let p = peripheral, let w = writer else { throw UserError.noResponse }
        let type: CBCharacteristicWriteType = w.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let size = max(20, min(chunk, onQueue { p.maximumWriteValueLength(for: type) }))
        let pause = useconds_t(pacingMs * 1000 * Double(size) / 180)
        let bytes = [UInt8](data)
        onQueue {
            acks = 0
            writeError = nil
        }
        var offset = 0, sent = 0, lastReport = Date()
        while offset < bytes.count {
            if isCancelled?() == true { throw UserError.cancelled }
            let end = min(offset + size, bytes.count)
            let piece = Data(bytes[offset..<end])
            if type == .withoutResponse {
                try wait(8, UserError.stalled) { p.canSendWriteWithoutResponse || !isConnected }
                guard onQueue({ isConnected }) else { throw UserError.interrupted }
                onQueue { p.writeValue(piece, for: w, type: .withoutResponse) }
            } else {
                sent += 1
                let target = sent
                onQueue { p.writeValue(piece, for: w, type: .withResponse) }
                try wait(8, UserError.stalled) { acks >= target || writeError != nil || !isConnected }
                if let e = onQueue({ writeError }) { throw UserError.interrupted.with(details: e.localizedDescription) }
                guard onQueue({ isConnected }) else { throw UserError.interrupted }
            }
            offset = end
            if pause > 0 { usleep(pause) }
            if let progress, Date().timeIntervalSince(lastReport) > 0.4 {
                progress(Double(offset) / Double(bytes.count))
                lastReport = Date()
            }
        }
        progress?(1)
    }

    func disconnect() {
        guard let p = peripheral else { return }
        usleep(1_500_000)  // give the printer time to drain its buffer
        onQueue { central.cancelPeripheralConnection(p) }
        peripheral = nil
        writer = nil
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .unauthorized { say("Bluetooth permission denied") }
        let state = central.state
        DispatchQueue.main.async { self.onStateChange?(state) }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        if !name.isEmpty { seen[peripheral.identifier] = (name, RSSI.intValue) }
        if discovered == nil && matches(name) {
            discovered = peripheral
            discoveredName = name
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectError = error ?? UserError.noResponse
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        isConnected = false
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        servicesLeft = services.count
        for s in services { peripheral.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        characteristics += service.characteristics ?? []
        servicesLeft -= 1
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { writeError = error }
        acks += 1
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let v = characteristic.value, !v.isEmpty {
            say("From printer: " + v.map { String(format: "%02X", $0) }.joined(separator: " "))
        }
    }
}
