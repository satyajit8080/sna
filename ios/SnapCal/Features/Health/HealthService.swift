import Foundation
import HealthKit
import SwiftUI
import Observation

/// Read-only HealthKit bridge.
///
/// SnapCal never writes to Health: we ask for steps, active energy and exercise
/// minutes so the coach and the weekly report can reason about activity, and
/// nothing else. Requesting write access we don't need would cost conversions
/// on the permission sheet for no benefit.
@Observable
@MainActor
final class HealthService {
    static let shared = HealthService()

    private(set) var isAvailable = HKHealthStore.isHealthDataAvailable()
    private(set) var isConnected = false
    private(set) var today: DailyActivity?
    private(set) var lastSyncError: String?

    struct DailyActivity: Equatable {
        var steps: Int
        var activeKcal: Int
        var exerciseMinutes: Int
    }

    private let store = HKHealthStore()

    private var readTypes: Set<HKObjectType> {
        Set([
            HKQuantityType(.stepCount),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.appleExerciseTime),
        ])
    }

    /// HealthKit deliberately never reports "denied" for read types — asking
    /// again is harmless, and a zero read is indistinguishable from a refusal.
    /// We treat "we got a non-nil sample once" as connected.
    @discardableResult
    func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }

        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            isConnected = true
            Analytics.track(.healthkitConnected)
            await syncToday()
            return true
        } catch {
            lastSyncError = "Health data isn't available right now."
            return false
        }
    }

    /// Pulls today's totals and pushes them to the backend, which is where the
    /// coach, planner and weekly report read from. Safe to call often; it is
    /// cheap and the backend upsert is idempotent.
    ///
    /// `force` skips the unchanged-since-last-sync guard — used when the app
    /// returns to the foreground, where steps have almost certainly moved.
    func syncToday(force: Bool = false) async {
        guard isAvailable, isConnected else { return }

        let start = Calendar.current.startOfDay(for: .now)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: .now)

        async let steps = sum(.stepCount, unit: .count(), predicate: predicate)
        async let energy = sum(.activeEnergyBurned, unit: .kilocalorie(), predicate: predicate)
        async let exercise = sum(.appleExerciseTime, unit: .minute(), predicate: predicate)

        let activity = DailyActivity(
            steps: Int(await steps),
            activeKcal: Int(await energy),
            exerciseMinutes: Int(await exercise)
        )

        // Don't spend a request when nothing has moved.
        guard force || activity != today else { return }
        today = activity

        do {
            try await APIClient.shared.syncHealth(
                steps: activity.steps,
                activeKcal: activity.activeKcal,
                exerciseMin: activity.exerciseMinutes
            )
            lastSyncError = nil
        } catch {
            // Activity is supplementary — a failed sync must never surface as a
            // blocking error, the app works fine without it.
            lastSyncError = "Couldn't sync activity."
        }
    }

    private func sum(_ identifier: HKQuantityTypeIdentifier,
                     unit: HKUnit,
                     predicate: NSPredicate) async -> Double {
        await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: HKQuantityType(identifier),
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, statistics, _ in
                continuation.resume(returning: statistics?.sumQuantity()?.doubleValue(for: unit) ?? 0)
            }
            store.execute(query)
        }
    }
}

/// Shown during onboarding, after the user has their targets and can see why
/// activity would matter.
struct HealthConnectView: View {
    @Environment(HealthService.self) private var health
    let onFinish: () -> Void

    @State private var working = false

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Spacer()

            Image(systemName: "heart.text.square")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(Theme.accent)

            VStack(spacing: Theme.Space.s) {
                Text("Connect Apple Health")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)

                Text("Your steps and workouts help your coach give better advice — and show up in your weekly progress.")
                    .font(.body_).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Space.m)
            }

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                row("figure.walk", "Steps")
                row("flame", "Active calories")
                row("timer", "Exercise minutes")
            }
            .card()

            Text("Read-only. SnapCal never writes to Health.")
                .font(.caption_).foregroundStyle(.tertiary)

            Spacer()

            VStack(spacing: Theme.Space.s) {
                Button {
                    working = true
                    Task {
                        await health.requestAuthorization()
                        working = false
                        onFinish()
                    }
                } label: {
                    if working { ProgressView().tint(.white) } else { Text("Connect Apple Health") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!health.isAvailable || working)

                Button("Not now", action: onFinish)
                    .buttonStyle(SecondaryButtonStyle())
            }

            if !health.isAvailable {
                Text("Health data isn't available on this device.")
                    .font(.caption_).foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Space.l)
        .background(Theme.bg)
    }

    private func row(_ icon: String, _ label: String) -> some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(Theme.accent)
            Text(label).font(.body_)
            Spacer()
        }
    }
}
