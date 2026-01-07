#include "Arm64EncoderIpc.h"
#include "alvr_server/Logger.h"
#include <filesystem>
#include <vector>

namespace Arm64EncoderIpc {

EncoderIpcClient::EncoderIpcClient() { }

EncoderIpcClient::~EncoderIpcClient() { Shutdown(); }

bool EncoderIpcClient::Initialize(uint32_t width, uint32_t height, const std::string& codec) {
    m_width = width;
    m_height = height;
    m_codec = codec;

    // 打开或创建共享内存
    m_sharedMemory = OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE, SHARED_MEM_NAME);

    if (m_sharedMemory == nullptr) {
        // 编码器进程会创建共享内存，我们需要先启动它
        Debug("Shared memory not found, launching encoder process...\n");
        if (!LaunchEncoderProcess()) {
            Error("Failed to launch ARM64 encoder process\n");
            return false;
        }

        // 等待编码器创建共享内存
        for (int i = 0; i < 50; i++) {
            Sleep(100);
            m_sharedMemory = OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE, SHARED_MEM_NAME);
            if (m_sharedMemory != nullptr)
                break;
        }

        if (m_sharedMemory == nullptr) {
            Error("Failed to open shared memory after launching encoder\n");
            return false;
        }
    }

    m_sharedPtr = (SharedMemoryLayout*)MapViewOfFile(m_sharedMemory, FILE_MAP_ALL_ACCESS, 0, 0, 0);

    if (m_sharedPtr == nullptr) {
        Error("Failed to map shared memory\n");
        CloseHandle(m_sharedMemory);
        m_sharedMemory = nullptr;
        return false;
    }

    // 打开事件
    m_frameReadyEvent = OpenEventW(EVENT_ALL_ACCESS, FALSE, FRAME_READY_EVENT);
    m_packetReadyEvent = OpenEventW(EVENT_ALL_ACCESS, FALSE, PACKET_READY_EVENT);
    m_encoderReadyEvent = OpenEventW(EVENT_ALL_ACCESS, FALSE, ENCODER_READY_EVENT);

    if (m_frameReadyEvent == nullptr || m_packetReadyEvent == nullptr
        || m_encoderReadyEvent == nullptr) {
        Error("Failed to open IPC events\n");
        Shutdown();
        return false;
    }

    // 等待编码器就绪
    if (!WaitForEncoderReady()) {
        Error("ARM64 encoder did not become ready in time\n");
        Shutdown();
        return false;
    }

    m_connected = true;
    Info("ARM64 encoder IPC connected\n");
    return true;
}

void EncoderIpcClient::Shutdown() {
    // 发送关闭信号
    if (m_sharedPtr != nullptr && m_connected) {
        m_sharedPtr->frame_header.shutdown = 1;
        if (m_frameReadyEvent != nullptr) {
            SetEvent(m_frameReadyEvent);
        }
    }

    // 清理资源
    if (m_sharedPtr != nullptr) {
        UnmapViewOfFile(m_sharedPtr);
        m_sharedPtr = nullptr;
    }
    if (m_sharedMemory != nullptr) {
        CloseHandle(m_sharedMemory);
        m_sharedMemory = nullptr;
    }
    if (m_frameReadyEvent != nullptr) {
        CloseHandle(m_frameReadyEvent);
        m_frameReadyEvent = nullptr;
    }
    if (m_packetReadyEvent != nullptr) {
        CloseHandle(m_packetReadyEvent);
        m_packetReadyEvent = nullptr;
    }
    if (m_encoderReadyEvent != nullptr) {
        CloseHandle(m_encoderReadyEvent);
        m_encoderReadyEvent = nullptr;
    }
    if (m_encoderProcess != nullptr) {
        // 等待进程退出
        WaitForSingleObject(m_encoderProcess, 3000);
        CloseHandle(m_encoderProcess);
        m_encoderProcess = nullptr;
    }

    m_connected = false;
}

