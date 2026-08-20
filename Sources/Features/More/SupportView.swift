import SwiftUI
import UIKit

struct SupportView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var expanded: Int?

    /// Answers to the questions the app's own design raises. Kept here rather
    /// than fetched, so support works offline like the rest of the app.
    private let faqs: [(String, String)] = [
        ("Why does my reading have a different label than last time?",
         """
         Categories come from the guideline you chose during setup. If you changed it \
         in Settings, every reading is relabelled — the readings themselves never change.
         """),
        ("Why are my clinic readings not in my averages?",
         """
         Home averages deliberately exclude clinic readings. Blood pressure is often \
         higher at a clinic, and mixing the two would hide exactly the gap you and your \
         doctor want to see.
         """),
        ("Why does the app take three readings in Rule of 3?",
         """
         The first reading in a sitting reliably runs high. With three, the first is \
         discarded and the rest averaged, which is closer to what a clinician would use.
         """),
        ("Why can't my family profiles use Apple Health?",
         """
         Apple Health belongs to the person who owns the device. There is no way to \
         separate one person's Health data from another's, so other profiles use \
         readings you enter by hand.
         """),
        ("Does my data leave my phone?",
         """
         Readings, medications and documents stay on your device. Scanned pages are read \
         on-device. If you use the AI coach, a short summary of recent readings is sent \
         to answer your question — never your full history, and never a document image.
         """),
        ("Why won't the coach tell me if something is an emergency?",
         """
         Urgency is decided by fixed clinical rules in the app, not by the AI. That way \
         the guidance is identical every time rather than depending on how a question \
         was phrased.
         """),
        ("Can BP Coach diagnose me?",
         """
         No, and it will not try. It describes patterns in your own numbers and helps you \
         explain them to a doctor. Diagnosis and treatment are theirs to give.
         """),
    ]

    var body: some View {
        BrandScreen {
            BrandHeader(
                title: "Help & Support",
                subtitle: "Answers, guides and a way to reach us",
                showsBack: true,
                onBack: { dismiss() }
            )

            BrandHeroCard(
                title: "How can we help?",
                message: "Most questions are answered below.",
                symbol: "questionmark.circle.fill"
            )

            BrandFormSection("Guides") {
                NavigationLink { MeasurementGuideView() } label: {
                    HStack(spacing: 12) {
                        BrandIconTile(symbol: "book.fill", tint: Brand.accent, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("How to measure properly")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Brand.textPrimary)
                            Text("Technique explains most surprising readings")
                                .font(.system(size: 12))
                                .foregroundStyle(Brand.textSecondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.textSecondary)
                    }
                    .padding(16)
                }
                .buttonStyle(.plain)
            }

            Text("Common questions")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Brand.textPrimary)

            VStack(spacing: 12) {
                ForEach(Array(faqs.enumerated()), id: \.offset) { index, faq in
                    BrandCard(padding: 16) {
                        VStack(alignment: .leading, spacing: 10) {
                            Button {
                                withAnimation(.snappy) {
                                    expanded = expanded == index ? nil : index
                                }
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Text(faq.0)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(Brand.textPrimary)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 8)
                                    Image(systemName: expanded == index ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Brand.accent)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if expanded == index {
                                Text(faq.1)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Brand.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }

            BrandFormSection(
                "Get in touch",
                footer: """
                Reporting a problem opens an email with your app and iOS version filled in. \
                No health data is attached.
                """
            ) {
                BrandActionRow(
                    title: "Rate BP Coach",
                    detail: "Reviews help other people find the app",
                    symbol: "star.fill",
                    tint: Brand.steps
                ) {
                    if let url = ReviewPrompt.writeReviewURL { openURL(url) }
                }
                BrandRowDivider()
                BrandActionRow(
                    title: "Email support",
                    symbol: "envelope.fill"
                ) { openURL(supportMailto) }
                BrandRowDivider()
                BrandActionRow(
                    title: "Report a problem",
                    symbol: "exclamationmark.bubble.fill",
                    tint: Brand.restingHeartRate
                ) { openURL(problemMailto) }
            }
        }
    }

    private var supportMailto: URL {
        URL(string: "mailto:support@bpcoach.app?subject=BP%20Coach%20support")
            ?? URL(string: "https://bpcoach.app")!
    }

    /// Prefilled with version details only. Attaching anything from the store
    /// would put health data in an email.
    private var problemMailto: URL {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let body = """
        Describe what happened:


        ---
        App: \(version) (\(build))
        iOS: \(UIDevice.current.systemVersion)
        Device: \(UIDevice.current.model)
        """
        var components = URLComponents(string: "mailto:support@bpcoach.app")!
        components.queryItems = [
            URLQueryItem(name: "subject", value: "BP Coach problem report"),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url ?? supportMailto
    }
}
