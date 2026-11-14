import Foundation

/// UserDefaults keys shared by @AppStorage in views and by non-view code.
enum SettingsKey {
    static let ricohBaseURL = "ricohBaseURL"
    static let olympusBaseURL = "olympusBaseURL"
    static let ftpPort = "ftpPort"
    static let ftpUsername = "ftpUsername"
    static let ftpPassword = "ftpPassword"
    static let exportAfterDownload = "exportAfterDownload"
}

enum AppDefaults {
    static let ricohBaseURL = RicohClient.defaultBaseURL
    static let olympusBaseURL = OlympusClient.defaultBaseURL
    static let ftpPort = 2121
    static let ftpUsername = "camera"

    /// Registers defaults and generates a random FTP password on first run.
    static func registerAndPrepare(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            SettingsKey.ricohBaseURL: ricohBaseURL,
            SettingsKey.olympusBaseURL: olympusBaseURL,
            SettingsKey.ftpPort: ftpPort,
            SettingsKey.ftpUsername: ftpUsername,
            SettingsKey.exportAfterDownload: false
        ])
        let existing = defaults.string(forKey: SettingsKey.ftpPassword) ?? ""
        if existing.isEmpty {
            defaults.set(randomPassword(), forKey: SettingsKey.ftpPassword)
        }
    }

    /// Easy-to-type random password (no look-alike characters).
    static func randomPassword(length: Int = 10) -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        var generator = SystemRandomNumberGenerator()
        var result = ""
        for _ in 0..<max(6, length) {
            if let character = alphabet.randomElement(using: &generator) {
                result.append(character)
            }
        }
        return result
    }

    static func baseURL(for camera: CameraModel, defaults: UserDefaults = .standard) -> URL? {
        switch camera {
        case .ricoh:
            return CameraHTTP.parseBaseURL(defaults.string(forKey: SettingsKey.ricohBaseURL) ?? ricohBaseURL)
        case .olympus:
            return CameraHTTP.parseBaseURL(defaults.string(forKey: SettingsKey.olympusBaseURL) ?? olympusBaseURL)
        case .sony:
            return nil
        }
    }

    static func ftpPortValue(_ defaults: UserDefaults = .standard) -> Int {
        let value = defaults.integer(forKey: SettingsKey.ftpPort)
        return value == 0 ? ftpPort : value
    }

    static func ftpUsernameValue(_ defaults: UserDefaults = .standard) -> String {
        let value = (defaults.string(forKey: SettingsKey.ftpUsername) ?? "").trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? ftpUsername : value
    }

    static func ftpPasswordValue(_ defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: SettingsKey.ftpPassword) ?? ""
    }
}
