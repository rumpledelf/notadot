import Foundation

/// Codex can send commentary, stable partial answers, and a final answer in one turn.
/// Keep commentary available for the UI's collapsed activity disclosures.
enum Transcript {
    static let toolTypes = ["dynamicToolCall", "commandExecution", "fileChange", "mcpToolCall", "webSearch"]
    /// Save tool details separately so the renderer can keep them collapsed.
    static func tool(_ item: [String: Any], completed: Bool, messages: inout [Message]) {
        guard let type = item["type"] as? String, toolTypes.contains(type), let id = item["id"] as? String else { return }
        let text = item["tool"] as? String ?? item["command"] as? String ?? item["query"] as? String ?? type
        var parts: [String] = []
        func add(_ label: String, _ value: Any?) {
            guard let value = value, !(value is NSNull) else { return }
            let body: String
            if let string = value as? String { body = string }
            else if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]), let string = String(data: data, encoding: .utf8) { body = string }
            else { return }
            parts.append(label + ":\n" + body)
        }
        add("Arguments", item["arguments"])
        add("Command", item["command"]); add("Directory", item["cwd"])
        add("Query", item["query"]); add("Action", item["action"])
        add("Changes", item["changes"])
        if completed {
            let mcpResult = item["result"] as? [String: Any]
            let content = item["contentItems"] as? [[String: Any]] ?? mcpResult?["content"] as? [[String: Any]] ?? []
            let output = content.compactMap { part -> String? in
                if let text = part["text"] as? String { return text }
                return part["type"] == nil ? nil : "[\(part["type"]!)]"
            }.joined(separator: "\n")
            if !output.isEmpty { add("Result", output) }
            add("Structured result", mcpResult?["structuredContent"])
            add("Output", item["aggregatedOutput"]); add("Exit code", item["exitCode"])
            add("Results", item["results"]); add("Error", item["error"])
            add("Status", item["status"]); add("Success", item["success"])
        }
        let details = parts.joined(separator: "\n\n")
        let bounded = String(details.prefix(16000)) + (details.count > 16000 ? "\n[Details truncated]" : "")
        if let i = messages.firstIndex(where: { $0.itemID == id }) {
            messages[i].text = text; messages[i].toolDetails = bounded
        } else { messages.append(Message(role: "tool", text: text, itemID: id, toolDetails: bounded)) }
    }
    static func item(_ item: [String: Any], turn: String?, messages: inout [Message]) {
        guard let id = item["id"] as? String else { return }
        if let i = messages.firstIndex(where: { $0.itemID == id }) {
            if let text = item["text"] as? String { messages[i].text = text }
            if let phase = item["phase"] as? String { messages[i].phase = phase }
            if let turn = turn { messages[i].turnID = turn }
        } else {
            messages.append(Message(role: "assistant", text: item["text"] as? String ?? "", itemID: id, phase: item["phase"] as? String, turnID: turn))
        }
    }
    static func delta(_ params: [String: Any], turn: String?, messages: inout [Message]) {
        guard let id = params["itemId"] as? String, let text = params["delta"] as? String else { return }
        if let i = messages.firstIndex(where: { $0.itemID == id }) {
            messages[i].text += text
            if let turn = turn { messages[i].turnID = turn }
        } else { messages.append(Message(role: "assistant", text: text, itemID: id, turnID: turn)) }
    }
    static func visible(_ messages: [Message]) -> [Message] {
        return messages.filter { message in
            guard message.role == "assistant" else { return true }
            if message.text.isEmpty { return false }
            return true
        }
    }
}
