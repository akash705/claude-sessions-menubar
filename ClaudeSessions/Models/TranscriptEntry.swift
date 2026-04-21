import Foundation

/// Minimal decoder for Claude Code JSONL transcript lines.
/// We only decode what the UI needs; unknown fields are ignored.
struct TranscriptEntry: Identifiable, Hashable {
    enum Kind: String {
        case user, assistant, system, attachment, fileHistorySnapshot = "file-history-snapshot", permissionMode = "permission-mode", unknown
    }

    enum Block: Hashable {
        case text(String)
        case toolUse(id: String, name: String, input: String)
        case toolResult(id: String, content: String, isError: Bool)
        case thinking(String)
        case other(String)
    }

    let id: String          // uuid
    let kind: Kind
    let timestamp: Date?
    let role: String?       // "user" | "assistant" when applicable
    let blocks: [Block]
    let rawLine: String     // for debugging / full-fidelity display

    /// Plain-text summary suitable for list preview. Strips tool_use/thinking blocks.
    var previewText: String {
        for block in blocks {
            if case .text(let s) = block, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return s
            }
        }
        // Fallbacks: first tool_use name, or first tool_result snippet
        for block in blocks {
            switch block {
            case .toolUse(_, let name, _): return "→ \(name)"
            case .toolResult(_, let s, _): return s
            case .thinking(let s): return s
            default: continue
            }
        }
        return ""
    }

    var hasError: Bool {
        blocks.contains {
            if case .toolResult(_, _, let isError) = $0 { return isError } else { return false }
        }
    }

    var toolUseBlocks: [(id: String, name: String, input: String)] {
        blocks.compactMap {
            if case .toolUse(let id, let name, let input) = $0 { return (id, name, input) }
            return nil
        }
    }

    var toolResultIds: [String] {
        blocks.compactMap {
            if case .toolResult(let id, _, _) = $0 { return id }
            return nil
        }
    }

    var endsWithAssistantMessage: Bool { role == "assistant" }
    var endsWithUserOrToolResult: Bool {
        if role == "user" { return true }
        return blocks.contains {
            if case .toolResult = $0 { return true } else { return false }
        }
    }
}

enum TranscriptDecoder {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func decode(line: String) -> TranscriptEntry? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let id = (obj["uuid"] as? String) ?? UUID().uuidString
        let typeRaw = (obj["type"] as? String) ?? "unknown"
        let kind = TranscriptEntry.Kind(rawValue: typeRaw) ?? .unknown

        let tsString = obj["timestamp"] as? String
        let timestamp = tsString.flatMap { iso.date(from: $0) ?? isoNoFrac.date(from: $0) }

        var role: String? = obj["role"] as? String
        if role == nil, let msg = obj["message"] as? [String: Any] {
            role = msg["role"] as? String
        }

        let blocks = parseBlocks(obj: obj, type: kind)

        return TranscriptEntry(
            id: id,
            kind: kind,
            timestamp: timestamp,
            role: role,
            blocks: blocks,
            rawLine: line
        )
    }

    private static func parseBlocks(obj: [String: Any], type: TranscriptEntry.Kind) -> [TranscriptEntry.Block] {
        // System / attachment entries carry `content` at the top level.
        // User / assistant entries wrap it in `message.content`.
        let content: Any? = (obj["message"] as? [String: Any])?["content"] ?? obj["content"]

        if let s = content as? String {
            return [.text(s)]
        }
        guard let arr = content as? [[String: Any]] else { return [] }
        return arr.compactMap { block -> TranscriptEntry.Block? in
            let t = block["type"] as? String
            switch t {
            case "text":
                return .text((block["text"] as? String) ?? "")
            case "tool_use":
                let id = (block["id"] as? String) ?? ""
                let name = (block["name"] as? String) ?? "tool"
                let input: String
                if let d = block["input"], let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted]),
                   let s = String(data: data, encoding: .utf8) {
                    input = s
                } else {
                    input = ""
                }
                return .toolUse(id: id, name: name, input: input)
            case "tool_result":
                let id = (block["tool_use_id"] as? String) ?? ""
                let isErr = (block["is_error"] as? Bool) ?? false
                let c = block["content"]
                if let s = c as? String {
                    return .toolResult(id: id, content: s, isError: isErr)
                } else if let items = c as? [[String: Any]] {
                    let joined = items.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    return .toolResult(id: id, content: joined, isError: isErr)
                }
                return .toolResult(id: id, content: "", isError: isErr)
            case "thinking":
                return .thinking((block["thinking"] as? String) ?? "")
            default:
                return .other(t ?? "block")
            }
        }
    }
}
