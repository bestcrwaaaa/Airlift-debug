import Foundation
import AirliftFFI

// MARK: - Failure

/// One thing the debug console could not do, phrased so the user can act on it.
struct DebugFailure: Error, Sendable {
    let message: String
}

// MARK: - Engine

/// The file plumbing behind the debug console.
///
/// Everything here rides the same AirTraffic/ATAirlock primitive the
/// announcement tooling already uses — the console only changes what comes
/// back: raw bytes instead of a digest, an arbitrary path instead of one fixed
/// directory, and a listing of what is on the device.
///
/// The exploit can only move objects around, so a read is still "relocate the
/// file into Media, read it over AFC, put it back". The write path is the
/// proven writer: the staged archive carries a symlink to the target
/// directory, and ATAirlock follows it when the payload lands.
enum DebugEngine {

    /// The C ABI cannot carry NUL bytes, so payloads travel as hex. This is
    /// the ceiling for a single transfer; the device is not the limit, the
    /// string in memory is.
    static let maxPayloadBytes = 8 * 1024 * 1024

    /// AFC — the channel the exploit reads and writes through — is rooted at
    /// the device's Media volume.
    static let mediaRoot = "/var/mobile/Media"

    /// A file that was read off the device.
    struct RemoteFile: Sendable {
        let path: String
        let data: Data

        var byteCount: Int { data.count }

        /// The file as text, when it is text. Binary payloads come back as
        /// nil and the console shows a hex dump instead.
        var text: String? {
            String(data: data, encoding: .utf8)
        }

        var looksBinary: Bool { text == nil }
    }

    /// One entry of a directory listing.
    struct Entry: Identifiable, Sendable {
        let name: String
        let size: Int
        let isDirectory: Bool
        var id: String { name }
    }

    // MARK: paths

