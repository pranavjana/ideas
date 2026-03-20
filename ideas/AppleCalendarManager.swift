import Foundation
import EventKit
import SwiftUI
import Combine

struct AppleCalendarEvent: Identifiable, Equatable {
    let calendarItemIdentifier: String
    let eventIdentifier: String?
    let externalIdentifier: String?
    let occurrenceDate: Date?
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let calendarTitle: String

    var id: String {
        let base = externalIdentifier ?? eventIdentifier ?? calendarItemIdentifier
        let anchorDate = occurrenceDate ?? startDate
        return "\(base)|\(Int(anchorDate.timeIntervalSinceReferenceDate))"
    }
}

@MainActor
final class AppleCalendarManager: ObservableObject {
    static let shared = AppleCalendarManager()

    private static let ideasCalendarTitle = "Ideas"
    private static let ideasCalendarIdentifierKey = "apple_calendar_ideas_calendar_identifier"

    @Published private(set) var authorizationStatus: EKAuthorizationStatus
    @Published private(set) var visibleEvents: [AppleCalendarEvent] = []
    @Published private(set) var lastErrorMessage: String? = nil

    private let calendar = Calendar.current
    private let eventStore = EKEventStore()

    private init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    }

    var hasFullAccess: Bool {
        if #available(iOS 17, macOS 14, *) {
            return authorizationStatus == .fullAccess
        } else {
            return authorizationStatus == .authorized
        }
    }

    func refreshAuthorizationStatus() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    }

    func requestAccess() async -> Bool {
        do {
            let granted: Bool
            if #available(iOS 17, macOS 14, *) {
                granted = try await eventStore.requestFullAccessToEvents()
            } else {
                granted = try await withCheckedThrowingContinuation { continuation in
                    eventStore.requestAccess(to: .event) { granted, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: granted)
                        }
                    }
                }
            }

            refreshAuthorizationStatus()
            lastErrorMessage = granted ? nil : "calendar access was not granted"
            return granted
        } catch {
            refreshAuthorizationStatus()
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    func refreshEvents(in interval: DateInterval, excluding linkedEventIDs: Set<String>) {
        refreshAuthorizationStatus()
        guard hasFullAccess else {
            visibleEvents = []
            return
        }

        let predicate = eventStore.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        let events = eventStore.events(matching: predicate)
            .filter { !linkedEventIDs.contains($0.calendarItemIdentifier) }
            .map { event in
                AppleCalendarEvent(
                    calendarItemIdentifier: event.calendarItemIdentifier,
                    eventIdentifier: event.eventIdentifier,
                    externalIdentifier: event.calendarItemExternalIdentifier,
                    occurrenceDate: event.occurrenceDate,
                    title: event.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? event.title! : "untitled event",
                    startDate: event.startDate,
                    endDate: event.endDate,
                    isAllDay: event.isAllDay,
                    calendarTitle: event.calendar.title
                )
            }
            .sorted { $0.startDate < $1.startDate }

        visibleEvents = events
    }

    func clearVisibleEvents() {
        visibleEvents = []
    }

    func syncIdea(_ idea: Idea, enabled: Bool) {
        refreshAuthorizationStatus()
        guard hasFullAccess, enabled else { return }

        guard idea.dueTime != nil,
              let scheduledDate = idea.dueDatetime else {
            removeSyncedEvent(for: idea)
            return
        }

        guard let targetCalendar = ideasCalendar() else { return }

        let event: EKEvent
        if let identifier = idea.appleCalendarEventIdentifier,
           let existing = eventStore.calendarItem(withIdentifier: identifier) as? EKEvent {
            event = existing
        } else {
            event = EKEvent(eventStore: eventStore)
        }

        event.calendar = targetCalendar
        event.title = idea.text
        event.startDate = scheduledDate
        event.endDate = scheduledDate.addingTimeInterval(Double(idea.scheduledDurationMinutes) * 60)
        event.isAllDay = false

        var notesParts: [String] = []
        if !idea.visibleTags.isEmpty {
            notesParts.append("ideas tags: \(idea.visibleTags.joined(separator: ", "))")
        }
        if !idea.category.isEmpty {
            notesParts.append("ideas category: \(idea.category)")
        }
        event.notes = notesParts.isEmpty ? nil : notesParts.joined(separator: "\n")

        do {
            try eventStore.save(event, span: .thisEvent)
            idea.appleCalendarEventIdentifier = event.calendarItemIdentifier
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func createStandaloneEvent(title: String, startDate: Date, durationMinutes: Int) -> Bool {
        refreshAuthorizationStatus()
        guard hasFullAccess else {
            lastErrorMessage = "calendar access was not granted"
            return false
        }

        guard let targetCalendar = ideasCalendar() else { return false }

        let event = EKEvent(eventStore: eventStore)
        event.calendar = targetCalendar
        event.title = title
        event.startDate = startDate
        event.endDate = startDate.addingTimeInterval(Double(max(durationMinutes, 15)) * 60)
        event.isAllDay = false

        do {
            try eventStore.save(event, span: .thisEvent)
            lastErrorMessage = nil
            return true
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func updateEvent(_ sourceEvent: AppleCalendarEvent, title: String?, startDate: Date?, durationMinutes: Int?, isAllDay: Bool? = nil) -> Bool {
        refreshAuthorizationStatus()
        guard hasFullAccess else {
            lastErrorMessage = "calendar access was not granted"
            return false
        }

        guard let event = resolvedEvent(for: sourceEvent) else {
            lastErrorMessage = "calendar event could not be found"
            return false
        }

        if let title {
            event.title = title
        }

        let existingDurationMinutes = max(Int(event.endDate.timeIntervalSince(event.startDate) / 60), 15)
        let resolvedAllDay = isAllDay ?? event.isAllDay
        guard let resolvedStartDate = startDate ?? event.startDate else {
            lastErrorMessage = "calendar event start date is missing"
            return false
        }

        if resolvedAllDay {
            let allDayStart = calendar.startOfDay(for: resolvedStartDate)
            event.isAllDay = true
            event.startDate = allDayStart
            event.endDate = calendar.date(byAdding: .day, value: 1, to: allDayStart) ?? allDayStart.addingTimeInterval(24 * 60 * 60)
        } else {
            event.isAllDay = false
            event.startDate = resolvedStartDate
            let resolvedDurationMinutes = max(durationMinutes ?? existingDurationMinutes, 15)
            event.endDate = event.startDate.addingTimeInterval(Double(resolvedDurationMinutes) * 60)
        }

        do {
            try eventStore.save(event, span: .thisEvent)
            lastErrorMessage = nil
            return true
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func deleteEvent(_ sourceEvent: AppleCalendarEvent) -> Bool {
        refreshAuthorizationStatus()
        guard hasFullAccess else {
            lastErrorMessage = "calendar access was not granted"
            return false
        }

        guard let event = resolvedEvent(for: sourceEvent) else {
            lastErrorMessage = "calendar event could not be found"
            return false
        }

        do {
            try eventStore.remove(event, span: .thisEvent)
            lastErrorMessage = nil
            return true
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    private func resolvedEvent(for sourceEvent: AppleCalendarEvent) -> EKEvent? {
        if let eventIdentifier = sourceEvent.eventIdentifier,
           let event = eventStore.event(withIdentifier: eventIdentifier),
           matches(event, sourceEvent) {
            return event
        }

        if let event = eventStore.calendarItem(withIdentifier: sourceEvent.calendarItemIdentifier) as? EKEvent,
           matches(event, sourceEvent) {
            return event
        }

        let anchorDate = sourceEvent.occurrenceDate ?? sourceEvent.startDate
        guard let windowStart = calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: anchorDate)),
              let windowEnd = calendar.date(byAdding: .day, value: 3, to: calendar.startOfDay(for: anchorDate))
        else {
            return nil
        }

        let predicate = eventStore.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: nil)
        return eventStore.events(matching: predicate).first(where: { matches($0, sourceEvent) })
    }

    private func matches(_ event: EKEvent, _ sourceEvent: AppleCalendarEvent) -> Bool {
        let sourceAnchor = sourceEvent.occurrenceDate ?? sourceEvent.startDate
        guard let eventAnchor = event.occurrenceDate ?? event.startDate else {
            return false
        }
        let sameAnchorMinute = abs(eventAnchor.timeIntervalSince(sourceAnchor)) < 60

        if let externalIdentifier = sourceEvent.externalIdentifier,
           event.calendarItemExternalIdentifier == externalIdentifier,
           sameAnchorMinute {
            return true
        }

        if let eventIdentifier = sourceEvent.eventIdentifier,
           event.eventIdentifier == eventIdentifier,
           sameAnchorMinute {
            return true
        }

        return event.calendarItemIdentifier == sourceEvent.calendarItemIdentifier && sameAnchorMinute
    }

    func removeSyncedEvent(for idea: Idea) {
        refreshAuthorizationStatus()
        guard hasFullAccess,
              let identifier = idea.appleCalendarEventIdentifier,
              let event = eventStore.calendarItem(withIdentifier: identifier) as? EKEvent else {
            idea.appleCalendarEventIdentifier = nil
            return
        }

        do {
            try eventStore.remove(event, span: .thisEvent)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
        idea.appleCalendarEventIdentifier = nil
    }

    private func ideasCalendar() -> EKCalendar? {
        if let identifier = UserDefaults.standard.string(forKey: Self.ideasCalendarIdentifierKey),
           let calendar = eventStore.calendar(withIdentifier: identifier),
           calendar.allowsContentModifications {
            return calendar
        }

        if let existing = eventStore.calendars(for: .event).first(where: {
            $0.title == Self.ideasCalendarTitle && $0.allowsContentModifications
        }) {
            UserDefaults.standard.set(existing.calendarIdentifier, forKey: Self.ideasCalendarIdentifierKey)
            return existing
        }

        guard let source = preferredIdeasCalendarSource() else {
            lastErrorMessage = "no writable calendar source is available"
            return nil
        }

        let calendar = EKCalendar(for: .event, eventStore: eventStore)
        calendar.title = Self.ideasCalendarTitle
        calendar.source = source

        do {
            try eventStore.saveCalendar(calendar, commit: true)
            UserDefaults.standard.set(calendar.calendarIdentifier, forKey: Self.ideasCalendarIdentifierKey)
            lastErrorMessage = nil
            return calendar
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    private func preferredIdeasCalendarSource() -> EKSource? {
        if let defaultSource = eventStore.defaultCalendarForNewEvents?.source {
            return defaultSource
        }

        let preferredTypes: [EKSourceType] = [.calDAV, .exchange, .local]
        for sourceType in preferredTypes {
            if let source = eventStore.sources.first(where: { $0.sourceType == sourceType }) {
                return source
            }
        }

        return eventStore.sources.first
    }
}
