import SwiftUI
import Testing
@testable import Nook

@MainActor
struct LiveTranscriptScrollTests {
    @Test
    func openingAndReopeningReachLatestWithoutAnotherTranscriptRevision() {
        var scroll = LiveTranscriptScrollState()
        #expect(scroll.isFollowing)
        #expect(scroll.position.edge == .bottom)

        scroll.phaseChanged(to: .interacting, isAtLatest: false)
        scroll.phaseChanged(to: .idle, isAtLatest: false)
        #expect(scroll.showsJumpToLatest)

        // Reopening a paused meeting must work without any new speech event.
        scroll.appeared()
        #expect(scroll.isFollowing)
        #expect(scroll.position.edge == .bottom)
        #expect(!scroll.showsJumpToLatest)
        #expect(scroll.phase == .idle)
    }

    @Test
    func newWordsRequestBottomAgainAndLateReflowGetsOneCorrection() {
        var scroll = LiveTranscriptScrollState()
        let original = geometry(offset: 580, contentHeight: 1_000, bottomInset: 80)
        let originalLayoutRequestedScroll = scroll.geometryChanged(scroll.observation(original))
        #expect(!originalLayoutRequestedScroll)
        let revisionRequestedScroll = scroll.transcriptChanged()
        #expect(revisionRequestedScroll)

        // Native replay showed that an edge position can stay at the old
        // offset when new text grows below it. Layout must issue another request.
        let appended = geometry(offset: 580, contentHeight: 1_100, bottomInset: 80)
        let appendedLayoutRequestedScroll = scroll.geometryChanged(scroll.observation(appended))
        #expect(appendedLayoutRequestedScroll)
        let repeatedAppendRequestedScroll = scroll.geometryChanged(scroll.observation(appended))
        #expect(!repeatedAppendRequestedScroll)
        #expect(scroll.isFollowing)
        #expect(!scroll.showsJumpToLatest)

        let arrived = geometry(offset: 680, contentHeight: 1_100, bottomInset: 80)
        let arrivalRequestedScroll = scroll.geometryChanged(scroll.observation(arrived))
        #expect(!arrivalRequestedScroll)
        #expect(scroll.isAtLatest)

        // A partial can wrap after that arrival without another final passage.
        let wrapped = geometry(offset: 680, contentHeight: 1_150, bottomInset: 80)
        let wrappedLayoutRequestedScroll = scroll.geometryChanged(scroll.observation(wrapped))
        #expect(wrappedLayoutRequestedScroll)
        let repeatedWrapRequestedScroll = scroll.geometryChanged(scroll.observation(wrapped))
        #expect(!repeatedWrapRequestedScroll)
        #expect(scroll.position.edge == .bottom)
    }

    @Test(arguments: [ScrollPhase.interacting, .decelerating])
    func userScrollingReleasesTheAnchorBeforeNewWordsCanOverrideIt(_ phase: ScrollPhase) {
        var scroll = LiveTranscriptScrollState()
        scroll.phaseChanged(to: phase, isAtLatest: true)
        #expect(!scroll.isFollowing)
        #expect(scroll.position.isPositionedByUser)
        #expect(scroll.position.edge == nil)

        for _ in 0..<100 {
            let revisionRequestedScroll = scroll.transcriptChanged()
            #expect(!revisionRequestedScroll)
            scroll.geometryChanged(scroll.observation(isAtLatest: false))
            scroll.geometryChanged(scroll.observation(isAtLatest: true))
            #expect(!scroll.isFollowing)
        }
    }

    @Test
    func touchingWithoutScrollingKeepsFollowingWhenNewWordsArrive() {
        var scroll = LiveTranscriptScrollState()
        scroll.phaseChanged(to: .tracking, isAtLatest: true)
        scroll.geometryChanged(scroll.observation(isAtLatest: false))
        scroll.phaseChanged(to: .idle, isAtLatest: false)
        #expect(scroll.isFollowing)
        #expect(!scroll.showsJumpToLatest)
    }

