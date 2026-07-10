import SwiftUI

// MARK: - HoverQueueableModifier

/// Registers `song` with the shared `HoveredTrackManager` while the cursor is
/// over this view, so the Q-to-queue hotkey can act on whatever's hovered.
private struct HoverQueueableModifier: ViewModifier {
    let song: Song?
    @Environment(HoveredTrackManager.self) private var hoveredTrackManager

    func body(content: Content) -> some View {
        content.onHover { hovering in
            guard let song else { return }
            if hovering {
                self.hoveredTrackManager.setHovered(song)
            } else {
                self.hoveredTrackManager.clearIfMatched(song)
            }
        }
    }
}

extension View {
    /// Registers `song` with the shared `HoveredTrackManager` while the cursor is over
    /// this view, so the Q-to-queue hotkey can act on whatever's hovered. Pass nil for
    /// rows/cards with nothing queueable.
    func hoverQueueable(for song: Song?) -> some View {
        self.modifier(HoverQueueableModifier(song: song))
    }
}
