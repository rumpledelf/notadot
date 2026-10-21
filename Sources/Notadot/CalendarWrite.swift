import AppKit
import EventKit

struct CalendarDraft: Equatable {
    var title: String
    var start: Date
    var end: Date
    var allDay = false
    var calendarID: String
    var calendarName: String
    var source: String
    var location = ""
    var notes = ""
    var timezone: String? = TimeZone.current.identifier

    func updating(_ args: [String: Any]) throws -> CalendarDraft {
        var draft = self
        if let value = args["title"] as? String { draft.title = value }
        if let value = args["start"] as? String { draft.start = try PlannerDates.parse(value) }
        if let value = args["end"] as? String { draft.end = try PlannerDates.parse(value) }
        if let value = args["allDay"] as? Bool { draft.allDay = value }
        if let value = args["location"] as? String { draft.location = value }
        if let value = args["notes"] as? String { draft.notes = value }
        try draft.validate(); return draft
    }
    func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError.message("Provide an event title.") }
        guard end > start else { throw AppError.message("The event end must be after its start.") }
        if allDay {
            var calendar = Calendar.current; calendar.timeZone = timezone.flatMap(TimeZone.init(identifier:)) ?? .current
            guard calendar.startOfDay(for: start) == start, calendar.startOfDay(for: end) == end else { throw AppError.message("All-day events need midnight start/end dates in the event timezone. The end date is exclusive.") }
        }
    }
    var preview: String {
        let format = DateFormatter(); format.dateStyle = .full; format.timeStyle = allDay ? .none : .short
        format.timeZone = timezone.flatMap(TimeZone.init(identifier:)) ?? .current
        return "Title: \(title)\nCalendar: \(calendarName) (\(source))\nTimezone: \(format.timeZone.identifier)\nStart: \(format.string(from: start))\nEnd\(allDay ? " (exclusive)" : ""): \(format.string(from: end))\nAll day: \(allDay ? "Yes" : "No")\nLocation: \(location.isEmpty ? "None" : location)\nNotes: \(notes.isEmpty ? "None" : notes)"
    }
}

enum CalendarWriteGate {
    /// Model input cannot grant approval. Every write goes through a native user decision,
    /// then revalidation, and only then the actual database operation.
    static func commit<T>(confirm: () -> Bool, revalidate: () throws -> Void, write: () throws -> T) throws -> T {
        guard confirm() else { throw AppError.message("User declined the calendar change. Nothing was changed.") }
        try revalidate()
        return try write()
    }
}

