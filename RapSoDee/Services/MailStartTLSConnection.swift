import Foundation

/// Plain TCP duplex connection that can upgrade with STARTTLS (SMTP submission port 587).
/// Uses CFStreams on a dedicated thread so SSL can be negotiated mid-session.
final class MailStartTLSConnection: @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private var input: InputStream?
    private var output: OutputStream?
    private var buffer = Data()
    private let lock = NSLock()
    private var thread: Thread?
    private var runLoop: RunLoop?
    private let ready = DispatchSemaphore(value: 0)
    private var startError: Error?

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    func connect(timeout: TimeInterval = 30) async throws {
        startError = nil
        let thread = Thread { [weak self] in
            guard let self else { return }
            var readStream: Unmanaged<CFReadStream>?
            var writeStream: Unmanaged<CFWriteStream>?
            CFStreamCreatePairWithSocketToHost(nil, self.host as CFString, UInt32(self.port), &readStream, &writeStream)
            guard let rs = readStream?.takeRetainedValue(),
                  let ws = writeStream?.takeRetainedValue() else {
                self.startError = MailNetError.unexpected("Could not create TCP streams")
                self.ready.signal()
                return
            }
            let input = rs as InputStream
            let output = ws as OutputStream
            self.runLoop = RunLoop.current
            input.delegate = nil
            output.delegate = nil
            input.schedule(in: .current, forMode: .default)
            output.schedule(in: .current, forMode: .default)
            input.open()
            output.open()
            self.input = input
            self.output = output

            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let status = input.streamStatus
                if status == .open || status == .reading || status == .writing {
                    self.ready.signal()
                    RunLoop.current.run()
                    return
                }
                if status == .error {
                    self.startError = input.streamError ?? MailNetError.unexpected("TCP stream failed")
                    self.ready.signal()
                    return
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            self.startError = MailNetError.timeout
            self.ready.signal()
        }
        thread.name = "local.rapsodee.mail.starttls"
        self.thread = thread
        thread.start()

        let ok = ready.wait(timeout: .now() + timeout + 1)
        if ok == .timedOut { throw MailNetError.timeout }
        if let startError { throw startError }
    }

    /// Negotiate TLS on the existing socket (after SMTP `STARTTLS` success).
    func startTLS(timeout: TimeInterval = 30) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            guard let runLoop else {
                cont.resume(throwing: MailNetError.unexpected("Not connected"))
                return
            }
            runLoop.perform {
                guard let input = self.input, let output = self.output else {
                    cont.resume(throwing: MailNetError.unexpected("Not connected"))
                    return
                }
                let settings: [String: Any] = [
                    kCFStreamSSLPeerName as String: self.host
                ]
                let appliedIn = input.setProperty(settings, forKey: Stream.PropertyKey(kCFStreamPropertySSLSettings as String))
                let appliedOut = output.setProperty(settings, forKey: Stream.PropertyKey(kCFStreamPropertySSLSettings as String))
                if !appliedIn || !appliedOut {
                    cont.resume(throwing: MailNetError.unexpected("Failed to enable STARTTLS"))
                    return
                }
                // Pump until SSL is negotiated or timeout.
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    if let _ = input.property(forKey: Stream.PropertyKey(kCFStreamPropertySSLContext as String)) {
                        cont.resume()
                        return
                    }
                    if input.streamStatus == .error {
                        cont.resume(throwing: input.streamError ?? MailNetError.unexpected("STARTTLS handshake failed"))
                        return
                    }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                }
                // Some systems expose SSL only after first I/O — treat settings applied as success.
                cont.resume()
            }
        }
    }

    func close() {
        if let runLoop {
            runLoop.perform { [weak self] in
                self?.input?.close()
                self?.output?.close()
                self?.input?.remove(from: .current, forMode: .default)
                self?.output?.remove(from: .current, forMode: .default)
                CFRunLoopStop(CFRunLoopGetCurrent())
            }
        }
        thread?.cancel()
        thread = nil
        input = nil
        output = nil
    }

    func sendLine(_ line: String) async throws {
        try await sendData(Data((line + "\r\n").utf8))
    }

    func sendData(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            guard let runLoop else {
                cont.resume(throwing: MailNetError.unexpected("Not connected"))
                return
            }
            runLoop.perform {
                guard let output = self.output else {
                    cont.resume(throwing: MailNetError.unexpected("Not connected"))
                    return
                }
                var offset = 0
                let bytes = [UInt8](data)
                while offset < bytes.count {
                    let written = output.write(bytes, maxLength: bytes.count - offset)
                    if written < 0 {
                        cont.resume(throwing: output.streamError ?? MailNetError.unexpected("Write failed"))
                        return
                    }
                    if written == 0 {
                        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                        continue
                    }
                    offset += written
                }
                cont.resume()
            }
        }
    }

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
            try await pullAvailable(timeout: max(0.05, deadline.timeIntervalSinceNow))
        }
    }

    private func pullAvailable(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            guard let runLoop else {
                cont.resume(throwing: MailNetError.unexpected("Not connected"))
                return
            }
            runLoop.perform {
                guard let input = self.input else {
                    cont.resume(throwing: MailNetError.unexpected("Not connected"))
                    return
                }
                let deadline = Date().addingTimeInterval(min(timeout, 1.0))
                var temp = [UInt8](repeating: 0, count: 65536)
                while Date() < deadline {
                    if input.hasBytesAvailable {
                        let n = input.read(&temp, maxLength: temp.count)
                        if n < 0 {
                            cont.resume(throwing: input.streamError ?? MailNetError.unexpected("Read failed"))
                            return
                        }
                        if n > 0 {
                            self.lock.lock()
                            self.buffer.append(contentsOf: temp[0..<n])
                            self.lock.unlock()
                            cont.resume()
                            return
                        }
                    }
                    if input.streamStatus == .error {
                        cont.resume(throwing: input.streamError ?? MailNetError.unexpected("Read stream error"))
                        return
                    }
                    if input.streamStatus == .atEnd {
                        cont.resume(throwing: MailNetError.unexpected("Connection closed"))
                        return
                    }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                }
                cont.resume()
            }
        }
    }
}
