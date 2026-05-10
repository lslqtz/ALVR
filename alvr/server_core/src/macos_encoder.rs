use alvr_common::{
    anyhow::{Result, bail},
    info, error,
};
use std::{
    io::{Read, Write, ErrorKind},
    net::{TcpStream, SocketAddr},
    time::Duration,
    thread,
    sync::{Arc, atomic::{AtomicBool, Ordering}},
};

const PROTOCOL_INIT: u32 = 1;
const PROTOCOL_ACK: u32 = 2;
const PROTOCOL_FRAME: u32 = 3;
const PROTOCOL_PACKET: u32 = 4;
const PROTOCOL_UPDATE_PARAMS: u32 = 5;
const PROTOCOL_SHUTDOWN: u32 = 6;

pub struct MacosEncoderClient {
    stream_send: TcpStream,
    is_running: Arc<AtomicBool>,
}

impl MacosEncoderClient {
    pub fn connect_and_start(
        host: &str,
        width: u32,
        height: u32,
        codec: u8,
        realtime: bool,
        nal_callback: impl Fn(u64, bool, &[u8]) + Send + Sync + 'static,
    ) -> Result<Self> {
        let addr: SocketAddr = host.parse()?;
        let mut stream = TcpStream::connect_timeout(&addr, Duration::from_secs(3))?;
        stream.set_nodelay(true)?;
        stream.set_read_timeout(Some(Duration::from_millis(500)))?;
        stream.set_write_timeout(Some(Duration::from_millis(500)))?;

        // 1. Send INIT
        let mut body = Vec::new();
        body.extend_from_slice(&width.to_le_bytes());
        body.extend_from_slice(&height.to_le_bytes());
        body.extend_from_slice(&[codec]);
        
        // 伪造 bitrate 和 framerate 给 InitMessage，因为在 connect_and_start 这里拿不到
        // 我们传入默认的或者从上下文中拿，目前简单塞点初始值，后续 UpdateParams 会修正
        let initial_bitrate_bps: u64 = 30_000_000;
        let initial_framerate: u32 = if realtime { 90 } else { 60 };
        body.extend_from_slice(&initial_bitrate_bps.to_le_bytes());
        body.extend_from_slice(&initial_framerate.to_le_bytes());

        Self::send_packet_sync(&mut stream, PROTOCOL_INIT, &body)?;

        // 2. Wait for ACK
        let (ptype, _) = Self::receive_packet_sync(&mut stream)?;
        // 注意：Swift 中的 initializeAck 是 2，我们需要对齐常量！
        if ptype != 2 {
            bail!("Expected ACK (2) after INIT, got {}", ptype);
        }

        info!("macOS hardware encoder initialized successfully");

        let stream_recv = stream.try_clone()?;
        let is_running = Arc::new(AtomicBool::new(true));
        
        let is_running_clone = is_running.clone();
        thread::spawn(move || {
            Self::receive_loop(stream_recv, is_running_clone, nal_callback);
        });

        Ok(Self { 
            stream_send: stream,
            is_running,
        })
    }

    pub fn update_params(&mut self, bitrate_bps: u64, framerate: f32) -> Result<()> {
        let mut body = Vec::new();
        body.extend_from_slice(&bitrate_bps.to_le_bytes());
        body.extend_from_slice(&framerate.to_le_bytes());
        Self::send_packet_sync(&mut self.stream_send, PROTOCOL_UPDATE_PARAMS, &body)
    }

    pub fn send_frame(
        &mut self,
        timestamp_ns: u64,
        insert_idr: bool,
        width: u32,
        height: u32,
        row_pitch: u32,
        pixel_format: u8,
        data: &[u8],
    ) -> Result<()> {
        if !self.is_running.load(Ordering::Relaxed) {
            bail!("macOS encoder client is stopped");
        }

        // FrameHeader: width (4), height (4), rowPitch (4), timestampNs (8), insertIDR (1), pixelFormat (1), dataSize (4) = 26 bytes
        let mut body = Vec::with_capacity(data.len() + 26);
        body.extend_from_slice(&width.to_le_bytes());
        body.extend_from_slice(&height.to_le_bytes());
        body.extend_from_slice(&row_pitch.to_le_bytes());
        body.extend_from_slice(&timestamp_ns.to_le_bytes());
        body.extend_from_slice(&[if insert_idr { 1 } else { 0 }]);
        body.extend_from_slice(&[pixel_format]);
        body.extend_from_slice(&(data.len() as u32).to_le_bytes());
        body.extend_from_slice(data);
        
        Self::send_packet_sync(&mut self.stream_send, PROTOCOL_FRAME, &body)
    }

    fn receive_loop(
        mut stream: TcpStream,
        is_running: Arc<AtomicBool>,
        nal_callback: impl Fn(u64, bool, &[u8]),
    ) {
        while is_running.load(Ordering::Relaxed) {
            match Self::receive_packet_sync(&mut stream) {
                Ok((ptype, body)) => {
                    if ptype == PROTOCOL_PACKET {
                        // EncodedPacket (Mac -> VM): timestampNs (8), isIDR (1), size (4), data
                        if body.len() >= 13 {
                            let timestamp_ns = u64::from_le_bytes(body[0..8].try_into().unwrap());
                            let is_idr = body[8] != 0;
                            let size = u32::from_le_bytes(body[9..13].try_into().unwrap()) as usize;
                            if body.len() >= 13 + size {
                                let nal_data = &body[13..13 + size];
                                nal_callback(timestamp_ns, is_idr, nal_data);
                            }
                        }
                    }
                }
                Err(e) => {
                    if let Some(io_err) = e.downcast_ref::<std::io::Error>() {
                        if io_err.kind() == ErrorKind::TimedOut || io_err.kind() == ErrorKind::WouldBlock {
                            continue;
                        }
                    }
                    error!("macOS encoder receive loop error: {}", e);
                    is_running.store(false, Ordering::Relaxed);
                    break;
                }
            }
        }
    }

    fn receive_packet_sync(stream: &mut TcpStream) -> Result<(u32, Vec<u8>)> {
        let mut header = [0u8; 8];
        stream.read_exact(&mut header)?;
        
        let ptype = u32::from_le_bytes(header[0..4].try_into().unwrap());
        let length = u32::from_le_bytes(header[4..8].try_into().unwrap());
        
        let mut body = vec![0u8; length as usize];
        if length > 0 {
            stream.read_exact(&mut body)?;
        }
        Ok((ptype, body))
    }

    fn send_packet_sync(stream: &mut TcpStream, ptype: u32, body: &[u8]) -> Result<()> {
        let mut packet = Vec::with_capacity(body.len() + 8);
        packet.extend_from_slice(&ptype.to_le_bytes());
        packet.extend_from_slice(&(body.len() as u32).to_le_bytes());
        packet.extend_from_slice(body);
        stream.write_all(&packet)?;
        Ok(())
    }
}

impl Drop for MacosEncoderClient {
    fn drop(&mut self) {
        self.is_running.store(false, Ordering::Relaxed);
        let _ = Self::send_packet_sync(&mut self.stream_send, PROTOCOL_SHUTDOWN, &[]);
    }
}
