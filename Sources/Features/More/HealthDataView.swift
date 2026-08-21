import SwiftData
import SwiftUI

/// Apple Health, implemented from the Figma design.
///
/// Read-only. BP Coach reads from Health; it does not write back, and it cannot
/// grant or revoke permissions itself — only Health can do that, which is why
/// the disconnect action explains rather than pretends.
struct HealthDataView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var isImporting = false
    @State private var importMessage: String?
    @State private var error: AppError?

    /// The categories the app reads, with the value each currently holds.
    private var categories: [(name: String, symbol: String, value: String?)] {
        let snapshot = app.health.snapshot
        return [
            ("Blood Pressure", "heart.text.square.fill", nil),
            ("Weight", "scalemass.fill",
             snapshot.weightKilograms.map { String(format: "%.1f kg", $0) }),
            ("Steps", "figure.walk", snapshot.steps.map { $0.formatted() }),
            ("Active Energy", "flame.fill",
             snapshot.activeEnergyKilocalories.map { "\($0) kcal" }),
            ("Sleep", "bed.double.fill",
             snapshot.sleepMinutes.map { "\($0 / 60)h \($0 % 60)m" }),
        ]
    }

    var body: some View {
        BrandScreen {
            BrandHeader(title: "Apple Health", showsBack: true, onBack: { dismiss() })

            connectCard

            Text("Connection Status")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Brand.textPrimary)

            statusCard

            Text("Data You're Sharing")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Brand.textPrimary)

            sharingCard

            if app.health.isAvailable {
                importCard
            }

            disconnectCard

            BrandPrimaryButton(title: "Open Apple Health Settings") {
                // Health permissions live in the Health app, not in Settings —
                // sending someone to the wrong place is worse than not offering
                // the shortcut at all.
                if let url = URL(string: "x-apple-health://") {
                    openURL(url)
                }
            }
        }
        .task { await app.health.refreshSnapshot(for: app.activeProfile) }
        .alert(item: $error) { error in
            Alert(title: Text(error.title), message: error.message.map(Text.init))
        }
    }

    // MARK: - Connect

    private var connectCard: some View {
        BrandCard(strokeColor: Brand.accent.opacity(0.5)) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connect with Apple Health")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Brand.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Sync your BP, weight, activity and more securely.")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Circle()
                    .fill(Brand.accent.opacity(0.1))
                    .frame(width: 69, height: 69)
                    .overlay {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(Brand.restingHeartRate)
                    }
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: - Status

    private var statusCard: some View {
        BrandCard(padding: 16) {
            HStack(spacing: 14) {
                Circle()
                    .fill(statusTint)
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(statusTint)
                    Text(statusDetail)
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                if !app.health.hasRequestedAuthorization, app.health.isAvailable {
                    Button {
                        Task {
                            do {
                                try await app.health.requestReadAuthorization(
                                    for: app.activeProfile
                                )
                            } catch {
                                self.error = .healthKitUnavailable
                            }
                        }
                    } label: {
                        Text("Connect")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Brand.onAccent)
                            .padding(.horizontal, 14)
                            .frame(height: 30)
                            .background(Brand.accent)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Three genuinely different states.
    ///
    /// HealthKit never reveals whether *read* permission was granted — by
    /// design, so an app cannot infer what you declined. So "Connected" here
    /// means data has actually come back, which is the only honest signal
    /// available. Asked-but-nothing-returned is a real and ambiguous state, and
    /// it is described rather than guessed at.
    private var statusTitle: String {
        if !app.health.isAvailable { return "Unavailable" }
        if app.health.hasReturnedData { return "Connected" }
        return app.health.hasRequestedAuthorization ? "No data yet" : "Not connected"
    }

    private var statusDetail: String {
        if !app.health.isAvailable {
            return "Apple Health is not available on this device. Manual entry works as normal."
        }
        if !app.health.hasReturnedData {
            return app.health.hasRequestedAuthorization
                ? "Permission was requested but nothing has come back yet. Health only shares what you allowed."
                : "Connect to read your readings and activity from Health."
        }
        if let synced = app.health.lastSyncedAt {
            return "Last synced: \(synced.formatted(date: .abbreviated, time: .shortened))"
        }
        return "Connected. Nothing synced yet."
    }

    private var statusTint: Color {
        if !app.health.isAvailable { return Brand.textSecondary }
        return app.health.hasReturnedData ? Brand.accent : Brand.statusEstimate
    }

    // MARK: - Sharing

    private var sharingCard: some View {
        BrandCard(padding: 0) {
            VStack(spacing: 0) {
                ForEach(Array(categories.enumerated()), id: \.offset) { index, category in
                    if index > 0 {
                        Rectangle()
                            .fill(Brand.cardStroke)
                            .frame(height: 1)
                            .padding(.horizontal, 10)
                    }

                    HStack(spacing: 14) {
                        BrandIconTile(symbol: category.symbol, tint: Brand.accent, size: 55)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(category.name)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Brand.textPrimary)
                            if let value = category.value {
                                Text(value)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Brand.textSecondary)
                            }
                        }

                        Spacer(minLength: 0)

                        // Shows the value where one exists rather than a blanket
                        // "On", which the design shows for every row. HealthKit
                        // will not say which categories were granted, so a row
                        // claiming "On" with no data behind it would be a guess
                        // presented as fact.
                        Text(category.value != nil ? "On" : "—")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(
                                category.value != nil ? Brand.accent : Brand.textSecondary
                            )
                    }
                    .padding(16)
                }
            }
        }
    }

    // MARK: - Import

    private var importCard: some View {
        BrandCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Import blood pressure")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Brand.textPrimary)
                Text("""
                Brings readings recorded by other apps or a connected monitor into \
                BP Coach. Duplicates are skipped.
                """)
                .font(.system(size: 12))
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

                if let importMessage {
                    Text(importMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.accent)
                }

                Button { importReadings() } label: {
                    HStack(spacing: 8) {
                        if isImporting {
                            ProgressView().controlSize(.small).tint(Brand.accent)
                        }
                        Text(isImporting ? "Importing…" : "Import now")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(Brand.accent)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .overlay { Capsule().strokeBorder(Brand.accent.opacity(0.5), lineWidth: 1) }
                }
                .buttonStyle(.plain)
                .disabled(isImporting)
            }
        }
    }

    // MARK: - Disconnect

    private var disconnectCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if let url = URL(string: "x-apple-health://") { openURL(url) }
            } label: {
                Text("Disconnect in Apple Health")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.statusSevere)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .overlay {
                        Capsule().strokeBorder(Theme.statusSevere, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)

            // An app cannot revoke its own Health permission. Saying so is more
            // useful than a button that appears to do it and does not.
            Text("To disconnect, manage permissions in Apple Health settings.")
                .font(.system(size: 12))
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func importReadings() {
        isImporting = true
        importMessage = nil
        Task {
            defer { isImporting = false }
            do {
                let count = try await app.health.importBloodPressure(
                    for: app.activeProfile,
                    into: context
                )
                importMessage = count == 0
                    ? "No new readings found in Health."
                    : "Imported \(count) reading\(count == 1 ? "" : "s")."
            } catch {
                self.error = .healthKitUnavailable
            }
        }
    }
}

