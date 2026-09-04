import Foundation

/// Lightweight SMTP client for Gmail (smtp.gmail.com:465 implicit TLS).
actor SimpleSMTPClient {
    private var conn: MailTLSConnection?

    func connect(host: String = "smtp.gmail.com", port: UInt16 = 465) async throws {
        let c = MailTLSConnection(host: host, port: port)
        try await c.connect()
        conn = c
        let greet = try await readResponse()
        guard greet.code == 220 else { throw MailNetError.smtpFailed(greet.raw) }
    }

    func login(email: String, password: String) async throws {
        guard let conn else { throw MailNetError.unexpected("Not connected") }
        try await conn.sendLine("EHLO rapsodee.local")
        let ehlo = try await readResponse()
        guard ehlo.code == 250 else { throw MailNetError.smtpFailed(ehlo.raw) }

        try await conn.sendLine("AUTH LOGIN")
        _ = try await readResponse() // 334
        try await conn.sendLine(Data(email.utf8).base64EncodedString())
        _ = try await readResponse()
        let pass = password.replacingOccurrences(of: " ", with: "")
        try await conn.sendLine(Data(pass.utf8).base64EncodedString())
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
        guard let conn else { throw MailNetError.unexpected("Not connected") }
        let recipients = (to + cc).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !recipients.isEmpty else { throw MailNetError.smtpFailed("No recipients") }

        try await conn.sendLine("MAIL FROM:<\(from)>")
        let mailFrom = try await readResponse()
        guard mailFrom.code == 250 else { throw MailNetError.smtpFailed(mailFrom.raw) }

        for rcpt in recipients {
            try await conn.sendLine("RCPT TO:<\(rcpt)>")
            let r = try await readResponse()
            guard r.code == 250 || r.code == 251 else { throw MailNetError.smtpFailed(r.raw) }
        }

        try await conn.sendLine("DATA")
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
        // Dot-stuff lines starting with .
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
        try await conn.sendData(Data(message.utf8))
        let done = try await readResponse()
        guard done.code == 250 else { throw MailNetError.smtpFailed(done.raw) }
    }

    func quit() async {
        if let conn {
            try? await conn.sendLine("QUIT")
            _ = try? await readResponse()
            conn.close()
        }
        conn = nil
    }

    private struct SMTPResponse {
        var code: Int
        var raw: String
    }

    private func readResponse() async throws -> SMTPResponse {
        guard let conn else { throw MailNetError.unexpected("Not connected") }
        var lines: [String] = []
        while true {
            let line = try await conn.readLine()
            lines.append(line)
            // "250-..." continues; "250 ..." ends
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
