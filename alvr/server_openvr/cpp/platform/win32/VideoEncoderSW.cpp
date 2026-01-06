#ifdef ALVR_GPL

#include "VideoEncoderSW.h"

#include "alvr_server/Logger.h"
#include "alvr_server/Settings.h"
#include "alvr_server/Utils.h"

#include <algorithm>
#include <array>
#include <iostream>
#include <string>

VideoEncoderSW::VideoEncoderSW(std::shared_ptr<CD3DRender> d3dRender, int width, int height)
    : m_d3dRender(d3dRender)
    , m_codec(ALVR_CODEC_H264)
    , m_refreshRate(Settings::Instance().m_refreshRate)
    , m_renderWidth(width)
    , m_renderHeight(height)
    , m_bitrateInMBits(30) {
    // #ifdef ALVR_DEBUG_LOG
    //     av_log_set_level(AV_LOG_DEBUG);
    //     av_log_set_callback(LibVALog);
    //     Debug("Set FFMPEG/LibAV to debug logging");
    // #endif
}

VideoEncoderSW::~VideoEncoderSW() { }

void VideoEncoderSW::LibVALog(void* v, int level, const char* data, va_list va) {
    const char* prefix = "[libav]: ";
    std::stringstream sstream;
    sstream << prefix << data;
    vprintf(sstream.str().c_str(), va);
}

void VideoEncoderSW::Initialize() {
    int err;
    Debug("Initializing VideoEncoderSW.\n");

    // 尝试使用 ARM64 编码器（仅在 Windows on ARM 上）
    if (TryInitArm64Encoder()) {
        // ARM64 编码器初始化成功，不需要初始化内置 FFmpeg
        return;
    }

    const auto& settings = Settings::Instance();

    // Query codec
    AVCodecID codecId = ToFFMPEGCodec(m_codec);
    if (!codecId)
        throw MakeException("Invalid requested codec %d", m_codec);

    const AVCodec* codec = avcodec_find_encoder(codecId);
    if (codec == NULL)
        throw MakeException("Could not find codec id %d", codecId);

    // Initialize CodecContext
    m_codecContext = avcodec_alloc_context3(codec);
    if (m_codecContext == NULL)
        throw MakeException("Failed to allocate encoder id %d", codecId);

    // Set codec settings
    AVDictionary* opt = NULL;
    av_dict_set(&opt, "preset", "ultrafast", 0);
    av_dict_set(&opt, "tune", "zerolatency", 0);

    switch (settings.m_h264Profile) {
    case ALVR_H264_PROFILE_BASELINE:
        m_codecContext->profile = FF_PROFILE_H264_BASELINE;
        break;
    case ALVR_H264_PROFILE_MAIN:
        m_codecContext->profile = FF_PROFILE_H264_MAIN;
        break;
    default:
    case ALVR_H264_PROFILE_HIGH:
        m_codecContext->profile = FF_PROFILE_H264_HIGH;
        break;
    }
    switch (settings.m_entropyCoding) {
    case ALVR_CABAC:
        av_dict_set(&opt, "coder", "ac", 0);
        break;
    case ALVR_CAVLC:
        av_dict_set(&opt, "coder", "vlc", 0);
        break;
    }

    m_codecContext->width = m_renderWidth;
    m_codecContext->height = m_renderHeight;
    m_codecContext->time_base = AVRational { 1, (int)(1e9) };
    m_codecContext->framerate = AVRational { settings.m_refreshRate, 1 };
    m_codecContext->sample_aspect_ratio = AVRational { 1, 1 };
    m_codecContext->pix_fmt
        = settings.m_use10bitEncoder ? AV_PIX_FMT_YUV420P10 : AV_PIX_FMT_YUV420P;
    m_codecContext->color_range = AVCOL_RANGE_JPEG;
    if (settings.m_enableHdr) {
        m_codecContext->color_primaries = AVCOL_PRI_BT2020;
        m_codecContext->color_trc = AVCOL_TRC_GAMMA22;
        m_codecContext->colorspace = AVCOL_SPC_BT2020_NCL;
    } else {
        m_codecContext->color_primaries = AVCOL_PRI_BT709;
        m_codecContext->color_trc = AVCOL_TRC_GAMMA22;
        m_codecContext->colorspace = AVCOL_SPC_BT709;
    }
    m_codecContext->max_b_frames = 0;
    m_codecContext->gop_size = 0;
    m_codecContext->bit_rate = m_bitrateInMBits * 1'000'000L;
    m_codecContext->rc_buffer_size = m_codecContext->bit_rate / settings.m_refreshRate * 1.1;
    switch (settings.m_rateControlMode) {
    case ALVR_CBR:
        if (settings.m_fillerData) {
            av_dict_set(&opt, "nal-hrd", "cbr", 0);
        }
        break;
    case ALVR_VBR:
        av_dict_set(&opt, "nal-hrd", "vbr", 0);
        break;
    }
    m_codecContext->rc_max_rate = m_codecContext->bit_rate;
    m_codecContext->thread_count = settings.m_swThreadCount;

    if ((err = avcodec_open2(m_codecContext, codec, &opt)))
        throw MakeException("Cannot open video encoder codec: %d", err);

    // Config transfer/encode frames
    m_transferredFrame = av_frame_alloc();
    m_transferredFrame->buf[0] = av_buffer_alloc(1);
    m_encoderFrame = av_frame_alloc();
    m_encoderFrame->width = m_codecContext->width;
    m_encoderFrame->height = m_codecContext->height;
    m_encoderFrame->format = m_codecContext->pix_fmt;
    if ((err = av_frame_get_buffer(m_encoderFrame, 0)))
        throw MakeException("Error when allocating encoder frame: %d", err);

    Debug("Successfully initialized VideoEncoderSW");
}

