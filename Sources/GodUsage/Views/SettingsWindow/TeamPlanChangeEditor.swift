import SwiftUI

/// The "Change Plan…" / "Update Payment…" sheet: the plan's new name and monthly price, and the day
/// they take effect. Past days are allowed (the cycle they fall in is prorated); the default is the
/// next renewal, or the day a member's Mac first detected the new plan.
struct TeamPlanChangeEditor: View {
    struct Draft: Identifiable {
        let id = UUID()
        var planID: String
        var planName: String
        var name: String
        var monthlyCostUSD: Double?
        var effective: Date
        /// The first day allowed: after the change in effect today. Nil allows any day.
        var earliest: Date?
        /// Set from a mismatch: the plan links to this detected plan once the change is saved.
        var linkDetectedPlan: String?
    }

    @Environment(\.dismiss) private var dismiss
    @State var draft: Draft
    let onSave: (Draft) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.linkDetectedPlan == nil ? "Change Plan" : "Update Payment").font(.title3.weight(.semibold))
                Text(draft.planName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 10) {
                TextField("New Name", text: $draft.name)
                HStack(spacing: 8) {
                    TextField("Monthly Cost", value: $draft.monthlyCostUSD, format: .currency(code: "USD"))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 110)
                    Text("/ mo").font(.caption).foregroundStyle(.secondary)
                }
                datePicker
            }
            .textFieldStyle(.roundedBorder)
            Text("From this day the plan has the new name and price. A billing cycle with a change costs each price for the days it applies.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save Change") {
                    onSave(draft)
                    dismiss()
                }
                .glassButtonStyle(prominent: true)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    @ViewBuilder
    private var datePicker: some View {
        if let earliest = draft.earliest {
            DatePicker("Effective", selection: $draft.effective, in: earliest..., displayedComponents: .date)
        } else {
            DatePicker("Effective", selection: $draft.effective, displayedComponents: .date)
        }
    }

    private var isValid: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty && (draft.monthlyCostUSD ?? 0) > 0
    }
}
