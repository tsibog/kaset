import Foundation
import Testing
@testable import Kaset

@Suite("Player bar progress lane", .tags(.model))
@MainActor
struct PlayerBarProgressLaneTests {
    @Test("Segment tooltip content stays within the track width")
    func segmentTooltipContentStaysWithinTrackWidth() {
        #expect(PlayerBarProgressLane.segmentTooltipContentMaxWidth(trackWidth: 320) == 298)
        #expect(PlayerBarProgressLane.segmentTooltipContentMaxWidth(trackWidth: 22) == 0)
        #expect(PlayerBarProgressLane.segmentTooltipContentMaxWidth(trackWidth: 10) == 0)
    }
}