    @Test
    func earlierPassagesStayInPlaceAfterTheUserStopsScrolling() {
        var scroll = LiveTranscriptScrollState()
        scroll.phaseChanged(to: .interacting, isAtLatest: false)
        scroll.phaseChanged(to: .decelerating, isAtLatest: false)
        scroll.phaseChanged(to: .idle, isAtLatest: false)

        for _ in 0..<100 {
            let revisionRequestedScroll = scroll.transcriptChanged()
            #expect(!revisionRequestedScroll)
            scroll.geometryChanged(scroll.observation(isAtLatest: false))
        }
        #expect(scroll.position.isPositionedByUser)
        #expect(scroll.position.edge == nil)
        #expect(!scroll.isFollowing)
        #expect(scroll.showsJumpToLatest)
    }

    @Test
    func growingContentNeverReclaimsHistoryWhileDetached() {
        var scroll = LiveTranscriptScrollState()
        scroll.phaseChanged(to: .interacting, isAtLatest: false)
        scroll.phaseChanged(to: .idle, isAtLatest: false)
        let history = geometry(offset: 200, contentHeight: 1_000, bottomInset: 80)
        let historyRequestedScroll = scroll.geometryChanged(scroll.observation(history))
        #expect(!historyRequestedScroll)
        let revisionRequestedScroll = scroll.transcriptChanged()
        #expect(!revisionRequestedScroll)
        let grown = geometry(offset: 200, contentHeight: 1_300, bottomInset: 80)
        let growthRequestedScroll = scroll.geometryChanged(scroll.observation(grown))
        #expect(!growthRequestedScroll)
        #expect(!scroll.isFollowing)
        #expect(scroll.showsJumpToLatest)
    }

    @Test
    func aTouchDefersGrowthCorrectionUntilIdleWithoutStealingTheGesture() {
        var scroll = LiveTranscriptScrollState()
        scroll.geometryChanged(scroll.observation(geometry(offset: 580, contentHeight: 1_000, bottomInset: 80)))
        scroll.phaseChanged(to: .tracking, isAtLatest: true)
        let revisionDuringTouchRequestedScroll = scroll.transcriptChanged()
        #expect(!revisionDuringTouchRequestedScroll)
        let layoutDuringTouchRequestedScroll = scroll.geometryChanged(scroll.observation(geometry(offset: 580, contentHeight: 1_100, bottomInset: 80)))
        #expect(!layoutDuringTouchRequestedScroll)
        #expect(scroll.isFollowing)
        let idleRequestedScroll = scroll.phaseChanged(to: .idle, isAtLatest: false)
        #expect(idleRequestedScroll)
        #expect(scroll.isFollowing)
    }

    @Test
    func lateLayoutCannotReclaimFollowingAfterTheUserStartsScrolling() {
        var scroll = LiveTranscriptScrollState()
        let revisionRequestedScroll = scroll.transcriptChanged()
        #expect(revisionRequestedScroll)
        let queued = scroll.observation(geometry(offset: 580, contentHeight: 1_100, bottomInset: 80))
        scroll.phaseChanged(to: .interacting, isAtLatest: false)
        scroll.phaseChanged(to: .idle, isAtLatest: false)
        let staleLayoutRequestedScroll = scroll.geometryChanged(queued)
        #expect(!staleLayoutRequestedScroll)
        #expect(!scroll.isFollowing)
        #expect(scroll.showsJumpToLatest)
    }

    @Test
    func keyboardOrAccessibilityOffsetChangesDetachEvenWithoutNativeUserFlags() {
        var scroll = LiveTranscriptScrollState()
        scroll.geometryChanged(scroll.observation(geometry(offset: 580, contentHeight: 1_000, bottomInset: 80)))
        #expect(!scroll.position.isPositionedByUser)

        // Page Up and setting the native scrollbar can change only geometry.
        // No phase or isPositionedByUser update is injected in this regression.
        let earlier = geometry(offset: 200, contentHeight: 1_000, bottomInset: 80)
        let historyRequestedScroll = scroll.geometryChanged(scroll.observation(earlier))
        #expect(!historyRequestedScroll)
        #expect(scroll.position.isPositionedByUser)
        #expect(scroll.showsJumpToLatest)
        let revisionRequestedScroll = scroll.transcriptChanged()
        #expect(!revisionRequestedScroll)
        #expect(scroll.observation(earlier).contentOffsetY == nil)

        let latest = geometry(offset: 580, contentHeight: 1_000, bottomInset: 80)
        let returnToLatestRequestedScroll = scroll.geometryChanged(scroll.observation(latest))
        #expect(returnToLatestRequestedScroll)
        #expect(scroll.isFollowing)
        #expect(!scroll.showsJumpToLatest)
    }

