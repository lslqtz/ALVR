import Foundation

// MARK: - Message Types

/// 协议消息类型，与 Windows 端 C++ 一一对应
enum MessageType: UInt32 {
    case initialize      = 0x01
    case initializeAck   = 0x02
    case frame           = 0x03
    case packet          = 0x04
    case updateParams    = 0x05
    case shutdown        = 0x06
}

/// 像素格式，与 ALVR Arm64EncoderIpc::PixelFormat 对齐
enum PixelFormat: UInt8 {
    case rgba = 0
    case nv12 = 1
    case p010 = 2
}

/// 编码器类型
enum CodecType: UInt8 {
    case h264 = 0
    case hevc = 1
}

// MARK: - Message Structs

/// 初始化请求 (VM → Mac)
struct InitMessage {
    let width: UInt32
    let height: UInt32
    let codec: CodecType
    let bitrateBps: UInt64
    let framerate: UInt32

    static let bodySize = 4 + 4 + 1 + 8 + 4  // 21 bytes

    static func decode(from data: Data) -> InitMessage? {
        guard data.count >= bodySize else { return nil }
        var offset = 0

        let width = data.readUInt32(at: &offset)
        let height = data.readUInt32(at: &offset)
        let codecRaw = data[offset]; offset += 1
        let codec = CodecType(rawValue: codecRaw) ?? .h264
        let bitrate = data.readUInt64(at: &offset)
        let framerate = data.readUInt32(at: &offset)

        return InitMessage(
            width: width, height: height,
            codec: codec, bitrateBps: bitrate, framerate: framerate
        )
    }
}

/// 初始化响应 (Mac → VM)
struct InitAckMessage {
    let success: Bool
    let message: String

    func encode() -> Data {
        let msgData = message.data(using: .utf8) ?? Data()
        var data = Data()
        // Header: type + total_len
        data.appendUInt32(MessageType.initializeAck.rawValue)
        let bodyLen = 1 + 4 + msgData.count
        data.appendUInt32(UInt32(bodyLen))
        // Body
        data.append(success ? 1 : 0)
        data.appendUInt32(UInt32(msgData.count))
        data.append(msgData)
        return data
    }
}

/// 帧数据头 (VM → Mac)，后面跟着像素数据
struct FrameHeader {
    let width: UInt32
    let height: UInt32
    let rowPitch: UInt32
    let timestampNs: UInt64
    let insertIDR: Bool
    let pixelFormat: PixelFormat
    let dataSize: UInt32

    static let bodySize = 4 + 4 + 4 + 8 + 1 + 1 + 4  // 26 bytes

    static func decode(from data: Data) -> FrameHeader? {
        guard data.count >= bodySize else { return nil }
        var offset = 0

        let width = data.readUInt32(at: &offset)
        let height = data.readUInt32(at: &offset)
        let rowPitch = data.readUInt32(at: &offset)
        let timestampNs = data.readUInt64(at: &offset)
        let insertIDR = data[offset] != 0; offset += 1
        let pixelFormatRaw = data[offset]; offset += 1
        let pixelFormat = PixelFormat(rawValue: pixelFormatRaw) ?? .rgba
        let dataSize = data.readUInt32(at: &offset)

        return FrameHeader(
            width: width, height: height, rowPitch: rowPitch,
            timestampNs: timestampNs, insertIDR: insertIDR,
            pixelFormat: pixelFormat, dataSize: dataSize
        )
    }
}

/// 编码后的 NAL 数据包 (Mac → VM)
struct EncodedPacket {
    let timestampNs: UInt64
    let isIDR: Bool
    let data: Data

    func encode() -> Data {
        var msg = Data()
        // Header
        msg.appendUInt32(MessageType.packet.rawValue)
        let bodyLen = 8 + 1 + 4 + data.count
        msg.appendUInt32(UInt32(bodyLen))
        // Body
        msg.appendUInt64(timestampNs)
        msg.append(isIDR ? 1 : 0)
        msg.appendUInt32(UInt32(data.count))
        msg.append(data)
        return msg
    }
}

/// 动态参数更新 (VM → Mac)
struct UpdateParamsMessage {
    let bitrateBps: UInt64
    let framerate: UInt32

    static let bodySize = 8 + 4  // 12 bytes

    static func decode(from data: Data) -> UpdateParamsMessage? {
        guard data.count >= bodySize else { return nil }
        var offset = 0
        let bitrate = data.readUInt64(at: &offset)
        let framerate = data.readUInt32(at: &offset)
        return UpdateParamsMessage(bitrateBps: bitrate, framerate: framerate)
    }
}

// MARK: - Data Extensions for Binary I/O

extension Data {
    func readUInt32(at offset: inout Int) -> UInt32 {
        let value = self.subdata(in: offset..<offset+4)
            .withUnsafeBytes { $0.load(as: UInt32.self) }
        offset += 4
        return UInt32(littleEndian: value)
    }

    func readUInt64(at offset: inout Int) -> UInt64 {
        let value = self.subdata(in: offset..<offset+8)
            .withUnsafeBytes { $0.load(as: UInt64.self) }
        offset += 8
        return UInt64(littleEndian: value)
    }

    mutating func appendUInt32(_ value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendUInt64(_ value: UInt64) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
