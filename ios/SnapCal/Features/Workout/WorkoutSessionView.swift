import SwiftUI

/// A workout you work through, not a wall of chat text.
///
/// The whole point of the structured endpoint is that a session can be started,
/// ticked off set by set, and logged — which then becomes the history the next
/// recommendation reads. Rendering it as a chat bubble would throw that away.
struct WorkoutSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app

    let plan: WorkoutPlan

    @State private var sets: [CompletedSet] = []
    @State private var effort: Double = 6
    @State private var saving = false
    @State private var showFinish = false
    @State private var error: String?
    @State private var restEndsAt: Date?
    @State private var restExercise: String?

    private var completedCount: Int { sets.filter(\.done).count }
    private var progress: Double {
        sets.isEmpty ? 0 : Double(completedCount) / Double(sets.count)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    header

                    if !plan.warmup.isEmpty {
                        phase("Warm-up", items: plan.warmup, icon: "figure.cooldown")
                    }

                    exerciseList

                    if let cardio = plan.optionalCardio, !cardio.isEmpty {
                        phase("Optional cardio", items: [cardio], icon: "figure.run")
                    }

                    if !plan.cooldown.isEmpty {
                        phase("Cool-down", items: plan.cooldown, icon: "wind")
                    }

                    if !plan.coachNote.isEmpty {
                        Text(plan.coachNote)
                            .font(.jakarta(13, .medium))
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .card(radius: Theme.Radius.row, padding: 0)
                    }

                    Color.clear.frame(height: 80)
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.top, Theme.Space.s)
            }
            .background(Theme.bg)
            .safeAreaInset(edge: .bottom) { finishBar }
            .navigationTitle(plan.workoutTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear(perform: buildSets)
            .alert("Couldn't save", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
            .overlay(alignment: .bottom) { restTimer }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.Space.s) {
                Label("\(plan.durationMinutes) min", systemImage: "clock")
                Label(plan.focus.replacingOccurrences(of: "_", with: " ").capitalized,
                      systemImage: "target")
            }
            .font(.jakarta(12, .semibold))
            .foregroundStyle(Theme.secondary)

            if !sets.isEmpty {
                ProgressView(value: progress)
                    .tint(Theme.accent)
                Text("\(completedCount) of \(sets.count) sets")
                    .font(.jakarta(12, .medium))
                    .foregroundStyle(Theme.secondary)
                    .contentTransition(.numericText())
            }
        }
        .padding(.top, Theme.Space.s)
    }

    private func phase(_ title: String, items: [String], icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.section)

            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(Theme.secondary.opacity(0.4))
                        .frame(width: 5, height: 5).padding(.top, 7)
                    Text(item)
                        .font(.body_)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card(radius: Theme.Radius.row, padding: 0)
    }

    private var exerciseList: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(plan.isRecovery ? "Today's movement" : "Exercises")
                .font(.section)

            ForEach(plan.exercises) { exercise in
                exerciseCard(exercise)
            }
        }
    }

    private func exerciseCard(_ exercise: PlannedExercise) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(exercise.exerciseName)
                        .font(.jakarta(16, .semibold))
                    Text("\(exercise.sets) × \(exercise.reps)")
                        .font(.jakarta(13, .medium))
                        .foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 0)

                if let weight = exercise.suggestedWeightKg {
                    Text("\(weight.formatted(.number.precision(.fractionLength(0...1)))) kg")
                        .font(.jakarta(16, .bold))
                        .foregroundStyle(Theme.accent)
                }
            }

            // The note explains where a weight came from — or why there isn't
            // one. A number with no explanation is a number nobody trusts.
            if let note = exercise.progressionNote, !note.isEmpty {
                Text(note)
                    .font(.jakarta(11, .medium))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !exercise.instructions.isEmpty {
                Label(exercise.instructions, systemImage: "lightbulb")
                    .font(.jakarta(12, .medium))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            ForEach($sets.filter { $0.wrappedValue.exercise == exercise.exerciseName }) { $set in
                setRow($set, exercise: exercise)
            }
        }
        .padding(14)
        .card(radius: Theme.Radius.row, padding: 0)
    }

    private func setRow(_ set: Binding<CompletedSet>, exercise: PlannedExercise) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text("Set \(set.wrappedValue.setNumber)")
                .font(.jakarta(13, .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 48, alignment: .leading)

            TextField("reps", value: set.reps, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .frame(width: 54)
                .padding(.vertical, 6)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))

            Text("×").foregroundStyle(Theme.secondary)

            TextField("kg", value: set.weightKg, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.center)
                .frame(width: 62)
                .padding(.vertical, 6)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))

            Spacer(minLength: 0)

            Button {
                Haptics.tap()
                withAnimation(Theme.quick) { set.wrappedValue.done.toggle() }
                if set.wrappedValue.done { startRest(exercise) }
            } label: {
                Image(systemName: set.wrappedValue.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24))
                    .foregroundStyle(set.wrappedValue.done ? Theme.accent : Theme.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private var restTimer: some View {
        if let endsAt = restEndsAt, let exercise = restExercise {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = Int(endsAt.timeIntervalSince(context.date).rounded())
                if remaining > 0 {
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: "timer")
                        Text("Rest \(remaining)s")
                            .font(.jakarta(14, .semibold).monospacedDigit())
                        Text("· \(exercise)")
                            .font(.jakarta(12, .medium))
                            .foregroundStyle(Theme.secondary)
                        Spacer(minLength: 0)
                        Button("Skip") { restEndsAt = nil }
                            .font(.jakarta(13, .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.card, in: Capsule())
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                    .padding(.horizontal, Theme.gutter)
                    .padding(.bottom, 78)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    private var finishBar: some View {
        VStack(spacing: Theme.Space.s) {
            Button {
                Haptics.commit()
                showFinish = true
            } label: {
                if saving { ProgressView().tint(.white) }
                else { Text(completedCount == 0 ? "Log this session" : "Finish workout") }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(saving)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, Theme.Space.s)
        .background(.bar)
        .confirmationDialog("How hard was that?", isPresented: $showFinish, titleVisibility: .visible) {
            ForEach([("Easy", 3), ("Moderate", 5), ("Hard", 7), ("All out", 9)], id: \.1) { label, value in
                Button(label) {
                    effort = Double(value)
                    Task { await finish() }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Actions

    private func buildSets() {
        guard sets.isEmpty else { return }
        sets = plan.exercises.flatMap { exercise in
            (1...max(exercise.sets, 1)).map { index in
                CompletedSet(
                    exercise: exercise.exerciseName,
                    setNumber: index,
                    // Pre-fill from the plan so the common case is one tap.
                    reps: Int(exercise.reps.split(separator: "-").first ?? "") ?? nil,
                    weightKg: exercise.suggestedWeightKg
                )
            }
        }
    }

    private func startRest(_ exercise: PlannedExercise) {
        restExercise = exercise.exerciseName
        withAnimation(Theme.snap) {
            restEndsAt = Date().addingTimeInterval(Double(exercise.restSeconds))
        }
    }

    private func finish() async {
        guard app.requireAccount(for: "log workouts") else { return }
        saving = true
        defer { saving = false }

        // Only completed sets are logged. Recording planned-but-not-done work
        // would corrupt the history that progression is calculated from.
        let done = sets.filter(\.done)

        let grouped = Dictionary(grouping: done, by: \.exercise)
        let exercises: [[String: Any]] = grouped.map { name, entries in
            var payload: [String: Any] = ["exercise": name, "sets": entries.count]
            if let reps = entries.compactMap(\.reps).max() { payload["reps"] = reps }
            if let weight = entries.compactMap(\.weightKg).max() { payload["weight_kg"] = weight }
            return payload
        }

        do {
            try await APIClient.shared.logWorkout(
                focus: plan.focus,
                minutes: plan.durationMinutes,
                effort: Int(effort),
                planId: plan.id,
                exercises: exercises
            )
            Haptics.success()
            await app.refresh()
            dismiss()
        } catch {
            self.error = (error as? APIError)?.errorDescription
                ?? "Couldn't save this session. Your sets are still here — try again."
        }
    }
}
