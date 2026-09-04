import Foundation

/// Lightweight SMTP client — Gmail implicit TLS (465) or Office 365 STARTTLS (587).
actor SimpleSMTPClient {
    private enum Backend {
        case tls(MailTLSConnection)
        case startTLS(MailStartTLSConnection)
    }

    private var backend: Backend?

    func connect(host: String = "smtp.gmail.com", port: UInt16 = 465, startTLS: Bool = false) async throws {
        if startTLS {
            let c = MailStartTLSConnection(host: host, port: port)
            try await c.connect()
            backend = .startTLS(c)
            let greet = try await readResponse()
            guard greet.code == 220 else { throw MailNetError.smtpFailed(greet.raw) }

            try await sendLine("EHLO rapsodee.local")
            let ehlo = try await readResponse()
            guard ehlo.code == 250 else { throw MailNetError.smtpFailed(ehlo.raw) }

            try await sendLine("STARTTLS")
            let tlsReady = try await readResponse()
            guard tlsReady.code == 220 else { throw MailNetError.smtpFailed(tlsReady.raw) }
            try await c.startTLS()
        } else {
            let c = MailTLSConnection(host: host, port: port)
            try await c.connect()
            backend = .tls(c)
            let greet = try await readResponse()
            guard greet.code == 220 else { throw MailNetError.smtpFailed(greet.raw) }
        }
    }

    func login(email: String, password: String, stripSpaces: Bool = true) async throws {
        guard backend != nil else { throw MailNetError.unexpected("Not connected") }
        try await sendLine("EHLO rapsodee.local")
        let ehlo = try await readResponse()
        guard ehlo.code == 250 else { throw MailNetError.smtpFailed(ehlo.raw) }

        try await sendLine("AUTH LOGIN")
        _ = try await readResponse() // 334
        try await sendLine(Data(email.utf8).base64EncodedString())
        _ = try await readResponse()
        let pass = stripSpaces ? password.replacingOccurrences(of: " ", with: "") : password
        try await sendLine(Data(pass.utf8).base64EncodedString())
        let auth = try await readResponse()
        guard auth.code == 235 else { throw MailNetError.authFailed(auth.raw) }
    }

    func send(
        from: String,
        to: [String],
        cc: [String] = [],
        subject: String,
        body: String
    ) async throws {
        guard backend != nil else { throw MailNetError.unexpected("Not connected") }
        let recipients = (to + cc).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !recipients.isEmpty else { throw MailNetError.smtpFailed("No recipients") }

        try await sendLine("MAIL FROM:<\(from)>")
        let mailFrom = try await readResponse()
        guard mailFrom.code == 250 else { throw MailNetError.smtpFailed(mailFrom.raw) }

        for rcpt in recipients {
            try await sendLine("RCPT TO:<\(rcpt)>")
            let r = try await readResponse()
            guard r.code == 250 || r.code == 251 else { throw MailNetError.smtpFailed(r.raw) }
        }

        try await sendLine("DATA")
        let dataReady = try await readResponse()
        guard dataReady.code == 354 else { throw MailNetError.smtpFailed(dataReady.raw) }

        var message = ""
        message += "From: \(from)\r\n"
        message += "To: \(to.joined(separator: ", "))\r\n"
        if !cc.isEmpty {
            message += "Cc: \(cc.joined(separator: ", "))\r\n"
        }
        message += "Subject: \(subject)\r\n"
        message += "MIME-Version: 1.0\r\n"
        message += "Content-Type: text/plain; charset=utf-8\r\n"
        message += "Content-Transfer-Encoding: 8bit\r\n"
        message += "Date: \(rfc2822Now())\r\n"
        message += "\r\n"
        let stuffed = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let s = String(line)
                return s.hasPrefix(".") ? "." + s : s
            }
            .joined(separator: "\r\n")
        message += stuffed
        message += "\r\n.\r\n"
        try await sendData(Data(message.utf8))
        let done = try await readResponse()
        guard done.code == 250 else { throw MailNetError.smtpFailed(done.raw) }
    }

    func quit() async {
        if backend != nil {
            try? await sendLine("QUIT")
            _ = try? await readResponse()
        }
        switch backend {
        case .tls(let c): c.close()
        case .startTLS(let c): c.close()
        case .none: break
        }
        backend = nil
    }

    private struct SMTPResponse {
        var code: Int
        var raw: String
    }

    private func sendLine(_ line: String) async throws {
        switch backend {
        case .tls(let c): try await c.sendLine(line)
        case .startTLS(let c): try await c.sendLine(line)
        case .none: throw MailNetError.unexpected("Not connected")
        }
    }

    private func sendData(_ data: Data) async throws {
        switch backend {
        case .tls(let c): try await c.sendData(data)
        case .startTLS(let c): try await c.sendData(data)
        case .none: throw MailNetError.unexpected("Not connected")
        }
    }

    private func readResponse() async throws -> SMTPResponse {
        var lines: [String] = []
        while true {
            let line: String
            switch backend {
            case .tls(let c): line = try await c.readLine()
            case .startTLS(let c): line = try await c.readLine()
            case .none: throw MailNetError.unexpected("Not connected")
            }
            lines.append(line)
            if line.count >= 4 {
                let codePart = String(line.prefix(3))
                let sep = line.dropFirst(3).first
                if sep == " " || sep == nil {
                    let code = Int(codePart) ?? 0
                    return SMTPResponse(code: code, raw: lines.joined(separator: "\n"))
                }
            }
        }
    }

    private func rfc2822Now() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: Date())
    }
}
