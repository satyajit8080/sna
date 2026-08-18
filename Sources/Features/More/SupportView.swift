import SwiftUI
import UIKit

struct SupportView: View {
    @Environment(\.openURL) private var openURL

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
        List {
            Section {
                NavigationLink { MeasurementGuideView() } label: {
                    Label("How to measure properly", systemImage: "book.fill")
                }
            }

            Section("Common questions") {
                ForEach(Array(faqs.enumerated()), id: \.offset) { _, faq in
                    DisclosureGroup {
                        Text(faq.1)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.vertical, Theme.Spacing.xs)
                    } label: {
                        Text(faq.0).font(.subheadline)
                    }
                }
            }

            Section {
                Button {
                    openURL(supportMailto)
                } label: {
                    Label("Email support", systemImage: "envelope.fill")
                }
                Button {
                    openURL(problemMailto)
                } label: {
                    Label("Report a problem", systemImage: "exclamationmark.bubble.fill")
                }
            } footer: {
                Text("""
                Reporting a problem opens an email with your app and iOS version filled in. \
                No health data is attached.
                """)
            }
        }
        .navigationTitle("Help & support")
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
