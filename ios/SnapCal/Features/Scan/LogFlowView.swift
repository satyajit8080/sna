import SwiftUI
import PhotosUI

enum LogMode: String, Identifiable {
    case camera, library, text, voice, barcode, search, manual
    var id: String { rawValue }

    /// The value the backend's `input_method` enum accepts.
    ///
    /// `camera` and `library` are *capture* mechanisms; the server records how
    /// the food was identified, and both are photo scans. Sending the raw case
    /// name was rejected as an invalid enum value on every camera scan.
    var inputMethod: String {
        switch self {
        case .camera, .library: "photo"
        case .text:             "text"
        case .voice:            "voice"
        case .barcode:          "barcode"
        case .search:           "search"
        case .manual:           "manual"
        }
    }
}

struct LogRoute: Identifiable {
    let mode: LogMode
    let slot: MealSlot
    var id: String { mode.rawValue }
}

/// One flow for every input method. The capture stage differs; analysis,
/// confirmation and saving are shared.
struct LogFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app
    @Environment(EntitlementStore.self) private var entitlements

    let route: LogRoute

    @State private var stage: Stage = .capture
    @State private var slot: MealSlot
    @State private var pickerItem: PhotosPickerItem?
    @State private var showPaywall = false

    enum Stage: Equatable {
        case capture
        case analyzing
        case confirm(AnalysisPayload)
        case failed(APIError)
    }

    init(route: LogRoute) {
        self.route = route
        _slot = State(initialValue: route.slot)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .capture:              captureStage
                case .analyzing:            AnalyzingView(mode: route.mode)
                case .confirm(let payload): ConfirmMealView(payload: payload, slot: $slot, onSaved: { dismiss() })
                case .failed(let error):    failureStage(error)
                }
            }
            .background(Theme.bg)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showPaywall, onDismiss: { dismiss() }) { PaywallView(context: .foodScan, source: "scan_flow") }
        }
        .interactiveDismissDisabled(stage == .analyzing)
    }

    // MARK: - Capture

    @ViewBuilder private var captureStage: some View {
        switch route.mode {
        case .camera:
            CameraCaptureView { image in analyze { try await APIClient.shared.analyze(image: image) } }
                .ignoresSafeArea()

        case .library:
            PhotoPickerStage(item: $pickerItem) { image in
                analyze { try await APIClient.shared.analyze(image: image) }
            }

        case .text:
            TextLogView { text in analyze { try await APIClient.shared.analyze(text: text) } }

        case .voice:
            VoiceLogView { transcript in analyze { try await APIClient.shared.analyze(transcript: transcript) } }

        case .barcode:
            BarcodeScannerView { code in analyze { try await APIClient.shared.lookup(barcode: code) } }
                .ignoresSafeArea()

        case .search:
            FoodSearchView { items in
                stage = .confirm(AnalysisPayload(
                    items: items, assumptions: [], confidence: 1,
                    method: LogMode.search.inputMethod, disclaimer: ""
                ))
            }

        case .manual:
            // Reached from "Log it manually" after a failed scan. There is
            // nothing to capture, so go straight to an empty confirm sheet
            // where the user adds foods by search.
            FoodSearchView { items in
                stage = .confirm(AnalysisPayload(
                    items: items, assumptions: [], confidence: nil,
                    method: LogMode.manual.inputMethod, disclaimer: ""
                ))
            }
        }
    }

    // MARK: - Failure

    private func failureStage(_ error: APIError) -> some View {
        VStack(spacing: Theme.Space.l) {
            Spacer()

            Image(systemName: iconFor(error))
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)

            Text(error.errorDescription ?? "Something went wrong.")
                .font(.title)
                .multilineTextAlignment(.center)

            Text(hintFor(error))
                .font(.body_)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Space.l)

            Spacer()

            VStack(spacing: Theme.Space.s) {
                if error.isRetryable || error == .noFoodDetected {
                    Button("Try again") { withAnimation(Theme.snap) { stage = .capture } }
                        .buttonStyle(PrimaryButtonStyle())
                }
                if case .scanLimitReached = error {
                    Button("Go unlimited") { showPaywall = true }
                        .buttonStyle(PrimaryButtonStyle())
                }
                if case .proRequired = error {
                    Button("See Pro") { showPaywall = true }
                        .buttonStyle(PrimaryButtonStyle())
                }
                Button("Log it manually") {
                    stage = .confirm(AnalysisPayload(
                        items: [], assumptions: [], confidence: nil,
                        method: LogMode.manual.inputMethod, disclaimer: ""
                    ))
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .padding(Theme.Space.l)
        }
    }

    private func iconFor(_ e: APIError) -> String {
        switch e {
        case .noFoodDetected: "questionmark.viewfinder"
        case .offline: "wifi.slash"
        case .scanLimitReached, .proRequired: "sparkles"
        default: "exclamationmark.triangle"
        }
    }

    private func hintFor(_ e: APIError) -> String {
        switch e {
        case .noFoodDetected: "Try getting the whole plate in frame with decent light — or just describe the meal instead."
        case .offline: "Check your connection and try once more."
        case .scanLimitReached: "Pro gives you unlimited scans, barcode and voice logging."
        case .proRequired: "This input method is part of Pro."
        default: "This one's on us. Give it another go."
        }
    }

    // MARK: - Shared analysis

    private func analyze(_ work: @escaping () async throws -> AnalysisResponse) {
        withAnimation(Theme.snap) { stage = .analyzing }

        Task {
            do {
                let res = try await work()
                Haptics.success()
                Analytics.track(.foodScanCompleted, ["method": route.mode.rawValue])
                withAnimation(Theme.snap) {
                    stage = .confirm(AnalysisPayload(
                        items: res.foods,
                        assumptions: res.assumptions,
                        confidence: res.confidence,
                        method: route.mode.inputMethod,
                        disclaimer: res.disclaimer,
                        verdict: res.verdict
                    ))
                }
                await app.refresh()
            } catch let error as APIError {
                Haptics.warn()
                // A spent allowance is not an error state — close the flow and
                // let the shared paywall explain, with copy for this feature.
                if case .premiumRequired = error {
                    _ = entitlements.handle(error, source: "scan")
                    dismiss()
                    return
                }
                withAnimation(Theme.snap) { stage = .failed(error) }
            } catch {
                withAnimation(Theme.snap) { stage = .failed(.server(error.localizedDescription)) }
            }
        }
    }
}

