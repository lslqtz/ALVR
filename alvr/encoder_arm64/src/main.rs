//! ALVR ARM64 Native Video Encoder
//!
//! This is an out-of-process encoder that runs natively on ARM64 Windows.
//! It communicates with the x64 ALVR driver via shared memory IPC.

mod encoder;
mod ipc;

use anyhow::{Context, Result};
use ipc::{EncoderIpc, FrameData, PacketData};
use tracing::{error, info, Level};
use tracing_subscriber::FmtSubscriber;

/// 共享内存名称前缀
pub const SHARED_MEM_NAME: &str = "ALVR_ARM64_ENCODER";
/// 帧就绪事件名称
pub const FRAME_READY_EVENT: &str = "ALVR_ARM64_FRAME_READY";
/// 数据包就绪事件名称  
pub const PACKET_READY_EVENT: &str = "ALVR_ARM64_PACKET_READY";
/// 编码器就绪事件名称
pub const ENCODER_READY_EVENT: &str = "ALVR_ARM64_ENCODER_READY";

fn main() -> Result<()> {
    // 初始化日志
    let subscriber = FmtSubscriber::builder()
        .with_max_level(Level::DEBUG)
        .init();
    
    info!("ALVR ARM64 Encoder starting...");
    
    // 解析命令行参数
    let args: Vec<String> = std::env::args().collect();
    let width: u32 = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(1920);
    let height: u32 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(1080);
    let codec: &str = args.get(3).map(|s| s.as_str()).unwrap_or("h264");
    
    info!("Encoder config: {}x{}, codec: {}", width, height, codec);
    
    // 初始化 IPC
    let mut ipc = EncoderIpc::new(width, height)
        .context("Failed to initialize IPC")?;
    
    info!("IPC initialized, waiting for frames...");
    
    // 初始化编码器
    let mut video_encoder = encoder::VideoEncoder::new(width, height, codec)
        .context("Failed to initialize video encoder")?;
    
    info!("Video encoder initialized");
    
    // 通知 ALVR 驱动编码器已就绪
    ipc.signal_encoder_ready()?;
    
    // 主循环
    loop {
        // 等待帧数据
        match ipc.wait_for_frame() {
            Ok(frame_data) => {
                // 检查是否收到退出信号
                if frame_data.shutdown {
                    info!("Received shutdown signal, exiting...");
                    break;
                }
                
                // 编码帧
                match video_encoder.encode_frame(&frame_data) {
                    Ok(packets) => {
                        // 发送编码后的数据包
                        for packet in packets {
                            if let Err(e) = ipc.send_packet(&packet) {
                                error!("Failed to send packet: {}", e);
                            }
                        }
                    }
                    Err(e) => {
                        error!("Encoding failed: {}", e);
                    }
                }
            }
            Err(e) => {
                error!("Failed to receive frame: {}", e);
                // 短暂等待后重试
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
        }
    }
    
    info!("ALVR ARM64 Encoder shutting down");
    Ok(())
}
