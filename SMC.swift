import Foundation
import IOKit

// ============================================================
//  SMC 直读电池遥测
//
//  背景：AppleSmartBattery 的 registry 属性实测每 8~17 秒才刷新一次，
//        而 SMC 通道（B0AC 电池电流 / B0AV 电池电压）约 1 秒刷新，
//        这正是 AlDente 一类工具的做法。
//
//  协议要点（Apple Silicon，已实测验证）：
//    · 服务名 "AppleSMC"，IOServiceOpen 无需 root（写才需要）
//    · selector = 2（kSMCHandleYPCEvent）
//    · SMCKeyData 结构 80 字节：
//        [0..3]   key      —— 必须按「反序」写入字节
//        [28..31] dataSize —— 小端 UInt32
//        [32..35] dataType —— char[4]
//        [42]     data8    —— 命令（5=读数据, 8=读索引, 9=读 key 信息）
//        [44..47] data32   —— 小端 UInt32（读索引时放索引号）
//        [48..79] bytes    —— 32 字节数据区
//    · 结果字节 [40]：0=成功，0x84=keyNotFound
// ============================================================

final class SMC {

    struct KeyInfo {
        var size: UInt32
        var type: String
    }

    private var conn: io_connect_t = 0
    private var infoCache: [String: KeyInfo] = [:]

    private let cmdReadBytes: UInt8 = 5
    private let cmdReadIndex: UInt8 = 8
    private let cmdReadKeyInfo: UInt8 = 9
    private let selector: UInt32 = 2

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return nil }
    }

    deinit { IOServiceClose(conn) }

    // ---------- 底层 ----------

    private func call(_ input: inout [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: 80)
        var outSize = 80
        let result = input.withUnsafeBytes { inBuffer in
            output.withUnsafeMutableBytes { outBuffer in
                IOConnectCallStructMethod(conn, selector, inBuffer.baseAddress, input.count,
                                          outBuffer.baseAddress, &outSize)
            }
        }
        guard result == KERN_SUCCESS, outSize == 80 else { return nil }
        return output
    }

    /// key 需要反序写入（实测确认）
    private func fillKey(_ input: inout [UInt8], _ key: String) {
        var b = Array(key.utf8)
        while b.count < 4 { b.append(0x20) }
        b.reverse()
        input[0] = b[0]; input[1] = b[1]; input[2] = b[2]; input[3] = b[3]
    }

    private func putU32(_ b: inout [UInt8], _ off: Int, _ v: UInt32) {
        b[off]     = UInt8(v & 0xFF)
        b[off + 1] = UInt8((v >> 8) & 0xFF)
        b[off + 2] = UInt8((v >> 16) & 0xFF)
        b[off + 3] = UInt8((v >> 24) & 0xFF)
    }

    private func getU32(_ b: [UInt8], _ off: Int) -> UInt32 {
        UInt32(b[off]) | UInt32(b[off + 1]) << 8
        | UInt32(b[off + 2]) << 16 | UInt32(b[off + 3]) << 24
    }

    // ---------- 对外 ----------

    func keyInfo(_ key: String) -> KeyInfo? {
        if let cached = infoCache[key] { return cached }
        guard key.utf8.count == 4 else { return nil }
        var input = [UInt8](repeating: 0, count: 80)
        fillKey(&input, key)
        input[42] = cmdReadKeyInfo
        guard let out = call(&input), out[40] == 0 else { return nil }

        let size = getU32(out, 28)
        let t = getU32(out, 32)
        let type = String(bytes: [UInt8((t >> 24) & 0xFF), UInt8((t >> 16) & 0xFF),
                                  UInt8((t >> 8) & 0xFF), UInt8(t & 0xFF)],
                          encoding: .ascii) ?? "????"
        guard size > 0, size <= 32 else { return nil }
        let info = KeyInfo(size: size, type: type)
        infoCache[key] = info
        return info
    }

    /// 读原始字节
    func read(_ key: String) -> (bytes: [UInt8], type: String)? {
        guard let info = keyInfo(key) else { return nil }
        guard key.utf8.count == 4 else { return nil }
        var input = [UInt8](repeating: 0, count: 80)
        fillKey(&input, key)
        putU32(&input, 28, info.size)
        input[42] = cmdReadBytes
        guard let out = call(&input), out[40] == 0 else { return nil }
        return (Array(out[48..<(48 + Int(info.size))]), info.type)
    }

    /// 读数值（自动按 SMC 数据类型解码）
    func readNumber(_ key: String) -> Double? {
        guard let r = read(key) else { return nil }
        guard let number = SMC.decode(r.bytes, r.type), number.isFinite else { return nil }
        return number
    }

    /// 枚举第 index 个 key（调试用）
    func keyAt(_ index: UInt32) -> String? {
        var input = [UInt8](repeating: 0, count: 80)
        putU32(&input, 44, index)
        input[42] = cmdReadIndex
        guard let out = call(&input), out[40] == 0 else { return nil }
        let b: [UInt8] = [out[3], out[2], out[1], out[0]]
        guard b.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        return String(bytes: b, encoding: .ascii)
    }

    /// Apple Silicon 的整数/float 通道按小端解码；sp78 固定点按 SMC 大端格式。
    static func decode(_ b: [UInt8], _ type: String) -> Double? {
        switch type {
        case "si16":
            guard b.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(b[0]) | UInt16(b[1]) << 8))
        case "ui16":
            guard b.count >= 2 else { return nil }
            return Double(UInt16(b[0]) | UInt16(b[1]) << 8)
        case "si8 ":
            return b.first.map { Double(Int8(bitPattern: $0)) }
        case "ui8 ":
            return b.first.map { Double($0) }
        case "ui32":
            guard b.count >= 4 else { return nil }
            return Double(UInt32(b[0]) | UInt32(b[1]) << 8
                        | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
        case "sp78":
            guard b.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256.0
        case "flt ":
            guard b.count >= 4 else { return nil }
            let bits = UInt32(b[0]) | UInt32(b[1]) << 8
                     | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            return Double(Float(bitPattern: bits))
        default:
            return nil
        }
    }
}
