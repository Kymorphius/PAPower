import Foundation
import IOKit

private enum SMCCommand: UInt8 {
    case readBytes = 5
    case readKeyInfo = 9
}

private struct SMCKeyData {
    typealias Bytes = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    struct PowerLimit {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpu: UInt32 = 0
        var gpu: UInt32 = 0
        var memory: UInt32 = 0
    }

    struct KeyInfo {
        var dataSize: IOByteCount32 = 0
        var dataType: UInt32 = 0
        var attributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var version = Version()
    var powerLimit = PowerLimit()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var command: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}

final class SMCClient {
    private static let userClientMethodIndex: UInt32 = 2

    private var connection: io_connect_t = 0
    private(set) var connectionError: String?

    init() {
        guard let matching = IOServiceMatching("AppleSMC") else {
            connectionError = "找不到 AppleSMC 匹配字典"
            return
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else {
            connectionError = "此 Mac 没有暴露 AppleSMC 服务"
            return
        }
        defer { IOObjectRelease(service) }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == kIOReturnSuccess else {
            connection = 0
            connectionError = "无法打开 AppleSMC（错误 \(result)）"
            return
        }
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    func readDouble(_ key: String) -> Double? {
        guard connection != 0, key.utf8.count == 4 else { return nil }

        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = fourCharacterCode(key)
        input.command = SMCCommand.readKeyInfo.rawValue

        guard call(input: &input, output: &output) == kIOReturnSuccess else {
            return nil
        }

        let dataSize = Int(output.keyInfo.dataSize)
        guard dataSize > 0, dataSize <= 32 else { return nil }

        let dataType = fourCharacterString(output.keyInfo.dataType)
        input.keyInfo.dataSize = output.keyInfo.dataSize
        input.command = SMCCommand.readBytes.rawValue

        guard call(input: &input, output: &output) == kIOReturnSuccess else {
            return nil
        }

        let bytes = withUnsafeBytes(of: &output.bytes) { rawBuffer in
            Array(rawBuffer.prefix(dataSize))
        }
        return decode(bytes: bytes, dataType: dataType)
    }

    private func call(input: inout SMCKeyData, output: inout SMCKeyData) -> kern_return_t {
        let inputSize = MemoryLayout<SMCKeyData>.stride
        var outputSize = MemoryLayout<SMCKeyData>.stride

        return IOConnectCallStructMethod(
            connection,
            Self.userClientMethodIndex,
            &input,
            inputSize,
            &output,
            &outputSize
        )
    }

    private func decode(bytes: [UInt8], dataType: String) -> Double? {
        switch dataType {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0])
                | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16
                | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))

        case "sp78":
            guard bytes.count >= 2 else { return nil }
            let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            return Double(Int16(bitPattern: raw)) / 256.0

        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            return Double(raw) / 4.0

        case "ui8 ":
            return bytes.first.map(Double.init)

        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))

        case "ui32":
            guard bytes.count >= 4 else { return nil }
            let raw = UInt32(bytes[0]) << 24
                | UInt32(bytes[1]) << 16
                | UInt32(bytes[2]) << 8
                | UInt32(bytes[3])
            return Double(raw)

        default:
            return nil
        }
    }

    private func fourCharacterCode(_ value: String) -> UInt32 {
        value.utf8.reduce(0) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
    }

    private func fourCharacterString(_ value: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}
