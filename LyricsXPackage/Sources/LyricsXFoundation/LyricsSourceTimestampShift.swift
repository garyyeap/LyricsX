import Foundation

/// Rewrites absolute LRC/LRCX timestamps without reserializing lyric content.
public enum LyricsSourceTimestampShift {
    public static func applying(offset: Int, to source: String) -> String {
        // Match the same timestamp grammar as LyricsKit, but only at the
        // beginning of a line. Bracketed text in lyrics is not a timestamp.
        let tagPattern = #"\[([+-]?\d+):(\d+)(?:\.(\d+))?\]"#
        let pattern = "^(?:" + tagPattern + #")+|^\[offset\s*:[^\]\r\n]*\]$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
              let tagRegex = try? NSRegularExpression(pattern: tagPattern) else {
            return source
        }
        let original = source as NSString
        let result = NSMutableString(string: source)
        for match in regex.matches(in: source, range: NSRange(location: 0, length: original.length)).reversed() {
            guard !original.substring(with: match.range).hasPrefix("[offset") else {
                result.replaceCharacters(in: match.range, with: "")
                continue
            }
            for tag in tagRegex.matches(in: source, range: match.range).reversed() {
                let minutes = Double(original.substring(with: tag.range(at: 1))) ?? 0
                let seconds = Double(original.substring(with: tag.range(at: 2))) ?? 0
                let fractionRange = tag.range(at: 3)
                let fraction = fractionRange.location == NSNotFound ? "" : original.substring(with: fractionRange)
                let time = max(0, minutes * 60 + seconds + (Double("0." + fraction) ?? 0) - Double(offset) / 1000)
                guard time.isFinite, time < Double(Int.max) else { continue }
                let precision = max(3, fraction.count)
                let minute = Int(time / 60)
                let second = time - Double(minute) * 60
                let secondText = String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), precision, second)
                let minuteText = minute < 10 ? "0\(minute)" : "\(minute)"
                let timestamp = "[\(minuteText):\(second < 10 ? "0" : "")\(secondText)]"
                result.replaceCharacters(in: tag.range, with: timestamp)
            }
        }
        return result as String
    }
}
