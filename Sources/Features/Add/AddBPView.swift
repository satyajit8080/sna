import SwiftData
import SwiftUI

struct AddBPView: View {
    @Environment(AppModel.self) private var app
    @Environment(GuidelineEngine.self) private var guidelines
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var systolic = 120
    @State private var diastolic = 80
    @State private var pulse: Int?
    @State private var recordedAt = Date.now
    @State private var source: BPSource = .manual
    @State private var notes = ""
    @State private var saveToHealth = true

    @State private var assessment: SafetyEngine.Assessment?
    @State private var isAskingSymptoms = false
    @State private var selectedSymptoms: Set<SafetyEngine.RedFlagSymptom> = []

    private var isValid: Bool {
        BPReading.isPlausible(systolic: systolic, diastolic: diastolic)
    }

    private var liveCategory: BPCategory {
        guidelines.category(systolic: systolic, diastolic: diastolic)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    BPStepperRow(label: "Systolic", value: $systolic, range: 60...300, tint: Theme.systolicColor)
                    BPStepperRow(label: "Diastolic", value: $diastolic, range: 30...200, tint: Theme.diastolicColor)
                    PulseStepperRow(pulse: $pulse)
                } header: {
                    Text("Reading")
                } footer: {
                    if isValid {
                        HStack {
                            CategoryBadge(category: liveCategory, compact: true)
                            Text("by \(guidelines.active.displayName)")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.top, Theme.Spacing.xs)
                    } else {
                        Text("Systolic must be higher than diastolic.")
                            .foregroundStyle(Theme.statusModerate)
                    }
                }

                Section("Context") {
                    DatePicker("When", selection: $recordedAt, in: ...Date.now)
                    Picker("Source", selection: $source) {
                        ForEach(BPSource.allCases, id: \.self) { source in
                            Text(source.label).tag(source)
                        }
                    }
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(1...4)
                }

                if app.activeProfile.kind.canUseHealthKit && app.health.isAvailable {
                    Section {
                        Toggle("Save to Apple Health", isOn: $saveToHealth)
                    } footer: {
                        Text("Your readings stay on this device. BP Coach does not send health data to any server.")
                    }
                }
            }
            .navigationTitle("Add reading")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Brand.background)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!isValid)
                }
            }
            .sheet(isPresented: $isAskingSymptoms) { symptomSheet }
        }
    }

    // MARK: - Rows

    private var symptomSheet: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(SafetyEngine.RedFlagSymptom.allCases) { symptom in
                        Button {
                            toggle(symptom)
                        } label: {
                            HStack {
                                Text(symptom.rawValue).foregroundStyle(Theme.textPrimary)
                                Spacer()
                                if selectedSymptoms.contains(symptom) {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Are you experiencing any of these right now?")
                }

                Section {
                    Button("None of these") { resolveSymptoms(hasRedFlags: false) }
                    Button("Continue") { resolveSymptoms(hasRedFlags: !selectedSymptoms.isEmpty) }
                        .fontWeight(.semibold)
                }
            }
            .navigationTitle("Quick check")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Brand.background)
        }
        .interactiveDismissDisabled()
    }

    // MARK: - Actions

    private func toggle(_ symptom: SafetyEngine.RedFlagSymptom) {
        if selectedSymptoms.contains(symptom) { selectedSymptoms.remove(symptom) }
        else { selectedSymptoms.insert(symptom) }
    }

    private func save() {
        let reading = BPReading(
            profileID: app.activeProfile.id,
            systolic: systolic,
            diastolic: diastolic,
            pulse: pulse,
            recordedAt: recordedAt,
            source: source,
            notes: notes.isEmpty ? nil : notes
        )
        context.insert(reading)
        try? context.save()

        if saveToHealth, app.activeProfile.kind.canUseHealthKit {
            // Write access is requested here, the first time it is actually
            // needed, rather than during onboarding. `save` refuses if the
            // bundle cannot support writing, so this can never abort.
            Task { try? await app.health.saveRequestingAuthorizationIfNeeded(
                reading: reading, for: app.activeProfile) }
        }

        let result = SafetyEngine.assess(reading)
        if result.urgency >= .urgent { Haptics.warning() } else { Haptics.success() }

        if result.showsSymptomCheck {
            assessment = result
            isAskingSymptoms = true
        } else {
            dismiss()
        }
    }

    private func resolveSymptoms(hasRedFlags: Bool) {
        assessment = SafetyEngine.assess(
            systolic: systolic,
            diastolic: diastolic,
            hasRedFlagSymptoms: hasRedFlags
        )
        isAskingSymptoms = false
        dismiss()
    }
}
