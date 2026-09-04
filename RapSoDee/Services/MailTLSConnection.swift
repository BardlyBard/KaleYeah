import Foundation
import Network

/// Minimal TLS line-oriented connection for IMAP/SMTP (macOS Network.framework).
final class MailTLSConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "local.rapsodee.mail.tls")
    private var buffer = Data()
    private let lock = NSLock()

    init(host: String, port: UInt16) {
        let tls = NWProtocolTLS.Options()
        let params = NWParameters(tls: tls, tcp: .init())
        params.allowLocalEndpointReuse = true
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
    }

    func connect(timeout: TimeInterval = 30) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            let finish: (Result<Void, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                cont.resume(with: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.success(()))
                case .failed(let error):
                    finish(.failure(error))
                case .cancelled:
                    finish(.failure(MailNetError.cancelled))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(.failure(MailNetError.timeout))
            }
        }
        startReceiveLoop()
    }

    func close() {
        connection.cancel()
    }

    func sendLine(_ line: String) async throws {
        let payload = Data((line + "\r\n").utf8)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: payload, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    func sendData(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    /// Read until CRLF. Returns line without CRLF.
    func readLine(timeout: TimeInterval = 60) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            lock.lock()
            if let range = buffer.range(of: Data([0x0D, 0x0A])) {
                let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                lock.unlock()
                return String(data: lineData, encoding: .utf8) ?? String(decoding: lineData, as: UTF8.self)
            }
            lock.unlock()
            if Date() > deadline { throw MailNetError.timeout }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Read exactly `count` bytes (for IMAP literals).
    func readExact(_ count: Int, timeout: TimeInterval = 120) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            lock.lock()
            if buffer.count >= count {
                let chunk = buffer.prefix(count)
                buffer.removeFirst(count)
                lock.unlock()
                return Data(chunk)
            }
            lock.unlock()
            if Date() > deadline { throw MailNetError.timeout }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func startReceiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let content, !content.isEmpty {
                self.lock.lock()
                self.buffer.append(content)
                self.lock.unlock()
            }
            if error == nil, !isComplete {
                self.startReceiveLoop()
            }
        }
    }
}

enum MailNetError: LocalizedError {
    case timeout
    case cancelled
    case unexpected(String)
    case authFailed(String)
    case smtpFailed(String)

    var errorDescription: String? {
        switch self {
        case .timeout: return "Connection timed out"
        case .cancelled: return "Connection cancelled"
        case .unexpected(let s): return s
        case .authFailed(let s): return "Authentication failed: \(s)"
        case .smtpFailed(let s): return "SMTP error: \(s)"
        }
    }
}
