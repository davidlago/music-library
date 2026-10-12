import AppIntents
import MusicLibraryGlance

// Compiled into the iPhone app and its widget extension (which defines WIDGET_EXTENSION): the widgets' buttons. As
// audio playback intents they run in the app's process, which iOS launches in the background if needed.

/// Where widget buttons reach the app's player. `PhoneModel.shared` rather than one the app hands over: an intent can
/// run before SwiftUI has set the app up (a background launch).
@MainActor
enum PlaybackCommandCenter {
    static func run(_ command: GlanceCommand) async {
        #if !WIDGET_EXTENSION
        _ = await PhoneModel.shared.perform(command)
        #endif
    }
}

nonisolated struct TogglePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult {
        await PlaybackCommandCenter.run(.playPause)
        return .result()
    }
}

nonisolated struct NextTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next Song"
    static let isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult {
        await PlaybackCommandCenter.run(.next)
        return .result()
    }
}

nonisolated struct PreviousTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous Song"
    static let isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult {
        await PlaybackCommandCenter.run(.previous)
        return .result()
    }
}

nonisolated struct ToggleLikeIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Like or Unlike the Song Playing"
    static let isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult {
        await PlaybackCommandCenter.run(.toggleLike)
        return .result()
    }
}

nonisolated struct ShuffleAllIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Shuffle Music on This iPhone"
    static let isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult {
        await PlaybackCommandCenter.run(.shuffleAll)
        return .result()
    }
}

/// Plays an album from the Rediscover and Recent Purchases widgets.
struct PlayAlbumIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Album"
    static let isDiscoverable = false

    @Parameter(title: "Album") var albumKey: String

    init() {}

    init(albumKey: String) {
        self.albumKey = albumKey
    }

    func perform() async throws -> some IntentResult {
        await PlaybackCommandCenter.run(.playAlbum(key: albumKey))
        return .result()
    }
}
