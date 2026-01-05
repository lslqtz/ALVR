//! 视频编码器模块 - 使用 FFmpeg 进行 H.264/HEVC 编码

use anyhow::{Context, Result, bail};
use std::ptr;
use tracing::{debug, info};

use crate::ipc::{FrameData, PacketData, PixelFormat};

// FFmpeg bindings (由 build.rs 生成)
#[allow(non_upper_case_globals)]
#[allow(non_camel_case_types)]
#[allow(non_snake_case)]
#[allow(dead_code)]
mod ffi {
    include!(concat!(env!("OUT_DIR"), "/ffmpeg_bindings.rs"));
}

/// 视频编码器
pub struct VideoEncoder {
    codec_ctx: *mut ffi::AVCodecContext,
    frame: *mut ffi::AVFrame,
    sws_ctx: *mut ffi::SwsContext,
    width: u32,
    height: u32,
    frame_count: u64,
}

impl VideoEncoder {
    pub fn new(width: u32, height: u32, codec_name: &str) -> Result<Self> {
        unsafe {
            // 查找编码器
            let codec_id = match codec_name {
                "h264" => ffi::AVCodecID_AV_CODEC_ID_H264,
                "hevc" | "h265" => ffi::AVCodecID_AV_CODEC_ID_HEVC,
                _ => ffi::AVCodecID_AV_CODEC_ID_H264,
            };
            
            let codec = ffi::avcodec_find_encoder(codec_id);
            if codec.is_null() {
                bail!("Could not find encoder for codec {:?}", codec_name);
            }
            
            // 分配编码器上下文
            let codec_ctx = ffi::avcodec_alloc_context3(codec);
            if codec_ctx.is_null() {
                bail!("Could not allocate codec context");
            }
            
            // 配置编码器
            (*codec_ctx).width = width as i32;
            (*codec_ctx).height = height as i32;
            (*codec_ctx).time_base = ffi::AVRational { num: 1, den: 1_000_000_000 }; // nanoseconds
            (*codec_ctx).framerate = ffi::AVRational { num: 72, den: 1 };
            (*codec_ctx).pix_fmt = ffi::AVPixelFormat_AV_PIX_FMT_YUV420P;
            (*codec_ctx).gop_size = 0; // All intra
            (*codec_ctx).max_b_frames = 0;
            (*codec_ctx).bit_rate = 30_000_000; // 30 Mbps default
            
            // 设置低延迟选项
            let mut opts: *mut ffi::AVDictionary = ptr::null_mut();
            let preset = std::ffi::CString::new("preset").unwrap();
            let ultrafast = std::ffi::CString::new("ultrafast").unwrap();
            ffi::av_dict_set(&mut opts, preset.as_ptr(), ultrafast.as_ptr(), 0);
            
            let tune = std::ffi::CString::new("tune").unwrap();
            let zerolatency = std::ffi::CString::new("zerolatency").unwrap();
            ffi::av_dict_set(&mut opts, tune.as_ptr(), zerolatency.as_ptr(), 0);
            
            // 打开编码器
            let ret = ffi::avcodec_open2(codec_ctx, codec, &mut opts);
            ffi::av_dict_free(&mut opts);
            
            if ret < 0 {
                ffi::avcodec_free_context(&mut (codec_ctx as *mut _));
                bail!("Could not open codec: error {}", ret);
            }
            
            // 分配帧
            let frame = ffi::av_frame_alloc();
            if frame.is_null() {
                ffi::avcodec_free_context(&mut (codec_ctx as *mut _));
                bail!("Could not allocate frame");
            }
            
            (*frame).width = width as i32;
            (*frame).height = height as i32;
            (*frame).format = ffi::AVPixelFormat_AV_PIX_FMT_YUV420P as i32;
            
            let ret = ffi::av_frame_get_buffer(frame, 0);
            if ret < 0 {
                ffi::av_frame_free(&mut (frame as *mut _));
                ffi::avcodec_free_context(&mut (codec_ctx as *mut _));
                bail!("Could not allocate frame buffer: error {}", ret);
            }
            
            info!("VideoEncoder initialized: {}x{}, codec: {}", width, height, codec_name);
            
            Ok(Self {
                codec_ctx,
                frame,
                sws_ctx: ptr::null_mut(),
                width,
                height,
                frame_count: 0,
            })
        }
    }
    
