import AppKit

/// Enough Markdown for notes and chat replies: headings, lists, fenced code, **bold**, `code` and links.
/// AppKit's own Markdown support needs macOS 12, and this app targets 11.
enum Markdown {
    static func render(_ text: String, size: CGFloat = 14, color: NSColor = .labelColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: size)
        let mono = NSFont.monospacedSystemFont(ofSize: size - 1.5, weight: .regular)
        var inCode = false
        let lines = text.components(separatedBy: "\n")
        for (index, raw) in lines.enumerated() {
            let newline = index < lines.count - 1 ? "\n" : ""
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle(); continue }
            if inCode {
                let style = NSMutableParagraphStyle(); style.headIndent = 12; style.firstLineHeadIndent = 12
                out.append(NSAttributedString(string: raw + newline, attributes: [.font: mono, .foregroundColor: color, .backgroundColor: NSColor.textColor.withAlphaComponent(0.05), .paragraphStyle: style]))
                continue
            }
            let line = raw.trimmingCharacters(in: .whitespaces)
            let style = NSMutableParagraphStyle(); style.paragraphSpacing = size * 0.35; style.lineSpacing = 2
            var font = body, content = line, prefix = ""
            if let level = line.prefix(while: { $0 == "#" }).count as Int?, level > 0, level <= 4, line.dropFirst(level).hasPrefix(" ") {
                font = .boldSystemFont(ofSize: size + CGFloat(max(0, 4 - level) * 2)); content = String(line.dropFirst(level + 1))
                style.paragraphSpacingBefore = size * 0.6
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                prefix = "•\t"; content = String(line.dropFirst(2))
            } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty, line[line.index(after: dot)...].hasPrefix(" ") {
                prefix = line[...dot] + "\t"; content = String(line[line.index(dot, offsetBy: 2)...])
            }
            if !prefix.isEmpty {
                let indent = CGFloat(raw.prefix(while: { $0 == " " }).count / 2) * 16
                style.headIndent = indent + 18; style.firstLineHeadIndent = indent
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent + 18)]; style.paragraphSpacing = size * 0.15
            }
            let paragraph = NSMutableAttributedString(string: prefix, attributes: [.font: body, .foregroundColor: color])
            paragraph.append(inline(content, font: font, mono: mono, color: color))
            paragraph.append(NSAttributedString(string: newline))
            paragraph.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: paragraph.length))
            out.append(paragraph)
        }
        return out
    }
    private static func inline(_ text: String, font: NSFont, mono: NSFont, color: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        // `code`, **bold**, [label](url) — scanned left to right, unmatched markers stay literal.
        let pattern = try! NSRegularExpression(pattern: "`([^`]+)`|\\*\\*([^*]+)\\*\\*|\\[([^\\]]+)\\]\\(([^)\\s]+)\\)")
        let ns = text as NSString; var last = 0
        for m in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out.append(NSAttributedString(string: ns.substring(with: NSRange(location: last, length: m.range.location - last)), attributes: [.font: font, .foregroundColor: color]))
            if m.range(at: 1).location != NSNotFound {
                out.append(NSAttributedString(string: ns.substring(with: m.range(at: 1)), attributes: [.font: mono, .foregroundColor: color, .backgroundColor: NSColor.textColor.withAlphaComponent(0.06)]))
            } else if m.range(at: 2).location != NSNotFound {
                out.append(NSAttributedString(string: ns.substring(with: m.range(at: 2)), attributes: [.font: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), .foregroundColor: color]))
            } else {
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.linkColor]
                if let url = URL(string: ns.substring(with: m.range(at: 4))) { attributes[.link] = url }
                out.append(NSAttributedString(string: ns.substring(with: m.range(at: 3)), attributes: attributes))
            }
            last = m.range.location + m.range.length
        }
        out.append(NSAttributedString(string: ns.substring(from: last), attributes: [.font: font, .foregroundColor: color]))
        return out
    }
}