    @Test
    func keyboardHistoryMovementWinsWhenNewWordsGrowInTheSameGeometryUpdate() {
        var scroll = LiveTranscriptScrollState()
        let original = geometry(offset: 580, contentHeight: 1_000, bottomInset: 80)
        scroll.geometryChanged(scroll.observation(original))

        // Native events can coalesce a Page Up or AX scrollbar change with
        // incoming words. No user phase or binding update accompanies this.
        let historyAndGrowth = geometry(offset: 200, contentHeight: 1_100, bottomInset: 80)
        let combinedUpdateRequestedScroll = scroll.geometryChanged(scroll.observation(historyAndGrowth))
        #expect(!combinedUpdateRequestedScroll)
        #expect(scroll.position.isPositionedByUser)
        #expect(scroll.showsJumpToLatest)
        let laterRevisionRequestedScroll = scroll.transcriptChanged()
        #expect(!laterRevisionRequestedScroll)
        let moreGrowth = geometry(offset: 200, contentHeight: 1_200, bottomInset: 80)
        let laterLayoutRequestedScroll = scroll.geometryChanged(scroll.observation(moreGrowth))
        #expect(!laterLayoutRequestedScroll)
    }

    @Test
    func geometryOnlyDetachmentInvalidatesAnOlderLatestVisibilityCallback() {
        var scroll = LiveTranscriptScrollState()
        let original = geometry(offset: 580, contentHeight: 1_000, bottomInset: 80)
        scroll.geometryChanged(scroll.observation(original))
        let queuedLatest = scroll.observation(original)
        let history = geometry(offset: 200, contentHeight: 1_000, bottomInset: 80)
        scroll.geometryChanged(scroll.observation(history))
        #expect(scroll.showsJumpToLatest)

        let staleArrivalRequestedScroll = scroll.geometryChanged(queuedLatest)
        #expect(!staleArrivalRequestedScroll)
        #expect(!scroll.isAtLatest)
        #expect(!scroll.isFollowing)
        #expect(scroll.position.isPositionedByUser)
        #expect(scroll.showsJumpToLatest)
    }

    @Test
    func shrinkingContentAndResizingCanMoveOffsetsBackwardsWithoutEnteringHistory() {
        let original = geometry(offset: 580, contentHeight: 1_000, bottomInset: 80)
        let layoutChanges = [
            geometry(offset: 450, contentHeight: 950, bottomInset: 80),
            geometry(offset: 400, contentHeight: 1_000, bottomInset: 80, viewportHeight: 450),
            geometry(offset: 400, contentHeight: 1_100, bottomInset: 80, viewportWidth: 650),
            geometry(offset: 400, contentHeight: 1_000, bottomInset: 120)
        ]
        for changed in layoutChanges {
            var scroll = LiveTranscriptScrollState()
            scroll.geometryChanged(scroll.observation(original))
            let layoutRequestedScroll = scroll.geometryChanged(scroll.observation(changed))
            #expect(layoutRequestedScroll)
            #expect(scroll.isFollowing)
            #expect(!scroll.position.isPositionedByUser)
            #expect(!scroll.showsJumpToLatest)
        }
    }

    @Test
    func shrinkingToShortContentCorrectsAStaleOffsetBeyondItsNewBottom() {
        var scroll = LiveTranscriptScrollState()
        let long = geometry(offset: 5_580, contentHeight: 6_000, bottomInset: 80)
        scroll.geometryChanged(scroll.observation(long))
        let revisionRequestedScroll = scroll.transcriptChanged()
        #expect(revisionRequestedScroll)

        let staleOffset = geometry(offset: 5_580, contentHeight: 200, bottomInset: 80)
        #expect(!LiveTranscriptScrollState.isAtLatest(staleOffset))
        let shrinkRequestedScroll = scroll.geometryChanged(scroll.observation(staleOffset))
        #expect(shrinkRequestedScroll)
        #expect(scroll.isFollowing)
        #expect(!scroll.isAtLatest)
        let repeatedLayoutRequestedScroll = scroll.geometryChanged(scroll.observation(staleOffset))
        #expect(!repeatedLayoutRequestedScroll)

        let clamped = geometry(offset: -20, contentHeight: 200, bottomInset: 80)
        let arrivalRequestedScroll = scroll.geometryChanged(scroll.observation(clamped))
        #expect(!arrivalRequestedScroll)
        #expect(scroll.isAtLatest)
        #expect(scroll.isFollowing)
        #expect(!scroll.showsJumpToLatest)
    }

