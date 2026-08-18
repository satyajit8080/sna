import SwiftUI

/// The scan hub. Five capture flows, each with real handling behind it.
struct ScanHubView: View {
    @Environment(AppModel.self) private var app
    @State private var route: ScanRoute?

    enum ScanRoute: String, Identifiable {
        case food, medicalReport, prescription, medicinePackaging, barcode
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.md) {
                card(
                    .medicalReport,
                    title: "Medical Report",
                    subtitle: "Blood test, lab report or doctor's letter",
                    detail: "Reads the page on your device and pulls out values you can check.",
                    symbol: "doc.text.viewfinder",
                    isAvailable: true
                )

                card(
                    .prescription,
                    title: "Prescription",
                    subtitle: "Medicines, doses and frequency",
                    detail: "Suggests what it reads. You confirm every medicine before it is saved.",
                    symbol: "list.clipboard",
                    isAvailable: true
                )

                card(
                    .medicinePackaging,
                    title: "Medicine Packaging",
                    subtitle: "Read the name from a box or label",
                    detail: "Prefills the name for you to confirm. It never identifies a medicine for you.",
                    symbol: "pills.circle",
                    isAvailable: true
                )

                card(
                    .barcode,
                    title: "Barcode",
                    subtitle: "Packaged food",
                    detail: barcodeDetail,
                    symbol: "barcode.viewfinder",
                    isAvailable: app.foodProvider.isAvailable
                )

                card(
                    .food,
                    title: "Food Photo",
                    subtitle: "Estimate sodium from a meal",
                    detail: foodDetail,
                    symbol: "camera.macro",
                    isAvailable: false
                )

                CardView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Label("How scanning works here", systemImage: "lock.shield")
                            .font(.subheadline.weight(.semibold))
                        Text("""
                        Text is read on your device using Apple's Vision framework — photos \
                        of prescriptions and reports are never uploaded. Anything read \
                        automatically is shown to you for confirmation before it is saved.
                        """)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(Theme.Spacing.lg)
        }
        .background(Theme.background)
        .navigationTitle("Scan")
        .sheet(item: $route) { route in
            switch route {
            case .medicalReport: DocumentScanView(kind: .bloodTest)
            case .prescription: PrescriptionScanView()
            case .medicinePackaging: MedicinePackagingScanView()
            case .barcode: BarcodeScanView()
            case .food: EmptyView()
            }
        }
    }

    private var barcodeDetail: String {
        app.foodProvider.isAvailable
            ? "Looks up nutrition from USDA FoodData Central."
            : "Needs a food data provider. Not configured in this build."
    }

    /// Stated plainly rather than shipped as a stub. Estimating sodium from a
    /// photograph needs a vision model this build has no provider for, and a
    /// fabricated number in a sodium tracker is worse than no feature.
    private var foodDetail: String {
        "Needs an image-analysis provider, which is not configured. Add food from the label instead — it is more accurate anyway."
    }

    private func card(
        _ target: ScanRoute,
        title: String,
        subtitle: String,
        detail: String,
        symbol: String,
        isAvailable: Bool
    ) -> some View {
        Button {
            guard isAvailable else { return }
            route = target
        } label: {
            CardView {
                HStack(alignment: .top, spacing: Theme.Spacing.md) {
                    Image(systemName: symbol)
                        .font(.title2)
                        .foregroundStyle(isAvailable ? Theme.accent : Theme.textTertiary)
                        .frame(width: 32)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(title).font(.headline)
                            if !isAvailable {
                                Text("Unavailable")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Theme.border)
                                    .foregroundStyle(Theme.textSecondary)
                                    .clipShape(Capsule())
                            }
                        }
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    if isAvailable {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .accessibilityElement(children: .combine)
        .accessibilityHint(isAvailable ? "" : "Not available in this build")
    }
}
