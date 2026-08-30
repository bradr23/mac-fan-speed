import Foundation
import IOKit

// MARK: - Errors

public enum SMCError: Error, CustomStringConvertible {
    case serviceNotFound
    case openFailed(kern_return_t)
    case callFailed(kern_return_t)
    case keyNotFound(String)
    case deviceError(String, UInt8)
    case unsupportedType(String, String)
    case layoutMismatch(String)

    public var description: String {
        switch self {
        case .serviceNotFound:
            return "AppleSMC service not found. This tool supports Apple Silicon Macs only."
        case .openFailed(let kr):
            return "Could not open the SMC connection (IOServiceOpen returned \(kr))."
        case .callFailed(let kr):
            return "SMC call failed (IOConnectCallStructMethod returned \(kr))."
        case .keyNotFound(let key):
            return "SMC key '\(key)' is not present on this Mac."
        case .deviceError(let key, let code):
            return "SMC returned error \(code) while reading '\(key)'."
        case .unsupportedType(let key, let type):
            return "SMC key '\(key)' has unsupported data type '\(type)'."
        case .layoutMismatch(let detail):
            return "SMC parameter struct layout mismatch: \(detail). Refusing to talk to the SMC."
        }
    }
}

// MARK: - Kernel struct layout

/// 32 raw bytes returned by the SMC for any key.
typealias SMCBytes32 = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    /// C gives this struct three bytes of trailing padding to reach its 4-byte
    /// alignment, and the kernel's struct is laid out accordingly. Swift packs
    /// the following field at offset 9 instead unless the padding is explicit.
    private var reserved: (UInt8, UInt8, UInt8) = (0, 0, 0)
}

/// Mirrors the SMCParamStruct the AppleSMC kernel extension expects. Swift's
/// field layout happens to match C's here, but that is an assumption worth
/// checking rather than trusting — see `SMCConnection.verifyStructLayout()`.
struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes32 = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )
}

private enum SMCSelector {
    static let kernelIndex: UInt32 = 2
    static let readKey: UInt8 = 5
    static let writeKey: UInt8 = 6
    static let getKeyInfo: UInt8 = 9
    static let keyFromIndex: UInt8 = 8
}

// MARK: - Decoded value

/// A value read from the SMC, with its raw bytes preserved so unknown types can
/// still be reported in diagnostics.
public struct SMCKeyValue {
    public let key: String
    public let type: String
    public let bytes: [UInt8]
    /// Raw attribute flags the SMC reports for this key.
    ///
    /// The bit meanings are not documented by Apple. This mapping was derived on
    /// a Mac16,8 by comparing keys of known character: `FNum` (0x80) and `F0Ac`
    /// (0x84) are inherently read-only, while `F0Md` (0xd0) and `F0Tg` (0xd4)
    /// are the two the SMC accepts writes for. The 0x40 bit appears on exactly
    /// the latter pair, so 0x40 is taken to mean writable.
    public let attributes: UInt8

    public var isReadable: Bool { attributes & 0x80 != 0 }
    public var isWritable: Bool { attributes & 0x40 != 0 }

    /// Human-readable flag breakdown, for diagnostics.
    public var attributeDescription: String {
        var flags: [String] = []
        if attributes & 0x80 != 0 { flags.append("readable") }
        if attributes & 0x40 != 0 { flags.append("writable") }
        if attributes & 0x20 != 0 { flags.append("function") }
        if attributes & 0x10 != 0 { flags.append("atomic") }
        let low = attributes & 0x0f
        if low != 0 { flags.append(String(format: "low=0x%x", low)) }
        return flags.isEmpty ? "none" : flags.joined(separator: "|")
    }

    /// Numeric interpretation, or nil for types this tool does not decode.
    public var number: Double? {
        switch type {
        case "ui8 ", "si8 ":
            return bytes.count >= 1 ? Double(bytes[0]) : nil
        case "ui16":
            // SMC integers are big-endian.
            return bytes.count >= 2 ? Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) : nil
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            let v = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
                  | UInt32(bytes[2]) << 8  | UInt32(bytes[3])
            return Double(v)
        case "flt ":
            // Floats are little-endian.
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8
                     | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "fpe2":
            // Legacy fixed point: 14 integer bits, 2 fractional.
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4.0
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256.0
        default:
            return nil
        }
    }
}

