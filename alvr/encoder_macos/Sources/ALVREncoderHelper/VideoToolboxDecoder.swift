import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// VideoToolbox 硬件解码器封装
/// 支持 H.264 和 HEVC 硬件解码
final class VideoToolboxDecoder {
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private let codec: CodecType
    private var frameCount: Int64 = 0

    /// 解码完成回调: (timestampNs, pixelBuffer)
    var onDecodedFrame: ((UInt64, CVPixelBuffer) -> Void)?

    init(codec: CodecType) {
        self.codec = codec
        print("[Decoder] VideoToolbox decoder created for codec: \(codec)")
    }

    deinit {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
    }

    // MARK: - Decoding

    /// 解码一个 NAL 数据包（Annex-B 格式）
    func decodeNAL(data: Data, timestampNs: UInt64, isIDR: Bool) {
        // 将 Annex-B 格式转为 AVCC 格式
        let (parameterSets, nalUnits) = parseAnnexB(data)

        // 如果是关键帧且有参数集，重建 format description
        if isIDR && !parameterSets.isEmpty {
            rebuildFormatDescription(parameterSets: parameterSets)
        }

        guard let formatDesc = formatDescription else {
            print("[Decoder] No format description available, waiting for IDR frame")
            return
        }

        // 解码每个 NAL 单元
        for nalUnit in nalUnits {
            decodeNALUnit(nalUnit, formatDescription: formatDesc, timestampNs: timestampNs)
        }
    }

    // MARK: - Session Management

    private func rebuildFormatDescription(parameterSets: [[UInt8]]) {
        // 释放旧 session
        if let session = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }

        // 创建 format description
        var formatDesc: CMVideoFormatDescription?
        let status: OSStatus

        let paramPtrs = parameterSets.map { $0.withUnsafeBufferPointer { $0.baseAddress! } }
        let paramSizes = parameterSets.map { $0.count }

