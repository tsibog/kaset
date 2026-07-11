import Foundation
import Testing
@testable import Kaset

@Suite(.tags(.model))
struct MixTracklistTests {
    // MARK: - Artist/Title Parsing

    @Test("Chapter title splits into artist and title on the first ' - '")
    func parsesArtistAndTitle() {
        let parsed = MixTrackEntry.parseArtistTitle(from: "Deepbass - Canna (Luigi Tozzi rmx)")
        #expect(parsed.artist == "Deepbass")
        #expect(parsed.title == "Canna (Luigi Tozzi rmx)")
    }

    @Test("Only the first ' - ' separates artist from title")
    func splitsOnFirstDashOnly() {
        let parsed = MixTrackEntry.parseArtistTitle(from: "Octo Aeterna - Opath - Reprise")
        #expect(parsed.artist == "Octo Aeterna")
        #expect(parsed.title == "Opath - Reprise")
    }

    @Test("Title without a dash yields nil artist and the whole string as title")
    func noDashLeavesArtistNil() {
        let parsed = MixTrackEntry.parseArtistTitle(from: "Untitled Jam")
        #expect(parsed.artist == nil)
        #expect(parsed.title == "Untitled Jam")
    }

    @Test("Surrounding whitespace is trimmed from both parts")
    func trimsWhitespace() {
        let parsed = MixTrackEntry.parseArtistTitle(from: "  Skoll  -  Defenestration  ")
        #expect(parsed.artist == "Skoll")
        #expect(parsed.title == "Defenestration")
    }

    @Test("Empty artist side falls back to nil")
    func emptyArtistFallsBackToNil() {
        let parsed = MixTrackEntry.parseArtistTitle(from: " - Just A Title")
        #expect(parsed.artist == nil)
        #expect(parsed.title == "Just A Title")
    }

    @Test("Chapter-title initializer uses the shared parser")
    func chapterInitParsesArtistTitle() {
        let entry = MixTrackEntry(fromChapterTitle: "Einox - Monk", startTime: 100, endTime: 200)
        #expect(entry.artist == "Einox")
        #expect(entry.title == "Monk")
        #expect(entry.source == .chapters)
        #expect(entry.duration == 100)
    }

    @MainActor
    @Test("Chapter parser preserves the final chapter's explicit end time")
    func finalChapterEndTime() async {
        let chapters = [
            YouTubeChapter(videoId: "mix", title: "A - One", startTime: 0, endTime: 100, timeText: nil, thumbnailURL: nil),
            YouTubeChapter(videoId: "mix", title: "B - Two", startTime: 100, endTime: 200, timeText: nil, thumbnailURL: nil),
            YouTubeChapter(videoId: "mix", title: "C - Three", startTime: 200, endTime: 290, timeText: nil, thumbnailURL: nil),
        ]
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = WatchNextData(
            videoTitle: "Mix",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            chapters: chapters
        )

        let tracklist = await MixTracklistParser(youTubeClient: mockYouTube).parseTracklist(videoId: "mix")

        #expect(tracklist?.entries.last?.endTime == 290)
        #expect(tracklist?.entries.last?.duration == 90)
    }

    // MARK: - isMix Threshold

    @Test("Three or more entries is a mix; fewer is not")
    func isMixThreshold() {
        func tracklist(entryCount: Int) -> MixTracklist {
            let entries = (0 ..< entryCount).map {
                MixTrackEntry(
                    startTime: TimeInterval($0) * 60, endTime: nil,
                    title: "T\($0)", artist: "A\($0)", source: .chapters
                )
            }
            return MixTracklist(videoId: "v", entries: entries, source: .chapters)
        }

        #expect(tracklist(entryCount: MixTracklist.minEntryCount - 1).isMix == false)
        #expect(tracklist(entryCount: MixTracklist.minEntryCount).isMix == true)
        #expect(tracklist(entryCount: MixTracklist.minEntryCount + 5).isMix == true)
    }

    // MARK: - entry(at:) Lookup

    @Test("entry(at:) returns the active sub-track and nil before the first entry")
    func entryLookupByProgress() {
        let entries = [
            MixTrackEntry(startTime: 0, endTime: 600, title: "A", artist: "1", source: .chapters),
            MixTrackEntry(startTime: 600, endTime: 1200, title: "B", artist: "2", source: .chapters),
            MixTrackEntry(startTime: 1200, endTime: nil, title: "C", artist: "3", source: .chapters),
        ]
        let list = MixTracklist(videoId: "v", entries: entries, source: .chapters)

        #expect(list.entry(at: 0)?.title == "A")
        #expect(list.entry(at: 599)?.title == "A")
        #expect(list.entry(at: 600)?.title == "B")
        #expect(list.entry(at: 5000)?.title == "C")
    }
}