bool EncoderIpcClient::LaunchEncoderProcess() {
    // 查找编码器可执行文件
    wchar_t modulePath[MAX_PATH];
    GetModuleFileNameW(nullptr, modulePath, MAX_PATH);

    std::filesystem::path exePath(modulePath);
    std::filesystem::path encoderPath = exePath.parent_path() / "alvr_encoder_arm64.exe";

    if (!std::filesystem::exists(encoderPath)) {
        Error("ARM64 encoder not found at: %ls\n", encoderPath.c_str());
        return false;
    }

    // 构建命令行
    std::wstring cmdLine = encoderPath.wstring();
    cmdLine += L" " + std::to_wstring(m_width);
    cmdLine += L" " + std::to_wstring(m_height);
    // 传递 codec 参数 (h264 或 hevc)
    std::wstring wcodec(m_codec.begin(), m_codec.end());
    cmdLine += L" " + wcodec;

    STARTUPINFOW si = { sizeof(si) };
    PROCESS_INFORMATION pi = {};

    if (!CreateProcessW(
            nullptr,
            cmdLine.data(),
            nullptr,
            nullptr,
            FALSE,
            CREATE_NEW_CONSOLE, // 可以改为 CREATE_NO_WINDOW
            nullptr,
            nullptr,
            &si,
            &pi
        )) {
        Error("Failed to start ARM64 encoder process: %d\n", GetLastError());
        return false;
    }

    m_encoderProcess = pi.hProcess;
    CloseHandle(pi.hThread);

    Debug("ARM64 encoder process started (PID: %d)\n", pi.dwProcessId);
    return true;
}

bool EncoderIpcClient::WaitForEncoderReady(DWORD timeout_ms) {
    if (m_encoderReadyEvent == nullptr)
        return false;

    DWORD result = WaitForSingleObject(m_encoderReadyEvent, timeout_ms);
    return result == WAIT_OBJECT_0;
}

bool EncoderIpcClient::SendFrame(
    const uint8_t* data,
    uint32_t data_size,
    uint32_t width,
    uint32_t height,
    uint32_t row_pitch,
    uint64_t timestamp_ns,
    bool insert_idr,
    PixelFormat format
) {
    if (!m_connected || m_sharedPtr == nullptr) {
        return false;
    }

    // 检查数据大小
    if (data_size > FRAME_BUFFER_SIZE) {
        Error("Frame data too large: %u > %zu\n", data_size, FRAME_BUFFER_SIZE);
        return false;
    }

    // 填充帧头
    m_sharedPtr->frame_header.width = width;
    m_sharedPtr->frame_header.height = height;
    m_sharedPtr->frame_header.timestamp_ns = timestamp_ns;
    m_sharedPtr->frame_header.insert_idr = insert_idr ? 1 : 0;
    m_sharedPtr->frame_header.pixel_format = static_cast<uint8_t>(format);
    m_sharedPtr->frame_header.row_pitch = row_pitch;
    m_sharedPtr->frame_header.data_size = data_size;
    m_sharedPtr->frame_header.shutdown = 0;

    // 复制帧数据
    memcpy(m_sharedPtr->frame_buffer, data, data_size);

    // 通知帧就绪
    if (!SetEvent(m_frameReadyEvent)) {
        Error("Failed to signal frame ready\n");
        return false;
    }

    return true;
}

bool EncoderIpcClient::ReceivePacket(
    std::vector<uint8_t>& packet_data, uint64_t& timestamp_ns, bool& is_idr, DWORD timeout_ms
) {
    if (!m_connected || m_sharedPtr == nullptr) {
        return false;
    }

    // 等待数据包就绪
    DWORD result = WaitForSingleObject(m_packetReadyEvent, timeout_ms);
    if (result != WAIT_OBJECT_0) {
        return false;
    }

    // 读取数据包
    uint32_t size = m_sharedPtr->packet_header.size;
    if (size > PACKET_BUFFER_SIZE) {
        Error("Packet too large: %u\n", size);
        return false;
    }

    packet_data.resize(size);
    memcpy(packet_data.data(), m_sharedPtr->packet_buffer, size);

    timestamp_ns = m_sharedPtr->packet_header.timestamp_ns;
    is_idr = m_sharedPtr->packet_header.is_idr != 0;

    return true;
}

} // namespace Arm64EncoderIpc
