import Foundation
import Testing
@testable import OpenClaw

@MainActor
struct PostUpdateBundledRuntimeTests {
    @Test func `same version runtime rebuild is updated once and preserves failed retries`() throws {
        let suite = "PostUpdateBundledRuntimeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_720_000_000)

        #expect(PostAppUpdateReceiptStore.pendingForLaunch(
            currentVersion: "2026.9.1",
            currentRuntimeBuildID: "build-a",
            onboardingSeen: false,
            defaults: defaults,
            now: now) == nil)
        #expect(PostAppUpdateReceiptStore.pendingForLaunch(
            currentVersion: "2026.9.1",
            currentRuntimeBuildID: "build-a",
            onboardingSeen: true,
            defaults: defaults,
            now: now) == nil)

        let update = try #require(PostAppUpdateReceiptStore.pendingForLaunch(
            currentVersion: "2026.9.1",
            currentRuntimeBuildID: "build-b",
            onboardingSeen: true,
            defaults: defaults,
            now: now))
        #expect(update.fromVersion == "2026.9.1")
        #expect(update.toVersion == "2026.9.1")
        #expect(update.runtimeBuildID == "build-b")

        let incomplete = PostAppUpdateReceiptStore.setGatewayUpdateIncomplete(
            true, receipt: update, defaults: defaults)
        #expect(PostAppUpdateReceiptStore.pendingForLaunch(
            currentVersion: "2026.9.1",
            currentRuntimeBuildID: "build-b",
            onboardingSeen: true,
            defaults: defaults,
            now: now) == incomplete)

        let replacement = try #require(PostAppUpdateReceiptStore.pendingForLaunch(
            currentVersion: "2026.9.1",
            currentRuntimeBuildID: "build-c",
            onboardingSeen: true,
            defaults: defaults,
            now: now))
        #expect(replacement.runtimeBuildID == "build-c")
        #expect(!replacement.gatewayUpdateIncomplete)
        let notified = PostAppUpdateReceiptStore.setNotificationInFlight(
            true, receipt: replacement, defaults: defaults)
        let retry = PostAppUpdateReceiptStore.recordNotificationFailure(receipt: notified, defaults: defaults)
        #expect(retry.runtimeBuildID == "build-c")
        PostAppUpdateReceiptStore.clear(defaults: defaults)
        #expect(PostAppUpdateReceiptStore.pendingForLaunch(
            currentVersion: "2026.9.1",
            currentRuntimeBuildID: "build-c",
            onboardingSeen: true,
            defaults: defaults,
            now: now) == nil)
    }

    @Test func `bundled Gateway updates never select package registry work`() {
        let statuses: [CLIInstaller.Status?] = [
            nil,
            .ready(location: "/fixture/openclaw", version: "2026.9.1"),
            .missing(location: "/fixture/openclaw"),
            .unusable(location: "/fixture/openclaw"),
            .incompatible(location: "/fixture/openclaw", found: "2026.8.1", required: "2026.9.1"),
        ]
        for status in statuses {
            for incomplete in [false, true] {
                #expect(PostUpdateController.gatewayAction(
                    status: status,
                    ownsManagedRuntime: true,
                    gatewayUpdateIncomplete: incomplete,
                    usesBundledRuntime: true) == .prepareBundledRuntime)
                #expect(PostUpdateController.gatewayAction(
                    status: status,
                    ownsManagedRuntime: false,
                    gatewayUpdateIncomplete: incomplete,
                    usesBundledRuntime: true) == (incomplete ? .ownershipFailure : .none))
            }
        }
    }

    @Test func `completed migration preserves notification receipts and synthetic launches remain silent`() {
        let receipt = PostAppUpdateReceipt(
            fromVersion: "2026.8.1",
            toVersion: "2026.9.1",
            recordedAt: .distantPast,
            notificationAttempts: 1)
        for verified in [false, true] {
            #expect(PostUpdateController.notificationContinuation(
                receipt: receipt,
                runtimeVerified: verified,
                migrationOnlyLaunchCheck: false) == .notify)
        }
        for inFlight in [false, true] {
            let pendingRuntime = PostAppUpdateReceipt(
                fromVersion: "2026.8.1",
                toVersion: "2026.9.1",
                recordedAt: .distantPast,
                gatewayUpdateIncomplete: true,
                notificationInFlight: inFlight)
            #expect(PostUpdateController.notificationContinuation(
                receipt: pendingRuntime,
                runtimeVerified: false,
                migrationOnlyLaunchCheck: false) == .waitForRuntime)
            #expect(PostUpdateController.notificationContinuation(
                receipt: pendingRuntime,
                runtimeVerified: true,
                migrationOnlyLaunchCheck: false) == (inFlight ? .deliveryUnconfirmed : .notify))
            #expect(PostUpdateController.notificationContinuation(
                receipt: pendingRuntime,
                runtimeVerified: true,
                migrationOnlyLaunchCheck: true) == .completeSilently)
        }
    }
}
