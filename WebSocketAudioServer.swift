import AVFoundation
import CryptoKit
import Foundation
import Network

final class WebSocketAudioServer {
    private let port: UInt16
    private let queue = DispatchQueue(label: "com.local.resonance432.websocket-audio-server")
    private var listener: NWListener?
    private var clients: [UUID: NWConnection] = [:]
    private var broadcastLogCount = 0

    init(port: UInt16 = 8765) {
        self.port = port
    }

    func start() throws {
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        let newListener = try NWListener(using: parameters, on: nwPort)
        newListener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("432 Resonance WebSocket server listening at ws://127.0.0.1:\(self.port)/audio")
            case .failed(let error):
                print("432 Resonance WebSocket server error: \(error)")
            case .cancelled:
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
            self.listener?.cancel()
            self.listener = nil
            self.broadcastLogCount = 0
        }
    }

    func broadcastPCMChunk(_ data: Data, sampleRate: Double, channelCount: AVAudioChannelCount) {
        queue.async {
            guard !self.clients.isEmpty else {
                return
            }

            self.broadcastLogCount += 1
            let frame = Self.binaryWebSocketFrame(payload: data)

            if self.broadcastLogCount <= 5 || self.broadcastLogCount.isMultiple(of: 50) {
                print(
                    "432 Resonance WebSocket broadcast #\(self.broadcastLogCount): " +
                    "chunkBytes=\(data.count), " +
                    "sampleRate=\(sampleRate), " +
                    "channels=\(channelCount), " +
                    "clients=\(self.clients.count)"
                )
            }

            for (clientID, connection) in self.clients {
                connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                    if let error {
                        print("432 Resonance WebSocket send error for client \(clientID): \(error)")
                        self?.removeClient(clientID)
                    }
                })
            }
        }
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
        let response = """
        HTTP/1.1 101 Switching Protocols\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Accept: \(acceptKey)\r
        \r
        """

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
                print("432 Resonance WebSocket client connected: \(clientID). clients=\(self.clients.count)")
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
        var frame = Data()
        frame.append(0x82)

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
