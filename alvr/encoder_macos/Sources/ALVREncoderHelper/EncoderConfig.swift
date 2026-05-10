import Foundation

// MARK: - Encoder Quality/Latency Configuration

/// 编码器配置，对齐 ALVR 的 NVENC/AMF 风格选项
struct EncoderConfig {
    // MARK: 基础参数
    var width: Int = 1920
    var height: Int = 1080
    var codec: CodecType = .h264
    var bitrateBps: UInt64 = 30_000_000
    var framerate: UInt32 = 72

    // MARK: 码率控制
    var rateControlMode: RateControlMode = .cbr
    /// 数据速率上限相对于平均码率的倍率 (1.0 = 无余量, 2.0 = 2x 峰值)
    var peakBitrateRatio: Double = 1.5

    // MARK: Profile / Level
    var h264Profile: H264Profile = .high
    var hevcProfile: HEVCProfile = .main

    // MARK: 关键帧
    /// 最大关键帧间隔 (秒)。0 = 编码器自动决定
    var maxKeyframeIntervalSec: Double = 2.0
    /// 最大关键帧间隔 (帧数)。0 = 由 maxKeyframeIntervalSec 计算
    var maxKeyframeIntervalFrames: Int = 0

    // MARK: 延迟控制
    /// 是否启用实时编码模式 (降低延迟，可能牺牲压缩效率)
    var realtime: Bool = true
    /// 是否允许帧重排序 (B 帧)。false = 最低延迟
    var allowFrameReordering: Bool = false
    /// 是否允许临时编码层（SVC temporal layers）
    var allowTemporalCompression: Bool = false
    /// 是否启用 macOS 11.3+ 低延迟速率控制
    var enableLowLatencyRateControl: Bool = true

    // MARK: 画质
    /// 编码质量 (0.0-1.0)，仅在 VBR/Quality 模式下生效。
    /// 0.0 = 最低质量最高速度, 1.0 = 最高质量
    var quality: Double = 0.5
    /// 是否优先保证画质稳定性 (以较高延迟为代价)
    var prioritizeQualityOverSpeed: Bool = false

    // MARK: 高级
    /// 10-bit 编码 (需要硬件支持)
    var use10Bit: Bool = false
    /// 是否开启 HDR
    var enableHDR: Bool = false
    /// 目标色域
    var colorSpace: ColorSpaceConfig = .bt709

    // MARK: - Serialization

    static let binarySize = 64  // 足够容纳所有字段

    static func decode(from data: Data) -> EncoderConfig? {
        guard data.count >= binarySize else { return nil }
        var config = EncoderConfig()
        var offset = 0

        config.width = Int(data.readUInt32(at: &offset))
        config.height = Int(data.readUInt32(at: &offset))
        config.codec = CodecType(rawValue: data[offset]) ?? .h264; offset += 1
        config.bitrateBps = data.readUInt64(at: &offset)
        config.framerate = data.readUInt32(at: &offset)

        // 码率控制
        config.rateControlMode = RateControlMode(rawValue: data[offset]) ?? .cbr; offset += 1

        // Profile
        config.h264Profile = H264Profile(rawValue: data[offset]) ?? .high; offset += 1
        config.hevcProfile = HEVCProfile(rawValue: data[offset]) ?? .main; offset += 1

        // 关键帧
        config.maxKeyframeIntervalFrames = Int(data.readUInt32(at: &offset))

        // 延迟/画质标志位 (packed into one byte)
        let flags = data[offset]; offset += 1
        config.realtime = (flags & 0x01) != 0
        config.allowFrameReordering = (flags & 0x02) != 0
        config.use10Bit = (flags & 0x04) != 0
        config.enableHDR = (flags & 0x08) != 0
        config.prioritizeQualityOverSpeed = (flags & 0x10) != 0
        config.allowTemporalCompression = (flags & 0x20) != 0
        config.enableLowLatencyRateControl = (flags & 0x40) != 0

        // 画质 (uint8 0-100 → 0.0-1.0)
        config.quality = Double(data[offset]) / 100.0; offset += 1

        // 色域
        config.colorSpace = ColorSpaceConfig(rawValue: data[offset]) ?? .bt709; offset += 1

        return config
    }

    /// 根据帧率计算关键帧间隔（帧数）
    var effectiveKeyframeInterval: Int {
        if maxKeyframeIntervalFrames > 0 {
            return maxKeyframeIntervalFrames
        }
        return Int(Double(framerate) * maxKeyframeIntervalSec)
    }
}

// MARK: - Option Enums

enum RateControlMode: UInt8 {
    case cbr = 0        // 恒定码率
    case vbr = 1        // 可变码率
    case quality = 2    // 质量优先 (CRF-like)
}

enum H264Profile: UInt8 {
    case baseline = 0
    case main = 1
    case high = 2
}

enum HEVCProfile: UInt8 {
    case main = 0
    case main10 = 1
}

enum ColorSpaceConfig: UInt8 {
    case bt709 = 0      // SDR
    case bt2020 = 1     // HDR
}