void VideoEncoderSW::Shutdown() {
    Debug("Shutting down VideoEncoderSW.\n");

    // 清理 ARM64 编码器
    if (m_arm64Encoder) {
        m_arm64Encoder->Shutdown();
        m_arm64Encoder.reset();
        m_useArm64Encoder = false;
    }

    // 清理内置 FFmpeg 编码器
    if (m_transferredFrame)
        av_frame_free(&m_transferredFrame);
    if (m_encoderFrame)
        av_frame_free(&m_encoderFrame);
    if (m_codecContext)
        avcodec_free_context(&m_codecContext);
    if (m_scalerContext) {
        sws_freeContext(m_scalerContext);
        m_scalerContext = nullptr;
    }

    Debug("Successfully shutdown VideoEncoderSW.\n");
}

void VideoEncoderSW::Transmit(
    ID3D11Texture2D* pTexture, uint64_t presentationTime, uint64_t targetTimestampNs, bool insertIDR
) {
    // 如果使用 ARM64 编码器，需要先准备 staging texture 然后发送
    if (m_useArm64Encoder) {
        // Setup staging texture if not defined yet
        if (!m_stagingTex) {
            HRESULT hr = SetupStagingTexture(pTexture);
            if (FAILED(hr)) {
                Error("Failed to create staging texture: %p %ls", hr, GetErrorStr(hr).c_str());
                return;
            }
        }

        // Copy texture to CPU accessible memory
        HRESULT hr = CopyTexture(pTexture);
        if (FAILED(hr)) {
            Error("Failed to copy texture: %p %ls", hr, GetErrorStr(hr).c_str());
            return;
        }

        // 通过 ARM64 编码器处理
        uint32_t dataSize = m_stagingTexMap.RowPitch * m_stagingTexDesc.Height;
        if (Settings::Instance().m_enableHdr) {
            // NV12/P010 有额外的 UV plane
            dataSize += m_stagingTexMap.RowPitch * (m_stagingTexDesc.Height / 2);
        }

        TransmitViaArm64((uint8_t*)m_stagingTexMap.pData, dataSize, targetTimestampNs, insertIDR);

        m_d3dRender->GetContext()->Unmap(m_stagingTex.Get(), 0);
        return;
    }

    // 内置 FFmpeg 编码器路径
    // Handle bitrate changes
    auto params = GetDynamicEncoderParams();
    if (params.updated) {
        m_codecContext->bit_rate = params.bitrate_bps;
        m_codecContext->framerate = AVRational { (int)params.framerate, 1 };
        m_codecContext->rc_buffer_size = m_codecContext->bit_rate / params.framerate * 1.1;
        m_codecContext->rc_max_rate = m_codecContext->bit_rate;
    }

    // Setup staging texture if not defined yet; we can only define it here as we now have the
    // texture's size
    if (!m_stagingTex) {
        HRESULT hr = SetupStagingTexture(pTexture);
        if (FAILED(hr)) {
            Error("Failed to create staging texture: %p %ls", hr, GetErrorStr(hr).c_str());
            return;
        }
        Debug("Success in creating staging texture");
    }

    // Copy texture and map it to memory
    /// SteamVR crashes if the swapchain textures are set to staging, which is needed to be read by
    /// the CPU. Unless there's another solution we have to copy the texture every time, which is
    /// gonna be another performance hit.
    HRESULT hr = CopyTexture(pTexture);
    if (FAILED(hr)) {
        Error("Failed to copy texture to staging: %p %ls", hr, GetErrorStr(hr).c_str());
        return;
    }
    // Debug("Success in mapping staging texture");

    // 确定输入纹理的像素格式
    // HDR 模式使用 NV12/P010 (semi-planar)，非 HDR 使用 RGBA
    AVPixelFormat inputFormat = AV_PIX_FMT_RGBA;
    if (Settings::Instance().m_enableHdr) {
        // NV12/P010 是 semi-planar 格式 (Y plane + interleaved UV plane)
        inputFormat = Settings::Instance().m_use10bitEncoder ? AV_PIX_FMT_P010 : AV_PIX_FMT_NV12;
    }

    // Setup software scaler if not defined yet; we can only define it here as we now have the
    // texture's size
    if (!m_scalerContext) {
        m_scalerContext = sws_getContext(
            m_stagingTexDesc.Width,
            m_stagingTexDesc.Height,
            inputFormat,
            m_codecContext->width,
            m_codecContext->height,
            m_codecContext->pix_fmt,
            SWS_BILINEAR,
            NULL,
            NULL,
            NULL
        );
        if (!m_scalerContext) {
            Error("Couldn't initialize SWScaler.");
            m_d3dRender->GetContext()->Unmap(m_stagingTex.Get(), 0);
            return;
        }
        Debug("Successfully initialized SWScaler.");
    }

    // We got the texture, populate tansferredFrame with data
    m_transferredFrame->width = m_stagingTexDesc.Width;
    m_transferredFrame->height = m_stagingTexDesc.Height;
    m_transferredFrame->format = inputFormat;
    m_transferredFrame->pts = targetTimestampNs;

    if (Settings::Instance().m_enableHdr) {
        // NV12/P010 有 2 个平面: Y plane 和 interleaved UV plane
        m_transferredFrame->data[0] = (uint8_t*)m_stagingTexMap.pData;
        m_transferredFrame->data[1]
            = m_transferredFrame->data[0] + m_stagingTexDesc.Height * m_stagingTexMap.RowPitch;
        m_transferredFrame->linesize[0] = m_stagingTexMap.RowPitch;
        m_transferredFrame->linesize[1] = m_stagingTexMap.RowPitch;
    } else {
        // RGBA 是单平面格式
        m_transferredFrame->data[0] = (uint8_t*)m_stagingTexMap.pData;
        m_transferredFrame->linesize[0] = m_stagingTexMap.RowPitch;
    }

    // Use SWScaler for scaling
    if (sws_scale(
            m_scalerContext,
            m_transferredFrame->data,
            m_transferredFrame->linesize,
            0,
            m_transferredFrame->height,
            m_encoderFrame->data,
            m_encoderFrame->linesize
        )
        == 0) {
        Error("SWScale failed.");
        m_d3dRender->GetContext()->Unmap(m_stagingTex.Get(), 0);
        return;
    }
    // Debug("SWScale succeeded.");

    // Send frame for encoding
    m_encoderFrame->pict_type = insertIDR ? AV_PICTURE_TYPE_I : AV_PICTURE_TYPE_NONE;
    m_encoderFrame->pts = targetTimestampNs;

    int err;
    if ((err = avcodec_send_frame(m_codecContext, m_encoderFrame)) < 0) {
        Error("Encoding frame failed: err code %d", err);
        m_d3dRender->GetContext()->Unmap(m_stagingTex.Get(), 0);
        return;
    }
    // Debug("Send frame succeeded.");

    // Retrieve frames from encoding and send them until buffer is emptied
    while (true) {
        AVPacket* packet = av_packet_alloc();
        err = avcodec_receive_packet(m_codecContext, packet);
        if (err != 0) {
            av_packet_free(&packet);
            break;
        }
        // Send encoded frame to client
        bool isIdr = (packet->flags & AV_PKT_FLAG_KEY) != 0;
        ParseFrameNals(m_codec, packet->data, packet->size, packet->pts, isIdr);
        // Debug("Sent encoded packet to client");
        av_packet_free(&packet);
    }
    if (err == AVERROR(EINVAL)) {
        Error("Received encoded frame failed: err code %d", err);
    }

    // Unmap the copied texture and delete it
    m_d3dRender->GetContext()->Unmap(m_stagingTex.Get(), 0);
}

