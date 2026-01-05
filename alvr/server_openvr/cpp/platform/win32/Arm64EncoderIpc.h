#pragma once
// ARM64 编码器 IPC 接口
// 用于 x64 ALVR 驱动与 ARM64 编码器进程之间的通信

#ifdef _WIN32
#include <windows.h>
#else
// 占位符：非 Windows 平台不支持此功能
typedef void* HANDLE;
typedef unsigned long DWORD;
#endif

#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

namespace Arm64EncoderIpc {

// 共享内存名称
constexpr const wchar_t* SHARED_MEM_NAME = L"ALVR_ARM64_ENCODER";
constexpr const wchar_t* FRAME_READY_EVENT = L"ALVR_ARM64_FRAME_READY";
constexpr const wchar_t* PACKET_READY_EVENT = L"ALVR_ARM64_PACKET_READY";
constexpr const wchar_t* ENCODER_READY_EVENT = L"ALVR_ARM64_ENCODER_READY";

// 帧缓冲区大小 (支持 4K RGBA)
constexpr size_t FRAME_BUFFER_SIZE = 4096 * 2160 * 4;
// 数据包缓冲区大小
constexpr size_t PACKET_BUFFER_SIZE = 4 * 1024 * 1024; // 4MB

// 像素格式
enum class PixelFormat : uint8_t {
    RGBA = 0,
    NV12 = 1,
    P010 = 2,
};

// 帧头信息 (必须与 Rust 端结构体完全一致)
#pragma pack(push, 1)
struct FrameHeader {
    uint32_t width;
    uint32_t height;
    uint64_t timestamp_ns;
    uint8_t insert_idr;
    uint8_t pixel_format;
    uint32_t row_pitch;
    uint32_t data_size;
    uint8_t shutdown;
    uint8_t _padding[3];
};

struct PacketHeader {
    uint32_t size;
    uint64_t timestamp_ns;
    uint8_t is_idr;
    uint8_t _padding[3];
};

struct SharedMemoryLayout {
    FrameHeader frame_header;
    PacketHeader packet_header;
    uint8_t frame_buffer[FRAME_BUFFER_SIZE];
    uint8_t packet_buffer[PACKET_BUFFER_SIZE];
};
#pragma pack(pop)

// IPC 客户端 (x64 驱动端使用)
class EncoderIpcClient {
public:
    EncoderIpcClient();
    ~EncoderIpcClient();

    // 初始化 IPC 连接
    bool Initialize(uint32_t width, uint32_t height);

    // 关闭 IPC 连接
    void Shutdown();

    // 启动 ARM64 编码器进程
    bool LaunchEncoderProcess();

    // 等待编码器就绪
    bool WaitForEncoderReady(DWORD timeout_ms = 5000);

    // 发送帧给编码器
    bool SendFrame(
        const uint8_t* data,
        uint32_t data_size,
        uint32_t width,
        uint32_t height,
        uint32_t row_pitch,
        uint64_t timestamp_ns,
        bool insert_idr,
        PixelFormat format
    );

    // 接收编码后的数据包 (阻塞)
    bool ReceivePacket(
        std::vector<uint8_t>& packet_data,
        uint64_t& timestamp_ns,
        bool& is_idr,
        DWORD timeout_ms = 1000
    );

    // 检查是否连接
    bool IsConnected() const { return m_connected; }

private:
    HANDLE m_sharedMemory = nullptr;
    SharedMemoryLayout* m_sharedPtr = nullptr;
    HANDLE m_frameReadyEvent = nullptr;
    HANDLE m_packetReadyEvent = nullptr;
    HANDLE m_encoderReadyEvent = nullptr;
    HANDLE m_encoderProcess = nullptr;

    uint32_t m_width = 0;
    uint32_t m_height = 0;
    bool m_connected = false;
};

} // namespace Arm64EncoderIpc
