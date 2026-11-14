import Foundation
import NetworkExtension

enum HotspotJoinResult: Equatable {
    case joined
    /// Joining automatically did not work; the user must join manually in Settings > Wi-Fi.
    case failed(String)
}

/// Joins the camera's Wi-Fi with NEHotspotConfiguration (needs the Hotspot Configuration entitlement).
/// Any failure (including a missing entitlement) is reported, never thrown, so the UI can fall back
/// to manual joining.
enum HotspotJoiner {

    static func join(ssid: String, passphrase: String?) async -> HotspotJoinResult {
        let configuration: NEHotspotConfiguration
        if let passphrase, !passphrase.isEmpty {
            configuration = NEHotspotConfiguration(ssid: ssid, passphrase: passphrase, isWEP: false)
        } else {
            configuration = NEHotspotConfiguration(ssid: ssid)
        }
        // Forget the network again when the app goes to the background; never pin BSSID or channel.
        configuration.joinOnce = true

        let error: Error? = await withCheckedContinuation { (continuation: CheckedContinuation<Error?, Never>) in
            NEHotspotConfigurationManager.shared.apply(configuration) { error in
                continuation.resume(returning: error)
            }
        }
        guard let error else { return .joined }
        let nsError = error as NSError
        if nsError.domain == NEHotspotConfigurationErrorDomain {
            switch nsError.code {
            case NEHotspotConfigurationError.alreadyAssociated.rawValue:
                return .joined
            case NEHotspotConfigurationError.userDenied.rawValue:
                return .failed("Joining was cancelled.")
            case NEHotspotConfigurationError.invalidWPAPassphrase.rawValue:
                return .failed("iOS rejected the Wi-Fi password.")
            default:
                break
            }
        }
        return .failed("Automatic joining is not available (\(nsError.localizedDescription)).")
    }
}