HRESULT VideoEncoderSW::SetupStagingTexture(ID3D11Texture2D* pTexture) {
    D3D11_TEXTURE2D_DESC desc;
    pTexture->GetDesc(&desc);
    m_stagingTexDesc.Width = desc.Width;
    m_stagingTexDesc.Height = desc.Height;
    m_stagingTexDesc.MipLevels = desc.MipLevels;
    m_stagingTexDesc.ArraySize = desc.ArraySize;
    m_stagingTexDesc.Format = desc.Format;
    m_stagingTexDesc.SampleDesc = desc.SampleDesc;
    m_stagingTexDesc.Usage = D3D11_USAGE_STAGING;
    m_stagingTexDesc.BindFlags = 0;
    m_stagingTexDesc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    m_stagingTexDesc.MiscFlags = 0;

    return m_d3dRender->GetDevice()->CreateTexture2D(&m_stagingTexDesc, nullptr, &m_stagingTex);
}

HRESULT VideoEncoderSW::CopyTexture(ID3D11Texture2D* pTexture) {
    m_d3dRender->GetContext()->CopyResource(m_stagingTex.Get(), pTexture);
    return m_d3dRender->GetContext()->Map(
        m_stagingTex.Get(), 0, D3D11_MAP_READ, 0, &m_stagingTexMap
    );
}

