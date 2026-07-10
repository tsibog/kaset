import SwiftUI

// MARK: - QueuedFeedbackModifier

/// Attaches a transient "added to queue" confirmation badge to a hoverable
/// row/card. Reads `HoveredTrackManager.recentlyQueuedSongID` and animates the
/// badge in/out when it matches `song`, giving the Q-to-queue hotkey visible
/// feedback (previously only a haptic tick, with nothing to see).
private struct QueuedFeedbackModifier: ViewModifier {
    let song: Song?
    @Environment(HoveredTrackManager.self) private var hoveredTrackManager

    private var isFlashing: Bool {
        guard let song else { return false }
        return self.hoveredTrackManager.recentlyQueuedSongID == song.videoId
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if self.isFlashing {
                    QueuedFeedbackBadge()
                        .padding(6)
                        .transition(.scale(scale: 0.4, anchor: .topTrailing).combined(with: .opacity))
                }
            }
            .animation(AppAnimation.bouncy, value: self.isFlashing)
    }
}

extension View {
    /// Shows a brief "added to queue" checkmark badge over this view when
    /// `song` was just queued via the Q hotkey.
    func queuedFeedback(for song: Song?) -> some View {
        self.modifier(QueuedFeedbackModifier(song: song))
    }
}

// MARK: - QueuedFeedbackBadge

private struct QueuedFeedbackBadge: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .compatGlass(tint: .green, in: Circle())
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .accessibilityHidden(true)
    }
}

// MARK: - Preview

#Preview("Queued Feedback Badge") {
    QueuedFeedbackBadge()
        .padding()
}