// MARK: - Connection

/// A read-only connection to the System Management Controller.
///
/// Writing is deliberately absent from this type. The privileged write path is
/// added in a separate, narrowly scoped API so that no caller can construct an
/// arbitrary SMC write. See SPEC.md "Safety rules".
public final class SMCConnection: @unchecked Sendable {
    private var connection: io_connect_t = 0

    /// Reading a key is two kernel calls — fetch the key's size and type, then
    /// read that many bytes. Interleaving two of those pairs would let one read
    /// use another's size, so the pair is serialized rather than merely being
    /// documented as single-threaded.
    private let lock = NSLock()

    public init() throws {
        try Self.verifyStructLayout()

        let matching = IOServiceMatching("AppleSMC")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == kIOReturnSuccess else { throw SMCError.openFailed(result) }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    /// The kernel copies a fixed-size struct in and out. If Swift ever lays the
    /// struct out differently we would silently corrupt the request, so fail loudly.
    private static func verifyStructLayout() throws {
        let stride = MemoryLayout<SMCParamStruct>.stride
        guard stride == 80 else {
            throw SMCError.layoutMismatch("expected 80 bytes, got \(stride)")
        }

        let expected: [(String, Int, Int?)] = [
            ("key", 0, MemoryLayout<SMCParamStruct>.offset(of: \.key)),
            ("keyInfo.dataSize", 28, MemoryLayout<SMCParamStruct>.offset(of: \.keyInfo.dataSize)),
            ("keyInfo.dataType", 32, MemoryLayout<SMCParamStruct>.offset(of: \.keyInfo.dataType)),
            ("result", 40, MemoryLayout<SMCParamStruct>.offset(of: \.result)),
            ("data32", 44, MemoryLayout<SMCParamStruct>.offset(of: \.data32)),
            ("bytes", 48, MemoryLayout<SMCParamStruct>.offset(of: \.bytes)),
        ]
        for (name, want, got) in expected where got != want {
            throw SMCError.layoutMismatch(
                "field '\(name)' is at offset \(got.map(String.init) ?? "unknown"), expected \(want)"
            )
        }
    }

    private func call(_ input: inout SMCParamStruct) throws -> SMCParamStruct {
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride

        let result = IOConnectCallStructMethod(
            connection,
            SMCSelector.kernelIndex,
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outputSize
        )
        guard result == kIOReturnSuccess else { throw SMCError.callFailed(result) }
        return output
    }

    /// Read a four-character SMC key. Throws `.keyNotFound` if the key is absent
    /// on this hardware, which callers are expected to handle rather than treat
    /// as fatal — key availability varies by Mac model.
    public func read(_ key: String) throws -> SMCKeyValue {
        let keyCode = try Self.fourCharCode(key)

        lock.lock()
        defer { lock.unlock() }

        // Step 1: ask the SMC how large this key is and what type it holds.
        var infoRequest = SMCParamStruct()
        infoRequest.key = keyCode
        infoRequest.data8 = SMCSelector.getKeyInfo
        let info = try call(&infoRequest)

        if info.result == 132 { throw SMCError.keyNotFound(key) }
        guard info.result == 0 else { throw SMCError.deviceError(key, info.result) }

        // Step 2: read that many bytes.
        var readRequest = SMCParamStruct()
        readRequest.key = keyCode
        readRequest.keyInfo.dataSize = info.keyInfo.dataSize
        readRequest.data8 = SMCSelector.readKey
        let value = try call(&readRequest)

        if value.result == 132 { throw SMCError.keyNotFound(key) }
        guard value.result == 0 else { throw SMCError.deviceError(key, value.result) }

        let size = Int(info.keyInfo.dataSize)
        var raw = withUnsafeBytes(of: value.bytes) { Array($0) }
        raw = Array(raw.prefix(min(size, 32)))

        return SMCKeyValue(
            key: key,
            type: Self.string(from: info.keyInfo.dataType),
            bytes: raw,
            attributes: info.keyInfo.dataAttributes
        )
    }

    /// Convenience read returning the decoded number, or nil if absent/undecodable.
    public func readNumber(_ key: String) -> Double? {
        (try? read(key))?.number
    }

    // MARK: Enumeration

    /// Total number of keys this SMC exposes.
    public func keyCount() -> Int {
        guard let value = try? read("#KEY"), let count = value.number else { return 0 }
        return Int(count)
    }

    /// Name of the key at `index` in the SMC's own table.
    ///
    /// Used to enumerate what a machine actually offers rather than probing a
    /// hardcoded list — the point of the exercise is to find keys we do not
    /// already know about.
    public func keyName(atIndex index: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }

        var request = SMCParamStruct()
        request.data8 = SMCSelector.keyFromIndex
        request.data32 = UInt32(index)

        guard let output = try? call(&request), output.result == 0 else { return nil }
        return Self.string(from: output.key)
    }