AVCodecID VideoEncoderSW::ToFFMPEGCodec(ALVR_CODEC codec) {
    switch (codec) {
    case ALVR_CODEC_H264:
        return AV_CODEC_ID_H264;
    case ALVR_CODEC_HEVC:
        return AV_CODEC_ID_HEVC;
    case ALVR_CODEC_AV1:
        Warn("AV1 is not supported. Using HEVC instead.");
        return AV_CODEC_ID_HEVC;
    default:
        return AV_CODEC_ID_NONE;
    }
}

// ARM64 编码器集成方法
bool VideoEncoderSW::TryInitArm64Encoder() {
#ifdef _WIN32
    // 检查是否在 Windows on ARM 上运行
    SYSTEM_INFO sysInfo;
    GetNativeSystemInfo(&sysInfo);

    // 只有在 ARM64 系统上才尝试使用 ARM64 编码器
    if (sysInfo.wProcessorArchitecture != PROCESSOR_ARCHITECTURE_ARM64) {
        Debug("Not running on ARM64, skipping ARM64 encoder\n");
        return false;
    }

    Debug("Detected ARM64 system, trying ARM64 encoder...\n");

    m_arm64Encoder = std::make_unique<Arm64EncoderIpc::EncoderIpcClient>();
    if (m_arm64Encoder->Initialize(m_renderWidth, m_renderHeight)) {
        m_useArm64Encoder = true;
        Info("ARM64 encoder initialized successfully, using out-of-process encoding\n");
        return true;
    }

    m_arm64Encoder.reset();
    Debug("ARM64 encoder not available, falling back to in-process FFmpeg\n");
#endif
    return false;
}

bool VideoEncoderSW::TransmitViaArm64(
    const uint8_t* data, uint32_t size, uint64_t timestampNs, bool insertIDR
) {
    if (!m_arm64Encoder || !m_arm64Encoder->IsConnected()) {
        return false;
    }

    // 确定像素格式
    const auto& settings = Settings::Instance();
    Arm64EncoderIpc::PixelFormat format = Arm64EncoderIpc::PixelFormat::RGBA;
    if (settings.m_enableHdr) {
        format = settings.m_use10bitEncoder ? Arm64EncoderIpc::PixelFormat::P010
                                            : Arm64EncoderIpc::PixelFormat::NV12;
    }

    // 发送帧给 ARM64 编码器
    if (!m_arm64Encoder->SendFrame(
            data,
            size,
            m_stagingTexDesc.Width,
            m_stagingTexDesc.Height,
            m_stagingTexMap.RowPitch,
            timestampNs,
            insertIDR,
            format
        )) {
        Error("Failed to send frame to ARM64 encoder\n");
        return false;
    }

    // 接收编码后的数据包
    std::vector<uint8_t> packet;
    uint64_t pts;
    bool isIdr;

    if (m_arm64Encoder->ReceivePacket(packet, pts, isIdr)) {
        // 发送到客户端
        ParseFrameNals(m_codec, packet.data(), packet.size(), pts, isIdr);
        return true;
    }

    return false;
}

#endif // ALVR_GPL
