import Foundation
import EventKit
import SwiftUI
import Combine

struct AppleCalendarEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let calendarTitle: String
}

@MainActor
final class AppleCalendarManager: ObservableObject {
    static let shared = AppleCalendarManager()

    @Published private(set) var authorizationStatus: EKAuthorizationStatus
    @Published private(set) var visibleEvents: [AppleCalendarEvent] = []
    @Published private(set) var lastErrorMessage: String? = nil

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
                    id: event.calendarItemIdentifier,
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

        let event: EKEvent
        if let identifier = idea.appleCalendarEventIdentifier,
           let existing = eventStore.calendarItem(withIdentifier: identifier) as? EKEvent {
            event = existing
        } else {
            event = EKEvent(eventStore: eventStore)
            event.calendar = eventStore.defaultCalendarForNewEvents
        }

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
}
