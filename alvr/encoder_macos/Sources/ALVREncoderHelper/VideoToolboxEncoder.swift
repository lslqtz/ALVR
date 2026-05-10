import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// VideoToolbox 硬件编码器封装
/// 支持 H.264 和 HEVC，使用 Apple Silicon 硬件加速
/// 包含完整的 ALVR 风格可调选项（码率控制、Profile、延迟、画质等）
final class VideoToolboxEncoder {
    private var compressionSession: VTCompressionSession?
    private var config: EncoderConfig
    private var frameCount: Int64 = 0

    /// 编码完成回调: (timestampNs, isIDR, nalData)
    var onEncodedPacket: ((UInt64, Bool, Data) -> Void)?

    init(config: EncoderConfig) throws {
        self.config = config
        try createSession()
        print("[Encoder] VideoToolbox initialized: \(config.width)x\(config.height), " +
              "codec=\(config.codec), bitrate=\(config.bitrateBps)bps, fps=\(config.framerate), " +
              "rc=\(config.rateControlMode), realtime=\(config.realtime)")
    }

    /// 简化初始化（向后兼容）
    convenience init(width: Int, height: Int, codec: CodecType, bitrateBps: UInt64, framerate: UInt32) throws {
        var config = EncoderConfig()
        config.width = width
        config.height = height
        config.codec = codec
        config.bitrateBps = bitrateBps
        config.framerate = framerate
        try self.init(config: config)
    }

    deinit {
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
    }

    // MARK: - Session Management

    private func createSession() throws {
        let codecType: CMVideoCodecType
        switch config.codec {
        case .h264:
            codecType = kCMVideoCodecType_H264
        case .hevc:
            codecType = kCMVideoCodecType_HEVC
        }

        let outputCallback: VTCompressionOutputCallback = { refcon, _, status, flags, sampleBuffer in
            guard let refcon = refcon else { return }
            let encoder = Unmanaged<VideoToolboxEncoder>.fromOpaque(refcon).takeUnretainedValue()
            encoder.handleEncodedFrame(status: status, flags: flags, sampleBuffer: sampleBuffer)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(config.width),
            height: Int32(config.height),
            codecType: codecType,
            encoderSpecification: nil,
            imageBufferAttributes: createPixelBufferAttributes(),
            compressedDataAllocator: nil,
            outputCallback: outputCallback,
            refcon: selfPtr,
            compressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            throw EncoderError.sessionCreationFailed(status)
        }

        configureSession(session)
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.compressionSession = session
    }

    private func createPixelBufferAttributes() -> CFDictionary {
        let pixelFormat: OSType = config.use10Bit
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_32RGBA

        let attrs: [CFString: Any] = [
            kCVPixelBufferWidthKey: config.width,
            kCVPixelBufferHeightKey: config.height,
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        return attrs as CFDictionary
    }

    private func configureSession(_ session: VTCompressionSession) {
        // ── 实时 / 延迟控制 ────────────────────────────────────────
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime,
                             value: config.realtime ? kCFBooleanTrue : kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: config.allowFrameReordering ? kCFBooleanTrue : kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowTemporalCompression,
                             value: config.allowTemporalCompression ? kCFBooleanTrue : kCFBooleanFalse)

        if config.prioritizeQualityOverSpeed {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
                                 value: kCFBooleanFalse)
        } else {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
                                 value: kCFBooleanTrue)
            
