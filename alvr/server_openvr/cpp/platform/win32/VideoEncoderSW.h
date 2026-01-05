#ifdef ALVR_GPL

#pragma once

#include <wrl.h>

#include "ALVR-common/packet_types.h"
#include "Arm64EncoderIpc.h"
#include "VideoEncoder.h"
#include "shared/d3drender.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libswscale/swscale.h>
}

using Microsoft::WRL::ComPtr;

// Software video encoder using FFMPEG
// Supports both in-process encoding and out-of-process ARM64 encoding via IPC
class VideoEncoderSW : public VideoEncoder {
public:
    VideoEncoderSW(std::shared_ptr<CD3DRender> pD3DRender, int width, int height);
    ~VideoEncoderSW();

    void Initialize();
    void Shutdown();

    static void LibVALog(void*, int level, const char* data, va_list va);

    AVCodecID ToFFMPEGCodec(ALVR_CODEC codec);

    void Transmit(
        ID3D11Texture2D* pTexture,
        uint64_t presentationTime,
        uint64_t targetTimestampNs,
        bool insertIDR
    );
    HRESULT SetupStagingTexture(ID3D11Texture2D* pTexture);
    HRESULT CopyTexture(ID3D11Texture2D* pTexture);

private:
    std::shared_ptr<CD3DRender> m_d3dRender;

    // In-process FFmpeg encoding (fallback)
    AVCodecContext* m_codecContext = nullptr;
    AVFrame *m_transferredFrame = nullptr, *m_encoderFrame = nullptr;
    SwsContext* m_scalerContext = nullptr;

    ComPtr<ID3D11Texture2D> m_stagingTex;
    D3D11_TEXTURE2D_DESC m_stagingTexDesc;
    D3D11_MAPPED_SUBRESOURCE m_stagingTexMap;

    ALVR_CODEC m_codec;
    int m_refreshRate;
    int m_renderWidth;
    int m_renderHeight;
    int m_bitrateInMBits;

    // ARM64 out-of-process encoder via IPC
    std::unique_ptr<Arm64EncoderIpc::EncoderIpcClient> m_arm64Encoder;
    bool m_useArm64Encoder = false;

    // 尝试初始化 ARM64 编码器，失败则使用内置 FFmpeg
    bool TryInitArm64Encoder();
    // 通过 ARM64 编码器处理帧
    bool TransmitViaArm64(const uint8_t* data, uint32_t size, uint64_t timestampNs, bool insertIDR);
};

#endif // ALVR_GPL
