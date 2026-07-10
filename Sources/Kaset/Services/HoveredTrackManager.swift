import AppKit
import Foundation
import Observation

// MARK: - HoveredTrackManager

/// Tracks the currently hovered track row so a keyboard shortcut can act on it.
/// Only one track is hovered at a time; the last `.onHover` update wins.
@MainActor
@Observable
final class HoveredTrackManager {
    /// The song currently under the cursor in a track row, if any.
    private(set) var hoveredSong: Song?

    /// Sets the hovered song. Called from `.onHover` on track rows.
    /// Pass nil when the cursor leaves a row.
    func setHovered(_ song: Song?) {
        self.hoveredSong = song
    }

    /// Clears the hovered song only if it matches the given song.
    /// Prevents a race where row A's hoverExit fires after row B's hoverEnter,
    /// which would incorrectly clear row B's song.
    func clearIfMatched(_ song: Song) {
        if self.hoveredSong?.videoId == song.videoId {
            self.hoveredSong = nil
        }
    }
}

// MARK: - HotkeyMonitor

/// Monitors for key presses when the app window is focused.
/// Currently handles: Q = add hovered track to queue.
@MainActor
final class HotkeyMonitor {
    static let shared = HotkeyMonitor()

    private var monitor: Any?

    private init() {}

    /// Starts listening for key events. Only fires when the app is frontmost
    /// (local monitor, not global), matching Daniel's requirement: window must be focused.
    func start(playerService: PlayerService, hoveredTrackManager: HoveredTrackManager) {
        guard self.monitor == nil else { return }

        self.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak playerService, weak hoveredTrackManager] event in
            guard let playerService, let hoveredTrackManager else { return event }

            // Only act when the app is frontmost (window is focused)
            guard NSApp.isActive else { return event }

            // Don't intercept if a text field or other text input has focus
            // (e.g., user is typing in the search bar)
            if NSApp.keyWindow?.firstResponder is NSText { return event }

            // Q key with no modifiers (not ⌘Q, ⌃Q, ⌥Q, etc.)
            // Subtract .capsLock from the mask check so the hotkey works with caps lock on.
            if event.charactersIgnoringModifiers?.lowercased() == "q",
               event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock).isEmpty
            {
                if let song = hoveredTrackManager.hoveredSong {
                    SongActionsHelper.addToQueueLast(song, playerService: playerService)
                    HapticService.toggle()
                    return nil // Consume the event
                }
            }

            return event
        }
    }

    /// Stops monitoring and removes the event tap.
    func stop() {
        if let monitor = self.monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
