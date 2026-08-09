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
