import Foundation
import Testing
@testable import Nook

struct ReleaseSecurityTests {
    @Test
    func officialUpdaterRequiresBothBuildMarkerAndBundleIdentity() {
        #expect(
            NookBuildIdentity.permitsOfficialUpdates(
                bundleIdentifier: "com.localfirst.nook",
                officialBuildValue: "YES"
            )
        )
        #expect(
            NookBuildIdentity.permitsOfficialUpdates(
                bundleIdentifier: "com.localfirst.nook",
                officialBuildValue: true
            )
        )
        #expect(
            !NookBuildIdentity.permitsOfficialUpdates(
                bundleIdentifier: "com.localfirst.nook.dev",
                officialBuildValue: "YES"
            )
        )
        #expect(
            !NookBuildIdentity.permitsOfficialUpdates(
                bundleIdentifier: "com.localfirst.nook",
                officialBuildValue: "NO"
            )
        )
    }

    /// About used to print "Developer ID signed · Common Tools Co." as a
    /// constant, in green, on every build including local ones. The badge is
    /// now read from the bundle's own signature.
    @Test
    func anUnsignedBuildDoesNotClaimToBeDeveloperIDSigned() {
        #expect(NookCodeSignature.builtFromSource.label == "Built from source")
        #expect(
            !NookCodeSignature.builtFromSource.label.contains("Developer ID")
        )
        #expect(
            NookCodeSignature.developerID(team: "Common Tools Co.").label
                == "Developer ID signed · Common Tools Co."
        )
        #expect(
            NookCodeSignature.developerID(team: "").label
                == "Developer ID signed"
        )
    }

    @Test
    func theSigningTeamIsReadOutOfTheCertificateName() {
        #expect(
            NookCodeSignature.team(
                fromCommonName: "Developer ID Application: Common Tools Co. (A1B2C3D4E5)"
            ) == "Common Tools Co."
        )
        #expect(
            NookCodeSignature.team(fromCommonName: "Apple Development: Someone")
                == "Someone"
        )
        #expect(NookCodeSignature.team(fromCommonName: "") == "")
    }

    /// Tests run against an ad-hoc signed build, which is exactly the case the
    /// old hardcoded badge got wrong.
    @Test
    func theRunningTestBundleReportsItsRealSignature() {
        #expect(NookCodeSignature.current == .builtFromSource)
    }

    @Test
    func contributorConfigurationIsUpdaterSafeByDefault() throws {
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("project.yml")
        let project = try String(contentsOf: projectURL, encoding: .utf8)

        #expect(project.contains("exactVersion: \"2.9.5\""))
        #expect(project.contains("PRODUCT_BUNDLE_IDENTIFIER: com.localfirst.nook.dev"))
        #expect(project.contains("NOOK_OFFICIAL_BUILD: NO"))
        #expect(project.contains("NookOfficialBuild: \"$(NOOK_OFFICIAL_BUILD)\""))
    }

    @Test
    func applicationBundleContainsCompleteSparkleNotices() throws {
        let noticesURL = try #require(
            Bundle.main.url(
                forResource: "THIRD_PARTY_NOTICES",
                withExtension: "md"
            )
        )
        let licenseURL = try #require(
            Bundle.main.url(
                forResource: "Sparkle-LICENSE",
                withExtension: "txt"
            )
        )
        let notices = try String(contentsOf: noticesURL, encoding: .utf8)
        let license = try String(contentsOf: licenseURL, encoding: .utf8)

        #expect(notices.contains("Sparkle 2.9.5"))
        #expect(license.contains("Copyright (c) 2006-2013 Andy Matuschak."))
        #expect(license.contains("EXTERNAL LICENSES"))
        #expect(license.contains("bspatch.c and bsdiff.c"))
        #expect(license.contains("Portable C implementation of Ed25519"))
    }

    @Test
    func applicationBundleContainsProjectLicenseAndTrademarkPolicy() throws {
        let licenseURL = try #require(
            Bundle.main.url(forResource: "LICENSE", withExtension: nil)
        )
        let noticeURL = try #require(
            Bundle.main.url(forResource: "NOTICE", withExtension: nil)
        )
        let trademarksURL = try #require(
            Bundle.main.url(forResource: "TRADEMARKS", withExtension: "md")
        )

        let license = try String(contentsOf: licenseURL, encoding: .utf8)
        let notice = try String(contentsOf: noticeURL, encoding: .utf8)
        let trademarks = try String(contentsOf: trademarksURL, encoding: .utf8)

        #expect(license.contains("Apache License"))
        #expect(license.contains("Version 2.0, January 2004"))
        #expect(notice.contains("Copyright 2026 Common Tools Co."))
        #expect(trademarks.contains("Nook/Resources/Brand/"))
        #expect(trademarks.contains("bundle identifier, update feed, signing identity"))
    }
}
