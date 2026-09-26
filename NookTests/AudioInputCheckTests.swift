import Combine
import Foundation
import ScreenCaptureKit
import Testing
@testable import Nook

struct AudioInputCheckTests {
    @Test
    func onlyTheTwoAudioOutputsHaveRoutes() {
        #expect(
            AudioInputCheckService.track(for: .microphone)
                == .microphone
        )
        #expect(AudioInputCheckService.track(for: .audio) == .meeting)
        #expect(AudioInputCheckService.track(for: .screen) == nil)
    }

    @Test
    func conflictPolicyNamesTheActiveCapture() {
        #expect(
            AudioInputCheckService.conflict(
                meetingIsActive: false,
                dictationIsActive: false
            ) == nil
        )
        #expect(
            AudioInputCheckService.conflict(
                meetingIsActive: true,
                dictationIsActive: false
            ) == .meeting
        )
        #expect(
            AudioInputCheckService.conflict(
                meetingIsActive: false,
                dictationIsActive: true
            ) == .dictation
        )
        #expect(
            AudioInputCheckService.conflict(
                meetingIsActive: true,
                dictationIsActive: true
            ) == .meeting
        )
    }

    @Test
    func staleLevelsFadeThenReachZero() {
        let now = 100.0
        #expect(
            AudioInputCheckService.staleAdjustedLevel(
                value: 0.6,
                receivedAt: now,
                now: now
            ) == 0.6
        )

        let fading = AudioInputCheckService.staleAdjustedLevel(
            value: 0.6,
            receivedAt: now - 0.7,
            now: now
        )
        #expect(fading > 0)
        #expect(fading < 0.6)

        #expect(
            AudioInputCheckService.staleAdjustedLevel(
                value: 0.6,
                receivedAt: now - 2,
                now: now
            ) == 0
        )
        #expect(
            AudioInputCheckService.staleAdjustedLevel(
                value: .infinity,
                receivedAt: now,
                now: now
            ) == 0
        )
    }

    @Test
    func policyHasNoArtifactOrModelPath() {
        let policy = AudioInputCheckService.policy
        #expect(!policy.usesRecordingOutput)
        #expect(!policy.writesFiles)
        #expect(!policy.usesSpeechRecognition)
        #expect(!policy.usesModel)
        #expect(!policy.usesRecovery)
        #expect(!policy.logsEvents)
        #expect(!policy.holdsSleepAssertion)
    }

    @Test
    func percentageIsBoundedForVoiceOver() {
        #expect(AudioInputCheckService.percentage(for: -1) == 0)
        #expect(AudioInputCheckService.percentage(for: 0.456) == 46)
        #expect(AudioInputCheckService.percentage(for: 2) == 100)
        #expect(AudioInputCheckService.percentage(for: .nan) == 0)
    }

    @Test @MainActor
    func successfulStartAndRepeatedStopOwnExactlyOneSession() async throws {
        let session = AudioCheckTestSession()
        var creations = 0
        let service = AudioInputCheckService { _ in
            creations += 1
            return session
        }
        await service.start()?.value
        #expect(service.phase == .running)
        #expect(service.isStopAvailable)
        #expect(service.start() == nil)
        #expect(creations == 1)
        await service.stop()
        await service.stop()
        #expect(service.phase == .idle)
        #expect(!service.isStopAvailable)
        #expect(session.startCalls == 1)
        #expect(session.stopCalls == 1)
        #expect(service.levels == .zero)
    }

    @Test(arguments: [AudioInputCheckConflict.meeting, .dictation]) @MainActor
    func conflictingCaptureNeverConstructsAnAudioTestSession(conflict: AudioInputCheckConflict) async {
        var creations = 0
        let service = AudioInputCheckService { _ in
            creations += 1
            return AudioCheckTestSession()
        }
        #expect(service.start(conflict: conflict) == nil)
        #expect(creations == 0)
        #expect(service.phase == .failed)
        #expect(!service.isStopAvailable)
        await service.stop()
    }

    @Test(arguments: [AudioInputCheckError.microphonePermissionDenied, .screenRecordingPermissionDenied]) @MainActor
    func deniedStartupExposesOnlyTheCorrespondingPermissionPane(error: AudioInputCheckError) async {
        let service = AudioInputCheckService { _ in throw error }
        await service.start()?.value
        let expected: NookPermission = error == .microphonePermissionDenied ? .microphone : .screenRecording
        #expect(service.phase == .failed)
        #expect(service.requiredPermission == expected)
        #expect(service.requiredPermission?.settingsURL == expected.settingsURL)
        #expect(service.requiredPermission != .speechRecognition)
        #expect(service.levels == .zero)
        #expect(!service.isStopAvailable)
    }

    @Test @MainActor
    func stoppingBeforeTheTaskStartsNeverRequestsPermissionsOrBuildsAStream() async {
        var creations = 0
        let service = AudioInputCheckService { _ in
            creations += 1
            return AudioCheckTestSession()
        }
        service.start()
        await service.stop()
        #expect(creations == 0)
        #expect(service.phase == .idle)
        #expect(!service.isStopAvailable)
    }

    @Test @MainActor
    func stoppingWhilePermissionsResolveDoesNotStartOrStopAnUnusedStream() async throws {
        let gate = AudioCheckTestGate()
        let session = AudioCheckTestSession()
        let service = AudioInputCheckService { _ in
            await gate.wait()
            return session
        }
        service.start()
        try await waitUntil { gate.isWaiting }
        let stopping = Task { await service.stop() }
        try await waitUntil { service.phase == .stopping }
        #expect(service.start() == nil)
        gate.release()
        await stopping.value
        #expect(service.phase == .idle)
        #expect(session.startCalls == 0)
        #expect(session.stopCalls == 0)
    }

    @Test(arguments: [false, true]) @MainActor
    func cancelledStartupRetainsAnUncertainStreamUntilCleanupSucceeds(failStop: Bool) async throws {
        let gate = AudioCheckTestGate()
        let session = AudioCheckTestSession()
        session.startGate = gate
        session.failsStop = failStop
        let service = AudioInputCheckService { _ in session }
        service.start()
        try await waitUntil { gate.isWaiting }
        let stopping = Task { await service.stop() }
        try await waitUntil { service.phase == .stopping }
        gate.release()
        await stopping.value
        #expect(session.startCalls == 1)
        #expect(session.stopCalls == 1)
        #expect(service.levels == .zero)
        if failStop {
            #expect(service.phase == .failed)
            #expect(service.isStopAvailable)
            #expect(service.start() == nil)
            do {
                try await service.prepareForOtherCapture()
                Issue.record("A competing capture must wait for confirmed cleanup.")
            } catch {
                #expect(error as? AudioInputCheckError == .stopFailed)
            }
            session.failsStop = false
            try await service.prepareForOtherCapture()
        }
        #expect(service.phase == .idle)
        #expect(!service.isStopAvailable)
        session.startGate = nil
        await service.start()?.value
        #expect(service.phase == .running)
        await service.stop()
    }

    @Test(arguments: [false, true]) @MainActor
    func aFailedStartCleansUpAndPreservesFailedCleanupForRetry(failStop: Bool) async {
        let session = AudioCheckTestSession()
        session.failsStart = true
        session.failsStop = failStop
        let service = AudioInputCheckService { _ in session }
        await service.start()?.value
        #expect(service.phase == .failed)
        #expect(session.stopCalls == 1)
        #expect(service.isStopAvailable == failStop)
        #expect(service.errorMessage == (failStop
            ? AudioInputCheckError.stopFailed.errorDescription
            : AudioInputCheckError.captureUnavailable.errorDescription))
        session.failsStop = false
        await service.stop()
        #expect(service.phase == .idle)
        #expect(!service.isStopAvailable)
    }

    @Test @MainActor
    func overlappingStopsShareTeardownAndBlockNewCaptureUntilItCompletes() async throws {
        let gate = AudioCheckTestGate()
        let session = AudioCheckTestSession()
        session.stopGate = gate
        let service = AudioInputCheckService { _ in session }
        await service.start()?.value
        let first = Task { await service.stop() }
        try await waitUntil { gate.isWaiting }
        let second = Task { await service.stop() }
        let capture = Task { try await service.prepareForOtherCapture() }
        #expect(service.phase == .stopping)
        #expect(service.start() == nil)
        #expect(session.stopCalls == 1)
        gate.release()
        await first.value
        await second.value
        try await capture.value
        #expect(session.stopCalls == 1)
        #expect(service.phase == .idle)
        #expect(!service.isStopAvailable)
    }

    @Test(arguments: [false, true]) @MainActor
    func aTerminalCallbackDuringStopDoesNotRestoreAnAlreadyStoppedStream(failStop: Bool) async throws {
        let gate = AudioCheckTestGate()
        let session = AudioCheckTestSession()
        session.stopGate = gate
        session.failsStop = failStop
        let service = AudioInputCheckService { _ in session }
        await service.start()?.value
        let stopping = Task { await service.stop() }
        try await waitUntil { gate.isWaiting }
        service.handleUnexpectedStop(streamID: ObjectIdentifier(session))
        #expect(service.phase == .stopping)
        #expect(service.start() == nil)
        var requestedCapture = false
        let competingCapture = Task {
            requestedCapture = true
            try await service.prepareForOtherCapture()
        }
        try await waitUntil { requestedCapture }
        #expect(service.phase == .stopping)
        gate.release()
        await stopping.value
        try await competingCapture.value
        #expect(service.phase == .idle)
        #expect(!service.isStopAvailable)
        #expect(session.stopCalls == 1)
        #expect(service.errorMessage == nil)
        // A receipt belongs to one stop, even if the same session object is
        // reused by this fixture. It cannot confirm a later failed teardown.
        session.stopGate = nil
        await service.start()?.value
        session.failsStop = true
        await service.stop()
        #expect(service.phase == .failed)
        #expect(service.isStopAvailable)
        session.failsStop = false
        await service.stop()
        #expect(service.phase == .idle)
    }

    @Test(arguments: [false, true]) @MainActor
    func aStopCallbackBeforeStartupReturnsCannotPublishARunningMeter(failStart: Bool) async throws {
        let gate = AudioCheckTestGate()
        let session = AudioCheckTestSession()
        session.startGate = gate
        session.failsStart = failStart
        let service = AudioInputCheckService { _ in session }
        let starting = try #require(service.start())
        try await waitUntil { gate.isWaiting }

        service.handleUnexpectedStop(streamID: ObjectIdentifier(session))
        #expect(service.phase == .failed)
        #expect(service.start() == nil)
        var completionNotifications = 0
        let observation = service.objectWillChange.sink { completionNotifications += 1 }
        defer { observation.cancel() }
        gate.release()
        await starting.value

        #expect(service.phase == .failed)
        #expect(completionNotifications > 0)
        #expect(service.levels == .zero)
        #expect(!service.isStopAvailable)
        #expect(session.stopCalls == 0)
        await service.stop()
    }

    @Test @MainActor
    func aStopCallbackDuringCancelledStartupConfirmsCleanupWithoutStoppingAgain() async throws {
        let gate = AudioCheckTestGate()
        let session = AudioCheckTestSession()
        session.startGate = gate
        session.failsStop = true
        let service = AudioInputCheckService { _ in session }
        service.start()
        try await waitUntil { gate.isWaiting }
        let stopping = Task { await service.stop() }
        try await waitUntil { service.phase == .stopping }
        service.handleUnexpectedStop(streamID: ObjectIdentifier(session))
        gate.release()
        await stopping.value

        #expect(service.phase == .idle)
        #expect(!service.isStopAvailable)
        #expect(session.stopCalls == 0)
        try await service.prepareForOtherCapture()
    }

    @Test @MainActor
    func aStopCallbackDuringFailedStartCleanupCannotRestoreAStoppedStream() async throws {
        let gate = AudioCheckTestGate()
        let session = AudioCheckTestSession()
        session.failsStart = true
        session.failsStop = true
        session.stopGate = gate
        let service = AudioInputCheckService { _ in session }
        let starting = try #require(service.start())
        try await waitUntil { gate.isWaiting }
        service.handleUnexpectedStop(streamID: ObjectIdentifier(session))
        gate.release()
        await starting.value

        #expect(service.phase == .failed)
        #expect(!service.isStopAvailable)
        #expect(service.errorMessage == AudioInputCheckError.captureUnavailable.errorDescription)
        session.failsStop = false
        session.stopGate = nil
        try await service.prepareForOtherCapture()
    }

    @Test @MainActor
    func anOldStopCallbackCannotEndANewerAudioCheck() async throws {
        let old = AudioCheckTestSession()
        let current = AudioCheckTestSession()
        var creations = 0
        let service = AudioInputCheckService { _ in
            creations += 1
            return creations == 1 ? old : current
        }
        await service.start()?.value
        service.handleUnexpectedStop(streamID: ObjectIdentifier(old))
        #expect(service.phase == .failed)
        await service.start()?.value
        #expect(service.phase == .running)
        service.handleUnexpectedStop(streamID: ObjectIdentifier(old))
        #expect(service.phase == .running)
        #expect(service.isStopAvailable)
        await service.stop()
    }

    @Test @MainActor
    func stoppingAfterAnEarlyFailureStillWaitsForTheStartupBarrier() async throws {
        let gate = AudioCheckTestGate()
        let session = AudioCheckTestSession()
        session.startGate = gate
        let service = AudioInputCheckService { _ in session }
        service.start()
        try await waitUntil { gate.isWaiting }
        service.handleUnexpectedStop(streamID: ObjectIdentifier(session))
        #expect(service.phase == .failed)
        #expect(service.isStopAvailable)
        let stopping = Task { await service.stop() }
        try await waitUntil { service.phase == .stopping }
        #expect(service.start() == nil)
        gate.release()
        await stopping.value
        #expect(service.phase == .idle)
        #expect(!service.isStopAvailable)
        #expect(session.stopCalls == 0)
    }

    @Test @MainActor
    func cancellingTheReturnedStartupTaskDoesNotLeaveAPermanentStartingState() async throws {
        let gate = AudioCheckTestGate()
        let session = AudioCheckTestSession()
        session.startGate = gate
        let service = AudioInputCheckService { _ in session }
        let starting = try #require(service.start())
        try await waitUntil { gate.isWaiting }
        starting.cancel()
        gate.release()
        await starting.value
        #expect(service.phase == .idle)
        #expect(!service.isStopAvailable)
        #expect(session.stopCalls == 1)
        session.startGate = nil
        await service.start()?.value
        #expect(service.phase == .running)
        await service.stop()
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }
}

@MainActor
private final class AudioCheckTestSession: AudioInputCheckSession {
    var startCalls = 0
    var stopCalls = 0
    var startGate: AudioCheckTestGate?
    var stopGate: AudioCheckTestGate?
    var failsStart = false
    var failsStop = false

    func startCapture() async throws {
        startCalls += 1
        if let startGate { await startGate.wait() }
        if failsStart { throw AudioInputCheckError.captureUnavailable }
    }

    func stopCapture() async throws {
        stopCalls += 1
        if let stopGate { await stopGate.wait() }
        if failsStop { throw AudioInputCheckError.stopFailed }
    }
}

@MainActor
private final class AudioCheckTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    func wait() async {
        await withCheckedContinuation {
            continuation = $0
            isWaiting = true
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
        isWaiting = false
    }
}