    /// 编码一帧
    pub fn encode_frame(&mut self, frame_data: &FrameData) -> Result<Vec<PacketData>> {
        unsafe {
            // 确保 sws_ctx 已初始化
            if self.sws_ctx.is_null() {
                self.init_scaler(frame_data.pixel_format)?;
            }
            
            // 准备输入数据
            let src_data = [frame_data.data.as_ptr(), ptr::null(), ptr::null(), ptr::null()];
            let src_linesize = [frame_data.row_pitch as i32, 0, 0, 0];
            
            // 颜色空间转换
            ffi::sws_scale(
                self.sws_ctx,
                src_data.as_ptr() as *const *const u8,
                src_linesize.as_ptr(),
                0,
                frame_data.height as i32,
                (*self.frame).data.as_ptr() as *mut *mut u8,
                (*self.frame).linesize.as_ptr(),
            );
            
            // 设置帧属性
            (*self.frame).pts = frame_data.timestamp_ns as i64;
            (*self.frame).pict_type = if frame_data.insert_idr {
                ffi::AVPictureType_AV_PICTURE_TYPE_I
            } else {
                ffi::AVPictureType_AV_PICTURE_TYPE_NONE
            };
            
            // 发送帧到编码器
            let ret = ffi::avcodec_send_frame(self.codec_ctx, self.frame);
            if ret < 0 {
                bail!("Error sending frame for encoding: {}", ret);
            }
            
            // 接收编码后的数据包
            let mut packets = Vec::new();
            let packet = ffi::av_packet_alloc();
            
            loop {
                let ret = ffi::avcodec_receive_packet(self.codec_ctx, packet);
                if ret == ffi::AVERROR(ffi::EAGAIN as i32) || ret == ffi::AVERROR_EOF {
                    break;
                }
                if ret < 0 {
                    ffi::av_packet_free(&mut (packet as *mut _));
                    bail!("Error receiving packet: {}", ret);
                }
                
                // 复制数据包数据
                let data = std::slice::from_raw_parts((*packet).data, (*packet).size as usize);
                let is_idr = ((*packet).flags & ffi::AV_PKT_FLAG_KEY as i32) != 0;
                
                packets.push(PacketData {
                    data: data.to_vec(),
                    timestamp_ns: (*packet).pts as u64,
                    is_idr,
                });
                
                ffi::av_packet_unref(packet);
            }
            
            ffi::av_packet_free(&mut (packet as *mut _));
            
            self.frame_count += 1;
            if self.frame_count % 100 == 0 {
                debug!("Encoded {} frames", self.frame_count);
            }
            
            Ok(packets)
        }
    }
    
    /// 初始化颜色空间转换器
    fn init_scaler(&mut self, pixel_format: PixelFormat) -> Result<()> {
        unsafe {
            let src_format = match pixel_format {
                PixelFormat::Rgba => ffi::AVPixelFormat_AV_PIX_FMT_RGBA,
                PixelFormat::Nv12 => ffi::AVPixelFormat_AV_PIX_FMT_NV12,
                PixelFormat::P010 => ffi::AVPixelFormat_AV_PIX_FMT_P010,
            };
            
            self.sws_ctx = ffi::sws_getContext(
                self.width as i32,
                self.height as i32,
                src_format,
                self.width as i32,
                self.height as i32,
                ffi::AVPixelFormat_AV_PIX_FMT_YUV420P,
                ffi::SWS_BILINEAR as i32,
                ptr::null_mut(),
                ptr::null_mut(),
                ptr::null_mut(),
            );
            
            if self.sws_ctx.is_null() {
                bail!("Could not initialize sws context");
            }
            
            info!("Scaler initialized for pixel format {:?}", pixel_format);
            Ok(())
        }
    }
    
    /// 更新比特率
    pub fn set_bitrate(&mut self, bitrate_bps: u64) {
        unsafe {
            (*self.codec_ctx).bit_rate = bitrate_bps as i64;
        }
    }
}

impl Drop for VideoEncoder {
    fn drop(&mut self) {
        unsafe {
            if !self.sws_ctx.is_null() {
                ffi::sws_freeContext(self.sws_ctx);
            }
            if !self.frame.is_null() {
                ffi::av_frame_free(&mut self.frame);
            }
            if !self.codec_ctx.is_null() {
                ffi::avcodec_free_context(&mut self.codec_ctx);
            }
        }
    }
}

// FFmpeg AVERROR 宏的 Rust 实现
impl ffi {
    #[inline]
    pub const fn AVERROR(e: i32) -> i32 {
        -e
    }
}
