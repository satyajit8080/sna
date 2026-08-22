import Foundation

/// The coach's first message.
///
/// Written here rather than generated, for the same reason the check-in
/// notifications are: this is the first thing a new user reads, it arrives
/// before they have asked anything, and nobody reviews it before it appears. A
/// model improvising a welcome would produce something different every install,
/// occasionally overclaim, and could not be tested.
///
/// The tone to aim for is a capable colleague introducing themselves — say what
/// you can do, say plainly what you will not do, and stop. No exclamation marks,
/// no promises about outcomes.
enum CoachWelcome {

    /// Whether the welcome has already been shown for this profile.
    ///
    /// Keyed per profile: a family member added later gets their own
    /// introduction rather than arriving mid-conversation.
    static func hasBeenShown(for profileID: UUID, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key(for: profileID))
    }

    static func markShown(for profileID: UUID, defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key(for: profileID))
    }

    private static func key(for profileID: UUID) -> String {
        "coach.welcome.\(profileID.uuidString)"
    }

    /// The message itself.
    ///
    /// Adapts slightly to what already exists: someone who imported readings
    /// from Apple Health during onboarding should not be told to record their
    /// first one.
    static func message(name: String?, hasReadings: Bool) -> String {
        let greeting: String = {
            guard let name, !name.isEmpty, name.lowercased() != "me" else {
                return "Hello — I'm your coach."
            }
            return "Hello \(name) — I'm your coach."
        }()

        let opening = hasReadings
            ? """
            You already have some readings, so I can start looking at those \
            whenever you like.
            """
            : """
            Once you record a few readings I can tell you what they show. Until \
            then I can still help.
            """

        return """
        \(greeting)

        \(opening)

        Here is what I am useful for:

        · Explaining your own numbers — what a reading means under the guideline \
        you chose, how your mornings compare to your evenings, whether your \
        average is moving.
        · Answering the general questions — how to measure properly, what affects \
        blood pressure, what to ask at your next appointment.
        · Setting things up. Tell me "my appointment with Dr Patel is next \
        Tuesday at 3" or "add ramipril 5mg every morning" and I will fill it in \
        for you to check before anything is saved.
        · Reading what you send me. Photograph a nutrition label, a lab report or \
        a prescription and I will work from what it says.

        Two things I will not do, so you know where you stand. I will not tell \
        you whether something is an emergency — the app decides that with fixed \
        clinical rules, not with me. And I will not suggest starting, stopping or \
        changing a medication. That is your doctor's, and I would be guessing.

        What brought you here?
        """
    }
}
