import Foundation
import CoreBluetooth

/// GATT identifiers for the Ricoh GR IV (from third-party reverse engineering on firmware 1.11).
/// Everything is discovered by UUID, never by handle.
enum RicohBLEUUID {
    /// Wireless LAN control service.
    static let wlanService = CBUUID(string: "F37F568F-9071-445D-A938-5441F2E82399")
    /// Network type: write 0x01 (with response) = start the camera's access point, 0x00 = stop.
    static let networkType = CBUUID(string: "9111CDD0-9F01-45C4-A2D4-E09E8FB0424D")
    static let ssid = CBUUID(string: "90638E5A-E77D-409D-B550-78F7E1CA5AB4")
    static let passphrase = CBUUID(string: "0F38279C-FE9E-461B-8596-81287E8C9A81")
    /// Camera power state (0x01 = on). Its service UUID is only known by its prefix.
    static let powerState = CBUUID(string: "B58CE84C-0666-4DE9-BEC8-2D27B27B3211")
    static let powerServicePrefix = "0F291746"
    static let batteryService = CBUUID(string: "180F")
    static let batteryLevel = CBUUID(string: "2A19")
}

/// Pure helpers (unit tested).
enum RicohBLEDecoding {
    /// Decodes a characteristic value as text. Returns nil for empty or non-printable data
    /// (for example when the camera returns the passphrase encrypted).
    static func text(from data: Data) -> String? {
        var bytes = [UInt8](data)
        while let last = bytes.last, last == 0 {
            bytes.removeLast()
        }
        guard !bytes.isEmpty, let string = String(bytes: bytes, encoding: .utf8) else { return nil }
        let printable = string.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && !(0x80...0x9F).contains(scalar.value)
        }
        return printable ? string : nil
    }

    static func hex(_ data: Data, limit: Int = 32) -> String {
        let shown = data.prefix(limit).map { String(format: "%02X", $0) }.joined(separator: " ")
        return data.count > limit ? shown + " ... (\(data.count) bytes)" : shown
    }

    /// True for advertised names that look like a Ricoh GR camera.
    static func looksLikeCamera(name: String?) -> Bool {
        guard let name, !name.isEmpty else { return false }
        let upper = name.uppercased()
        return upper.contains("RICOH") || name.contains("GR")
    }

    /// Power state value: first byte 0x01 = on.
    static func powerIsOn(_ data: Data) -> Bool? {
        guard let first = data.first else { return nil }
        return first == 0x01
    }
}

enum RicohBLEError: LocalizedError {
    case bluetoothOff
    case unauthorized
    case unsupported
    case noCameraFound
    case disconnected
    case serviceNotFound
    case characteristicMissing(String)
    case ssidUnreadable(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .bluetoothOff:
            return "Bluetooth is off. Turn it on in Control Center or Settings."
        case .unauthorized:
            return "Bluetooth access is not allowed for Camera Transfer. Allow it in Settings > Privacy & Security > Bluetooth."
        case .unsupported:
            return "This device does not support Bluetooth LE."
        case .noCameraFound:
            return "No Ricoh camera was found nearby. Make sure the camera is on, Bluetooth pairing is set up, then tap Find camera and pick it from the list."
        case .disconnected:
            return "The camera's Bluetooth connection dropped."
        case .serviceNotFound:
            return "The camera does not offer the expected Wi-Fi control service over Bluetooth (firmware may differ)."
        case .characteristicMissing(let name):
            return "The camera's Bluetooth service is missing the \(name) value."
        case .ssidUnreadable(let detail):
            return "The camera's Wi-Fi name came back in an unreadable (probably encrypted) form: \(detail)"
        case .timeout(let step):
            return "Timed out while \(step) over Bluetooth."
        }
    }

    static func isPairingError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == CBATTErrorDomain {
            return ns.code == CBATTError.Code.insufficientAuthentication.rawValue
                || ns.code == CBATTError.Code.insufficientEncryption.rawValue
                || ns.code == CBATTError.Code.insufficientAuthorization.rawValue
        }
        if ns.domain == CBErrorDomain {
            return ns.code == CBError.Code.peerRemovedPairingInformation.rawValue
                || ns.code == CBError.Code.encryptionTimedOut.rawValue
        }
        return false
    }
}

struct DiscoveredCamera: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
    let looksLikeCamera: Bool
}

