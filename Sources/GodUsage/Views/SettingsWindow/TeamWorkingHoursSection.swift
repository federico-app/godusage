import SwiftUI

/// Settings → Teams → Members: each member's working days and hours, which Live Pace spreads today's
/// weekly-limit budget over. A member edits their own hours; owners edit anyone's. Hours belong to the
/// person (shared across their teams) and run in their own Mac's time zone.
struct TeamWorkingHoursSection: View {
    @Environment(AppContainer.self) private var container
    let teamID: String

    @State private var editing: TeamWorkingHoursEditor.Draft?

    private var store: TeamPlansStore { container.teamPlans }
    private var schedules: TeamSchedules? { store.schedules(teamID: teamID) }
    private var myID: String? { container.teams.user?.id }

    var body: some View {
        SettingsSection("Working Hours") {
            if let schedules {
                ForEach(schedules.members) { member in
                    row(member, canEdit: member.userID == myID || schedules.canEditOthers)
                }
                .padding(.top, 4)
            } else if store.scheduleError == nil {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                    .padding(.vertical, 12)
            }
            if let error = store.scheduleError {
                SettingsInlineNotice(error)
                    .padding(.top, 8)
            }
            SettingsCaption(
                "Live Pace spreads today's weekly-limit budget over these hours, in each person's own time zone. "
                    + "A shared account uses everyone's hours combined."
            )
            .padding(.top, 4)
        }
        .task(id: teamID) { await store.loadSchedules(teamID: teamID) }
        .sheet(item: $editing) { draft in
            TeamWorkingHoursEditor(draft: draft) { userID, schedule in
                await store.saveSchedule(teamID: teamID, userID: userID, schedule: schedule)
            }
        }
    }

    private func row(_ member: TeamSchedules.Member, canEdit: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(member.displayName).lineLimit(1)
                if member.userID == myID {
                    Text("You").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if member.isDefault {
                    Text("Team Default").font(.caption).foregroundStyle(.secondary)
                }
                if canEdit {
                    Button("Edit…") {
                        editing = TeamWorkingHoursEditor.Draft(
                            userID: member.userID,
                            name: member.displayName,
                            schedule: member.schedule,
                            isDefault: member.isDefault
                        )
                    }
                    .controlSize(.small)
                }
            }
            HStack(spacing: 10) {
                TeamWeekdayInitials(days: member.schedule.days)
                Text(Self.span(member.schedule.start, member.schedule.end))
                    .monospacedDigit()
                if let breakStart = member.schedule.breakStart, let breakEnd = member.schedule.breakEnd {
                    Text("Break \(Self.span(breakStart, breakEnd))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let city = Self.city(member.timeZone) {
                    Text(city).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    /// "9:00 – 18:00".
    static func span(_ start: Int, _ end: Int) -> String {
        "\(TeamSchedule.clock(start)) – \(TeamSchedule.clock(end))"
    }

    /// "Rome" from "Europe/Rome", "New York" from "America/New_York".
    static func city(_ timeZone: String?) -> String? {
        guard let last = timeZone?.split(separator: "/").last else { return nil }
        return last.replacingOccurrences(of: "_", with: " ")
    }
}

/// The seven weekdays as initials, Monday first, working days highlighted.
private struct TeamWeekdayInitials: View {
    let days: [Int]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...7, id: \.self) { day in
                let works = days.contains(day)
                Text(Calendar.current.veryShortWeekdaySymbols[day % 7])
                    .font(.caption2.weight(works ? .semibold : .regular))
                    .foregroundStyle(works ? Color.accentColor : Color.secondary.opacity(0.6))
                    .frame(width: 11)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(days.sorted().map { Calendar.current.weekdaySymbols[$0 % 7] }.joined(separator: ", "))
    }
}

/// The "Edit…" sheet: working days, start and end, and an optional break, in 15-minute steps. Use Team
/// Default clears the member's own hours.
struct TeamWorkingHoursEditor: View {
    struct Draft: Identifiable {
        let id = UUID()
        var userID: String
        var name: String
        var schedule: TeamSchedule
        var isDefault: Bool
    }

    @Environment(\.dismiss) private var dismiss
    @State var draft: Draft
    @State private var isSaving = false
    /// Saves the hours (nil = team default); returns whether the server accepted them.
    let onSave: (String, TeamSchedule?) async -> Bool

    private static let quarterHours = Array(stride(from: 0, through: 24 * 60, by: 15))

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Working Hours").font(.title3.weight(.semibold))
                Text(draft.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 4) {
                    ForEach(1...7, id: \.self) { day in
                        Toggle(TeamPlansSection.weekdaySymbol(day), isOn: dayBinding(day))
                            .toggleStyle(.button)
                            .controlSize(.small)
                    }
                }
                HStack(spacing: 8) {
                    timePicker("From", $draft.schedule.start)
                    timePicker("To", $draft.schedule.end)
                }
                Toggle("Break", isOn: breakBinding)
                if draft.schedule.hasBreak {
                    HStack(spacing: 8) {
                        timePicker("From", optional($draft.schedule.breakStart))
                        timePicker("To", optional($draft.schedule.breakEnd))
                    }
                }
            }
            if let problem = draft.schedule.problem {
                Text(problem).font(.caption).foregroundStyle(Theme.notice)
            } else {
                Text("\(draft.schedule.weeklyHours.formatted(.number.precision(.fractionLength(0...2)))) hours a week, in this person's own time zone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("Use Team Default") { save(nil) }
                    .disabled(isSaving || draft.isDefault)
                Spacer()
                if isSaving { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save(draft.schedule) }
                    .glassButtonStyle(prominent: true)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || draft.schedule.problem != nil)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func save(_ schedule: TeamSchedule?) {
        isSaving = true
        Task {
            let saved = await onSave(draft.userID, schedule)
            isSaving = false
            // A refused save keeps the sheet open; the section shows the error.
            if saved { dismiss() }
        }
    }

    private func timePicker(_ label: String, _ minutes: Binding<Int>) -> some View {
        Picker(label, selection: minutes) {
            ForEach(Self.quarterHours, id: \.self) { value in
                Text(TeamSchedule.clock(value)).tag(value)
            }
            // A saved time off the 15-minute grid stays selectable.
            if !Self.quarterHours.contains(minutes.wrappedValue) {
                Text(TeamSchedule.clock(minutes.wrappedValue)).tag(minutes.wrappedValue)
            }
        }
        .fixedSize()
    }

    private func dayBinding(_ day: Int) -> Binding<Bool> {
        Binding(
            get: { draft.schedule.days.contains(day) },
            set: { on in
                var days = Set(draft.schedule.days)
                if on { days.insert(day) } else { days.remove(day) }
                draft.schedule.days = days.sorted()
            }
        )
    }

    /// Turning the break on starts it at 13:00–14:00.
    private var breakBinding: Binding<Bool> {
        Binding(
            get: { draft.schedule.hasBreak },
            set: { on in
                draft.schedule.breakStart = on ? 13 * 60 : nil
                draft.schedule.breakEnd = on ? 14 * 60 : nil
            }
        )
    }

    private func optional(_ value: Binding<Int?>) -> Binding<Int> {
        Binding(get: { value.wrappedValue ?? 0 }, set: { value.wrappedValue = $0 })
    }
}