        if codec == .h264 {
            status = paramPtrs.withUnsafeBufferPointer { ptrs in
                paramSizes.withUnsafeBufferPointer { sizes in
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: parameterSets.count,
                        parameterSetPointers: ptrs.baseAddress!,
                        parameterSetSizes: sizes.baseAddress!,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &formatDesc
                    )
                }
            }
        } else {
            status = paramPtrs.withUnsafeBufferPointer { ptrs in
                paramSizes.withUnsafeBufferPointer { sizes in
                    CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: parameterSets.count,
                        parameterSetPointers: ptrs.baseAddress!,
                        parameterSetSizes: sizes.baseAddress!,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &formatDesc
                    )
                }
            }
        }

        guard status == noErr, let desc = formatDesc else {
            print("[Decoder] Failed to create format description: \(status)")
            return
        }

        self.formatDescription = desc
        createDecompressionSession(formatDescription: desc)
    }

    private func createDecompressionSession(formatDescription: CMVideoFormatDescription) {
        let outputCallback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refcon, _, status, _, imageBuffer, pts, _ in
                guard let refcon = refcon else { return }
                let decoder = Unmanaged<VideoToolboxDecoder>.fromOpaque(refcon).takeUnretainedValue()
                decoder.handleDecodedFrame(status: status, imageBuffer: imageBuffer, pts: pts)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        let destinationAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]

        var callback = outputCallback
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: destinationAttrs as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &session
        )

        guard status == noErr, let sess = session else {
            print("[Decoder] Failed to create decompression session: \(status)")
            return
        }

        // 实时解码模式
        VTSessionSetProperty(sess, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        self.decompressionSession = sess
        print("[Decoder] Decompression session created")
    }

    // MARK: - NAL Unit Decoding

    private func decodeNALUnit(_ nalData: [UInt8], formatDescription: CMVideoFormatDescription, timestampNs: UInt64) {
        guard let session = decompressionSession else { return }

        // 构造 AVCC 格式: [4B length][NAL data]
        var avccData = [UInt8](repeating: 0, count: 4 + nalData.count)
        let nalLength = UInt32(nalData.count).bigEndian
        withUnsafeBytes(of: nalLength) { avccData.replaceSubrange(0..<4, with: $0) }
        avccData.replaceSubrange(4..<4+nalData.count, with: nalData)

        // 创建 CMBlockBuffer
        var blockBuffer: CMBlockBuffer?
        let _ = avccData.withUnsafeMutableBufferPointer { bufPtr in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: bufPtr.baseAddress,
                blockLength: bufPtr.count,
                blockAllocator: kCFAllocatorNull,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: bufPtr.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }

        guard let bb = blockBuffer else { return }

        // 创建 CMSampleBuffer
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = avccData.count
        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard let sb = sampleBuffer else { return }

        // 异步解码
        let flags = VTDecodeFrameFlags._EnableAsynchronousDecompression
        var infoFlags = VTDecodeInfoFlags()

        VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sb,
            flags: flags,
            frameRefcon: UnsafeMutableRawPointer(bitPattern: UInt(timestampNs)),
            infoFlagsOut: &infoFlags
        )

        frameCount += 1
    }

    private func handleDecodedFrame(status: OSStatus, imageBuffer: CVImageBuffer?, pts: CMTime) {
        guard status == noErr else {
            print("[Decoder] Decode error: \(status)")
            return
        }
        guard let pixelBuffer = imageBuffer else { return }

        let timestampNs = UInt64(CMTimeGetSeconds(pts) * 1_000_000_000)
        onDecodedFrame?(timestampNs, pixelBuffer)
    }

    // MARK: - Annex-B Parsing

    /// 解析 Annex-B 格式，分离出参数集和 NAL 单元
    private func parseAnnexB(_ data: Data) -> (parameterSets: [[UInt8]], nalUnits: [[UInt8]]) {
        var parameterSets: [[UInt8]] = []
        var nalUnits: [[UInt8]] = []

        let bytes = [UInt8](data)
        var i = 0

        while i < bytes.count {
            // 查找起始码 0x00 0x00 0x00 0x01 或 0x00 0x00 0x01
            var startCodeLen = 0
            if i + 3 < bytes.count && bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 0 && bytes[i+3] == 1 {
                startCodeLen = 4
            } else if i + 2 < bytes.count && bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 1 {
                startCodeLen = 3
            } else {
                i += 1
                continue
            }

            let nalStart = i + startCodeLen

            // 查找下一个起始码
            var nalEnd = bytes.count
            var j = nalStart + 1
            while j < bytes.count - 2 {
                if bytes[j] == 0 && bytes[j+1] == 0 {
                    if j + 2 < bytes.count && bytes[j+2] == 1 {
                        nalEnd = j
                        break
                    }
                    if j + 3 < bytes.count && bytes[j+2] == 0 && bytes[j+3] == 1 {
                        nalEnd = j
                        break
                    }
                }
                j += 1
            }

            let nalData = Array(bytes[nalStart..<nalEnd])
            if !nalData.isEmpty {
                let nalType = isParameterSet(nalData)
                if nalType {
                    parameterSets.append(nalData)
                } else {
                    nalUnits.append(nalData)
                }
            }

            i = nalEnd
        }

        return (parameterSets, nalUnits)
    }

    /// 判断 NAL 单元是否为参数集 (SPS/PPS/VPS)
    private func isParameterSet(_ nal: [UInt8]) -> Bool {
        guard !nal.isEmpty else { return false }

        if codec == .h264 {
            let nalType = nal[0] & 0x1F
            return nalType == 7 || nalType == 8  // SPS=7, PPS=8
        } else {
            let nalType = (nal[0] >> 1) & 0x3F
            return nalType == 32 || nalType == 33 || nalType == 34  // VPS=32, SPS=33, PPS=34
        }
    }
}