struct PrivacyView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrandHeader(title: "Privacy & Data", subtitle: "What is stored, and how to remove it", showsBack: true, onBack: { dismiss() })
                .padding(.horizontal, Brand.Metric.pagePadding)
                .padding(.bottom, 8)

            List {
            Section {
                Label("Your readings stay on this device", systemImage: "iphone")
                Label("No account required", systemImage: "person.crop.circle.badge.checkmark")
                Label("No analytics or tracking", systemImage: "eye.slash")
                Label("No ads", systemImage: "rectangle.slash")
                Label("No server", systemImage: "externaldrive.badge.xmark")
            } header: {
                Text("How BP Coach handles your data")
            } footer: {
                Text("""
                Blood pressure, medications and lifestyle entries are stored locally using \
                Apple's on-device database. Health data read from Apple Health is not sent \
                anywhere. If a future feature ever needs to send data off the device, it \
                will ask first and explain exactly what it sends.
                """)
            }

            Section("Profiles") {
                Text("""
                Each profile's data is kept separate. Queries, exports and anything sent to \
                the AI coach are filtered by profile before they are built, not afterwards.
                """)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
            }
        }
        .navigationTitle("Privacy")
        .scrollContentBackground(.hidden)
        .background(Brand.background)
        }
        .background(Brand.background)
        .navigationBarHidden(true)
    }
}