            // 极限压榨延迟 (macOS 11.3+ / iOS 14.5+)
            if #available(macOS 11.3, iOS 14.5, *) {
                let key = "EnableLowLatencyRateControl" as CFString
                VTSessionSetProperty(session, key: key, value: kCFBooleanTrue)
            }
        }

        // ── 码率控制 ─────────────────────────────────────────────
        switch config.rateControlMode {
        case .cbr:
            let bitrateNum = NSNumber(value: Int(config.bitrateBps))
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrateNum)

            // 数据速率限制: [bytes_per_second, duration_seconds]
            let bytesPerSecond = Double(config.bitrateBps) / 8.0 * config.peakBitrateRatio
            let dataRateLimit: [NSNumber] = [NSNumber(value: bytesPerSecond), NSNumber(value: 1.0)]
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                                 value: dataRateLimit as CFArray)

        case .vbr:
            let bitrateNum = NSNumber(value: Int(config.bitrateBps))
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrateNum)
            // VBR: 不设 DataRateLimits，允许峰值更高

        case .quality:
            // 质量模式: 使用 Quality 属性
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality,
                                 value: NSNumber(value: config.quality))
        }

        // ── 帧率 ────────────────────────────────────────────────
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: NSNumber(value: Int(config.framerate)))

        // ── 关键帧间隔 ──────────────────────────────────────────
        let keyframeInterval = config.effectiveKeyframeInterval
        if keyframeInterval > 0 {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                                 value: NSNumber(value: keyframeInterval))
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                                 value: NSNumber(value: config.maxKeyframeIntervalSec))
        }

        // ── Profile / Level ─────────────────────────────────────
        if config.codec == .h264 {
            let profile: CFString
            switch config.h264Profile {
            case .baseline:
                profile = kVTProfileLevel_H264_Baseline_AutoLevel
            case .main:
                profile = kVTProfileLevel_H264_Main_AutoLevel
            case .high:
                profile = kVTProfileLevel_H264_High_AutoLevel
            }
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)
        } else {
            let profile: CFString
            switch config.hevcProfile {
            case .main:
                profile = kVTProfileLevel_HEVC_Main_AutoLevel
            case .main10:
                profile = kVTProfileLevel_HEVC_Main10_AutoLevel
            }
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)
        }

        // ── 色域 ────────────────────────────────────────────────
        if config.enableHDR || config.colorSpace == .bt2020 {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries,
                                 value: kCVImageBufferColorPrimaries_ITU_R_2020)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction,
                                 value: kCVImageBufferTransferFunction_ITU_R_2100_HLG)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix,
                                 value: kCVImageBufferYCbCrMatrix_ITU_R_2020)
        } else {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries,
                                 value: kCVImageBufferColorPrimaries_ITU_R_709_2)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction,
                                 value: kCVImageBufferTransferFunction_ITU_R_709_2)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix,
                                 value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        }

        print("[Encoder] Session configured: rc=\(config.rateControlMode), " +
              "profile=\(config.codec == .h264 ? "\(config.h264Profile)" : "\(config.hevcProfile)"), " +
              "keyframeInterval=\(keyframeInterval), " +
              "reorder=\(config.allowFrameReordering), 10bit=\(config.use10Bit)")
    }

    // MARK: - Encoding

    /// 编码一帧原始像素数据
    func encodeFrame(pixelData: Data, header: FrameHeader) {
        guard let session = compressionSession else {
            print("[Encoder] No compression session")
            return
        }

        guard let pixelBuffer = createPixelBuffer(from: pixelData, header: header) else {
            print("[Encoder] Failed to create pixel buffer")
            return
        }

        let pts = CMTimeMake(value: Int64(header.timestampNs), timescale: 1_000_000_000)

        var frameProperties: [CFString: Any] = [:]
        if header.insertIDR {
            frameProperties[kVTEncodeFrameOptionKey_ForceKeyFrame] = kCFBooleanTrue
        }

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: frameProperties.isEmpty ? nil : frameProperties as CFDictionary,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )

        if status != noErr {
            print("[Encoder] Encode frame failed: \(status)")
        }

        frameCount += 1
        if frameCount % 300 == 0 {
            print("[Encoder] Encoded \(frameCount) frames")
        }
    }

    /// 动态更新编码参数（不重建 session）
    func updateParams(bitrateBps: UInt64, framerate: UInt32) {
        config.bitrateBps = bitrateBps
        config.framerate = framerate

        guard let session = compressionSession else { return }

        let bitrateNum = NSNumber(value: Int(bitrateBps))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrateNum)

        if config.rateControlMode == .cbr {
            let bytesPerSecond = Double(bitrateBps) / 8.0 * config.peakBitrateRatio
            let dataRateLimit: [NSNumber] = [NSNumber(value: bytesPerSecond), NSNumber(value: 1.0)]
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                                 value: dataRateLimit as CFArray)
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: NSNumber(value: Int(framerate)))

        print("[Encoder] Updated: bitrate=\(bitrateBps)bps, fps=\(framerate)")
    }

    /// 使用完整配置重建 session（Profile、色域等变更需要重建）
    func reconfigure(with newConfig: EncoderConfig) throws {
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
        config = newConfig
        try createSession()
        print("[Encoder] Reconfigured with new settings")
    }

    // MARK: - Pixel Buffer Creation

    private func createPixelBuffer(from data: Data, header: FrameHeader) -> CVPixelBuffer? {
        let pixelFormat: OSType
        switch header.pixelFormat {
        case .nv12:
            pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .p010:
            pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case .rgba:
            pixelFormat = kCVPixelFormatType_32RGBA
        }

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(header.width), Int(header.height),
            pixelFormat, nil, &pixelBuffer
        )

        guard status == kCVReturnSuccess, let pb = pixelBuffer else {
            print("[Encoder] CVPixelBufferCreate failed: \(status)")
            return nil
        }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        if header.pixelFormat == .nv12 || header.pixelFormat == .p010 {
            copyPlanarData(to: pb, from: data, header: header)
        } else {
            if let baseAddress = CVPixelBufferGetBaseAddress(pb) {
                let dstRowBytes = CVPixelBufferGetBytesPerRow(pb)
                let srcRowPitch = Int(header.rowPitch)
                let copyWidth = min(dstRowBytes, srcRowPitch)

                data.withUnsafeBytes { srcPtr in
                    guard let src = srcPtr.baseAddress else { return }
                    for row in 0..<Int(header.height) {
                        let srcOffset = row * srcRowPitch
                        let dstOffset = row * dstRowBytes
                        guard srcOffset + copyWidth <= data.count else { break }
                        memcpy(baseAddress + dstOffset, src + srcOffset, copyWidth)
                    }
                }
            }
        }

        return pb
    }

    private func copyPlanarData(to pb: CVPixelBuffer, from data: Data, header: FrameHeader) {
        let planeCount = CVPixelBufferGetPlaneCount(pb)
        guard planeCount >= 2 else { return }

        let srcRowPitch = Int(header.rowPitch)
        let h = Int(header.height)

        data.withUnsafeBytes { srcPtr in
            guard let src = srcPtr.baseAddress else { return }

            if let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
                let yRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
                let copyWidth = min(yRowBytes, srcRowPitch)
                for row in 0..<h {
                    memcpy(yBase + row * yRowBytes, src + row * srcRowPitch, copyWidth)
                }
            }

            if let uvBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
                let uvRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
                let uvOffset = h * srcRowPitch
                let copyWidth = min(uvRowBytes, srcRowPitch)
                for row in 0..<(h / 2) {
                    let srcOff = uvOffset + row * srcRowPitch
                    guard srcOff + copyWidth <= data.count else { break }
                    memcpy(uvBase + row * uvRowBytes, src + srcOff, copyWidth)
                }
            }
        }
    }

    // MARK: - Output Callback

    private func handleEncodedFrame(status: OSStatus, flags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
        guard status == noErr else {
            print("[Encoder] Encode callback error: \(status)")
            return
        }
        guard let sampleBuffer = sampleBuffer else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestampNs = UInt64(CMTimeGetSeconds(pts) * 1_000_000_000)

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        var isIDR = true
        if let attachments = attachments, CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
            if CFDictionaryGetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()) != nil {
                isIDR = false
            }
        }

        guard let nalData = extractNALData(from: sampleBuffer, isIDR: isIDR) else {
            print("[Encoder] Failed to extract NAL data")
            return
        }

        onEncodedPacket?(timestampNs, isIDR, nalData)
    }

    /// 从 CMSampleBuffer 提取 Annex-B 格式的 NAL 单元
    private func extractNALData(from sampleBuffer: CMSampleBuffer, isIDR: Bool) -> Data? {
        var nalData = Data()

        if isIDR {
            guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else {
                return nil
            }

            if config.codec == .h264 {
                var spsSize: Int = 0, spsCount: Int = 0
                var spsPtr: UnsafePointer<UInt8>?
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDesc, parameterSetIndex: 0,
                    parameterSetPointerOut: &spsPtr, parameterSetSizeOut: &spsSize,
                    parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: nil
                )
                if let sps = spsPtr {
                    nalData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                    nalData.append(sps, count: spsSize)
                }

                var ppsSize: Int = 0
                var ppsPtr: UnsafePointer<UInt8>?
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDesc, parameterSetIndex: 1,
                    parameterSetPointerOut: &ppsPtr, parameterSetSizeOut: &ppsSize,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                )
                if let pps = ppsPtr {
                    nalData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                    nalData.append(pps, count: ppsSize)
                }
            } else {
                for i in 0..<3 {
                    var paramSize: Int = 0
                    var paramPtr: UnsafePointer<UInt8>?
                    let s = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                        formatDesc, parameterSetIndex: i,
                        parameterSetPointerOut: &paramPtr, parameterSetSizeOut: &paramSize,
                        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                    )
                    if s == noErr, let ptr = paramPtr {
                        nalData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                        nalData.append(ptr, count: paramSize)
                    }
                }
            }
        }

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nalData.isEmpty ? nil : nalData
        }

        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength, dataPointerOut: &dataPointer
        )

        guard status == kCMBlockBufferNoErr, let ptr = dataPointer else {
            return nalData.isEmpty ? nil : nalData
        }

        var offset = 0
        while offset < totalLength - 4 {
            var nalLength: UInt32 = 0
            memcpy(&nalLength, ptr + offset, 4)
            nalLength = nalLength.bigEndian
            offset += 4

            guard offset + Int(nalLength) <= totalLength else { break }

            nalData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            nalData.append(UnsafeBufferPointer(
                start: UnsafeRawPointer(ptr + offset).assumingMemoryBound(to: UInt8.self),
                count: Int(nalLength)
            ))
            offset += Int(nalLength)
        }

        return nalData.isEmpty ? nil : nalData
    }
}

// MARK: - Errors

enum EncoderError: Error, CustomStringConvertible {
    case sessionCreationFailed(OSStatus)

    var description: String {
        switch self {
        case .sessionCreationFailed(let status):
            return "VTCompressionSession creation failed: \(status)"
        }
    }
}