    @Test
    func aBackwardsClampFromAnInvalidOldOffsetDoesNotMasqueradeAsHistoryNavigation() {
        var scroll = LiveTranscriptScrollState()
        scroll.geometryChanged(scroll.observation(geometry(offset: 5_580, contentHeight: 6_000, bottomInset: 80)))
        let staleOffset = geometry(offset: 5_580, contentHeight: 1_000, bottomInset: 80)
        let shrinkRequestedScroll = scroll.geometryChanged(scroll.observation(staleOffset))
        #expect(shrinkRequestedScroll)

        // The native clamp can report an intermediate position before arrival.
        let settling = geometry(offset: 570, contentHeight: 1_000, bottomInset: 80)
        let intermediateRequestedScroll = scroll.geometryChanged(scroll.observation(settling))
        #expect(!intermediateRequestedScroll)
        #expect(scroll.isFollowing)
        #expect(!scroll.position.isPositionedByUser)
        scroll.geometryChanged(scroll.observation(geometry(offset: 580, contentHeight: 1_000, bottomInset: 80)))
        #expect(scroll.isAtLatest)
    }

    @Test
    func shrinkingContentDoesNotOverrideAStillValidDetachedReadingPosition() {
        var scroll = LiveTranscriptScrollState()
        scroll.phaseChanged(to: .interacting, isAtLatest: false)
        scroll.phaseChanged(to: .idle, isAtLatest: false)
        scroll.geometryChanged(scroll.observation(geometry(offset: 200, contentHeight: 1_300, bottomInset: 80)))
        let shorter = geometry(offset: 200, contentHeight: 1_000, bottomInset: 80)
        let shrinkRequestedScroll = scroll.geometryChanged(scroll.observation(shorter))
        #expect(!shrinkRequestedScroll)
        #expect(!scroll.isFollowing)
        #expect(scroll.showsJumpToLatest)
    }

    @Test
    func programmaticForwardMovementAndJumpAnimationDoNotLookLikeReadingHistory() {
        var scroll = LiveTranscriptScrollState()
        scroll.geometryChanged(scroll.observation(geometry(offset: 580, contentHeight: 1_000, bottomInset: 80)))
        let growthRequestedScroll = scroll.geometryChanged(scroll.observation(geometry(offset: 580, contentHeight: 1_200, bottomInset: 80)))
        #expect(growthRequestedScroll)
        let forwardMovementRequestedScroll = scroll.geometryChanged(scroll.observation(geometry(offset: 700, contentHeight: 1_200, bottomInset: 80)))
        #expect(!forwardMovementRequestedScroll)
        #expect(scroll.isFollowing)
        scroll.geometryChanged(scroll.observation(geometry(offset: 780, contentHeight: 1_200, bottomInset: 80)))
        #expect(scroll.isAtLatest)

        scroll.jumpToLatest()
        scroll.phaseChanged(to: .animating, isAtLatest: false)
        let inFlight = scroll.observation(geometry(offset: 300, contentHeight: 1_200, bottomInset: 80))
        #expect(inFlight.contentOffsetY == nil)
        let animationGeometryRequestedScroll = scroll.geometryChanged(inFlight)
        #expect(!animationGeometryRequestedScroll)
        let revisionDuringAnimationRequestedScroll = scroll.transcriptChanged()
        #expect(!revisionDuringAnimationRequestedScroll)
        #expect(scroll.isFollowing)
        let idleRequestedScroll = scroll.phaseChanged(to: .idle, isAtLatest: false)
        #expect(idleRequestedScroll)
    }

