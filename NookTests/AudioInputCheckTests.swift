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
}