private struct Pending<T> {
    let token: Int
    let continuation: CheckedContinuation<T, Error>
}

/// Wakes the Ricoh GR IV's Wi-Fi over Bluetooth LE. All state lives on the main actor;
/// CoreBluetooth calls back on the main queue through `RicohBLEDelegateProxy`.
@MainActor
@Observable
final class RicohBLE {
    static let shared = RicohBLE()
    static let restoreIdentifier = "CameraTransfer.RicohBLE"
    private static let rememberedIDKey = "ricohBLEPeripheralID"
    private static let rememberedNameKey = "ricohBLEPeripheralName"

    enum Stage: Equatable {
        case idle
        case scanning
        case connecting
        case discovering
        case waitingForPairing
        case wakingWiFi
        case ready
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "Idle"
            case .scanning: return "Looking for cameras..."
            case .connecting: return "Connecting over Bluetooth..."
            case .discovering: return "Reading the camera's Bluetooth services..."
            case .waitingForPairing: return "Waiting for pairing - confirm the code on the iPhone and the camera"
            case .wakingWiFi: return "Asking the camera to start Wi-Fi..."
            case .ready: return "Camera Wi-Fi started"
            case .failed(let message): return message
            }
        }
    }

    private(set) var stage: Stage = .idle
    private(set) var discovered: [DiscoveredCamera] = []
    private(set) var rememberedID: UUID?
    private(set) var rememberedName: String?
    private(set) var batteryPercent: Int?
    private(set) var cameraPoweredOn: Bool?
    private(set) var isConnected = false
    private(set) var log: [String] = []

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var proxy: RicohBLEDelegateProxy?
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var peripheralsByID: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var characteristics: [CBUUID: CBCharacteristic] = [:]
    @ObservationIgnored private var wlanCharacteristics: [CBCharacteristic] = []
    @ObservationIgnored private var poweredOnWaiters: [CheckedContinuation<Void, Error>] = []
    @ObservationIgnored private var scanWaiter: Pending<CBPeripheral>?
    @ObservationIgnored private var connectWaiter: Pending<Void>?
    @ObservationIgnored private var servicesWaiter: Pending<Void>?
    @ObservationIgnored private var characteristicsWaiter: Pending<Void>?
    @ObservationIgnored private var servicesLeft = 0
    @ObservationIgnored private var readWaiters: [CBUUID: Pending<Data>] = [:]
    @ObservationIgnored private var writeWaiters: [CBUUID: Pending<Void>] = [:]
    @ObservationIgnored private var powerContinuations: [UUID: AsyncStream<Bool>.Continuation] = [:]
    @ObservationIgnored private var nextToken = 0
    /// After a successful wake we stay connected (and reconnect) to receive power-on notifications.
    @ObservationIgnored private var keepConnected = false

    init() {
        let defaults = UserDefaults.standard
        if let text = defaults.string(forKey: RicohBLE.rememberedIDKey) {
            rememberedID = UUID(uuidString: text)
        }
        rememberedName = defaults.string(forKey: RicohBLE.rememberedNameKey)
    }

    // MARK: Public API

    /// Creates the central manager (this is what triggers the Bluetooth permission prompt).
    func activate() {
        guard central == nil else { return }
        let proxy = RicohBLEDelegateProxy(owner: self)
        self.proxy = proxy
        central = CBCentralManager(delegate: proxy, queue: nil, options: [
            CBCentralManagerOptionRestoreIdentifierKey: RicohBLE.restoreIdentifier,
            CBCentralManagerOptionShowPowerAlertKey: true
        ])
    }

    /// New stream of power-state changes (true = camera switched on).
    var powerStateStream: AsyncStream<Bool> {
        let (stream, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(4))
        let id = UUID()
        powerContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.powerContinuations.removeValue(forKey: id)
            }
        }
        return stream
    }

    func startScan() {
        Task {
            do {
                try await self.waitUntilPoweredOn()
                self.beginScan()
            } catch {
                self.stage = .failed(CameraError.userMessage(for: error, baseURL: nil))
            }
        }
    }

    func stopScan() {
        central?.stopScan()
        if stage == .scanning { stage = .idle }
    }

    func choose(_ camera: DiscoveredCamera) {
        stopScan()
        if let old = peripheral, old.identifier != camera.id {
            central?.cancelPeripheralConnection(old)
            peripheral = nil
        }
        remember(id: camera.id, name: camera.name)
        appendLog("Selected \(camera.name)")
    }

    func forget() {
        keepConnected = false
        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        rememberedID = nil
        rememberedName = nil
        batteryPercent = nil
        cameraPoweredOn = nil
        UserDefaults.standard.removeObject(forKey: RicohBLE.rememberedIDKey)
        UserDefaults.standard.removeObject(forKey: RicohBLE.rememberedNameKey)
        stage = .idle
        appendLog("Forgot the camera. To pair again, also remove it in iOS Settings > Bluetooth if needed.")
    }

    /// Connects (retrying while the first pairing settles), asks the camera to start its access point,
    /// and returns the SSID and, if readable, the passphrase.
    func wakeWiFi() async throws -> (ssid: String, passphrase: String?) {
        do {
            try await waitUntilPoweredOn()
            let target = try await resolvePeripheral()
            peripheral = target
            try await connectWithRetry(target)
            stage = .discovering
            try await discoverEverything(target)
            await readBatteryAndSubscribePower()

            stage = .wakingWiFi
            try await withPairingRetry("starting Wi-Fi") {
                try await self.write(Data([0x01]), to: RicohBLEUUID.networkType)
            }
            appendLog("Wrote 0x01 to Network Type (start access point)")

            let ssidData = try await withPairingRetry("reading the SSID") {
                try await self.read(RicohBLEUUID.ssid)
            }
            var passphraseData: Data?
            do {
                passphraseData = try await withPairingRetry("reading the passphrase") {
                    try await self.read(RicohBLEUUID.passphrase)
                }
            } catch {
                appendLog("Passphrase read failed: \(error.localizedDescription)")
            }
            await logOtherWLANCharacteristics()

            guard let ssid = RicohBLEDecoding.text(from: ssidData) else {
                throw RicohBLEError.ssidUnreadable(RicohBLEDecoding.hex(ssidData))
            }
            var passphrase: String?
            if let passphraseData {
                passphrase = RicohBLEDecoding.text(from: passphraseData)
                if passphrase == nil {
                    appendLog("Passphrase is not plain text (\(passphraseData.count) bytes, probably encrypted): \(RicohBLEDecoding.hex(passphraseData))")
                }
            }
            appendLog("Camera Wi-Fi: SSID \(ssid), passphrase \(passphrase == nil ? "unreadable" : "read")")
            keepConnected = true
            stage = .ready
            return (ssid: ssid, passphrase: passphrase)
        } catch {
            let message = CameraError.userMessage(for: error, baseURL: nil)
            stage = .failed(message)
            appendLog("Wake failed: \(message)")
            throw error
        }
    }

    /// Asks the camera to stop its access point (best effort).
    func stopWiFi() async {
        guard let peripheral, peripheral.state == .connected, characteristics[RicohBLEUUID.networkType] != nil else {
            return
        }
        do {
            try await write(Data([0x00]), to: RicohBLEUUID.networkType)
            appendLog("Wrote 0x00 to Network Type (stop access point)")
        } catch {
            appendLog("Stop Wi-Fi failed: \(error.localizedDescription)")
        }
        if stage == .ready { stage = .idle }
    }

    func clearLog() {
        log = []
    }

    // MARK: Steps

    private func makeToken() -> Int {
        nextToken += 1
        return nextToken
    }

    private func appendLog(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        log.append("\(formatter.string(from: Date())) BLE: \(text)")
        if log.count > 400 {
            log.removeFirst(log.count - 400)
        }
    }

    private func after(_ seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            action()
        }
    }

    private func remember(id: UUID, name: String) {
        rememberedID = id
        rememberedName = name
        UserDefaults.standard.set(id.uuidString, forKey: RicohBLE.rememberedIDKey)
        UserDefaults.standard.set(name, forKey: RicohBLE.rememberedNameKey)
    }

    private func waitUntilPoweredOn() async throws {
        activate()
        guard let central else { throw RicohBLEError.unsupported }
        switch central.state {
        case .poweredOn:
            return
        case .poweredOff:
            throw RicohBLEError.bluetoothOff
        case .unauthorized:
            throw RicohBLEError.unauthorized
        case .unsupported:
            throw RicohBLEError.unsupported
        default:
            break
        }
        after(10) { [weak self] in
            guard let self, !self.poweredOnWaiters.isEmpty else { return }
            let waiters = self.poweredOnWaiters
            self.poweredOnWaiters = []
            waiters.forEach { $0.resume(throwing: RicohBLEError.timeout("starting Bluetooth")) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            poweredOnWaiters.append(continuation)
        }
    }

    private func beginScan() {
        guard let central else { return }
        discovered = []
        stage = .scanning
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        appendLog("Scanning for Bluetooth devices")
    }

    private func resolvePeripheral() async throws -> CBPeripheral {
        guard let central else { throw RicohBLEError.unsupported }
        if let id = rememberedID {
            if let known = peripheralsByID[id] { return known }
            if let retrieved = central.retrievePeripherals(withIdentifiers: [id]).first {
                peripheralsByID[id] = retrieved
                return retrieved
            }
            appendLog("Remembered camera not known to iOS any more; scanning")
        }
        if let candidate = discovered.first(where: { $0.looksLikeCamera }), let known = peripheralsByID[candidate.id] {
            remember(id: candidate.id, name: candidate.name)
            return known
        }
        beginScan()
        let token = makeToken()
        after(15) { [weak self] in
            guard let self, let waiter = self.scanWaiter, waiter.token == token else { return }
            self.scanWaiter = nil
            self.stopScan()
            waiter.continuation.resume(throwing: RicohBLEError.noCameraFound)
        }
        let found = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CBPeripheral, Error>) in
            scanWaiter = Pending(token: token, continuation: continuation)
        }
        stopScan()
        remember(id: found.identifier, name: found.name ?? "Ricoh camera")
        return found
    }

    private func connectWithRetry(_ target: CBPeripheral) async throws {
        if target.state == .connected {
            isConnected = true
            return
        }
        stage = .connecting
        var delay: Double = 1
        var lastError: Error = RicohBLEError.timeout("connecting")
        // The first pairing can take ~15 s of failed connects.
        for attempt in 1...6 {
            do {
                try await connectOnce(target, timeout: 10)
                appendLog("Connected to \(target.name ?? "camera") (attempt \(attempt))")
                return
            } catch {
                lastError = error
                appendLog("Connect attempt \(attempt) failed: \(error.localizedDescription)")
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                delay = min(delay * 2, 4)
            }
        }
        throw lastError
    }

    private func connectOnce(_ target: CBPeripheral, timeout: Double) async throws {
        guard let central else { throw RicohBLEError.unsupported }
        target.delegate = proxy
        let token = makeToken()
        let targetID = target.identifier
        after(timeout) { [weak self] in
            guard let self, let waiter = self.connectWaiter, waiter.token == token else { return }
            self.connectWaiter = nil
            if let pending = self.peripheralsByID[targetID] {
                self.central?.cancelPeripheralConnection(pending)
            }
            waiter.continuation.resume(throwing: RicohBLEError.timeout("connecting"))
        }
        peripheralsByID[targetID] = target
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connectWaiter = Pending(token: token, continuation: continuation)
            central.connect(target, options: nil)
        }
    }

    private func discoverEverything(_ target: CBPeripheral) async throws {
        characteristics = [:]
        wlanCharacteristics = []
        let servicesToken = makeToken()
        after(10) { [weak self] in
            guard let self, let waiter = self.servicesWaiter, waiter.token == servicesToken else { return }
            self.servicesWaiter = nil
            waiter.continuation.resume(throwing: RicohBLEError.timeout("discovering services"))
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            servicesWaiter = Pending(token: servicesToken, continuation: continuation)
            target.discoverServices(nil)
        }
        let services = target.services ?? []
        appendLog("Services: " + services.map { $0.uuid.uuidString }.joined(separator: ", "))
        guard !services.isEmpty else { throw RicohBLEError.serviceNotFound }

        let characteristicsToken = makeToken()
        after(10) { [weak self] in
            guard let self, let waiter = self.characteristicsWaiter, waiter.token == characteristicsToken else { return }
            self.characteristicsWaiter = nil
            waiter.continuation.resume(throwing: RicohBLEError.timeout("discovering characteristics"))
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            characteristicsWaiter = Pending(token: characteristicsToken, continuation: continuation)
            servicesLeft = services.count
            for service in services {
                target.discoverCharacteristics(nil, for: service)
            }
        }
        guard services.contains(where: { $0.uuid == RicohBLEUUID.wlanService }) else {
            throw RicohBLEError.serviceNotFound
        }
        guard characteristics[RicohBLEUUID.networkType] != nil else {
            throw RicohBLEError.characteristicMissing("Network Type")
        }
    }

    private func readBatteryAndSubscribePower() async {
        guard let peripheral else { return }
        if let power = characteristics[RicohBLEUUID.powerState] {
            if power.properties.contains(.notify) || power.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: power)
            }
            if power.properties.contains(.read), let data = try? await read(RicohBLEUUID.powerState) {
                cameraPoweredOn = RicohBLEDecoding.powerIsOn(data)
            }
        } else {
            appendLog("Power-state characteristic not found")
        }
        if let battery = characteristics[RicohBLEUUID.batteryLevel] {
            if let data = try? await read(RicohBLEUUID.batteryLevel), let first = data.first {
                batteryPercent = min(100, Int(first))
                appendLog("Battery service: \(Int(first))%")
            }
            if battery.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: battery)
            }
        }
    }

    /// The Wi-Fi service has more characteristics (security, frequency, BSSID) whose UUIDs are unpublished.
    private func logOtherWLANCharacteristics() async {
        let known: Set<CBUUID> = [RicohBLEUUID.networkType, RicohBLEUUID.ssid, RicohBLEUUID.passphrase]
        for characteristic in wlanCharacteristics where !known.contains(characteristic.uuid) {
            guard characteristic.properties.contains(.read) else {
                appendLog("WLAN char \(characteristic.uuid.uuidString): not readable")
                continue
            }
            do {
                let data = try await read(characteristic.uuid)
                let text = RicohBLEDecoding.text(from: data).map { " \"\($0)\"" } ?? ""
                appendLog("WLAN char \(characteristic.uuid.uuidString): \(RicohBLEDecoding.hex(data))\(text)")
            } catch {
                appendLog("WLAN char \(characteristic.uuid.uuidString): read failed (\(error.localizedDescription))")
            }
        }
    }

    private func withPairingRetry<T>(_ what: String, _ operation: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch {
                attempt += 1
                let pairing = RicohBLEError.isPairingError(error)
                var dropped = false
                if let bleError = error as? RicohBLEError, case .disconnected = bleError {
                    dropped = true
                }
                guard (pairing || dropped) && attempt < 6 else { throw error }
                if pairing {
                    stage = .waitingForPairing
                    appendLog("\(what): needs pairing (\(error.localizedDescription)). Confirm the code on both devices; retrying.")
                } else {
                    appendLog("\(what): connection dropped (often happens while pairing); reconnecting.")
                }
                try await Task.sleep(nanoseconds: 4_000_000_000)
                if let peripheral, peripheral.state != .connected {
                    try await connectWithRetry(peripheral)
                    try await discoverEverything(peripheral)
                }
                stage = .wakingWiFi
            }
        }
    }

    private func read(_ uuid: CBUUID, timeout: Double = 8) async throws -> Data {
        guard let peripheral, peripheral.state == .connected else { throw RicohBLEError.disconnected }
        guard let characteristic = characteristics[uuid] else {
            throw RicohBLEError.characteristicMissing(uuid.uuidString)
        }
        let token = makeToken()
        after(timeout) { [weak self] in
            guard let self, let waiter = self.readWaiters[uuid], waiter.token == token else { return }
            self.readWaiters[uuid] = nil
            waiter.continuation.resume(throwing: RicohBLEError.timeout("reading \(uuid.uuidString)"))
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            readWaiters[uuid] = Pending(token: token, continuation: continuation)
            peripheral.readValue(for: characteristic)
        }
    }

    private func write(_ data: Data, to uuid: CBUUID, timeout: Double = 8) async throws {
        guard let peripheral, peripheral.state == .connected else { throw RicohBLEError.disconnected }
        guard let characteristic = characteristics[uuid] else {
            throw RicohBLEError.characteristicMissing(uuid.uuidString)
        }
        let token = makeToken()
        after(timeout) { [weak self] in
            guard let self, let waiter = self.writeWaiters[uuid], waiter.token == token else { return }
            self.writeWaiters[uuid] = nil
            waiter.continuation.resume(throwing: RicohBLEError.timeout("writing \(uuid.uuidString)"))
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeWaiters[uuid] = Pending(token: token, continuation: continuation)
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
        }
    }

    private func failAllPending(_ error: Error) {
        if let waiter = connectWaiter { connectWaiter = nil; waiter.continuation.resume(throwing: error) }
        if let waiter = servicesWaiter { servicesWaiter = nil; waiter.continuation.resume(throwing: error) }
        if let waiter = characteristicsWaiter { characteristicsWaiter = nil; waiter.continuation.resume(throwing: error) }
        let reads = readWaiters
        readWaiters = [:]
        reads.values.forEach { $0.continuation.resume(throwing: error) }
        let writes = writeWaiters
        writeWaiters = [:]
        writes.values.forEach { $0.continuation.resume(throwing: error) }
    }

    private func publishPower(_ on: Bool) {
        let changed = cameraPoweredOn != on
        cameraPoweredOn = on
        if changed { appendLog("Camera power: \(on ? "on" : "off")") }
        for continuation in powerContinuations.values {
            continuation.yield(on)
        }
    }

    // MARK: Delegate events (called on the main queue by the proxy)

    fileprivate func handleStateUpdate(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            appendLog("Bluetooth on")
            let waiters = poweredOnWaiters
            poweredOnWaiters = []
            waiters.forEach { $0.resume() }
            if keepConnected, let peripheral, peripheral.state != .connected {
                central?.connect(peripheral, options: nil)
            }
        case .poweredOff, .unauthorized, .unsupported:
            let error: RicohBLEError = state == .poweredOff ? .bluetoothOff : (state == .unauthorized ? .unauthorized : .unsupported)
            let waiters = poweredOnWaiters
            poweredOnWaiters = []
            waiters.forEach { $0.resume(throwing: error) }
            failAllPending(error)
            isConnected = false
            stage = .failed(error.errorDescription ?? "Bluetooth unavailable")
        default:
            break
        }
    }

    fileprivate func handleRestore(_ peripherals: [CBPeripheral]) {
        for restored in peripherals {
            restored.delegate = proxy
            peripheralsByID[restored.identifier] = restored
            if restored.identifier == rememberedID {
                peripheral = restored
                keepConnected = true
            }
        }
        appendLog("Restored \(peripherals.count) Bluetooth peripheral(s)")
    }

    fileprivate func handleDiscover(_ found: CBPeripheral, advertisedName: String?, rssi: Int) {
        let name = found.name ?? advertisedName
        guard let name, !name.isEmpty else { return }
        peripheralsByID[found.identifier] = found
        let entry = DiscoveredCamera(id: found.identifier, name: name, rssi: rssi,
                                     looksLikeCamera: RicohBLEDecoding.looksLikeCamera(name: name))
        if let index = discovered.firstIndex(where: { $0.id == entry.id }) {
            discovered[index] = entry
        } else {
            discovered.append(entry)
            appendLog("Found \(name) (RSSI \(rssi))")
        }
        discovered.sort { lhs, rhs in
            if lhs.looksLikeCamera != rhs.looksLikeCamera { return lhs.looksLikeCamera }
            return lhs.rssi > rhs.rssi
        }
        if entry.looksLikeCamera, let waiter = scanWaiter {
            scanWaiter = nil
            waiter.continuation.resume(returning: found)
        }
    }

    fileprivate func handleConnect(_ connected: CBPeripheral) {
        isConnected = true
        if let waiter = connectWaiter {
            connectWaiter = nil
            waiter.continuation.resume()
        } else if keepConnected && connected.identifier == peripheral?.identifier {
            // Automatic reconnection: re-discover so power-on notifications keep coming.
            appendLog("Reconnected to camera")
            Task {
                do {
                    try await self.discoverEverything(connected)
                    await self.readBatteryAndSubscribePower()
                } catch {
                    self.appendLog("Re-discovery failed: \(error.localizedDescription)")
                }
            }
        }
    }

    fileprivate func handleFailToConnect(_ failed: CBPeripheral, error: Error?) {
        if let waiter = connectWaiter {
            connectWaiter = nil
            waiter.continuation.resume(throwing: error ?? RicohBLEError.disconnected)
        }
    }

    fileprivate func handleDisconnect(_ lost: CBPeripheral, error: Error?) {
        isConnected = false
        appendLog("Disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
        failAllPending(RicohBLEError.disconnected)
        characteristics = [:]
        wlanCharacteristics = []
        if keepConnected, lost.identifier == rememberedID {
            // A pending connect has no timeout: iOS reconnects when the camera is back in range / switched on.
            central?.connect(lost, options: nil)
        }
    }

    fileprivate func handleServicesDiscovered(error: Error?) {
        guard let waiter = servicesWaiter else { return }
        servicesWaiter = nil
        if let error {
            waiter.continuation.resume(throwing: error)
        } else {
            waiter.continuation.resume()
        }
    }

    fileprivate func handleCharacteristicsDiscovered(for service: CBService, error: Error?) {
        if let error {
            appendLog("Characteristics of \(service.uuid.uuidString) failed: \(error.localizedDescription)")
        }
        for characteristic in service.characteristics ?? [] {
            characteristics[characteristic.uuid] = characteristic
            if service.uuid == RicohBLEUUID.wlanService {
                wlanCharacteristics.append(characteristic)
            }
        }
        if service.uuid.uuidString.uppercased().hasPrefix(RicohBLEUUID.powerServicePrefix) {
            appendLog("Power service \(service.uuid.uuidString) has \(service.characteristics?.count ?? 0) characteristic(s)")
        }
        servicesLeft -= 1
        if servicesLeft <= 0, let waiter = characteristicsWaiter {
            characteristicsWaiter = nil
            waiter.continuation.resume()
        }
    }

    fileprivate func handleValueUpdate(_ characteristic: CBCharacteristic, error: Error?) {
        let value = characteristic.value ?? Data()
        if let waiter = readWaiters.removeValue(forKey: characteristic.uuid) {
            if let error {
                waiter.continuation.resume(throwing: error)
            } else {
                waiter.continuation.resume(returning: value)
            }
            return
        }
        guard error == nil else { return }
        // Notifications.
        if characteristic.uuid == RicohBLEUUID.powerState, let on = RicohBLEDecoding.powerIsOn(value) {
            publishPower(on)
        } else if characteristic.uuid == RicohBLEUUID.batteryLevel, let first = value.first {
            batteryPercent = min(100, Int(first))
        }
    }

    fileprivate func handleWrite(_ characteristic: CBCharacteristic, error: Error?) {
        guard let waiter = writeWaiters.removeValue(forKey: characteristic.uuid) else { return }
        if let error {
            waiter.continuation.resume(throwing: error)
        } else {
            waiter.continuation.resume()
        }
    }

    fileprivate func handleNotificationState(_ characteristic: CBCharacteristic, error: Error?) {
        if let error {
            appendLog("Subscribe to \(characteristic.uuid.uuidString) failed: \(error.localizedDescription)")
        } else {
            appendLog("Subscribed to \(characteristic.uuid.uuidString)")
        }
    }
}

