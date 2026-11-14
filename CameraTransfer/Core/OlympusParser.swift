import Foundation

/// One line of an OM System / Olympus `get_imglist.cgi` response:
/// `dir,name,size,attrib,date,time`.
struct OlympusListEntry: Equatable, Sendable {
    let directory: String
    let name: String
    let size: Int64
    let attributes: Int
    let fatDate: Int
    let fatTime: Int

    /// FAT attribute bit 0x10 marks a directory.
    var isDirectory: Bool { (attributes & 0x10) != 0 }

    /// Full path on the camera, e.g. "/DCIM/100OMSYS/P1010001.JPG".
    var path: String {
        if directory.hasSuffix("/") { return directory + name }
        return directory + "/" + name
    }
}

/// Pure parsing for the OI.Share-style HTTP API used by Olympus / OM System cameras.
enum OlympusParser {

    /// Extracts `<model>...</model>` from `get_caminfo.cgi`.
    static func parseModel(fromCamInfo data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        guard let open = text.range(of: "<model>", options: .caseInsensitive),
              let close = text.range(of: "</model>", options: .caseInsensitive, range: open.upperBound..<text.endIndex) else {
            return nil
        }
        let value = text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Parses the text body of `get_imglist.cgi`. The first line is a version marker such as `VER_100`.
    static func parseImageList(_ text: String) -> [OlympusListEntry] {
        var entries: [OlympusListEntry] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.uppercased().hasPrefix("VER_") { continue }
            let fields = line.components(separatedBy: ",")
            guard fields.count >= 6 else { continue }
            // Be robust to a filename containing a comma: the last four fields are always numeric.
            let count = fields.count
            let directory = fields[0].trimmingCharacters(in: .whitespaces)
            let name = fields[1..<(count - 4)].joined(separator: ",").trimmingCharacters(in: .whitespaces)
            guard let size = Int64(fields[count - 4].trimmingCharacters(in: .whitespaces)),
                  let attributes = Int(fields[count - 3].trimmingCharacters(in: .whitespaces)),
                  let date = Int(fields[count - 2].trimmingCharacters(in: .whitespaces)),
                  let time = Int(fields[count - 1].trimmingCharacters(in: .whitespaces)) else {
                continue
            }
            guard !directory.isEmpty, !name.isEmpty, name != ".", name != "..", !name.contains("/") else { continue }
            entries.append(OlympusListEntry(directory: directory, name: name, size: size,
                                            attributes: attributes, fatDate: date, fatTime: time))
        }
        return entries
    }

    /// Decodes FAT-packed date and time integers:
    /// date = ((year - 1980) << 9) | (month << 5) | day, time = (hour << 11) | (minute << 5) | (second / 2).
    static func decodeFATDateTime(date: Int, time: Int, timeZone: TimeZone = .current) -> Date? {
        let year = (date >> 9) + 1980
        let month = (date >> 5) & 0x0F
        let day = date & 0x1F
        let hour = (time >> 11) & 0x1F
        let minute = (time >> 5) & 0x3F
        let second = (time & 0x1F) * 2
        guard (1...12).contains(month), (1...31).contains(day),
              hour < 24, minute < 60, second < 60 else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return calendar.date(from: components)
    }

    static func photo(from entry: OlympusListEntry, timeZone: TimeZone = .current) -> RemotePhoto {
        RemotePhoto(folder: entry.directory,
                    filename: entry.name,
                    size: entry.size,
                    date: decodeFATDateTime(date: entry.fatDate, time: entry.fatTime, timeZone: timeZone))
    }
}