    @Test
    func viewportOrShelfChangesCorrectTheLatestEdgeWithoutAnotherTranscriptRevision() {
        var scroll = LiveTranscriptScrollState()
        scroll.geometryChanged(scroll.observation(geometry(offset: 580, contentHeight: 1_000, bottomInset: 80)))
        let tallerShelf = geometry(offset: 580, contentHeight: 1_000, bottomInset: 120)
        let shelfRequestedScroll = scroll.geometryChanged(scroll.observation(tallerShelf))
        #expect(shelfRequestedScroll)
        let repeatedShelfRequestedScroll = scroll.geometryChanged(scroll.observation(tallerShelf))
        #expect(!repeatedShelfRequestedScroll)
        let smallerViewport = geometry(offset: 580, contentHeight: 1_000, bottomInset: 120, viewportHeight: 450)
        let viewportRequestedScroll = scroll.geometryChanged(scroll.observation(smallerViewport))
        #expect(viewportRequestedScroll)
        let repeatedViewportRequestedScroll = scroll.geometryChanged(scroll.observation(smallerViewport))
        #expect(!repeatedViewportRequestedScroll)
    }

    @Test
    func scrollingBackToLatestResumesOnlyAfterMomentumFinishes() {
        var scroll = LiveTranscriptScrollState()
        scroll.phaseChanged(to: .interacting, isAtLatest: false)
        scroll.phaseChanged(to: .decelerating, isAtLatest: true)
        scroll.geometryChanged(scroll.observation(isAtLatest: true))
        #expect(!scroll.isFollowing)

        scroll.phaseChanged(to: .idle, isAtLatest: true)
        #expect(scroll.isFollowing)
        #expect(!scroll.showsJumpToLatest)
    }

    @Test(arguments: [false, true])
    func idlePhaseRejectsOlderVisibilityCallbacksInBothDirections(_ staleIsAtLatest: Bool) {
        var scroll = LiveTranscriptScrollState()
        scroll.phaseChanged(to: .interacting, isAtLatest: staleIsAtLatest)
        let queued = scroll.observation(isAtLatest: staleIsAtLatest)
        scroll.phaseChanged(to: .idle, isAtLatest: !staleIsAtLatest)
        scroll.geometryChanged(queued)
        #expect(scroll.isAtLatest == !staleIsAtLatest)
        #expect(scroll.isFollowing == !staleIsAtLatest)
        #expect(scroll.showsJumpToLatest == staleIsAtLatest)
    }

    @Test
    func explicitJumpAndReopeningInvalidateQueuedGeometryBeforeReanchoring() {
        var scroll = LiveTranscriptScrollState()
        scroll.phaseChanged(to: .interacting, isAtLatest: false)
        scroll.phaseChanged(to: .idle, isAtLatest: false)
        let beforeJump = scroll.observation(isAtLatest: true)
        scroll.jumpToLatest()
        scroll.geometryChanged(beforeJump)
        #expect(scroll.isFollowing)
        // Jump requests the new position; only fresh geometry confirms arrival.
        #expect(!scroll.isAtLatest)

        let beforeReopening = scroll.observation(isAtLatest: false)
        scroll.appeared()
        scroll.geometryChanged(beforeReopening)
        #expect(scroll.isAtLatest)
        #expect(scroll.isFollowing)
    }

    @Test
    func userPositioningWithoutGesturePhasesCanReturnToLatest() {
        var scroll = LiveTranscriptScrollState()
        // The native binding also reports user positioning independently of a
        // trackpad gesture. The policy does not require a .tracking callback.
        scroll.position.isPositionedByUser = true
        scroll.geometryChanged(scroll.observation(isAtLatest: false))
        #expect(scroll.showsJumpToLatest)

        scroll.geometryChanged(scroll.observation(isAtLatest: true))
        #expect(scroll.isFollowing)
        #expect(!scroll.showsJumpToLatest)
    }

    @Test
    func jumpingResumesFollowingButAUserCanInterruptTheProgrammaticAnimation() {
        var scroll = LiveTranscriptScrollState()
        scroll.phaseChanged(to: .interacting, isAtLatest: false)
        scroll.phaseChanged(to: .idle, isAtLatest: false)
        scroll.jumpToLatest()
        scroll.phaseChanged(to: .animating, isAtLatest: false)
        #expect(scroll.isFollowing)
        #expect(!scroll.showsJumpToLatest)

        scroll.phaseChanged(to: .interacting, isAtLatest: false)
        scroll.phaseChanged(to: .idle, isAtLatest: false)
        #expect(!scroll.isFollowing)
        #expect(scroll.showsJumpToLatest)
    }

