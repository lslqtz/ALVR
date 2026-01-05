//! IPC 模块 - 使用 Windows 共享内存和命名事件进行进程间通信

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use std::ffi::c_void;
use std::ptr;
use windows::core::PCWSTR;
use windows::Win32::Foundation::{CloseHandle, HANDLE, WAIT_OBJECT_0};
use windows::Win32::System::Memory::{
    CreateFileMappingW, MapViewOfFile, UnmapViewOfFile, FILE_MAP_ALL_ACCESS,
    PAGE_READWRITE,
};
use windows::Win32::System::Threading::{
    CreateEventW, OpenEventW, SetEvent, WaitForSingleObject, EVENT_ALL_ACCESS, INFINITE,
};

use crate::{ENCODER_READY_EVENT, FRAME_READY_EVENT, PACKET_READY_EVENT, SHARED_MEM_NAME};

/// 帧缓冲区大小 (支持 4K RGBA)
const FRAME_BUFFER_SIZE: usize = 4096 * 2160 * 4;
/// 数据包缓冲区大小 (编码后数据通常更小)
const PACKET_BUFFER_SIZE: usize = 4 * 1024 * 1024; // 4MB

/// 共享内存布局
#[repr(C)]
pub struct SharedMemoryLayout {
    /// 帧元数据
    pub frame_header: FrameHeader,
    /// 数据包元数据
    pub packet_header: PacketHeader,
    /// 帧数据缓冲区
    pub frame_buffer: [u8; FRAME_BUFFER_SIZE],
    /// 数据包缓冲区
    pub packet_buffer: [u8; PACKET_BUFFER_SIZE],
}

/// 帧头信息
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct FrameHeader {
    /// 帧宽度
    pub width: u32,
    /// 帧高度
    pub height: u32,
    /// 帧时间戳
    pub timestamp_ns: u64,
    /// 是否请求 IDR 帧
    pub insert_idr: u8,
    /// 像素格式 (0=RGBA, 1=NV12, 2=P010)
    pub pixel_format: u8,
    /// 行跨度 (stride)
    pub row_pitch: u32,
    /// 帧数据大小
    pub data_size: u32,
    /// 关闭信号
    pub shutdown: u8,
    /// 填充对齐
    _padding: [u8; 3],
}

/// 数据包头信息
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct PacketHeader {
    /// 数据包大小
    pub size: u32,
    /// 时间戳
    pub timestamp_ns: u64,
    /// 是否为 IDR 帧
    pub is_idr: u8,
    /// 填充对齐
    _padding: [u8; 3],
}

/// 帧数据 (反序列化后的)
pub struct FrameData {
    pub width: u32,
    pub height: u32,
    pub timestamp_ns: u64,
    pub insert_idr: bool,
    pub pixel_format: PixelFormat,
    pub row_pitch: u32,
    pub data: Vec<u8>,
    pub shutdown: bool,
}

/// 编码后的数据包
pub struct PacketData {
    pub data: Vec<u8>,
    pub timestamp_ns: u64,
    pub is_idr: bool,
}

/// 像素格式
#[derive(Clone, Copy, Debug)]
pub enum PixelFormat {
    Rgba,
    Nv12,
    P010,
}

impl From<u8> for PixelFormat {
    fn from(v: u8) -> Self {
        match v {
            1 => PixelFormat::Nv12,
            2 => PixelFormat::P010,
            _ => PixelFormat::Rgba,
        }
    }
}

/// IPC 管理器
pub struct EncoderIpc {
    shared_memory: HANDLE,
    shared_ptr: *mut SharedMemoryLayout,
    frame_ready_event: HANDLE,
    packet_ready_event: HANDLE,
    encoder_ready_event: HANDLE,
    width: u32,
    height: u32,
}

