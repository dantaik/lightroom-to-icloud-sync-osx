import Foundation

/// Helpers for the quirks of the JSON served by Lightroom's web gallery.
public enum AdobeJSON {
    /// Lightroom prefixes JSON bodies with `while (1) {}` (an anti-hijacking guard).
    /// Returns the body with that prefix removed, if present.
    public static func stripGuardPrefix(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var start = 0
        while start < bytes.count, isWhitespace(bytes[start]) { start += 1 }
        guard start < bytes.count else { return Data() }
        if bytes[start] == UInt8(ascii: "{") || bytes[start] == UInt8(ascii: "[") {
            return Data(bytes[start...])
        }
        // Drop the guard line, then skip whitespace again.
        guard let newline = bytes[start...].firstIndex(of: UInt8(ascii: "\n")) else { return data }
        var rest = newline + 1
        while rest < bytes.count, isWhitespace(bytes[rest]) { rest += 1 }
        return Data(bytes[rest...])
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: stripGuardPrefix(data))
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    }
}

/// Parses the timestamp formats used by Lightroom's cloud APIs.
public enum AdobeDate {
    /// Accepts `2024-09-18T21:07:30.325Z`, `2022-11-18T01:48:50.384971Z`, `2013-09-07T19:47:13`
    /// (no zone: interpreted as local time, like EXIF) and `2024-01-01T10:00:00+02:00`.
    /// Rejects placeholders such as `0000-00-00T00:00:00`.
    public static func parse(_ string: String?, localTimeZone: TimeZone = .current) -> Date? {
        guard let string = string?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let chars = Array(string)
        guard chars.count >= 19,
              chars[4] == "-", chars[7] == "-", chars[10] == "T", chars[13] == ":", chars[16] == ":"
        else { return nil }
        func int(_ range: Range<Int>) -> Int? { Int(String(chars[range])) }
        guard let year = int(0..<4), let month = int(5..<7), let day = int(8..<10),
              let hour = int(11..<13), let minute = int(14..<16), let second = int(17..<19),
              year > 0, (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second)
        else { return nil }

        var index = 19
        var nanoseconds = 0
        if index < chars.count, chars[index] == "." {
            index += 1
            var digits = ""
            while index < chars.count, chars[index].isNumber {
                digits.append(chars[index])
                index += 1
            }
            if !digits.isEmpty {
                nanoseconds = Int(String((digits + "000000000").prefix(9))) ?? 0
            }
        }

        var timeZone = localTimeZone
        if index < chars.count {
            let suffix = String(chars[index...])
            if suffix == "Z" {
                timeZone = TimeZone(secondsFromGMT: 0) ?? timeZone
            } else if let offset = parseOffset(suffix), let zone = TimeZone(secondsFromGMT: offset) {
                timeZone = zone
            } else {
                return nil
            }
        }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.nanosecond = nanoseconds
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: components)
    }

    private static func parseOffset(_ text: String) -> Int? {
        guard let sign = text.first, sign == "+" || sign == "-" else { return nil }
        let body = text.dropFirst().replacingOccurrences(of: ":", with: "")
        guard body.count == 4, let hours = Int(body.prefix(2)), let minutes = Int(body.suffix(2)) else { return nil }
        let seconds = hours * 3600 + minutes * 60
        return sign == "-" ? -seconds : seconds
    }
}
