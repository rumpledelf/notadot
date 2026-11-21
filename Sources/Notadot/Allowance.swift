import AppKit

private final class RemainingBar: NSView {
    var percent = 0
    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3)
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        track.fill()
        track.addClip()
        NSColor.labelColor.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: bounds.width * CGFloat(percent) / 100, height: bounds.height)).fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class AllowanceRows: NSStackView {
    private var countdowns: [(Date, NSTextField)] = []

    func update(_ snapshot: [String: Any]) -> [String] {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        countdowns.removeAll()
        orientation = .vertical
        alignment = .leading
        spacing = 12
        var readings: [String] = []
        for key in ["primary", "secondary"] {
            guard let window = snapshot[key] as? [String: Any], let used = window["usedPercent"] as? Int else { continue }
            let remaining = 100 - min(100, max(0, used))
            let title: String
            switch window["windowDurationMins"] as? Int {
            case 10080: title = "Weekly limit"
            case let mins? where mins > 0 && mins % 60 == 0: title = "\(mins / 60)-hour limit"
            case let mins? where mins > 0: title = "\(mins)-minute limit"
            default: title = "\(key.capitalized) limit"
            }
            let reset = label("Reset time unavailable")
            let percent = label("\(remaining)% left")
            for field in [reset, percent] {
                field.font = .systemFont(ofSize: 11)
                field.textColor = .secondaryLabelColor
            }
            if let stamp = window["resetsAt"] as? Double {
                let date = Date(timeIntervalSince1970: stamp)
                countdowns.append((date, reset))
                reset.toolTip = DateFormatter.localizedString(from: date, dateStyle: .full, timeStyle: .short)
            }
            let info = NSStackView(views: [reset, NSView(), percent])
            let bar = RemainingBar()
            bar.percent = remaining
            let row = NSStackView(views: [label(title, bold: true), info, bar])
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 4
            addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: widthAnchor),
                info.widthAnchor.constraint(equalTo: row.widthAnchor),
                bar.widthAnchor.constraint(equalTo: row.widthAnchor),
                bar.heightAnchor.constraint(equalToConstant: 6)
            ])
            readings.append("\(title): \(remaining)% left")
        }
        tick()
        isHidden = readings.isEmpty
        return readings
    }

    func tick() {
        for (date, field) in countdowns {
            let mins = max(0, Int(ceil(date.timeIntervalSinceNow / 60)))
            let caption: String
            switch mins {
            case 0: caption = "Reset due"
            case 1..<60: caption = "Resets in \(mins)m"
            case 60..<1440: caption = "Resets in \(mins / 60)h \(mins % 60)m"
            default: caption = "Resets in \(mins / 1440)d \(mins % 1440 / 60)h"
            }
            if field.stringValue != caption { field.stringValue = caption }
        }
    }
}
