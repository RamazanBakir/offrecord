import EventKit
import Foundation

/// Finds the calendar event happening right now to name the recording.
enum CalendarLookup {
    struct Match {
        var title: String
        var attendees: [String]
        /// Set when exactly one other person attends: used as the remote speaker name.
        var otherPerson: String?
    }

    static func currentEvent() async -> Match? {
        let store = EKEventStore()
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess: break
        case .notDetermined:
            guard (try? await store.requestFullAccessToEvents()) == true else { return nil }
        default: return nil
        }

        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-3 * 3600), end: now.addingTimeInterval(15 * 60), calendars: nil
        )
        let candidates = store.events(matching: predicate).filter { event in
            !event.isAllDay
                // Running now, or starting within the next 15 minutes.
                && event.endDate > now
                && event.startDate < now.addingTimeInterval(15 * 60)
        }
        // Prefer the event whose start is closest to now.
        guard let event = candidates.min(by: {
            abs($0.startDate.timeIntervalSince(now)) < abs($1.startDate.timeIntervalSince(now))
        }) else { return nil }

        let participants = event.attendees ?? []
        let others = participants.filter { !$0.isCurrentUser }.compactMap(displayName)
        return Match(
            title: event.title ?? L("Meeting"),
            attendees: participants.compactMap(displayName),
            otherPerson: others.count == 1 ? others.first : nil
        )
    }

    private static func displayName(_ participant: EKParticipant) -> String? {
        if let name = participant.name, !name.isEmpty { return name }
        let address = participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
        return address.isEmpty ? nil : address
    }
}
