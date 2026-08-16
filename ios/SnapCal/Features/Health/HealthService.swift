import Foundation
import HealthKit
import SwiftUI
import Observation

/// Read-only HealthKit bridge.
///
/// SnapCal never writes to Health: it reads steps, active energy and exercise
/// minutes so the coach and weekly report can reason about activity. Asking
/// for write access we don't need would cost conversions on the permission
/// sheet for nothing.
@Observable
@MainActor
final class HealthService: NSObject {
    static let shared = HealthService()

    private(set) var isAvailable = HKHealthStore.isHealthDataAvailable()
    private(set) var today: DailyActivity?
    private(set) var lastSyncError: String?
    private(set) var lastSyncedAt: Date?

    /// Whether we have ever asked. Persisted, because HealthKit does not tell
    /// us whether *read* access was granted — asking again is harmless, but we
    /// only want to show the priming screen once.
    private(set) var hasRequested: Bool {
        get { UserDefaults.standard.bool(forKey: "health.requested") }
        set { UserDefaults.standard.set(newValue, forKey: "health.requested") }
    }

    /// True once a read has actually returned data. Drives the "connect"
    /// prompt: zero steps with this false almost always means no permission.
    private(set) var hasData: Bool {
        get { UserDefaults.standard.bool(forKey: "health.hasData") }
        set { UserDefaults.standard.set(newValue, forKey: "health.hasData") }
    }

    struct DailyActivity: Equatable {
        var steps: Int
        var activeKcal: Int
        var exerciseMinutes: Int
        var distanceMetres: Int
    }

    private let store = HKHealthStore()
    private var observers: [HKObserverQuery] = []

    private var readTypes: Set<HKObjectType> {
        Set([
            HKQuantityType(.stepCount),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.appleExerciseTime),
            HKQuantityType(.distanceWalkingRunning),
        ])
    }

    /// HealthKit deliberately never reports "denied" for read types, so we
    /// cannot branch on authorization status. We always attempt the read; a
    /// refusal is indistinguishable from a genuinely empty day, which is why
    /// `hasData` exists.
    @discardableResult
    func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        hasRequested = true

        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            Analytics.track(.healthkitConnected)
            await syncToday(force: true)
            startObserving()
            return hasData
        } catch {
            lastSyncError = "Health data isn't available right now."
            return false
        }
    }

    /// Pulls today's totals and pushes them to the backend.
    ///
    /// Previously this bailed out unless an in-memory `isConnected` flag was
    /// set during onboarding — which reset on every launch, so after the first
    /// session steps silently stayed at zero forever. There is no gate now:
    /// the read is cheap and returns zero when unauthorised.
    func syncToday(force: Bool = false) async {
        guard isAvailable else { return }

        let start = Calendar.current.startOfDay(for: .now)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: .now)

        async let steps = sum(.stepCount, unit: .count(), predicate: predicate)
        async let energy = sum(.activeEnergyBurned, unit: .kilocalorie(), predicate: predicate)
        async let exercise = sum(.appleExerciseTime, unit: .minute(), predicate: predicate)
        async let distance = sum(.distanceWalkingRunning, unit: .meter(), predicate: predicate)

        let activity = DailyActivity(
            steps: Int(await steps),
            activeKcal: Int(await energy),
            exerciseMinutes: Int(await exercise),
            distanceMetres: Int(await distance)
        )

        if activity.steps > 0 || activity.activeKcal > 0 { hasData = true }

        // Skip the request when nothing moved, unless forced.
        guard force || activity != today else { return }
        today = activity

        do {
            try await APIClient.shared.syncHealth(
                steps: activity.steps,
                activeKcal: activity.activeKcal,
                exerciseMin: activity.exerciseMinutes,
                distanceM: activity.distanceMetres
            )
            lastSyncError = nil
            lastSyncedAt = .now
        } catch {
            // Activity is supplementary — a failed sync must never block the
            // app, which works fine without it.
            lastSyncError = "Couldn't sync activity."
        }
    }

    /// Live updates while the app is open, so a walk is reflected without the
    /// user pulling to refresh.
    func startObserving() {
        guard isAvailable, observers.isEmpty else { return }

        for identifier in [HKQuantityTypeIdentifier.stepCount, .activeEnergyBurned] {
            let type = HKQuantityType(identifier)
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, _ in
                Task { @MainActor in
                    await self?.syncToday()
                    await self?.onUpdate?()
                }
                completion()
            }
            store.execute(query)
            observers.append(query)

            // Wakes the app for step updates even from the background.
            store.enableBackgroundDelivery(for: type, frequency: .hourly) { _, _ in }
        }
    }

    /// Called after a successful sync so the dashboard can refresh its budget.
    var onUpdate: (() async -> Void)?

    /// True when we have no activity to show and probably no permission.
    var needsPermission: Bool {
        isAvailable && !hasData && (today?.steps ?? 0) == 0
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

/// Shown during onboarding, after the user has targets and can see why
/// activity matters.
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
                    .font(.jakarta(26, .bold))
                    .multilineTextAlignment(.center)

                Text("Your steps and workouts help your coach give better advice — and earn back calories as you move.")
                    .font(.body_).foregroundStyle(Theme.secondary)
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
                .font(.jakarta(11)).foregroundStyle(Theme.secondary)

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
                    .font(.jakarta(11)).foregroundStyle(Theme.secondary)
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