    /// Every key the SMC reports, in table order.
    public func allKeyNames() -> [String] {
        (0..<keyCount()).compactMap { keyName(atIndex: $0) }
    }

    // MARK: Writing

    /// The only write in this codebase.
    ///
    /// The key is built here from a fan index and a fixed enum, so no caller can
    /// name an arbitrary SMC key — writing anything but `F{i}Md` / `F{i}Tg` is
    /// not expressible. Requires root.
    ///
    /// The value is encoded according to the type the SMC reports for the key,
    /// not an assumed one, so this stays correct on hardware where these keys
    /// have different representations.
    func writeFan(index: Int, field: FanWritableField, value: Double) throws {
        var key = field.key(index: index)

        // Some hardware spells the mode key differently. Rather than branching on
        // chip generation, ask the SMC which name it actually has.
        if let alternate = field.alternateKey(index: index),
           (try? read(key)) == nil,
           (try? read(alternate)) != nil {
            key = alternate
        }
        let keyCode = try Self.fourCharCode(key)

        lock.lock()
        defer { lock.unlock() }

        var infoRequest = SMCParamStruct()
        infoRequest.key = keyCode
        infoRequest.data8 = SMCSelector.getKeyInfo
        let info = try call(&infoRequest)

        if info.result == 132 { throw SMCError.keyNotFound(key) }
        guard info.result == 0 else { throw SMCError.deviceError(key, info.result) }

        let type = Self.string(from: info.keyInfo.dataType)
        let encoded = try Self.encode(value, as: type, key: key)

        var writeRequest = SMCParamStruct()
        writeRequest.key = keyCode
        writeRequest.keyInfo.dataSize = info.keyInfo.dataSize
        writeRequest.data8 = SMCSelector.writeKey
        withUnsafeMutableBytes(of: &writeRequest.bytes) { buffer in
            for (offset, byte) in encoded.enumerated() where offset < buffer.count {
                buffer[offset] = byte
            }
        }

        let result = try call(&writeRequest)
        guard result.result == 0 else {
            throw FanControlError.writeRejected(key, result.result)
        }
    }

    private static func encode(_ value: Double, as type: String, key: String) throws -> [UInt8] {
        switch type {
        case "ui8 ":
            return [UInt8(value.clamped(to: 0...255))]
        case "ui16":
            let v = UInt16(value.clamped(to: 0...65535))
            return [UInt8(v >> 8), UInt8(v & 0xff)]
        case "flt ":
            let bits = Float(value).bitPattern
            return [
                UInt8(bits & 0xff),
                UInt8((bits >> 8) & 0xff),
                UInt8((bits >> 16) & 0xff),
                UInt8((bits >> 24) & 0xff),
            ]
        default:
            throw FanControlError.unwritableType(key, type)
        }
    }

    // MARK: FourCC helpers

    static func fourCharCode(_ key: String) throws -> UInt32 {
        let chars = Array(key.utf8)
        guard chars.count == 4 else {
            throw SMCError.unsupportedType(key, "key must be exactly 4 characters")
        }
        return UInt32(chars[0]) << 24 | UInt32(chars[1]) << 16
             | UInt32(chars[2]) << 8  | UInt32(chars[3])
    }

    static func string(from code: UInt32) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff),
        ]
        return String(decoding: bytes, as: UTF8.self)
    }
}
