import Foundation

// MARK: - MixTrackEntry

/// A single sub-track within a long mix video (e.g., a DJ set or compilation).
/// Each entry maps a time range within the video to an artist and title,
/// enabling per-sub-track scrobbling instead of scrobbling the entire mix as one track.
struct MixTrackEntry: Identifiable, Hashable {
    let id: UUID
    /// Start time in seconds from the beginning of the video.
    let startTime: TimeInterval
    /// End time in seconds. Nil means "until the next entry or end of video."
    let endTime: TimeInterval?
    /// Track title (without the artist prefix).
    let title: String
    /// Artist name, if parsed from the chapter title or description.
    /// Falls back to the mix uploader name when parsing can't separate artist from title.
    let artist: String?
    /// Where this entry was parsed from.
    let source: Source

    enum Source: String, Hashable {
        case chapters
        case description
    }

    /// Duration of this sub-track in seconds, if end time is known.
    var duration: TimeInterval? {
        guard let endTime else { return nil }
        return endTime - self.startTime
    }

    init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval?,
        title: String,
        artist: String?,
        source: Source
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.title = title
        self.artist = artist
        self.source = source
    }

    /// Creates a MixTrackEntry from a YouTubeChapter title by splitting on " - ".
    /// If the title has no dash, the full title is used as the track title
    /// and the artist is left nil (caller should provide a fallback).
    init(fromChapterTitle title: String, startTime: TimeInterval, endTime: TimeInterval?) {
        let parsed = Self.parseArtistTitle(from: title)
        self.id = UUID()
        self.startTime = startTime
        self.endTime = endTime
        self.source = .chapters
        self.artist = parsed.artist
        self.title = parsed.title
    }

    /// Splits a chapter/description label like "Artist - Title" into its parts, trimming whitespace.
    /// Splits on the FIRST " - "; if absent, the whole string is the title and the artist is nil
    /// (the caller supplies a fallback). Shared by the chapter and description tracklist tiers.
    static func parseArtistTitle(from raw: String) -> (artist: String?, title: String) {
        guard let dashRange = raw.range(of: " - ") else {
            return (nil, raw.trimmingCharacters(in: .whitespaces))
        }
        let artist = raw[..<dashRange.lowerBound].trimmingCharacters(in: .whitespaces)
        let title = raw[dashRange.upperBound...].trimmingCharacters(in: .whitespaces)
        return (artist.isEmpty ? nil : artist, title)
    }
}

// MARK: - MixTracklist

/// A parsed tracklist for a long mix video, containing sub-tracks with timestamps.
/// Used by `ScrobblingCoordinator` to scrobble individual tracks within a mix
/// instead of scrobbling the entire video as a single entry.
struct MixTracklist: Hashable {
    /// The YouTube video ID this tracklist belongs to.
    let videoId: String
    /// Sub-tracks sorted by start time.
    let entries: [MixTrackEntry]
    /// Where the tracklist was parsed from.
    let source: MixTrackEntry.Source

    init(videoId: String, entries: [MixTrackEntry], source: MixTrackEntry.Source) {
        self.videoId = videoId
        self.entries = entries.sorted { $0.startTime < $1.startTime }
        self.source = source
    }

    /// Find the entry active at a given playback position (seconds from start).
    /// Returns the last entry whose startTime is <= progress, or nil if progress
    /// is before the first entry.
    func entry(at progress: TimeInterval) -> MixTrackEntry? {
        // Binary search for the last entry with startTime <= progress
        guard !self.entries.isEmpty else { return nil }
        guard progress >= self.entries.first!.startTime else { return nil }

        var low = 0
        var high = self.entries.count - 1
        var result = 0

        while low <= high {
            let mid = (low + high) / 2
            if self.entries[mid].startTime <= progress {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        return self.entries[result]
    }

    /// Minimum entry count for a tracklist to be treated as a mix.
    /// A single track with 2 chapters is not a mix; 3+ entries indicates a real tracklist.
    static let minEntryCount = 3

    /// Whether this tracklist has enough entries to be treated as a mix.
    var isMix: Bool {
        self.entries.count >= Self.minEntryCount
    }
}
