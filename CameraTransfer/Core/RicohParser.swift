import Foundation

/// Pure parsing of the (reverse-engineered) Ricoh GR II / GR III HTTP API responses.
/// The GR IV is assumed to use the same format; parsing is deliberately tolerant.
enum RicohParser {

    /// Extracts the model name from `GET /v1/props`.
    static func parseModel(fromProps data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            return nil
        }
        for key in ["model", "Model", "modelName", "productName"] {
            if let value = root[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    /// Parses model, firmware, battery and storages from `GET /v1/props`. Unknown fields become nil.
    /// Example: `{"model":"RICOH GR IV","firmwareVersion":"1.11","battery":80,
    ///            "storages":[{"name":"in","equipped":true,"numOfPhotos":3,"numOfMovies":0}, ...]}`
    static func parseDeviceInfo(fromProps data: Data) -> CameraDeviceInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            return nil
        }
        let model = parseModel(fromProps: data) ?? "Ricoh camera"
        var firmware: String?
        for key in ["firmwareVersion", "firmware", "fwVersion", "firmVersion"] {
            if let value = root[key] as? String, !value.isEmpty {
                firmware = value
                break
            }
            if let number = root[key] as? NSNumber, !isBoolean(number) {
                firmware = number.stringValue
                break
            }
        }
        var battery: Int?
        for key in ["battery", "batteryLevel", "battery_level", "batteryPercent", "batteryRemain"] {
            if let value = percentValue(root[key]) {
                battery = value
                break
            }
        }
        return CameraDeviceInfo(model: model, firmware: firmware, batteryPercent: battery, storages: parseStorages(root["storages"]))
    }

    static func parseStorages(_ any: Any?) -> [CameraStorage] {
        guard let list = any as? [Any] else { return [] }
        var storages: [CameraStorage] = []
        for case let dict as [String: Any] in list {
            guard let name = stringValue(dict["name"]) ?? stringValue(dict["storageId"]), !name.isEmpty else { continue }
            storages.append(CameraStorage(name: name,
                                          equipped: boolValue(dict["equipped"]) ?? true,
                                          numberOfPhotos: intValue(dict["numOfPhotos"]),
                                          numberOfMovies: intValue(dict["numOfMovies"])))
        }
        return storages
    }

    /// Parses `GET /v1/photos`:
    /// `{"errCode":200,"dirs":[{"name":"100RICOH","files":["R0000001.JPG", ...]}]}`.
    /// Files may also be objects such as `{"n":"R0000001.JPG","s":123,"d":"2024-01-01T10:00:00"}`.
    static func parsePhotoList(_ data: Data, storage: String? = nil) throws -> [RemotePhoto] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CameraError.badResponse("photo list is not valid JSON")
        }
        guard let root = object as? [String: Any] else {
            throw CameraError.badResponse("photo list is not a JSON object")
        }
        if let code = intValue(root["errCode"]), code != 200 {
            let message = (root["errMsg"] as? String) ?? ""
            throw CameraError.badResponse("camera reported error \(code) \(message)".trimmingCharacters(in: .whitespaces))
        }
        guard let dirs = root["dirs"] as? [Any] else {
            return []
        }

        var photos: [RemotePhoto] = []
        for case let dir as [String: Any] in dirs {
            guard let dirName = stringValue(dir["name"]) ?? stringValue(dir["n"]), !dirName.isEmpty else {
                continue
            }
            let files = (dir["files"] as? [Any]) ?? []
            for entry in files {
                if let name = entry as? String {
                    if isUsableName(name) {
                        photos.append(RemotePhoto(folder: dirName, filename: name, storage: storage))
                    }
                } else if let dict = entry as? [String: Any] {
                    guard let name = stringValue(dict["n"]) ?? stringValue(dict["name"]), isUsableName(name) else {
                        continue
                    }
                    let size = int64Value(dict["s"]) ?? int64Value(dict["size"])
                    let date = parseDate(dict["d"] ?? dict["date"])
                    photos.append(RemotePhoto(folder: dirName, filename: name, size: size, date: date, storage: storage))
                }
            }
        }
        return photos
    }

    // MARK: Helpers

    static func isUsableName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "." && trimmed != ".." && !trimmed.contains("/")
    }

    static func stringValue(_ any: Any?) -> String? {
        if let string = any as? String { return string }
        return nil
    }

    static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    static func boolValue(_ any: Any?) -> Bool? {
        if let number = any as? NSNumber { return number.boolValue }
        if let string = any as? String {
            switch string.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }

    /// A 0...100 battery percentage from a number or a string such as "80" or "80%".
    static func percentValue(_ any: Any?) -> Int? {
        var value: Int?
        if let number = any as? NSNumber, !isBoolean(number) {
            value = number.intValue
        } else if let string = any as? String {
            value = Int(string.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
        }
        guard let value, (0...100).contains(value) else { return nil }
        return value
    }

    static func intValue(_ any: Any?) -> Int? {
        if let number = any as? NSNumber { return number.intValue }
        if let string = any as? String { return Int(string) }
        return nil
    }

    static func int64Value(_ any: Any?) -> Int64? {
        if let number = any as? NSNumber { return number.int64Value }
        if let string = any as? String { return Int64(string) }
        return nil
    }

    static func parseDate(_ any: Any?) -> Date? {
        guard let string = any as? String, !string.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: string) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy:MM:dd HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }
}
