import AVFoundation
import CryptoKit
import Foundation
import Network

final class WebSocketAudioServer {
    private let port: UInt16
    private let sampleRate: Double
    private let channelCount: Int
    private let queue = DispatchQueue(label: "com.local.resonance432.websocket-audio-server")
    private let stateLock = NSLock()
    private var listener: NWListener?
    private var clients: [UUID: NWConnection] = [:]
    private var audioSendInFlight = false
    private var _isListening = false
    private var _connectedClientCount = 0
    private var _droppedAudioFrames: UInt64 = 0

    init(sampleRate: Double, channelCount: Int, port: UInt16 = 8765) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.port = port
    }

    var connectedClientCount: Int {
        stateLock.withLock { _connectedClientCount }
    }

    var isListening: Bool {
        stateLock.withLock { _isListening }
    }

    var listeningPort: UInt16 {
        port
    }

    var droppedAudioFrames: UInt64 {
        stateLock.withLock { _droppedAudioFrames }
    }

    func start() throws {
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        let newListener = try NWListener(using: parameters, on: nwPort)
        newListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.stateLock.withLock { self._isListening = true }
                print("432 Resonance WebSocket server listening at ws://127.0.0.1:\(self.port)/audio")
            case .failed(let error):
                self.stateLock.withLock { self._isListening = false }
                print("432 Resonance WebSocket server error: \(error)")
            case .cancelled:
                self.stateLock.withLock { self._isListening = false }
                print("432 Resonance WebSocket server stopped.")
            default:
                break
            }
        }

        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        listener = newListener
        newListener.start(queue: queue)
    }

    func stop() {
        queue.async {
            self.clients.values.forEach { $0.cancel() }
            self.clients.removeAll()
            self.stateLock.withLock {
                self._connectedClientCount = 0
                self.audioSendInFlight = false
                self._isListening = false
            }
            self.listener?.cancel()
            self.listener = nil
        }
    }

    @discardableResult
    func broadcastPCMChunk(_ data: Data, frameCount: Int) -> Bool {
        let accepted = stateLock.withLock {
            guard _connectedClientCount > 0, !audioSendInFlight else {
                _droppedAudioFrames += UInt64(frameCount)
                return false
            }
            audioSendInFlight = true
            return true
        }
        guard accepted else {
            return false
        }

        queue.async {
            guard !self.clients.isEmpty else {
                self.stateLock.withLock { self.audioSendInFlight = false }
                return
            }

            let frame = Self.binaryWebSocketFrame(payload: data)
            let sendGroup = DispatchGroup()
            for (clientID, connection) in self.clients {
                sendGroup.enter()
                connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                    defer { sendGroup.leave() }
                    guard let self else { return }
                    if let error {
                        print("432 Resonance WebSocket send error for client \(clientID): \(error)")
                        self.removeClient(clientID)
                    }
                })
            }
            sendGroup.notify(queue: self.queue) {
                self.stateLock.withLock { self.audioSendInFlight = false }
            }
        }
        return true
    }
}

private extension WebSocketAudioServer {
    func accept(_ connection: NWConnection) {
        let clientID = UUID()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                print("432 Resonance WebSocket client \(clientID) failed: \(error)")
                self?.removeClient(clientID)
            case .cancelled:
                self?.removeClient(clientID)
            default:
                break
            }
        }

        connection.start(queue: queue)
        readHandshake(from: connection, clientID: clientID, requestData: Data())
    }

    func readHandshake(from connection: NWConnection, clientID: UUID, requestData: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }

            if let error {
                print("432 Resonance WebSocket handshake error for client \(clientID): \(error)")
                connection.cancel()
                return
            }

            var accumulatedData = requestData
            if let data {
                accumulatedData.append(data)
            }

            guard let request = String(data: accumulatedData, encoding: .utf8) else {
                connection.cancel()
                return
            }

            if request.contains("\r\n\r\n") {
                self.finishHandshake(request: request, connection: connection, clientID: clientID)
            } else if isComplete {
                connection.cancel()
            } else {
                self.readHandshake(from: connection, clientID: clientID, requestData: accumulatedData)
            }
        }
    }

    func finishHandshake(request: String, connection: NWConnection, clientID: UUID) {
        guard request.hasPrefix("GET "),
              let key = Self.headerValue(named: "Sec-WebSocket-Key", in: request) else {
            print("432 Resonance WebSocket rejected non-WebSocket client \(clientID).")
            connection.cancel()
            return
        }

        let acceptKey = Self.acceptKey(for: key)
        let response =
            "HTTP/1.1 101 Switching Protocols\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Accept: \(acceptKey)\r\n" +
            "\r\n"

        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { [weak self] error in
            guard let self else {
                return
            }

            if let error {
                print("432 Resonance WebSocket handshake response error for client \(clientID): \(error)")
                connection.cancel()
                return
            }

            self.queue.async {
                self.clients[clientID] = connection
                self.stateLock.withLock { self._connectedClientCount = self.clients.count }
                print("432 Resonance WebSocket client connected: \(clientID). clients=\(self.clients.count)")
                let metadata = "{\"type\":\"audio-format\",\"sampleRate\":\(self.sampleRate),\"channelCount\":\(self.channelCount),\"sampleFormat\":\"float32-le-interleaved\"}"
                connection.send(
                    content: Self.textWebSocketFrame(payload: Data(metadata.utf8)),
                    completion: .idempotent
                )
                self.receiveClientControlFrames(from: connection, clientID: clientID)
            }
        })
    }

    func receiveClientControlFrames(from connection: NWConnection, clientID: UUID) {
        connection.receive(minimumIncompleteLength: 2, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }

            if let error {
                print("432 Resonance WebSocket receive error for client \(clientID): \(error)")
                self.removeClient(clientID)
                return
            }

            if let firstByte = data?.first {
                let opcode = firstByte & 0x0F
                if opcode == 0x8 {
                    print("432 Resonance WebSocket client requested close: \(clientID)")
                    self.removeClient(clientID)
                    return
                }
            }

            if isComplete {
                self.removeClient(clientID)
            } else {
                self.receiveClientControlFrames(from: connection, clientID: clientID)
            }
        }
    }

    func removeClient(_ clientID: UUID) {
        queue.async {
            guard let connection = self.clients.removeValue(forKey: clientID) else {
                return
            }

            connection.cancel()
            self.stateLock.withLock { self._connectedClientCount = self.clients.count }
            print("432 Resonance WebSocket client disconnected: \(clientID). clients=\(self.clients.count)")
        }
    }

    static func headerValue(named name: String, in request: String) -> String? {
        request
            .components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix(name.lowercased() + ":") }?
            .split(separator: ":", maxSplits: 1)
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func acceptKey(for key: String) -> String {
        let magic = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data(magic.utf8))
        return Data(digest).base64EncodedString()
    }

    static func binaryWebSocketFrame(payload: Data) -> Data {
        webSocketFrame(opcode: 0x82, payload: payload)
    }

    static func textWebSocketFrame(payload: Data) -> Data {
        webSocketFrame(opcode: 0x81, payload: payload)
    }

    static func webSocketFrame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data()
        frame.append(opcode)

        switch payload.count {
        case 0...125:
            frame.append(UInt8(payload.count))
        case 126...65_535:
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        default:
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((UInt64(payload.count) >> UInt64(shift)) & 0xFF))
            }
        }

        frame.append(payload)
        return frame
    }
}
