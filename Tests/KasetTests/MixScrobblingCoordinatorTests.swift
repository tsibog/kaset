import Foundation
import Testing
@testable import Kaset

@Suite(.serialized, .tags(.service))
@MainActor
struct MixScrobblingCoordinatorTests {
    // MARK: - Clock

    /// Mutable clock captured by the coordinator's `now` closure, so tests can advance time
    /// deterministically without waiting on the real wall clock.
    final class Clock {
        var current: Date
        init(_ date: Date) {
            self.current = date
        }

        func advance(by seconds: TimeInterval) {
            self.current.addTimeInterval(seconds)
        }
    }

    // MARK: - Harness

    /// Wires a real PlayerService + mix provider + coordinator with a controlled clock, mock scrobble
    /// service enabled+connected, and the low `scrobbleMinSeconds` needed to cross the mix sub-track
    /// threshold in a handful of deterministic polls. Caller must `defer(cleanup)`.
    struct Harness {
        let player: PlayerService
        let provider: NowPlayingTracklistProvider
        let coordinator: ScrobblingCoordinator
        let mockService: MockScrobbleService
        let clock: Clock
        let cleanup: () -> Void
    }

    // MARK: - Fixtures

    private func makeTemporaryDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MixScrobblingCoordinatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func cleanupDirectory(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeWatchNextData(chapters: [YouTubeChapter]) -> WatchNextData {
        WatchNextData(
            videoTitle: "Long Mix",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            chapters: chapters
        )
    }

    private func makeMixChapters(videoId: String = "mix1", count: Int = 3) -> [YouTubeChapter] {
        (0 ..< count).map { index in
            YouTubeChapter(
                videoId: videoId,
                title: "Artist \(index) - Track \(index)",
                startTime: TimeInterval(index) * 600,
                endTime: TimeInterval(index + 1) * 600,
                timeText: nil,
                thumbnailURL: nil
            )
        }
    }

    private func makeProvider(chapters: [YouTubeChapter]) -> NowPlayingTracklistProvider {
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = self.makeWatchNextData(chapters: chapters)
        let parser = MixTracklistParser(youTubeClient: mockYouTube)
        return NowPlayingTracklistProvider(parser: parser)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeHarness() throws -> Harness {
        let provider = self.makeProvider(chapters: self.makeMixChapters(count: 3))
        let player = PlayerService()
        player.setNowPlayingTracklistProvider(provider)

        let mockService = MockScrobbleService()
        mockService.authState = .connected(username: "testuser")

        let settings = SettingsManager.shared
        settings.setServiceEnabled("Mock", true)
        let originalMinSeconds = settings.scrobbleMinSeconds
        settings.scrobbleMinSeconds = 5

        let dir = try self.makeTemporaryDirectory()
        let queue = ScrobbleQueue(directory: dir)

        let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
        let coordinator = ScrobblingCoordinator(
            playerService: player,
            settingsManager: settings,
            services: [mockService],
            queue: queue,
            nowPlayingTracklistProvider: provider,
            now: { clock.current }
        )

        let cleanup = {
            settings.setServiceEnabled("Mock", false)
            settings.scrobbleMinSeconds = originalMinSeconds
            self.cleanupDirectory(dir)
        }

        return Harness(
            player: player,
            provider: provider,
            coordinator: coordinator,
            mockService: mockService,
            clock: clock,
            cleanup: cleanup
        )
    }

    /// Drives the sub-track tracker past the scrobble threshold (`scrobbleMinSeconds` = 5) via small
    /// deterministic accumulate ticks, calling `pollPlayerState()` synchronously each time.
    private func accumulateMixEntry(
        player: PlayerService,
        coordinator: ScrobblingCoordinator,
        clock: Clock,
        startProgress: TimeInterval,
        ticks: Int = 6
    ) {
        player.progress = startProgress
        player.state = .playing
        coordinator.pollPlayerState() // baseline tick — establishes lastProgressTime, no accumulation yet

        for _ in 0 ..< ticks {
            clock.advance(by: 1)
            player.progress += 1
            coordinator.pollPlayerState()
        }
    }

    // MARK: - Happy Path

    @Test("handleMixPlayback enqueues a scrobble for the sub-track once its threshold is met")
    func mixSubTrackScrobblesAtThreshold() async throws {
        let harness = try self.makeHarness()
        defer { harness.cleanup() }

        let mix = TestFixtures.makeSong(id: "mix1", title: "Long Mix", duration: 1800)
        harness.player.currentTrack = mix
        harness.player.duration = 1800
        await self.waitUntil { harness.provider.tracklist != nil }

        self.accumulateMixEntry(player: harness.player, coordinator: harness.coordinator, clock: harness.clock, startProgress: 10)

        let queued = harness.coordinator.queue.pendingTracks
        #expect(queued.count == 1)
        #expect(queued.first?.title == "Track 0")
        #expect(queued.first?.artist == "Artist 0")
        #expect(harness.mockService.scrobbledBatches.isEmpty) // not flushed yet, just enqueued
    }

    // MARK: - Sub-track Transition

    @Test("Moving progress into the next sub-track finalizes the previous entry and starts the new one")
    func mixSubTrackTransitionFinalizesPrevious() async throws {
        let harness = try self.makeHarness()
        defer { harness.cleanup() }

        let mix = TestFixtures.makeSong(id: "mix1", title: "Long Mix", duration: 1800)
        harness.player.currentTrack = mix
        harness.player.duration = 1800
        await self.waitUntil { harness.provider.tracklist != nil }

        self.accumulateMixEntry(player: harness.player, coordinator: harness.coordinator, clock: harness.clock, startProgress: 10)
        #expect(harness.coordinator.queue.pendingTracks.count == 1)

        // Jump into entry 1's range (starts at 600s) without crossing its own threshold.
        harness.clock.advance(by: 1)
        harness.player.progress = 605
        harness.coordinator.pollPlayerState()

        let queued = harness.coordinator.queue.pendingTracks
        #expect(queued.count == 1, "entry 1 hasn't accumulated enough play time to scrobble yet")
        #expect(queued.first?.title == "Track 0")
    }

    // MARK: - Track-switch behaviour (sub-track scrobble survives the switch, no loss or duplicate)

    //
    // Note: this is a behavioural guard, not the discriminating regression test. The outgoing
    // sub-track already scrobbled during accumulation, so `finalizeMixEntry`'s `hasScrobbled` guard
    // makes the snapshot-vs-live tracklist read inert here. The actual regression (a spurious
    // whole-mix scrobble via the single-track fallback) is pinned by
    // `switchingAwayFromMixDoesNotScrobbleWholeMix` below.

    @Test("Switching to a different song still scrobbles the outgoing mix sub-track")
    func outgoingMixEntryScrobblesAfterTrackSwitch() async throws {
        let harness = try self.makeHarness()
        defer { harness.cleanup() }

        let mix = TestFixtures.makeSong(id: "mix1", title: "Long Mix", duration: 1800)
        harness.player.currentTrack = mix
        harness.player.duration = 1800
        await self.waitUntil { harness.provider.tracklist != nil }

        self.accumulateMixEntry(player: harness.player, coordinator: harness.coordinator, clock: harness.clock, startProgress: 10)
        #expect(harness.coordinator.queue.pendingTracks.count == 1, "sub-track 0 should already be threshold-eligible")

        // Switch to an unrelated song. PlayerService's `currentTrack` didSet synchronously resets the
        // provider's tracklist to nil (new video, no mix) before the coordinator polls again.
        let otherSong = TestFixtures.makeSong(id: "unrelated-video", title: "Other Song", duration: 200)
        harness.player.currentTrack = otherSong
        harness.player.duration = 200
        #expect(harness.provider.tracklist == nil, "provider must already have reset for the incoming video")

        harness.clock.advance(by: 1)
        harness.coordinator.pollPlayerState()

        let queued = harness.coordinator.queue.pendingTracks
        #expect(queued.count == 1, "sub-track 0's scrobble must have been enqueued during the earlier accumulation, and finalize must not have skipped it or double-enqueued")
        #expect(queued.first?.title == "Track 0")
    }

    // MARK: - Regression: finalize must not fall through to a spurious whole-mix scrobble

    /// Discriminating regression for the `trackedMixTracklist`-vs-live-`mixTracklist` finalize guard.
    /// The single-track tracker accumulates past `minSeconds` while `duration == 0` (whose threshold
    /// check is gated on `duration > 0`), so it becomes eligible-but-unscrobbled. The mix tracklist
    /// then loads and freezes that tracker. On a track switch the provider resets to the incoming
    /// (non-mix) video, so a finalize that reads the *live* provider (`mixTracklist == nil`) would
    /// skip the mix branch AND take the single-track branch, enqueuing a spurious whole-"Long Mix"
    /// scrobble. Reading the cached snapshot keeps the mix branch active and suppresses that path.
    @Test("Switching away from a mix does not enqueue a spurious whole-mix scrobble")
    func switchingAwayFromMixDoesNotScrobbleWholeMix() async throws {
        let harness = try self.makeHarness()
        defer { harness.cleanup() }

        // Unknown-duration mix song so the provider fetch is gated on `player.duration`, letting the
        // single-track tracker accumulate before the tracklist resolves.
        let mix = TestFixtures.makeSong(id: "mix1", title: "Long Mix", duration: nil)
        harness.player.currentTrack = mix
        harness.player.duration = 0

        // Accumulate whole-track play time past minSeconds (5) while duration is unknown. The
        // single-track threshold check is gated on `duration > 0`, so the tracker stays unscrobbled.
        harness.player.progress = 10
        harness.player.state = .playing
        harness.coordinator.pollPlayerState() // baseline — arms lastProgressTime, no accumulation
        for _ in 0 ..< 8 {
            harness.clock.advance(by: 1)
            harness.player.progress += 1
            harness.coordinator.pollPlayerState()
        }
        #expect(harness.coordinator.queue.pendingTracks.isEmpty, "no whole-track scrobble while duration is unknown")

        // Duration resolves → provider fetches. Do NOT poll until the tracklist loads, or the
        // now-known duration would fire the whole-track threshold in single-track mode.
        harness.player.duration = 1800
        await self.waitUntil { harness.provider.tracklist != nil }

        // One mix-mode poll caches `trackedMixTracklist` and freezes the single-track tracker.
        harness.clock.advance(by: 1)
        harness.coordinator.pollPlayerState()

        // Switch to an unrelated non-mix song; the provider resets synchronously.
        let otherSong = TestFixtures.makeSong(id: "unrelated-video", title: "Other Song", duration: 200)
        harness.player.currentTrack = otherSong
        harness.player.duration = 200
        #expect(harness.provider.tracklist == nil, "provider must already have reset for the incoming video")

        harness.clock.advance(by: 1)
        harness.coordinator.pollPlayerState()

        let queued = harness.coordinator.queue.pendingTracks
        #expect(
            !queued.contains { $0.title == "Long Mix" },
            "finalize must not fall through to the single-track path and scrobble the whole mix"
        )
    }
}