    @Test
    func theReservedControlShelfMustBeClearedBeforeCallingTheBottomVisible() {
        let obscured = geometry(offset: 500, contentHeight: 1_000, bottomInset: 80)
        let visible = geometry(offset: 580, contentHeight: 1_000, bottomInset: 80)
        let rounded = geometry(offset: 578.5, contentHeight: 1_000, bottomInset: 80)
        #expect(!LiveTranscriptScrollState.isAtLatest(obscured))
        #expect(LiveTranscriptScrollState.isAtLatest(visible))
        #expect(LiveTranscriptScrollState.isAtLatest(rounded))

        let short = geometry(offset: -20, contentHeight: 200, bottomInset: 80)
        #expect(LiveTranscriptScrollState.isAtLatest(short))

        let farBeyondLong = geometry(offset: 800, contentHeight: 1_000, bottomInset: 80)
        let farBeyondShort = geometry(offset: 800, contentHeight: 200, bottomInset: 80)
        let shortRounding = geometry(offset: -18.5, contentHeight: 200, bottomInset: 80)
        #expect(!LiveTranscriptScrollState.isAtLatest(farBeyondLong))
        #expect(!LiveTranscriptScrollState.isAtLatest(farBeyondShort))
        #expect(LiveTranscriptScrollState.isAtLatest(shortRounding))
    }

    @Test
    func observedNativeBottomIncludesTheShelfOnceUsingMeasuredVisibleHeight() {
        // Values captured from the native replay, not inferred from the public
        // ScrollGeometry initializer: visibleHeight is larger than containerSize.
        let native = LiveTranscriptScrollState.Extent(
            contentHeight: 3_835,
            viewportHeight: 455,
            viewportWidth: 900,
            visibleHeight: 535,
            topInset: 0,
            bottomInset: 80
        )
        #expect(native.latestOffsetY == 3_380)
        #expect(native.isAtLatest(offsetY: 3_380))
        #expect(!native.isAtLatest(offsetY: 3_350))
        #expect(!native.isAtLatest(offsetY: 3_460))
    }

    @Test
    func returningToTheObservedNativeBottomResumesFollowingWithTheJumpShelfVisible() {
        let native = LiveTranscriptScrollState.Extent(
            contentHeight: 4_940.5,
            viewportHeight: 413,
            viewportWidth: 900,
            visibleHeight: 535,
            topInset: 0,
            bottomInset: 122
        )
        var scroll = LiveTranscriptScrollState()
        scroll.phaseChanged(to: .interacting, isAtLatest: false)
        scroll.phaseChanged(to: .idle, isAtLatest: false)
        #expect(scroll.showsJumpToLatest)

        let nativeBottomRequestedFollow = scroll.geometryChanged(
            scroll.observation(extent: native, offsetY: 4_527.5)
        )
        #expect(nativeBottomRequestedFollow)
        #expect(scroll.isFollowing)
        #expect(scroll.isAtLatest)
        #expect(!scroll.showsJumpToLatest)
        let repeatedBottomRequestedFollow = scroll.geometryChanged(
            scroll.observation(extent: native, offsetY: 4_527.5)
        )
        #expect(!repeatedBottomRequestedFollow)
    }

    @Test
    func observedShortContentStaysTopAlignedAndRejectsTheOldLongOffset() {
        let native = LiveTranscriptScrollState.Extent(
            contentHeight: 338.5,
            viewportHeight: 455,
            viewportWidth: 900,
            visibleHeight: 535,
            topInset: 0,
            bottomInset: 80
        )
        #expect(native.latestOffsetY == 0)
        #expect(native.isAtLatest(offsetY: 0))
        #expect(!native.isAtLatest(offsetY: 3_380))
    }

    private func geometry(
        offset: CGFloat,
        contentHeight: CGFloat,
        bottomInset: CGFloat,
        viewportHeight: CGFloat = 500,
        viewportWidth: CGFloat = 700
    ) -> ScrollGeometry {
        ScrollGeometry(
            contentOffset: CGPoint(x: 0, y: offset),
            contentSize: CGSize(width: viewportWidth, height: contentHeight),
            contentInsets: EdgeInsets(top: 20, leading: 0, bottom: bottomInset, trailing: 0),
            containerSize: CGSize(width: viewportWidth, height: viewportHeight)
        )
    }
}