    /// Splits an absolute path into the directory and the bare file name the
    /// exploit needs: the staged symlink points at the directory and the
    /// payload lands inside it under the file name.
    static func split(_ path: String) -> (directory: String, leaf: String)? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let ns = trimmed as NSString
        let leaf = ns.lastPathComponent
        guard !leaf.isEmpty, leaf != ".", leaf != ".." else { return nil }
        var directory = ns.deletingLastPathComponent
        if directory.isEmpty { directory = "/" }
        return (directory, leaf)
    }

    /// The AFC-relative form of an absolute path. AFC only sees the Media
    /// volume, so a path outside it has no relative form.
    static func afcRelativePath(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalised = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        let root = String(mediaRoot.dropFirst())
        if normalised == root { return "" }
        guard normalised.hasPrefix(root + "/") else { return nil }
        return String(normalised.dropFirst(root.count + 1))
    }

    /// The absolute path of a child inside an AFC directory.
    static func absolutePath(afcRelative: String) -> String {
        let trimmed = afcRelative.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return mediaRoot }
        return mediaRoot + "/" + trimmed
    }

    // MARK: read

    /// Read a file off the device.
    ///
    /// The exploit moves the file out to Media, reads it over AFC and writes it
    /// straight back, so the device is left as it was found — unless the
    /// write-back fails, which the console reports as a warning rather than
    /// swallowing the bytes it already has.
    static func read(path: String, pairingPath: String) -> Result<RemoteFile, DebugFailure> {
        guard let (directory, leaf) = split(path) else {
            return .failure(DebugFailure(message: String(localized: "That is not an absolute path")))
        }

        var hex: UnsafeMutablePointer<CChar>?
        var size: UInt64 = 0
        var warning: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<CChar>?

        let rc = pairingPath.withCString { p in
            directory.withCString { d in
                leaf.withCString { l in
                    al_exploit_read_file_bytes(p, d, l, alLogBridge, nil, &hex, &size, &warning, &error)
                }
            }
        }
        defer {
            if let hex { al_string_free(hex) }
            if let warning { al_string_free(warning) }
            if let error { al_string_free(error) }
        }

        if rc != 0 {
            return .failure(DebugFailure(message: message(error) ?? String(localized: "Read failed (rc=\(rc))")))
        }
        guard let hex else {
            return .failure(DebugFailure(message: String(localized: "The device returned nothing")))
        }
        guard let data = decodeHex(String(cString: hex)) else {
            return .failure(DebugFailure(message: String(localized: "The device returned data that could not be decoded")))
        }
        return .success(RemoteFile(path: path, data: data))
    }

    // MARK: write

    /// Write one file to an arbitrary path on the device.
    static func write(path: String, data: Data, pairingPath: String) -> Result<Int, DebugFailure> {
        guard let (directory, leaf) = split(path) else {
            return .failure(DebugFailure(message: String(localized: "That is not an absolute path")))
        }
        guard data.count <= maxPayloadBytes else {
            return .failure(DebugFailure(message: String(localized: "The payload is larger than \(maxPayloadBytes) bytes")))
        }

        let payload = encodeHex(data)
        var written: UInt64 = 0
        var error: UnsafeMutablePointer<CChar>?

        let rc = pairingPath.withCString { p in
            directory.withCString { d in
                leaf.withCString { l in
                    payload.withCString { h in
                        al_exploit_write_file_bytes(p, d, l, h, alLogBridge, nil, &written, &error)
                    }
                }
            }
        }
        defer { if let error { al_string_free(error) } }

        if rc != 0 {
            return .failure(DebugFailure(message: message(error) ?? String(localized: "Write failed (rc=\(rc))")))
        }
        return .success(Int(written))
    }

    // MARK: list

    /// List a directory on the device.
    ///
    /// This one goes straight over AFC, so it browses the Media volume. Files
    /// outside Media are reachable through the exploit itself, one path at a
    /// time.
    static func list(path: String, pairingPath: String) -> Result<[Entry], DebugFailure> {
        guard let relative = afcRelativePath(path) else {
            return .failure(DebugFailure(message: String(localized: "AFC can only browse \(mediaRoot)")))
        }

        var json: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<CChar>?

        let rc = pairingPath.withCString { p in
            relative.withCString { d in
                al_exploit_list_dir(p, d, alLogBridge, nil, &json, &error)
            }
        }
        defer { if let error { al_string_free(error) } }

        if rc != 0 {
            return .failure(DebugFailure(message: message(error) ?? String(localized: "Listing failed (rc=\(rc))")))
        }
        guard let json else {
            return .failure(DebugFailure(message: String(localized: "The device returned nothing")))
        }
        return .success(decodeEntries(String(cString: json)))
    }

    /// Turn the JSON the core returns into entries.
    static func decodeEntries(_ json: String) -> [Entry] {
        guard let data = json.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return items.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            let size = (item["size"] as? NSNumber)?.intValue ?? 0
            let isDirectory = (item["is_dir"] as? NSNumber)?.boolValue ?? false
            return Entry(name: name, size: size, isDirectory: isDirectory)
        }
    }

    // MARK: hex

    /// Hex-encode bytes. The transport format of every payload in both
    /// directions — a C string cannot carry NUL bytes, and a raw buffer would
    /// need a length argument and a free on every path out of the FFI.
    static func encodeHex(_ data: Data) -> String {
        let table: [Character] = Array("0123456789abcdef")
        var out = String()
        out.reserveCapacity(data.count * 2)
        for byte in data {
            out.append(table[Int(byte >> 4)])
            out.append(table[Int(byte & 0x0F)])
        }
        return out
    }

    /// Decode a hex string back into bytes.
    static func decodeHex(_ text: String) -> Data? {
        let chars = Array(text.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var data = Data(capacity: chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let high = hexValue(chars[index]), let low = hexValue(chars[index + 1]) else { return nil }
            data.append(high << 4 | low)
            index += 2
        }
        return data
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x61...0x66: return byte - 0x61 + 10
        case 0x41...0x46: return byte - 0x41 + 10
        default: return nil
        }
    }

    /// A hex dump of the first bytes of a payload, for binary files.
    static func hexDump(_ data: Data, limit: Int = 512) -> String {
        var out = ""
        for (offset, byte) in data.prefix(limit).enumerated() {
            if offset % 16 == 0 {
                if offset > 0 { out += "\n" }
                out += String(format: "%08x  ", offset)
            }
            out += String(format: "%02x ", byte)
        }
        if data.count > limit {
            out += "\n… \(data.count - limit) more byte(s)"
        }
        return out
    }

    // MARK: helpers

    private static func message(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        return String(cString: pointer)
    }
}