struct AnalysisPayload: Equatable {
    var items: [FoodItem]
    var assumptions: [String]
    var confidence: Double?
    var method: String
    var disclaimer: String
    /// Present for a scan, absent for manual entry — there is nothing to
    /// assess when the user typed the food themselves.
    var verdict: ScanVerdict?
}

// MARK: - Analyzing state

struct AnalyzingView: View {
    let mode: LogMode
    @State private var phaseIndex = 0
    @State private var pulse = false

    /// Progressive copy so a 2-3 second wait feels narrated rather than stalled.
    private var messages: [String] {
        mode == .barcode
            ? ["Looking up the label…"]
            : ["Looking at your plate…", "Identifying the food…", "Estimating portions…", "Adding up the macros…"]
    }

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Spacer()

            ZStack {
                Circle()
                    .stroke(Theme.accentSoft, lineWidth: 3)
                    .frame(width: 120, height: 120)
                    .scaleEffect(pulse ? 1.15 : 0.9)
                    .opacity(pulse ? 0 : 1)

                Image(systemName: "sparkles")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Theme.accent)
            }
            .onAppear {
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
            }

            Text(messages[min(phaseIndex, messages.count - 1)])
                .font(.title)
                .contentTransition(.opacity)
                .id(phaseIndex)

            Text("Usually takes a couple of seconds")
                .font(.caption_).foregroundStyle(.tertiary)

            Spacer()

            // Skeleton of the confirm screen — the wait previews the destination.
            VStack(spacing: Theme.Space.s) {
                ForEach(0..<3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(Theme.hairline)
                        .frame(height: 56)
                        .opacity(1 - Double(i) * 0.25)
                }
            }
            .padding(Theme.Space.l)
            .redacted(reason: .placeholder)
        }
        .task {
            for i in 1..<messages.count {
                try? await Task.sleep(for: .milliseconds(750))
                withAnimation(Theme.quick) { phaseIndex = i }
            }
        }
    }
}

// MARK: - Photo library

private struct PhotoPickerStage: View {
    @Binding var item: PhotosPickerItem?
    let onPicked: (UIImage) -> Void
    @State private var isPresented = true

    var body: some View {
        Color.clear
            .photosPicker(isPresented: $isPresented, selection: $item, matching: .images)
            .onChange(of: item) { _, newValue in
                guard let newValue else { return }
                Task {
                    if let data = try? await newValue.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        onPicked(image)
                    }
                }
            }
    }
}
