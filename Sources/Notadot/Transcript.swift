import Foundation

/// Codex can send commentary, stable partial answers, and a final answer in one turn.
/// Keep the underlying items intact, but don't present commentary as a second finished reply.
enum Transcript {
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
        let finished = Set(messages.filter { $0.role == "assistant" && $0.phase == "final_answer" && !$0.text.isEmpty }.compactMap(\.turnID))
        return messages.filter { message in
            guard message.role == "assistant" else { return true }
            if message.text.isEmpty { return false }
            return !(message.phase == "commentary" && message.turnID.map { finished.contains($0) } == true)
        }
    }
}
