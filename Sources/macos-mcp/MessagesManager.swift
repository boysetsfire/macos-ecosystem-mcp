import Foundation
import MCP
import SQLite3

// SQLite wants a destructor sentinel for bound text so it copies the buffer.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - MessagesManager actor

/// Actor that owns all iMessage access.
///
/// Reads (list/read/search) go straight at the local `chat.db` SQLite database
/// opened **read-only + immutable** so we never lock Messages or trip on its WAL.
/// Sends go through `osascript`/AppleScript (Messages.framework is private) and
/// are gated by a fail-closed contact allowlist.
///
/// Reading `chat.db` and sending both require the process running this server to
/// have **Full Disk Access** (System Settings → Privacy & Security). That grant
/// cannot be requested programmatically — a failed DB open returns an actionable
/// error pointing the user at the setting.
actor MessagesManager {

    /// `~/Library/Messages/chat.db`
    private var dbPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Messages/chat.db").path
    }

    // MARK: - Tools

    /// List the most recent conversations, newest first.
    func listChats(args: [String: Value]) async throws -> String {
        let limit = max(1, min(args["limit"].asInt ?? 20, 100))
        let db = try openDB()
        defer { sqlite3_close(db) }

        let chats = try rows(db, """
            SELECT c.ROWID AS chat_id, c.guid AS guid, c.chat_identifier AS chat_identifier,
                   c.display_name AS display_name, MAX(m.date) AS last_date
            FROM chat c
            JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
            JOIN message m ON m.ROWID = cmj.message_id
            GROUP BY c.ROWID
            ORDER BY last_date DESC
            LIMIT ?
            """, [limit])

        guard !chats.isEmpty else { return "No conversations found." }

        var out = "Recent conversations (\(chats.count)):\n\n"
        for (i, chat) in chats.enumerated() {
            let chatId = chat["chat_id"] as? Int ?? 0
            let guid = chat["guid"] as? String ?? ""
            let identifier = chat["chat_identifier"] as? String ?? ""
            let display = (chat["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }

            // Participants for the title when there's no group display name.
            let participants = try rows(db, """
                SELECT h.id AS id
                FROM chat_handle_join chj
                JOIN handle h ON h.ROWID = chj.handle_id
                WHERE chj.chat_id = ?
                """, [chatId]).compactMap { $0["id"] as? String }

            let title = display
                ?? (participants.isEmpty ? identifier : participants.joined(separator: ", "))

            // Last message for a preview.
            let last = try rows(db, """
                SELECT m.text AS text, m.attributedBody AS attributedBody,
                       m.is_from_me AS is_from_me, m.date AS date
                FROM message m
                JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                WHERE cmj.chat_id = ?
                ORDER BY m.date DESC LIMIT 1
                """, [chatId]).first

            out += "\(i + 1). \(title)\n"
            out += "   guid: \(guid)\n"
            if let last {
                let ts = formatDate(last["date"] as? Int)
                let fromMe = (last["is_from_me"] as? Int ?? 0) == 1
                let body = truncate(messageText(last), 80)
                out += "   last: \(ts) — \(fromMe ? "Me: " : "")\(body)\n"
            }
            out += "\n"
        }
        return out
    }

    /// Read messages from a conversation, identified by `chat_guid` (precise) or `handle`.
    func readMessages(args: [String: Value]) async throws -> String {
        let chatGuid = args["chat_guid"]?.stringValue
        let handle = args["handle"]?.stringValue
        let limit = max(1, min(args["limit"].asInt ?? 25, 200))

        guard chatGuid != nil || handle != nil else {
            throw messagesError("Either 'chat_guid' (from imessage_list_chats) or 'handle' is required.")
        }

        let db = try openDB()
        defer { sqlite3_close(db) }

        // Resolve target chat ROWIDs.
        var chatIds: [Int]
        if let chatGuid {
            chatIds = try rows(db, "SELECT ROWID AS id FROM chat WHERE guid = ?", [chatGuid])
                .compactMap { $0["id"] as? Int }
            guard !chatIds.isEmpty else { throw messagesError("No conversation found with guid: \(chatGuid)") }
        } else {
            let wanted = normalizeHandle(handle!)
            let handleIds = try rows(db, "SELECT ROWID AS id, id AS handle FROM handle")
                .filter { normalizeHandle($0["handle"] as? String ?? "") == wanted }
                .compactMap { $0["id"] as? Int }
            guard !handleIds.isEmpty else { throw messagesError("No handle matching '\(handle!)' found in Messages.") }
            chatIds = try rows(db, """
                SELECT DISTINCT chat_id AS id FROM chat_handle_join
                WHERE handle_id IN (\(inClause(handleIds)))
                """).compactMap { $0["id"] as? Int }
            guard !chatIds.isEmpty else { throw messagesError("No conversation found for '\(handle!)'.") }
        }

        let messages = try rows(db, """
            SELECT m.ROWID AS rowid, m.text AS text, m.attributedBody AS attributedBody,
                   m.is_from_me AS is_from_me, m.date AS date,
                   m.cache_has_attachments AS has_attachments, h.id AS sender
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE cmj.chat_id IN (\(inClause(chatIds)))
            ORDER BY m.date DESC
            LIMIT ?
            """, [limit])

        guard !messages.isEmpty else { return "No messages found in that conversation." }

        var out = "Messages (\(messages.count), newest last):\n\n"
        for msg in messages.reversed() {
            let ts = formatDate(msg["date"] as? Int)
            let fromMe = (msg["is_from_me"] as? Int ?? 0) == 1
            let who = fromMe ? "Me" : (msg["sender"] as? String ?? "Unknown")
            let body = messageText(msg)
            out += "[\(ts)] \(who): \(body.isEmpty ? "(no text)" : body)\n"

            if (msg["has_attachments"] as? Int ?? 0) == 1, let rowid = msg["rowid"] as? Int {
                let atts = try rows(db, """
                    SELECT a.filename AS filename, a.transfer_name AS transfer_name, a.mime_type AS mime_type
                    FROM message_attachment_join maj
                    JOIN attachment a ON a.ROWID = maj.attachment_id
                    WHERE maj.message_id = ?
                    """, [rowid])
                for a in atts {
                    let name = (a["transfer_name"] as? String) ?? "attachment"
                    let mime = (a["mime_type"] as? String).map { " (\($0))" } ?? ""
                    let path = (a["filename"] as? String).map { expandTilde($0) } ?? "?"
                    out += "    📎 \(name)\(mime): \(path)\n"
                }
            }
        }
        return out
    }

    /// Full-text search over message bodies (case-insensitive LIKE).
    func searchMessages(args: [String: Value]) async throws -> String {
        guard let query = args["query"]?.stringValue, !query.isEmpty else {
            throw messagesError("'query' is required.")
        }
        let handleFilter = args["handle"]?.stringValue.map { normalizeHandle($0) }
        let limit = max(1, min(args["limit"].asInt ?? 25, 200))

        let db = try openDB()
        defer { sqlite3_close(db) }

        // Fetch extra when we'll post-filter by sender so the cap still holds after filtering.
        let fetch = handleFilter != nil ? limit * 4 : limit
        var results = try rows(db, """
            SELECT m.text AS text, m.is_from_me AS is_from_me, m.date AS date,
                   h.id AS sender, c.guid AS chat_guid, c.display_name AS display_name
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat c ON c.ROWID = cmj.chat_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE m.text LIKE ? ESCAPE '\\'
            ORDER BY m.date DESC
            LIMIT ?
            """, ["%\(escapeLike(query))%", fetch])

        if let handleFilter {
            results = results.filter { normalizeHandle($0["sender"] as? String ?? "") == handleFilter }
        }
        results = Array(results.prefix(limit))

        guard !results.isEmpty else { return "No messages found matching \"\(query)\"." }

        var out = "Found \(results.count) message(s) matching \"\(query)\":\n\n"
        for m in results {
            let ts = formatDate(m["date"] as? Int)
            let fromMe = (m["is_from_me"] as? Int ?? 0) == 1
            let who = fromMe ? "Me" : (m["sender"] as? String ?? "Unknown")
            let convo = (m["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (m["chat_guid"] as? String ?? "")
            out += "[\(ts)] \(who) in \(convo):\n    \(truncate(messageText(m), 200))\n\n"
        }
        return out
    }

    /// Send an iMessage (text and/or a file attachment) to an allowlisted handle.
    func sendMessage(args: [String: Value]) async throws -> String {
        guard let to = args["to"]?.stringValue, !to.isEmpty else {
            throw messagesError("'to' (phone number or Apple ID) is required.")
        }
        let text = args["text"]?.stringValue
        let filePath = args["file_path"]?.stringValue

        guard (text?.isEmpty == false) || (filePath?.isEmpty == false) else {
            throw messagesError("Provide 'text' and/or 'file_path' to send.")
        }

        // Fail-closed allowlist gate.
        let allowlist = loadAllowlist()
        guard !allowlist.isEmpty else {
            throw messagesError("""
                Sending is disabled: no contact allowlist configured. Set the \
                MACOS_MCP_IMESSAGE_ALLOWLIST env var (comma-separated handles) and/or create \
                ~/.config/macos-mcp/imessage-allowlist.json with {"allow": ["+15551234567"]}.
                """)
        }
        guard allowlist.contains(normalizeHandle(to)) else {
            throw messagesError("'\(to)' is not on the send allowlist. Add it to MACOS_MCP_IMESSAGE_ALLOWLIST or the allowlist file.")
        }

        // Validate the attachment path before touching AppleScript.
        var safeFileClause = ""
        if let filePath, !filePath.isEmpty {
            let resolved = resolvePath(filePath)
            guard FileManager.default.fileExists(atPath: resolved) else {
                throw messagesError("File not found: \(filePath)")
            }
            guard !isBlockedAttachmentPath(resolved) else {
                throw messagesError("Refusing to send a file from a protected directory (\(resolved)).")
            }
            safeFileClause = "    send POSIX file \"\(NotesHandler.escapeAppleScript(resolved))\" to targetBuddy\n"
        }

        var textClause = ""
        if let text, !text.isEmpty {
            textClause = "    send \"\(NotesHandler.escapeAppleScript(text))\" to targetBuddy\n"
        }

        let script = """
            tell application "Messages"
                set targetService to id of 1st account whose service type = iMessage
                set targetBuddy to buddy "\(NotesHandler.escapeAppleScript(to))" of account id targetService
            \(textClause)\(safeFileClause)end tell
            """

        _ = try await NotesHandler.runAppleScript(script)

        var what: [String] = []
        if text?.isEmpty == false { what.append("message") }
        if filePath?.isEmpty == false { what.append("file") }
        return "✓ Sent \(what.joined(separator: " + ")) to \(to)"
    }

    // MARK: - Allowlist / path safety

    private func loadAllowlist() -> Set<String> {
        var raw: [String] = []
        if let env = ProcessInfo.processInfo.environment["MACOS_MCP_IMESSAGE_ALLOWLIST"] {
            raw += env.split(separator: ",").map(String.init)
        }
        let cfg = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/macos-mcp/imessage-allowlist.json")
        if let data = try? Data(contentsOf: cfg),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let arr = obj["allow"] as? [String] {
            raw += arr
        }
        return Set(raw.map { normalizeHandle($0) }.filter { !$0.isEmpty })
    }

    /// Normalise a handle for comparison: emails lowercased, phones reduced to their
    /// last 10 digits (so +1 country codes and formatting differences still match).
    private func normalizeHandle(_ h: String) -> String {
        let t = h.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("@") { return t.lowercased() }
        let digits = t.filter(\.isNumber)
        return digits.count >= 10 ? String(digits.suffix(10)) : digits
    }

    private func resolvePath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath().path
    }

    private func isBlockedAttachmentPath(_ resolved: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let blocked = [home + "/.config/macos-mcp", home + "/Library/Messages"]
        return blocked.contains { resolved == $0 || resolved.hasPrefix($0 + "/") }
    }

    // MARK: - SQLite plumbing

    private func openDB() throws -> OpaquePointer {
        let encoded = dbPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? dbPath

        // Prefer a plain read-only open so committed WAL data is visible — recent
        // messages live in chat.db-wal until Messages checkpoints, and an immutable
        // open ignores the WAL entirely. WAL mode is concurrent-safe for readers, so
        // this does not lock Messages. Fall back to an immutable open only if the
        // -wal/-shm can't be accessed (degraded: won't show the very newest messages).
        var lastRC: Int32 = SQLITE_OK
        for query in ["", "?immutable=1"] {
            let uri = "file:\(encoded)\(query)"
            var handle: OpaquePointer?
            lastRC = sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
            if lastRC == SQLITE_OK, let db = handle {
                // Force an actual read to surface WAL/shm access failures now, not mid-query.
                if sqlite3_exec(db, "SELECT 1 FROM sqlite_master LIMIT 1", nil, nil, nil) == SQLITE_OK {
                    return db
                }
                sqlite3_close(db)
            } else if let handle {
                sqlite3_close(handle)
            }
        }
        throw messagesError("""
            Cannot open the Messages database at \(dbPath) (SQLite rc=\(lastRC)). Grant \
            Full Disk Access to the app running this server: System Settings → Privacy & \
            Security → Full Disk Access.
            """)
    }

    /// Run a query and return rows as `[column: value]` dictionaries.
    /// Values are `Int`, `Double`, `String`, or `Data`; NULLs are omitted.
    private func rows(_ db: OpaquePointer, _ sql: String, _ binds: [Any] = []) throws -> [[String: Any]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw messagesError("SQL prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }

        for (i, bind) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch bind {
            case let s as String: sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case let n as Int:    sqlite3_bind_int64(stmt, idx, Int64(n))
            default:              sqlite3_bind_null(stmt, idx)
            }
        }

        var out: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT:   row[name] = sqlite3_column_double(stmt, c)
                case SQLITE_TEXT:    row[name] = String(cString: sqlite3_column_text(stmt, c))
                case SQLITE_BLOB:
                    if let ptr = sqlite3_column_blob(stmt, c) {
                        row[name] = Data(bytes: ptr, count: Int(sqlite3_column_bytes(stmt, c)))
                    }
                default: break // NULL
                }
            }
            out.append(row)
        }
        return out
    }

    /// Build a safe `IN (...)` list from integer ROWIDs (never user-supplied strings).
    private func inClause(_ ids: [Int]) -> String {
        ids.isEmpty ? "NULL" : ids.map(String.init).joined(separator: ",")
    }

    // MARK: - Formatting helpers

    /// Best display text for a message. Modern macOS often stores the body only in
    /// `attributedBody` (a typedstream archive) with `text` NULL, so fall back to a
    /// lightweight extractor when needed.
    private func messageText(_ row: [String: Any]) -> String {
        if let t = row["text"] as? String, !t.isEmpty { return t }
        if let blob = row["attributedBody"] as? Data, let t = decodeAttributedBody(blob) { return t }
        return ""
    }

    /// Extract the plain string from an NSAttributedString typedstream blob.
    /// Locates the `NSString` marker, then reads the length-prefixed UTF-8 payload.
    /// Best-effort — returns nil on any layout it doesn't recognise.
    private func decodeAttributedBody(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        let marker = Array("NSString".utf8)
        guard let start = firstIndex(of: marker, in: bytes) else { return nil }

        // After the marker come class-stream bytes ending in '+' (0x2B) before the length.
        var i = start + marker.count
        let scanEnd = min(bytes.count, i + 8)
        while i < scanEnd, bytes[i] != 0x2B { i += 1 }
        guard i < scanEnd, bytes[i] == 0x2B else { return nil }
        i += 1
        guard i < bytes.count else { return nil }

        var length = Int(bytes[i]); i += 1
        if length == 0x81 {
            guard i + 1 < bytes.count else { return nil }
            length = Int(bytes[i]) | (Int(bytes[i + 1]) << 8); i += 2
        } else if length == 0x82 {
            guard i + 3 < bytes.count else { return nil }
            length = Int(bytes[i]) | (Int(bytes[i + 1]) << 8)
                   | (Int(bytes[i + 2]) << 16) | (Int(bytes[i + 3]) << 24); i += 4
        }
        guard length > 0, i + length <= bytes.count else { return nil }
        return String(bytes: bytes[i..<(i + length)], encoding: .utf8)
    }

    private func firstIndex(of pattern: [UInt8], in bytes: [UInt8]) -> Int? {
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return nil }
        for i in 0...(bytes.count - pattern.count) where Array(bytes[i..<(i + pattern.count)]) == pattern {
            return i
        }
        return nil
    }

    /// Convert an Apple Core Data timestamp (ns or s since 2001-01-01) to a local string.
    private func formatDate(_ raw: Int?) -> String {
        guard let raw, raw > 0 else { return "unknown" }
        // Modern DBs store nanoseconds; older ones store seconds.
        let seconds = raw > 100_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
        let unix = seconds + 978_307_200 // 2001-01-01 → Unix epoch
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: unix))
    }

    private func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private func truncate(_ s: String, _ n: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= n ? flat : String(flat.prefix(n)) + "…"
    }

    /// Escape LIKE wildcards in user input (paired with `ESCAPE '\'` in the query).
    private func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "%", with: "\\%")
         .replacingOccurrences(of: "_", with: "\\_")
    }
}

// MARK: - Helpers

private func messagesError(_ message: String) -> NSError {
    NSError(domain: "macos-mcp.Messages", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
}
