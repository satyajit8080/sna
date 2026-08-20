import SwiftUI
import UIKit

/// User preferences that affect the whole app.
///
/// Units are a display choice only: weight is always *stored* in kilograms, so
/// switching to pounds never rewrites history or makes an old entry ambiguous.
@Observable
@MainActor
final class AppSettings {

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }

        var label: String {
            switch self {
            case .system: "Match device"
            case .light: "Light"
            case .dark: "Dark"
            }
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    enum WeightUnit: String, CaseIterable, Identifiable {
        case kilograms, pounds
        var id: String { rawValue }
        var label: String { self == .kilograms ? "Kilograms (kg)" : "Pounds (lb)" }
        var short: String { self == .kilograms ? "kg" : "lb" }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // The design is dark-only, so dark is the default rather than following
        // the device. A user who prefers light can still choose it.
        self.appearance = Appearance(
            rawValue: defaults.string(forKey: "settings.appearance") ?? ""
        ) ?? .dark

        if let stored = defaults.string(forKey: "settings.weightUnit"),
           let unit = WeightUnit(rawValue: stored) {
            self.weightUnit = unit
        } else {
            // Follow the device's measurement system on first launch.
            self.weightUnit = Locale.current.measurementSystem == .metric ? .kilograms : .pounds
        }
    }

    var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: "settings.appearance") }
    }

    var weightUnit: WeightUnit {
        didSet { defaults.set(weightUnit.rawValue, forKey: "settings.weightUnit") }
    }

    /// Converts a stored kilogram value for display.
    func displayWeight(_ kilograms: Double) -> String {
        weightUnit == .pounds
            ? String(format: "%.1f lb", kilograms * 2.20462)
            : String(format: "%.1f kg", kilograms)
    }
}

struct AppSettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL

    var body: some View {
        @Bindable var settings = app.settings

        return List {
            Section {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppSettings.Appearance.allCases) { Text($0.label).tag($0) }
                }
            } footer: {
                Text("Onboarding is always dark; the rest of the app follows this setting.")
            }

            Section {
                Picker("Weight", selection: $settings.weightUnit) {
                    ForEach(AppSettings.WeightUnit.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Blood pressure", value: "mmHg")
                LabeledContent("Sodium", value: "mg")
            } header: {
                Text("Units")
            } footer: {
                Text("""
                Weight is always stored in kilograms and converted for display, so changing \
                this never alters what you already recorded. Blood pressure is mmHg \
                worldwide, and sodium labels use milligrams.
                """)
            }

            Section {
                Button {
                    // Language is an iOS-level setting; apps cannot change their
                    // own without a restart, so this opens the right screen.
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    LabeledContent {
                        Text(Locale.current.localizedString(
                            forIdentifier: Locale.current.identifier
                        ) ?? Locale.current.identifier)
                    } label: {
                        Label("Language", systemImage: "globe")
                    }
                }
            } footer: {
                Text("BP Coach follows your iPhone's language. Change it in iOS Settings.")
            }

            Section("Targets") {
                NavigationLink { SodiumTargetView() } label: {
                    LabeledContent {
                        Text("\(SodiumSettings.dailyTarget) mg")
                    } label: {
                        Label("Daily sodium target", systemImage: "drop.fill")
                    }
                }
            }

            Section("Blood pressure guideline") {
                NavigationLink { GuidelineSettingsView() } label: {
                    LabeledContent {
                        Text(app.guidelines.active.displayName)
                    } label: {
                        Label("Guideline", systemImage: "list.clipboard")
                    }
                }
            }
        }
        .navigationTitle("App Settings")
        .scrollContentBackground(.hidden)
        .background(Brand.background)
    }
}