impl EncoderIpc {
    pub fn new(width: u32, height: u32) -> Result<Self> {
        unsafe {
            // 创建共享内存
            let mem_name = to_wide_string(SHARED_MEM_NAME);
            let shared_memory = CreateFileMappingW(
                HANDLE(-1isize as *mut c_void), // INVALID_HANDLE_VALUE
                None,
                PAGE_READWRITE,
                0,
                std::mem::size_of::<SharedMemoryLayout>() as u32,
                PCWSTR(mem_name.as_ptr()),
            ).context("Failed to create shared memory")?;

            let shared_ptr = MapViewOfFile(
                shared_memory,
                FILE_MAP_ALL_ACCESS,
                0,
                0,
                0,
            );
            
            if shared_ptr.Value.is_null() {
                bail!("Failed to map shared memory");
            }

            // 创建事件
            let frame_event_name = to_wide_string(FRAME_READY_EVENT);
            let frame_ready_event = CreateEventW(
                None,
                false, // auto-reset
                false, // initial state
                PCWSTR(frame_event_name.as_ptr()),
            ).context("Failed to create frame ready event")?;

            let packet_event_name = to_wide_string(PACKET_READY_EVENT);
            let packet_ready_event = CreateEventW(
                None,
                false,
                false,
                PCWSTR(packet_event_name.as_ptr()),
            ).context("Failed to create packet ready event")?;

            let encoder_event_name = to_wide_string(ENCODER_READY_EVENT);
            let encoder_ready_event = CreateEventW(
                None,
                true, // manual-reset for encoder ready
                false,
                PCWSTR(encoder_event_name.as_ptr()),
            ).context("Failed to create encoder ready event")?;

            Ok(Self {
                shared_memory,
                shared_ptr: shared_ptr.Value as *mut SharedMemoryLayout,
                frame_ready_event,
                packet_ready_event,
                encoder_ready_event,
                width,
                height,
            })
        }
    }

    /// 通知 ALVR 驱动编码器已就绪
    pub fn signal_encoder_ready(&self) -> Result<()> {
        unsafe {
            SetEvent(self.encoder_ready_event)
                .context("Failed to signal encoder ready")?;
        }
        Ok(())
    }

    /// 等待帧数据
    pub fn wait_for_frame(&self) -> Result<FrameData> {
        unsafe {
            // 等待帧就绪事件
            let result = WaitForSingleObject(self.frame_ready_event, INFINITE);
            if result != WAIT_OBJECT_0 {
                bail!("Wait for frame failed");
            }

            // 读取帧头
            let header = (*self.shared_ptr).frame_header;
            
            // 复制帧数据
            let data_size = header.data_size as usize;
            let mut data = vec![0u8; data_size];
            ptr::copy_nonoverlapping(
                (*self.shared_ptr).frame_buffer.as_ptr(),
                data.as_mut_ptr(),
                data_size,
            );

            Ok(FrameData {
                width: header.width,
                height: header.height,
                timestamp_ns: header.timestamp_ns,
                insert_idr: header.insert_idr != 0,
                pixel_format: header.pixel_format.into(),
                row_pitch: header.row_pitch,
                data,
                shutdown: header.shutdown != 0,
            })
        }
    }

    /// 发送编码后的数据包
    pub fn send_packet(&mut self, packet: &PacketData) -> Result<()> {
        unsafe {
            // 写入数据包头
            (*self.shared_ptr).packet_header = PacketHeader {
                size: packet.data.len() as u32,
                timestamp_ns: packet.timestamp_ns,
                is_idr: if packet.is_idr { 1 } else { 0 },
                _padding: [0; 3],
            };

            // 复制数据包数据
            ptr::copy_nonoverlapping(
                packet.data.as_ptr(),
                (*self.shared_ptr).packet_buffer.as_mut_ptr(),
                packet.data.len(),
            );

            // 通知数据包就绪
            SetEvent(self.packet_ready_event)
                .context("Failed to signal packet ready")?;
        }
        Ok(())
    }
}

impl Drop for EncoderIpc {
    fn drop(&mut self) {
        unsafe {
            if !self.shared_ptr.is_null() {
                let _ = UnmapViewOfFile(windows::Win32::System::Memory::MEMORY_MAPPED_VIEW_ADDRESS {
                    Value: self.shared_ptr as *mut c_void,
                });
            }
            if !self.shared_memory.is_invalid() {
                let _ = CloseHandle(self.shared_memory);
            }
            if !self.frame_ready_event.is_invalid() {
                let _ = CloseHandle(self.frame_ready_event);
            }
            if !self.packet_ready_event.is_invalid() {
                let _ = CloseHandle(self.packet_ready_event);
            }
            if !self.encoder_ready_event.is_invalid() {
                let _ = CloseHandle(self.encoder_ready_event);
            }
        }
    }
}

/// 转换为 Windows 宽字符串
fn to_wide_string(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}
