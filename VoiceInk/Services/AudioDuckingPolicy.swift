import Foundation

enum AudioDuckingProfile {
    case standard
    case music
    case communication
}

enum AudioDuckingPolicy {
    static let defaultStandardLevel = 0.2
    static let defaultMusicLevel = 0.15
    static let defaultCommunicationLevel = 0.3

    private static let musicBundleIdentifiers = [
        "com.spotify.client",
        "com.apple.music",
        "com.tidal.desktop",
        "com.amazon.music",
        "com.deezer.deezer",
        "com.plexamp.plexamp",
    ]

    private static let communicationBundleIdentifiers = [
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "us.zoom.xos",
        "com.cisco.webex",
        "com.cisco.webexmeetingsapp",
        "com.apple.facetime",
        "com.hnc.discord",
        "com.tinyspeck.slackmacgap",
    ]

    static func normalizedLevel(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite, value > 0 else { return fallback }
        return min(max(value, 0.05), 1.0)
    }

    static func profile(for activeBundleIdentifiers: Set<String>) -> AudioDuckingProfile {
        let normalizedIdentifiers = Set(activeBundleIdentifiers.map { $0.lowercased() })

        if containsMatch(
            in: normalizedIdentifiers,
            candidates: communicationBundleIdentifiers
        ) {
            return .communication
        }

        if containsMatch(in: normalizedIdentifiers, candidates: musicBundleIdentifiers) {
            return .music
        }

        return .standard
    }

    static func level(
        for profile: AudioDuckingProfile,
        standardLevel: Double,
        musicLevel: Double,
        communicationLevel: Double
    ) -> Double {
        switch profile {
        case .standard:
            return normalizedLevel(standardLevel, fallback: defaultStandardLevel)
        case .music:
            return normalizedLevel(musicLevel, fallback: defaultMusicLevel)
        case .communication:
            return normalizedLevel(
                communicationLevel,
                fallback: defaultCommunicationLevel
            )
        }
    }

    private static func containsMatch(
        in identifiers: Set<String>,
        candidates: [String]
    ) -> Bool {
        identifiers.contains { identifier in
            candidates.contains { candidate in
                identifier == candidate || identifier.hasPrefix(candidate + ".")
            }
        }
    }
}
