import SwiftData
import SwiftUI

/// Edit or delete an existing reading.
///
/// Editing never silently rewrites the recorded timestamp's timezone or its
/// morning/evening classification unless the date itself changes — a correction
/// to a typo should not reclassify the reading.
struct EditBPView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(GuidelineEngine.self) private var guidelines

    let reading: BPReading

    @State private var systolic: Int
    @State private var diastolic: Int
    @State private var pulse: Int?
    @State private var recordedAt: Date
    @State private var source: BPSource
    @State private var notes: String
    @State private var isConfirmingDelete = false

    init(reading: BPReading) {
        self.reading = reading
        _systolic = State(initialValue: reading.systolic)
        _diastolic = State(initialValue: reading.diastolic)
        _pulse = State(initialValue: reading.pulse)
        _recordedAt = State(initialValue: reading.recordedAt)
        _source = State(initialValue: reading.source)
        _notes = State(initialValue: reading.notes ?? "")
    }

    private var isValid: Bool {
        BPReading.isPlausible(systolic: systolic, diastolic: diastolic)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    BPStepperRow(label: "Systolic", value: $systolic, range: 60...300, tint: Theme.systolicColor)
                    BPStepperRow(label: "Diastolic", value: $diastolic, range: 30...200, tint: Theme.diastolicColor)
                    PulseStepperRow(pulse: $pulse)
                } footer: {
                    if isValid {
                        HStack {
                            CategoryBadge(
                                category: guidelines.category(systolic: systolic, diastolic: diastolic),
                                compact: true
                            )
                            Text("by \(guidelines.active.displayName)")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    } else {
                        Text("Systolic must be higher than diastolic.")
                            .foregroundStyle(Theme.statusModerate)
                    }
                }

                Section("Context") {
                    DatePicker("When", selection: $recordedAt, in: ...Date.now)
                    Picker("Source", selection: $source) {
                        ForEach(BPSource.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    TextField("Notes", text: $notes, axis: .vertical).lineLimit(1...4)
                }

                Section {
                    Button("Delete reading", role: .destructive) {
                        isConfirmingDelete = true
                    }
                }
            }
            .navigationTitle("Edit reading")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!isValid)
                }
            }
            .confirmationDialog(
                "Delete this reading?",
                isPresented: $isConfirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { delete() }
                Button("Keep", role: .cancel) {}
            } message: {
                Text("This cannot be undone. It does not remove the reading from Apple Health.")
            }
        }
    }

    private func save() {
        let dateChanged = reading.recordedAt != recordedAt

        reading.systolic = systolic
        reading.diastolic = diastolic
        reading.pulse = pulse
        reading.recordedAt = recordedAt
        reading.sourceRaw = source.rawValue
        reading.notes = notes.isEmpty ? nil : notes

        if dateChanged {
            reading.timeZoneOffset = TimeZone.current.secondsFromGMT(for: recordedAt)
            reading.timeOfDayRaw = BPTimeOfDay.classify(recordedAt).rawValue
        }

        try? context.save()
        Haptics.success()
        dismiss()
    }

    private func delete() {
        context.delete(reading)
        try? context.save()
        Haptics.success()
        dismiss()
    }
}

// MARK: - Shared rows

struct BPStepperRow: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let tint: Color

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(value)")
                .font(Theme.number(28, weight: .bold))
                .foregroundStyle(tint)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy, value: value)
            Stepper(label, value: $value, in: range)
                .labelsHidden()
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(value)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if value < range.upperBound { value += 1 }
            case .decrement: if value > range.lowerBound { value -= 1 }
            default: break
            }
        }
    }
}

struct PulseStepperRow: View {
    @Binding var pulse: Int?

    var body: some View {
        HStack {
            Text("Pulse")
            Spacer()
            if let pulse {
                Text("\(pulse)")
                    .font(Theme.number(24, weight: .semibold))
                    .foregroundStyle(Theme.pulseColor)
                    .monospacedDigit()
            } else {
                Text("Not recorded").foregroundStyle(Theme.textTertiary).font(.subheadline)
            }
            Stepper("Pulse", value: Binding(
                get: { pulse ?? 70 },
                set: { pulse = $0 }
            ), in: 30...220)
            .labelsHidden()
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(pulse.map { "\($0) beats per minute" } ?? "Not recorded")
    }
}
