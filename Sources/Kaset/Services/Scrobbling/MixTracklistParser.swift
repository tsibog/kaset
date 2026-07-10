import Foundation
import os

// MARK: - MixTracklistParser

/// Parses tracklists for long mix videos using a two-tier approach:
/// 1. YouTube chapters (structured API data, no LLM needed)
/// 2. Description timestamps (regex first, then Foundation Models fallback)
///
/// Chapters are fetched via `YouTubeClient.getWatchNext(videoId:)`, which calls
/// the regular YouTube `next` endpoint. The YTMusic `next` endpoint does NOT
/// return chapter data (confirmed via API exploration, 2026-07-10).
@MainActor
final class MixTracklistParser {
    private let youTubeClient: any YouTubeClientProtocol
    private var cache: [String: MixTracklist] = [:]
    private let logger = DiagnosticsLogger.scrobbling

    init(youTubeClient: any YouTubeClientProtocol) {
        self.youTubeClient = youTubeClient
    }

    /// Parse a tracklist for a video. Returns nil if no tracklist is available.
    /// Results are cached by video ID for the lifetime of this parser instance.
    func parseTracklist(videoId: String) async -> MixTracklist? {
        if let cached = self.cache[videoId] {
            return cached
        }

        // Tier 1: YouTube chapters via the regular YouTube next endpoint
        if let tracklist = await self.parseFromChapters(videoId: videoId) {
            self.cache[videoId] = tracklist
            self.logger.info("Mix tracklist parsed from chapters: \(tracklist.entries.count) entries for \(videoId)")
            return tracklist
        }

        // Tier 2: Description parsing (deferred — needs WatchNextParser extension for description extraction)
        // TODO: Extract description text from engagementPanels in the next response,
        // then regex parse for timestamp patterns, then Foundation Models fallback.

        return nil
    }

    // MARK: - Tier 1: Chapter Extraction

    /// Extract tracklist from YouTube chapters via `YouTubeClient.getWatchNext`.
    private func parseFromChapters(videoId: String) async -> MixTracklist? {
        do {
            let watchNextData = try await self.youTubeClient.getWatchNext(videoId: videoId)
            let chapters = watchNextData.chapters

            // Only treat as a mix if there are 3+ chapters
            guard chapters.count >= 3 else { return nil }

            // Convert chapters to MixTrackEntry, computing endTime from the next chapter's startTime
            let entries = chapters.enumerated().map { index, chapter -> MixTrackEntry in
                let endTime: TimeInterval?
                if index + 1 < chapters.count {
                    endTime = chapters[index + 1].startTime
                } else {
                    // Last chapter — endTime stays nil (until end of video)
                    endTime = nil
                }

                return MixTrackEntry(
                    fromChapterTitle: chapter.title,
                    startTime: chapter.startTime,
                    endTime: endTime
                )
            }

            return MixTracklist(videoId: videoId, entries: entries, source: .chapters)
        } catch {
            self.logger.debug("Chapter extraction failed for \(videoId): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Cache Management

    /// Clears the cache for a specific video, forcing a re-parse on next access.
    func invalidate(videoId: String) {
        self.cache.removeValue(forKey: videoId)
    }

    /// Clears all cached tracklists.
    func invalidateAll() {
        self.cache.removeAll()
    }
}
