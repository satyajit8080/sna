import SwiftUI

/// The Scan hub, implemented from the Figma design.
struct ScanHubView: View {
    @Environment(AppModel.self) private var app
    @State private var route: ScanRoute?

    enum ScanRoute: String, Identifiable {
        case food, medicalReport, prescription, medicinePackaging, barcode
        var id: String { rawValue }
    }

    var body: some View {
        BrandScreen {
            BrandHeader(title: "Scan", subtitle: "Scan anything related to your health")

            BrandHeroCard(
                title: "Scan. Understand",
                message: "Take control of your health,",
                symbol: "viewfinder",
                bullets: [
                    "Get instant AI insights",
                    "Track & save securely",
                    "Better decisions every day",
                ]
            )

            Text("Scan Options")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Brand.textPrimary)

            VStack(spacing: 12) {
                BrandListRow(
                    title: "Food Label Scan",
                    subtitle: "Photograph a nutrition panel and read the sodium from it.",
                    symbol: "text.viewfinder",
                    tint: Brand.steps
                ) { route = .food }

                BrandListRow(
                    title: "Medical Report Scan",
                    subtitle: "Scan lab reports, ECG, BP reports and more.",
                    symbol: "doc.text.viewfinder"
                ) { route = .medicalReport }

                BrandListRow(
                    title: "Prescription Scan",
                    subtitle: "Scan your prescription to save medicines & instructions.",
                    symbol: "list.clipboard.fill",
                    tint: Brand.medication
                ) { route = .prescription }

                BrandListRow(
                    title: "Medicine Scan",
                    subtitle: "Read the name from a box. It never identifies a medicine for you.",
                    symbol: "pills.circle.fill",
                    tint: Brand.medication
                ) { route = .medicinePackaging }

                BrandListRow(
                    title: "Barcode Scan",
                    subtitle: barcodeSubtitle,
                    symbol: "barcode.viewfinder",
                    tint: Brand.weight,
                    isAvailable: app.foodProvider.isAvailable
                ) { route = .barcode }
            }

            BrandCard(padding: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("How scanning works here", systemImage: "lock.shield")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Brand.textPrimary)
                    Text("""
                    Text is read on your device using Apple's Vision framework — photos of \
                    prescriptions and reports are never uploaded. Anything read automatically \
                    is shown to you for confirmation before it is saved.
                    """)
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .sheet(item: $route) { route in
            switch route {
            case .medicalReport: DocumentScanView(kind: .bloodTest)
            case .prescription: PrescriptionScanView()
            case .medicinePackaging: MedicinePackagingScanView()
            case .barcode: BarcodeScanView()
            case .food: FoodLabelScanView()
            }
        }
    }

    private var barcodeSubtitle: String {
        app.foodProvider.isAvailable
            ? "Scan any product barcode to know nutrition & health info."
            : "Needs a food data provider. Not configured in this build."
    }
}
