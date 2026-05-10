import Foundation

/// ALVR macOS Encoder Helper
/// 运行在 macOS 宿主机上，通过 TCP 为 Windows VM 中的 ALVR 提供 VideoToolbox 硬件编码
///
/// 用法:
///   alvr_encoder_helper [--port 9945]

func main() {
    print("=== ALVR macOS Encoder Helper ===")
    print("VideoToolbox hardware encoder for ALVR (Windows VM → macOS host)")
    print("")

    // 解析命令行参数
    let args = CommandLine.arguments
    var port: UInt16 = 9945

    if let portIdx = args.firstIndex(of: "--port"), portIdx + 1 < args.count,
       let p = UInt16(args[portIdx + 1]) {
        port = p
    }

    // 创建并启动服务器
    let server = NetworkServer(port: port)

    do {
        try server.start()
    } catch {
        print("[Fatal] Failed to start server: \(error)")
        exit(1)
    }

    // 注册信号处理器
    signal(SIGINT) { _ in
        print("\n[Signal] Shutting down...")
        exit(0)
    }
    signal(SIGTERM) { _ in
        print("\n[Signal] Shutting down...")
        exit(0)
    }

    print("[Main] Server running. Press Ctrl+C to stop.")
    print("[Main] Waiting for ALVR connection on port \(port)...")

    // 保持主线程运行
    dispatchMain()
}

main()