/// Receives CoreBluetooth callbacks (main queue) and forwards them synchronously to the main-actor `RicohBLE`.
final class RicohBLEDelegateProxy: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    weak var owner: RicohBLE?

    init(owner: RicohBLE) {
        self.owner = owner
        super.init()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard let owner else { return }
        let state = central.state
        MainActor.assumeIsolated { owner.handleStateUpdate(state) }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let owner else { return }
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        MainActor.assumeIsolated { owner.handleRestore(peripherals) }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard let owner else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let rssi = RSSI.intValue
        MainActor.assumeIsolated { owner.handleDiscover(peripheral, advertisedName: name, rssi: rssi) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let owner else { return }
        MainActor.assumeIsolated { owner.handleConnect(peripheral) }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard let owner else { return }
        MainActor.assumeIsolated { owner.handleFailToConnect(peripheral, error: error) }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard let owner else { return }
        MainActor.assumeIsolated { owner.handleDisconnect(peripheral, error: error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let owner else { return }
        MainActor.assumeIsolated { owner.handleServicesDiscovered(error: error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let owner else { return }
        MainActor.assumeIsolated { owner.handleCharacteristicsDiscovered(for: service, error: error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let owner else { return }
        MainActor.assumeIsolated { owner.handleValueUpdate(characteristic, error: error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let owner else { return }
        MainActor.assumeIsolated { owner.handleWrite(characteristic, error: error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let owner else { return }
        MainActor.assumeIsolated { owner.handleNotificationState(characteristic, error: error) }
    }
}