final class CalendarWriter {
    static let actions = ["calendar_add", "calendar_update", "calendar_delete"]
    let events: EKEventStore
    init(events: EKEventStore) { self.events = events }
    static func validate(_ args: [String: Any]) throws {
        let action = args["action"] as? String ?? ""
        guard actions.contains(action) else { throw AppError.message("Unknown calendar write action.") }
        if action == "calendar_add" {
            guard let start = args["start"] as? String, let end = args["end"] as? String else { throw AppError.message("Provide start and end for the new event.") }
            let draft = CalendarDraft(title: args["title"] as? String ?? "", start: try PlannerDates.parse(start), end: try PlannerDates.parse(end), allDay: args["allDay"] as? Bool ?? false, calendarID: "", calendarName: "", source: "")
            try draft.validate()
        } else {
            guard !(args["event"] as? String ?? "").isEmpty, let occurrence = args["occurrence"] as? String else { throw AppError.message("Use the event ID and original occurrence timestamp returned by calendar_events.") }
            _ = try PlannerDates.parse(occurrence)
            for field in ["start", "end"] { if let value = args[field] as? String { _ = try PlannerDates.parse(value) } }
        }
    }
    func perform(_ args: [String: Any]) throws -> [String: Any] {
        try Self.validate(args)
        let action = args["action"] as? String ?? ""
        let original = action == "calendar_add" ? nil : try occurrence(args)
        if let original = original, !original.calendar.allowsContentModifications { throw AppError.message("The event's calendar is read-only.") }
        let before = original.map(snapshot)
        let calendar = try selectedCalendar(action == "calendar_delete" ? nil : args["calendar"] as? String, fallback: original?.calendar)
        let targetID = calendar.calendarIdentifier
        let draft: CalendarDraft
        if let original = original { draft = try snapshot(original).updating(args) }
        else {
            draft = try CalendarDraft(title: args["title"] as? String ?? "", start: PlannerDates.parse(args["start"] as? String ?? ""), end: PlannerDates.parse(args["end"] as? String ?? ""), calendarID: targetID, calendarName: calendar.title, source: calendar.source.title).updating(args)
        }
        var after = draft; after.calendarID = targetID; after.calendarName = calendar.title; after.source = calendar.source.title
        if action == "calendar_update", after == before { throw AppError.message("No event fields would change.") }
        let revision = original?.lastModifiedDate
        let repeating = original.map { $0.hasRecurrenceRules || $0.isDetached } ?? false
        let guests = original?.attendees?.map { $0.url.absoluteString }.sorted() ?? []
        var fresh: EKEvent?
        let result: [String: Any] = try CalendarWriteGate.commit(confirm: {
            self.confirm(action, before: before, after: after, repeating: repeating, guests: guests.count)
        }, revalidate: {
            self.events.reset()
            let selected = try self.selectedCalendar(targetID, fallback: nil)
            guard selected.title == after.calendarName, selected.source.title == after.source else { throw AppError.message("The calendar changed during review. Please review the change again.") }
            if let before = before {
                let current = try self.occurrence(args)
                guard current.calendar.allowsContentModifications, self.snapshot(current) == before, current.lastModifiedDate == revision,
                      (current.attendees?.map { $0.url.absoluteString }.sorted() ?? []) == guests,
                      (current.hasRecurrenceRules || current.isDetached) == repeating else { throw AppError.message("The event changed during review. List events and review the change again.") }
                fresh = current
            }
        }, write: {
            if action == "calendar_delete" {
                guard let event = fresh else { throw AppError.message("The event no longer exists.") }
                do { try self.events.remove(event, span: .thisEvent, commit: true) }
                catch { self.events.reset(); throw error }
                return ["deleted": true, "event": args["event"] as? String ?? "", "occurrence": args["occurrence"] as? String ?? "", "scope": "this occurrence only"]
            }
            let event = fresh ?? EKEvent(eventStore: self.events)
            event.title = after.title; event.startDate = after.start; event.endDate = after.end; event.isAllDay = after.allDay
            event.calendar = try self.selectedCalendar(targetID, fallback: nil)
            event.timeZone = after.timezone.flatMap(TimeZone.init(identifier:)); event.location = after.location.isEmpty ? nil : after.location; event.notes = after.notes.isEmpty ? nil : after.notes
            do { try self.events.save(event, span: .thisEvent, commit: true) }
            catch { self.events.reset(); throw error }
            return ["saved": true, "event": event.eventIdentifier ?? "", "title": after.title, "start": ISO8601DateFormatter().string(from: after.start), "end": ISO8601DateFormatter().string(from: after.end), "calendar": after.calendarName, "scope": "this occurrence only"]
        })
        return result
    }
    private func selectedCalendar(_ name: String?, fallback: EKCalendar?) throws -> EKCalendar {
        let calendar: EKCalendar?
        if let name = name, !name.isEmpty {
            let matches = events.calendars(for: .event).filter { $0.calendarIdentifier == name || $0.title == name }
            guard matches.count == 1 else { throw AppError.message("Use a unique calendar ID from calendar_lists.") }
            calendar = matches.first
        } else { calendar = fallback ?? events.defaultCalendarForNewEvents }
        guard let selected = calendar, selected.allowsContentModifications else { throw AppError.message("Choose a writable calendar from calendar_lists.") }
        return selected
    }
    private func occurrence(_ args: [String: Any]) throws -> EKEvent {
        guard let id = args["event"] as? String, let raw = args["occurrence"] as? String else { throw AppError.message("Provide the event ID and original occurrence timestamp.") }
        let date = try PlannerDates.parse(raw)
        let predicate = events.predicateForEvents(withStart: date.addingTimeInterval(-1), end: date.addingTimeInterval(1), calendars: nil)
        let matches = events.events(matching: predicate).filter { $0.eventIdentifier == id && abs($0.startDate.timeIntervalSince(date)) < 0.5 }
        guard matches.count == 1, let event = matches.first else { throw AppError.message("That event occurrence no longer exists or moved. List events again before editing it.") }
        return event
    }
    private func snapshot(_ event: EKEvent) -> CalendarDraft {
        CalendarDraft(title: event.title ?? "", start: event.startDate, end: event.endDate, allDay: event.isAllDay, calendarID: event.calendar.calendarIdentifier, calendarName: event.calendar.title, source: event.calendar.source.title, location: event.location ?? "", notes: event.notes ?? "", timezone: event.timeZone?.identifier)
    }
    private func confirm(_ action: String, before: CalendarDraft?, after: CalendarDraft, repeating: Bool, guests: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = action == "calendar_add" ? "Create this calendar event?" : action == "calendar_delete" ? "Delete this calendar event?" : "Update this calendar event?"
        var detail = action == "calendar_delete" ? "DELETE\n\n\(before?.preview ?? after.preview)" : before.map { "BEFORE\n\n\($0.preview)\n\nAFTER\n\n\(after.preview)" } ?? after.preview
        if repeating { detail += "\n\nRepeating event: only this occurrence will change." }
        if guests > 0 { detail += "\n\nThis event has \(guests) guests. The calendar provider may notify them about the change." }
        alert.informativeText = "Nothing changes until you approve this exact action."
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 340)); view.string = detail; view.isEditable = false; view.font = .systemFont(ofSize: 13); view.autoresizingMask = [.width]; view.isVerticallyResizable = true; view.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(frame: view.frame); scroll.hasVerticalScroller = true; scroll.documentView = view; alert.accessoryView = scroll
        alert.addButton(withTitle: "Allow Once"); alert.addButton(withTitle: "Don't Allow")
        if action == "calendar_delete" { alert.buttons.first?.hasDestructiveAction = true }
        return alert.runModal() == .alertFirstButtonReturn
    }
}
