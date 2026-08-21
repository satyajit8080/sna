import SwiftUI

/// Terms and the medical disclaimer.
///
/// Written in plain language rather than boilerplate. The disclaimer is the part
/// that matters for a blood pressure app, so it goes first and says exactly what
/// the app does and does not do.
struct TermsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                section(
                    "Medical disclaimer",
                    """
                    BP Coach is not a medical device and does not diagnose, treat, cure or \
                    prevent any condition. It records measurements you take and describes \
                    patterns in them.

                    Blood pressure categories come from published guidelines — currently \
                    ACC/AHA 2017 and ESC/ESH 2023 — applied to the readings you enter. They \
                    are not a clinical assessment of your health.

                    Guidance about high readings follows fixed rules based on widely used \
                    thresholds. It is not tailored to your medical history, and it is not a \
                    substitute for a clinician who knows you.

                    Never change, start or stop a prescribed medication based on anything in \
                    this app.

                    If you feel unwell, seek medical care. In an emergency, contact your local \
                    emergency services.
                    """
                )

                section(
                    "What the AI coach is",
                    """
                    The coach explains your own recorded data in plain language. It is a \
                    language model, not a clinician, and it can be wrong.

                    It will not diagnose, predict future readings, or advise on medication. \
                    Decisions about urgency are made by fixed rules in the app, never by the \
                    coach.

                    When it is asked something outside those limits, it says so rather than \
                    guessing.
                    """
                )

                section(
                    "Your data",
                    """
                    Readings, medications, documents and everything else you record stay on \
                    this device. There is no sync.

                    You can sign in with Apple, Google or an email address, but it is \
                    optional and nothing is withheld if you do not. An account stores only \
                    an identifier — never your health data — kept in this device's Keychain.

                    If you use the coach, your first name and a short summary of recent \
                    readings are sent to answer your question — never your full history, and \
                    never a document image. Nothing is stored on the server.

                    Scanned pages are read on your device using Apple's Vision framework. The \
                    images are not uploaded.

                    You can export or delete everything at any time in Privacy & Data.
                    """
                )

                section(
                    "Accuracy",
                    """
                    Values read from a scanned document are recognised automatically and can be \
                    wrong. Always check them against the original. Anything the app is unsure \
                    of is marked for review.

                    Sodium figures are as accurate as their source: a nutrition label is exact, \
                    an estimate is a guess and is labelled as one.
                    """
                )

                section(
                    "Using the app",
                    """
                    BP Coach is provided as-is, for personal use. You are responsible for the \
                    accuracy of what you enter and for decisions you make about your health.

                    Share reports only with people you intend to share health information with.
                    """
                )
            }
            .padding(Theme.Spacing.lg)
        }
        .background(Theme.background)
        .navigationTitle("Terms of Use")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section(_ title: String, _ body: String) -> some View {
        CardView {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text(title).font(.headline)
                Text(body)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
