import Foundation
import Network

/// TCP 网络服务器
/// 监听来自 Windows VM 中 ALVR 的连接，处理二进制协议消息
final class NetworkServer {
    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private var encoder: VideoToolboxEncoder?
    private let port: UInt16
    private let queue = DispatchQueue(label: "alvr.encoder.network", qos: .userInteractive)

    /// 接收缓冲区
    private var receiveBuffer = Data()

    init(port: UInt16 = 9945) {
        self.port = port
    }

    // MARK: - Server Lifecycle

    func start() throws {
        // 配置 TCP 参数: 禁用 Nagle 算法，降低延迟
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)

        let nwPort = NWEndpoint.Port(rawValue: port)!
        listener = try NWListener(using: params, on: nwPort)

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[Server] Listening on port \(self?.port ?? 0)")
            case .failed(let error):
                print("[Server] Listener failed: \(error)")
                self?.listener?.cancel()
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener?.start(queue: queue)
        print("[Server] Starting on port \(port)...")
    }

    func stop() {
        activeConnection?.cancel()
        listener?.cancel()
        encoder = nil
        print("[Server] Stopped")
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        // 只允许一个活跃连接
        if let existing = activeConnection {
            print("[Server] Replacing existing connection")
            existing.cancel()
            encoder = nil
        }

        activeConnection = connection
        receiveBuffer = Data()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let endpoint = connection.endpoint
                print("[Server] Client connected: \(endpoint)")
                self?.startReceiving(connection)
            case .failed(let error):
                print("[Server] Connection failed: \(error)")
                self?.activeConnection = nil
                self?.encoder = nil
            case .cancelled:
                print("[Server] Connection closed")
                self?.activeConnection = nil
                self?.encoder = nil
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    // MARK: - Message Receiving

    private func startReceiving(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024 * 1024) {
            [weak self] data, _, isComplete, error in

            if let error = error {
                print("[Server] Receive error: \(error)")
                connection.cancel()
                return
            }

            if let data = data, !data.isEmpty {
                self?.receiveBuffer.append(data)
                self?.processMessages(connection)
            }

            if isComplete {
                print("[Server] Connection completed")
                connection.cancel()
                return
            }

            // 继续接收
            self?.startReceiving(connection)
        }
    }

    /// 解析缓冲区中的完整消息
    private func processMessages(_ connection: NWConnection) {
        while receiveBuffer.count >= 8 {
            // 读取消息头: [4B type][4B total_body_len]
            var offset = 0
            let typeRaw = receiveBuffer.readUInt32(at: &offset)
            let bodyLen = receiveBuffer.readUInt32(at: &offset)

            let totalMessageSize = 8 + Int(bodyLen)
            guard receiveBuffer.count >= totalMessageSize else {
                // 还没收完整，等下一次
                return
            }

            // 提取消息体
            let body = receiveBuffer.subdata(in: 8..<totalMessageSize)
            receiveBuffer.removeFirst(totalMessageSize)

            // 分发处理
            guard let msgType = MessageType(rawValue: typeRaw) else {
                print("[Server] Unknown message type: \(typeRaw)")
                continue
            }

            handleMessage(msgType, body: body, connection: connection)
        }
    }

    // MARK: - Message Dispatch

    private func handleMessage(_ type: MessageType, body: Data, connection: NWConnection) {
        switch type {
        case .initialize:
            handleInit(body: body, connection: connection)
        case .frame:
            handleFrame(body: body, connection: connection)
        case .updateParams:
            handleUpdateParams(body: body)
        case .shutdown:
            handleShutdown()
        default:
            print("[Server] Unhandled message type: \(type)")
        }
    }

    private func handleInit(body: Data, connection: NWConnection) {
        guard let msg = InitMessage.decode(from: body) else {
            sendInitAck(success: false, message: "Invalid init message", connection: connection)
            return
        }

        print("[Server] Init request: \(msg.width)x\(msg.height), codec: \(msg.codec), bitrate: \(msg.bitrateBps)")

        do {
            var config = EncoderConfig()
            config.width = Int(msg.width)
            config.height = Int(msg.height)
            config.codec = msg.codec
            config.bitrateBps = msg.bitrateBps
            config.framerate = msg.framerate
            config.prioritizeQualityOverSpeed = !msg.prioritizeSpeed
            config.realtime = msg.realtime
            config.enableLowLatencyRateControl = msg.enableLowLatencyRateControl
            config.allowFrameReordering = msg.allowFrameReordering

            encoder = try VideoToolboxEncoder(config: config)

            // 设置编码回调
            encoder?.onEncodedPacket = { [weak self] timestampNs, isIDR, nalData in
                let packet = EncodedPacket(timestampNs: timestampNs, isIDR: isIDR, data: nalData)
                self?.sendData(packet.encode(), connection: connection)
            }

            sendInitAck(success: true, message: "OK", connection: connection)
            print("[Server] Encoder initialized successfully")
        } catch {
            sendInitAck(success: false, message: "\(error)", connection: connection)
            print("[Server] Encoder init failed: \(error)")
        }
    }

    private func handleFrame(body: Data, connection: NWConnection) {
        guard let encoder = encoder else {
            print("[Server] Frame received but no encoder")
            return
        }

        // 解析帧头
        guard let header = FrameHeader.decode(from: body) else {
            print("[Server] Invalid frame header")
            return
        }

        // 帧数据紧跟在帧头之后
        let pixelDataOffset = FrameHeader.bodySize
        guard body.count >= pixelDataOffset + Int(header.dataSize) else {
            print("[Server] Frame data truncated: expected \(header.dataSize), got \(body.count - pixelDataOffset)")
            return
        }

        let pixelData = body.subdata(in: pixelDataOffset..<pixelDataOffset + Int(header.dataSize))

        encoder.encodeFrame(pixelData: pixelData, header: header)
    }

    private func handleUpdateParams(body: Data) {
        guard let msg = UpdateParamsMessage.decode(from: body) else { return }
        encoder?.updateParams(bitrateBps: msg.bitrateBps, framerate: msg.framerate)
    }

    private func handleShutdown() {
        print("[Server] Shutdown requested")
        encoder = nil
        activeConnection?.cancel()
    }

    // MARK: - Sending

    private func sendInitAck(success: Bool, message: String, connection: NWConnection) {
        let ack = InitAckMessage(success: success, message: message)
        sendData(ack.encode(), connection: connection)
    }

    private func sendData(_ data: Data, connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("[Server] Send error: \(error)")
            }
        })
    }
}
