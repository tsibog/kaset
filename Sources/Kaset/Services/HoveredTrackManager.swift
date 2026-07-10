import AppKit
import Foundation
import Observation

// MARK: - HoverClaim

/// A hover-claim guard: the last `set` wins, and `clearIfMatched` only clears
/// when the key it's given still matches what's currently held. Guards the
/// classic race where one row's hover-exit fires after a different row's
/// hover-enter, which would otherwise wrongly clear the second row's claim.
struct HoverClaim<Value, Key: Hashable> {
    private let keyOf: (Value) -> Key

    init(keyOf: @escaping (Value) -> Key) {
        self.keyOf = keyOf
    }

    /// True if `current`'s key equals `key` — i.e. an exit event for `key` should clear `current`.
    func matches(_ current: Value?, _ key: Key) -> Bool {
        guard let current else { return false }
        return self.keyOf(current) == key
    }
}

// MARK: - HoveredTrackManager

/// Tracks the currently hovered track row so a keyboard shortcut can act on it.
/// Only one track is hovered at a time; the last `.onHover` update wins.
@MainActor
@Observable
final class HoveredTrackManager {
    /// The song currently under the cursor in a track row, if any.
    private(set) var hoveredSong: Song?
    private let claim = HoverClaim<Song, String>(keyOf: \.videoId)

    /// videoId of a song just added to the queue via the Q hotkey. Briefly
    /// non-nil so the originating row can animate a confirmation badge.
    private(set) var recentlyQueuedSongID: String?
    private var flashResetTask: Task<Void, Never>?

    /// Sets the hovered song. Called from `.onHover` on track rows.
    /// Pass nil when the cursor leaves a row.
    func setHovered(_ song: Song?) {
        self.hoveredSong = song
    }

    /// Clears the hovered song only if it matches the given song.
    /// Prevents a race where row A's hoverExit fires after row B's hoverEnter,
    /// which would incorrectly clear row B's song.
    func clearIfMatched(_ song: Song) {
        if self.claim.matches(self.hoveredSong, song.videoId) {
            self.hoveredSong = nil
        }
    }

    /// Marks `song` as just-queued for a brief window, driving a confirmation
    /// badge on its row via `HoverObservingRow`/`HomeSectionItemCard`.
    func flashQueued(_ song: Song) {
        self.flashResetTask?.cancel()
        self.recentlyQueuedSongID = song.videoId
        self.flashResetTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            self?.recentlyQueuedSongID = nil
        }
    }
}

// MARK: - QueueRowHoverTracker

/// Tracks which row of the Queue side panel (an `NSTableView`, so it can't use
/// SwiftUI `.onHover`) is under the cursor, and exposes the action to remove it.
/// Lets the Q hotkey remove the hovered queue entry instead of adding a new one.
@MainActor
final class QueueRowHoverTracker {
    static let shared = QueueRowHoverTracker()

    private init() {}

    /// Index of the queue row currently under the cursor, if any.
    private(set) var hoveredIndex: Int?
    private let claim = HoverClaim<Int, Int>(keyOf: { $0 })

    /// Set by the active `QueueListControllerRepresentable.Coordinator`.
    /// Removes the row at the given index with a slide-out animation.
    var removeHandler: ((Int) -> Void)?

    /// Sets the hovered row. Called from `QueueTableCellView`'s tracking area.
    func setHovered(_ index: Int) {
        self.hoveredIndex = index
    }

    /// Clears the hovered row only if it matches, preventing the same
    /// enter-after-exit race `HoveredTrackManager.clearIfMatched` guards against.
    func clearIfMatched(_ index: Int) {
        if self.claim.matches(self.hoveredIndex, index) {
            self.hoveredIndex = nil
        }
    }

    /// Resets all state. Called when the Queue panel closes so a stale hover
    /// (e.g. panel dismissed without a mouseExited event) can't linger.
    func reset() {
        self.hoveredIndex = nil
        self.removeHandler = nil
    }
}

// MARK: - HotkeyMonitor

/// Monitors for key presses when the app window is focused.
/// Currently handles: Q = add hovered track to queue, or remove it from the
/// queue if the hovered row is inside the Queue side panel.
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
            if NSApp.keyWindow?.firstResponder is NSText {
                return event
            }

            // Q key with no modifiers (not ⌘Q, ⌃Q, ⌥Q, etc.)
            // Subtract .capsLock from the mask check so the hotkey works with caps lock on.
            if event.charactersIgnoringModifiers?.lowercased() == "q",
               event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock).isEmpty
            {
                // Hovering a row inside the Queue panel takes priority: Q removes it.
                if let queueRow = QueueRowHoverTracker.shared.hoveredIndex {
                    QueueRowHoverTracker.shared.removeHandler?(queueRow)
                    HapticService.success()
                    return nil
                }

                if let song = hoveredTrackManager.hoveredSong {
                    SongActionsHelper.addToQueueLast(song, playerService: playerService)
                    hoveredTrackManager.flashQueued(song)
                    HapticService.success()
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
