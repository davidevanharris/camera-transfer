import Foundation

/// How eager automatic transfer is. Thresholds are *strictly greater than*.
enum AutoTransferMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case manual = "manual"
    case standard = "default"
    case batterySaver = "batterySaver"
    case gonnaChargeSoon = "gonnaChargeSoon"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .manual: return "Off"
        case .standard: return "Default"
        case .batterySaver: return "Battery saver"
        case .gonnaChargeSoon: return "Gonna charge soon"
        }
    }

    /// Minimum battery percentage (exclusive) for both phone and camera. `nil` = auto-transfer off.
    var threshold: Int? {
        switch self {
        case .manual: return nil
        case .standard: return 75
        case .batterySaver: return 90
        case .gonnaChargeSoon: return 25
        }
    }

    var summary: String {
        switch self {
        case .manual: return "Auto-transfer is off. Use Download on each camera tab."
        case .standard: return "Auto-transfer new JPEGs while phone and camera are both above 75%."
        case .batterySaver: return "Auto-transfer only while phone and camera are both above 90%."
        case .gonnaChargeSoon: return "Auto-transfer while phone and camera are both above 25%."
        }
    }
}

/// What we know about the camera's battery.
enum CameraBatteryReading: Equatable, Sendable {
    case percent(Int)
    /// The camera could report it but did not (or we could not read it).
    case unknown
    /// Not part of the decision at all (Sony over FTP: only the phone side is checked).
    case notApplicable
}

struct TransferDecision: Equatable, Sendable {
    let allowed: Bool
    let reason: String
}

/// Pure decision function for automatic transfers (unit tested).
enum TransferPolicy {

    /// - Parameters:
    ///   - phonePercent: 0...100, or nil when unknown (e.g. the Simulator reports -1).
    ///   - phoneCharging: true when the phone is charging or full. A charging phone always passes the phone check.
    ///   - allowWhenCameraBatteryUnknown: whether an `.unknown` camera battery passes the camera check.
    static func evaluate(mode: AutoTransferMode,
                         phonePercent: Int?,
                         phoneCharging: Bool,
                         camera: CameraBatteryReading,
                         allowWhenCameraBatteryUnknown: Bool) -> TransferDecision {
        guard let threshold = mode.threshold else {
            return TransferDecision(allowed: false, reason: "Auto-transfer is off.")
        }
        let requirement = "\(mode.displayName) mode needs above \(threshold)%"

        // Phone side.
        let phoneText: String
        if phoneCharging {
            phoneText = phonePercent.map { "phone charging (\($0)%)" } ?? "phone charging"
        } else if let phone = phonePercent {
            guard phone > threshold else {
                return TransferDecision(allowed: false, reason: "Paused: phone at \(phone)%, \(requirement).")
            }
            phoneText = "phone \(phone)%"
        } else {
            phoneText = "phone battery unknown"
        }

        // Camera side.
        let cameraText: String
        switch camera {
        case .percent(let value):
            guard value > threshold else {
                return TransferDecision(allowed: false, reason: "Paused: camera at \(value)%, \(requirement).")
            }
            cameraText = ", camera \(value)%"
        case .unknown:
            guard allowWhenCameraBatteryUnknown else {
                return TransferDecision(allowed: false,
                                        reason: "Paused: camera battery level is unknown and \"Allow when camera battery is unknown\" is off.")
            }
            cameraText = ", camera battery unknown"
        case .notApplicable:
            cameraText = ""
        }

        return TransferDecision(allowed: true,
                                reason: "Auto-transfer on: \(phoneText)\(cameraText) (\(requirement)).")
    }
}

/// UserDefaults-backed auto-transfer settings.
enum AutoTransferSettings {
    static let modeKey = "autoTransferMode"
    static let allowUnknownCameraBatteryKey = "allowWhenCameraBatteryUnknown"
    static let keepCopyKey = "keepCopyInAppFolder"

    static func register(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            modeKey: AutoTransferMode.manual.rawValue,
            allowUnknownCameraBatteryKey: true,
            keepCopyKey: false
        ])
    }

    static func mode(_ defaults: UserDefaults = .standard) -> AutoTransferMode {
        AutoTransferMode(rawValue: defaults.string(forKey: modeKey) ?? "") ?? .manual
    }

    static func allowWhenCameraBatteryUnknown(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: allowUnknownCameraBatteryKey)
    }

    static func keepCopy(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: keepCopyKey)
    }
}
