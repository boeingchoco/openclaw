import CryptoKit
import Foundation
import OpenClawNativeState

/// The core updater owns version changes; this owner switches only a same-version service runtime.
@MainActor
enum ManagedNodeGatewayMigration {
    static let resumeCommandKey = "gatewayNodeResumeCommand"

    private struct ResumeCommand: Codable {
        let prefix: [String]
        let sqliteLibrary: String?
    }

    static func resumeData(for cli: GatewayLaunchAgentManager.InstalledServiceCLI) throws -> Data {
        // Service credentials stay with core. Only executable/package references survive pause.
        try JSONEncoder().encode(ResumeCommand(prefix: cli.prefix, sqliteLibrary: cli.sqliteLibrary))
    }

    static func resumeCLI(from data: Data, stateDirectory: URL) throws -> GatewayLaunchAgentManager
    .InstalledServiceCLI {
        let command = try JSONDecoder().decode(ResumeCommand.self, from: data)
        guard let node = command.prefix.first, let entry = command.prefix.last,
              self.isManagedNode(node, stateDirectory: stateDirectory),
              self.isWithinState(entry, stateDirectory: stateDirectory)
        else { throw Failure(message: "The retained Node Gateway command is invalid; repair its managed installation.")
        }
        let snapshot = LaunchAgentPlistSnapshot(
            programArguments: command.prefix + ["gateway"],
            environment: command.sqliteLibrary.map { ["OPENCLAW_SQLITE_LIBRARY": $0] } ?? [:],
            stdoutPath: nil,
            stderrPath: nil,
            port: nil,
            bind: nil,
            token: nil,
            password: nil)
        guard let cli = GatewayLaunchAgentManager.installedServiceCLI(
            snapshot: snapshot,
            environmentFile: stateDirectory.appendingPathComponent("service-env/unused.env"),
            environmentWrapper: stateDirectory.appendingPathComponent("service-env/unused-wrapper.sh"))
        else {
            throw Failure(message: "The retained Node Gateway entrypoint is invalid; repair its managed installation.")
        }
        return cli
    }

    struct Candidate: Sendable {
        let cli: GatewayLaunchAgentManager.InstalledServiceCLI
        let snapshot: LaunchAgentPlistSnapshot
        let version: String
        let port: Int
        let allowUnconfigured: Bool
    }

    enum Outcome {
        case versionUpdated
        case migrated(BundledRuntime)
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? {
            self.message
        }
    }

    struct Operations {
        var checkCurrent: () throws -> Void
        var updateVersion: (Candidate, String) async throws -> Void
        var recapture: () async throws -> Candidate
        var seed: () async throws -> BundledRuntime
        var setServiceHosting: () -> Void
        var install: (Candidate, BundledRuntime) async throws -> Void
        var restore: (Candidate) async throws -> Void
        var verifyHealth: () async throws -> Void
    }

    /// launchd can reserve a draining job's label for ExitTimeOut + ten seconds before bootstrap.
    private static let serviceInstallTimeout = GatewayChildSupervisor.shutdownTimeoutSeconds + 10 +
        GatewayLaunchAgentManager.startupMigrationTolerance

    static func shutdownTimeout(candidate: Candidate, targetVersion: String?) -> TimeInterval {
        if candidate.version != targetVersion { return CLIInstaller.managedUpdateTimeout + 45 }
        return 2 * self.serviceInstallTimeout + 2 * GatewayLaunchAgentManager.startupMigrationTolerance + 45
    }

    static func run(candidate: Candidate, targetVersion: String, operations: Operations) async throws -> Outcome {
        try operations.checkCurrent()
        if candidate.version != targetVersion {
            try await Task { @MainActor in
                try await operations.updateVersion(candidate, targetVersion)
            }.value
            try operations.checkCurrent()
            let updated = try await operations.recapture()
            guard updated.version == targetVersion else {
                throw Failure(
                    message: "The managed Node Gateway did not reach the app's version; its runtime was not changed.")
            }
            // A fresh capture on Retry or next launch separates core's version migration from runtime rollback.
            return .versionUpdated
        }

        let current = try await operations.recapture()
        guard current.version == targetVersion, current.snapshot == candidate.snapshot else {
            throw Failure(message: "The managed Node Gateway changed during migration; retry.")
        }
        let runtime = try await operations.seed()
        try operations.checkCurrent()
        let beforeInstall = try await operations.recapture()
        guard beforeInstall.version == targetVersion, beforeInstall.snapshot == current.snapshot else {
            throw Failure(message: "The managed Node Gateway changed during runtime preparation; retry.")
        }
        try operations.checkCurrent()
        operations.setServiceHosting()
        do {
            try await Task { @MainActor in
                try await operations.install(current, runtime)
            }.value
            try operations.checkCurrent()
            try await operations.verifyHealth()
            try operations.checkCurrent()
            return .migrated(runtime)
        } catch {
            let migrationError = error.localizedDescription
            // Pause/quit may cancel the original operation. Its drain still owns recovery until
            // the previous same-version Node service is restored and verified.
            let restoration = Task { @MainActor in
                try await operations.restore(current)
                try await operations.verifyHealth()
            }
            do {
                try await restoration.value
            } catch {
                throw Failure(
                    message: "Bun migration failed: \(migrationError) " +
                        "Node restoration also failed: \(error.localizedDescription)")
            }
            throw Failure(
                message: "Bun migration failed: \(migrationError) " +
                    "The same-version Node Gateway was restored. Retry to switch to Bun.")
        }
    }

    static func candidate(
        profile: AppProfile = .current,
        onboardingSeen: Bool,
        installPolicy: String?,
        gatewayUpdateChannel: String? = nil) async throws -> Candidate?
    {
        guard !profile.isActive, onboardingSeen, installPolicy == "exact",
              gatewayUpdateChannel != "extended-stable", gatewayUpdateChannel != "beta",
              gatewayUpdateChannel != "dev", !GatewayLaunchAgentManager.isLaunchAgentWriteDisabled()
        else { return nil }
        return try await self.capture(profile: profile)
    }

    private static func capture(profile: AppProfile) async throws -> Candidate? {
        guard let snapshot = GatewayLaunchAgentManager.launchdConfigSnapshot() else { return nil }
        let state = profile.stateDirectoryURL()
        let artifacts = GatewayLaunchAgentManager.generatedEnvironmentArtifacts(
            directory: state.appendingPathComponent("service-env"), profile: profile)
        guard CLIInstallPrompter.launchAgentUsesManagedCLI(programArguments: snapshot.programArguments),
              let cli = GatewayLaunchAgentManager.installedServiceCLI(
                  snapshot: snapshot, environmentFile: artifacts.environment, environmentWrapper: artifacts.wrapper),
              let executable = cli.prefix.first,
              self.isManagedNode(executable, stateDirectory: state)
        else { return nil }
        guard let entrypoint = cli.prefix.last,
              self.isWithinState(entrypoint, stateDirectory: state),
              snapshot.environment["OPENCLAW_STATE_DIR"].map({
                  URL(fileURLWithPath: $0).standardizedFileURL == state.standardizedFileURL
              }) ?? true,
              snapshot.environment["OPENCLAW_CONFIG_PATH"].map({
                  URL(fileURLWithPath: $0).standardizedFileURL == state.appendingPathComponent("openclaw.json")
                      .standardizedFileURL
              }) ?? true
        else { return nil }
        if snapshot.programArguments.first == "/bin/sh" || snapshot.programArguments.first == artifacts.wrapper.path {
            guard FileManager.default.isReadableFile(atPath: artifacts.environment.path),
                  FileManager.default.isReadableFile(atPath: artifacts.wrapper.path)
            else {
                throw Failure(
                    message: "The managed Node service environment could not be read; repair it before migration.")
            }
        }
        guard let port = snapshot.port ?? snapshot.environment["OPENCLAW_GATEWAY_PORT"].flatMap(Int.init),
              (1...65535).contains(port)
        else { throw Failure(message: "The managed Node service port could not be inspected.") }
        guard try await !self.hasRuntimePin(stateDirectory: state, profile: profile) else { return nil }
        let version = try await self.installedVersion(cli: cli, profile: profile)
        guard GatewayLaunchAgentManager.launchdConfigSnapshot() == snapshot,
              try await !self.hasRuntimePin(stateDirectory: state, profile: profile)
        else {
            throw Failure(message: "The managed Node service changed during inspection; retry.")
        }
        return Candidate(
            cli: cli,
            snapshot: snapshot,
            version: version,
            port: port,
            allowUnconfigured: snapshot.programArguments.contains("--allow-unconfigured"))
    }

    private static func isWithinState(_ path: String, stateDirectory: URL) -> Bool {
        let url = URL(fileURLWithPath: path)
        return url.standardizedFileURL.path.hasPrefix(stateDirectory.standardizedFileURL.path + "/") &&
            url.resolvingSymlinksInPath().path.hasPrefix(stateDirectory.resolvingSymlinksInPath().path + "/")
    }

    static func isManagedNode(_ executable: String, stateDirectory: URL) -> Bool {
        let url = URL(fileURLWithPath: executable)
        guard executable.hasPrefix("/"), url.lastPathComponent == "node" else { return false }
        func owned(_ node: URL, root: URL) -> Bool {
            let tools = root.appendingPathComponent("tools").standardizedFileURL.path + "/"
            let path = node.standardizedFileURL.path
            guard path.hasPrefix(tools) else { return false }
            let parts = path.dropFirst(tools.count).split(separator: "/")
            return parts.count == 3 && (parts[0] == "node" || parts[0].hasPrefix("node-")) &&
                parts[1] == "bin" && parts[2] == "node"
        }
        return owned(url, root: stateDirectory) && owned(
            url.resolvingSymlinksInPath(), root: stateDirectory.resolvingSymlinksInPath())
    }

    nonisolated static func runtimePinKey(profile: AppProfile, configPath: String) throws -> String {
        // Keep the external store key aligned with daemon/runtime-pin-state.ts's resolveScope.
        let scope = ["gateway", "darwin", profile.gatewayLaunchAgentLabel, configPath]
        let bytes = try JSONSerialization.data(withJSONObject: scope, options: [.withoutEscapingSlashes])
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return "daemon-runtime-pin:" + hash
    }

    nonisolated static func hasRuntimePin(stateDirectory: URL, profile: AppProfile) async throws -> Bool {
        try await self.runtimePinRecord(stateDirectory: stateDirectory, profile: profile) != nil
    }

    nonisolated static func runtimePinRecord(
        stateDirectory: URL,
        profile: AppProfile) async throws -> OpenClawNativeStateConfigValue?
    {
        try await Task.detached {
            let databaseURL = stateDirectory.appendingPathComponent("state/openclaw.sqlite")
            do {
                _ = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
                (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError)
            {
                return nil
            }
            let key = try self.runtimePinKey(
                profile: profile, configPath: stateDirectory.appendingPathComponent("openclaw.json").path)
            let database = try OpenClawNativeStateSQLite(
                databaseURL: databaseURL, createIfMissing: false, readOnly: true)
            // Any stored intent is operator-owned for this legacy migration, even if its path
            // happens to point into tools/node. Malformed/stale intent is preserved as well.
            return try database.configMachineStateValue(key: key)
        }.value
    }

    private static func installedVersion(
        cli: GatewayLaunchAgentManager.InstalledServiceCLI,
        profile: AppProfile) async throws -> String
    {
        let environment = GatewayLaunchAgentManager.daemonEnvironment(
            runtime: nil,
            installedCLI: cli,
            environment: ProcessInfo.processInfo.environment,
            profile: profile,
            searchPaths: CommandResolver.preferredPaths())
        let response = await ShellExecutor.runDetailed(
            command: cli.prefix + ["--version"], cwd: nil, env: environment, timeout: 15)
        guard response.success,
              let version = GatewayEnvironment.normalizeGatewayVersionOutput(response.stdout),
              Semver.parse(version) != nil
        else { throw Failure(message: "The installed Node Gateway version could not be verified.") }
        return version
    }

    static func liveOperations(
        checkCurrent: @escaping () throws -> Void,
        verifyHealth: @escaping () async throws -> Void,
        setServiceHosting: @escaping () -> Void,
        statusHandler: @escaping @MainActor @Sendable (String) async -> Void) -> Operations
    {
        let custody = RestorationCustody()
        return Operations(
            checkCurrent: checkCurrent,
            updateVersion: { candidate, version in
                let outcome = await CLIInstaller.updateManaged(
                    targetVersion: version, installedCLI: candidate.cli, statusHandler: statusHandler)
                if case let .failure(message, details) = outcome {
                    throw Failure(message: [message, details].compactMap(\.self).joined(separator: " "))
                }
            },
            recapture: {
                guard let candidate = try await self.capture(profile: .current) else {
                    throw Failure(message: "The Gateway is no longer an eligible app-managed Node service.")
                }
                return candidate
            },
            seed: { try await BundledRuntime.seed() },
            setServiceHosting: setServiceHosting,
            install: { candidate, runtime in
                let original = try await self.captureServiceCustody()
                guard original.runtimePin == nil,
                      GatewayLaunchAgentManager.launchdConfigSnapshot() == candidate.snapshot
                else { throw Failure(message: "The Node Gateway changed before installation; it was preserved.") }
                custody.original = original
                let installError = await GatewayLaunchAgentManager.runDaemonCommand(
                    GatewayLaunchAgentManager.installArguments(
                        port: candidate.port,
                        allowUnconfigured: candidate.allowUnconfigured,
                        runtime: runtime,
                        launchAgentExists: true,
                        replaceRuntime: true),
                    timeout: self.serviceInstallTimeout,
                    runtime: runtime)
                try await custody.finishInstall(error: installError) {
                    try await self.installedServiceCustody(
                        runtime: runtime, candidate: candidate, allowMissingRuntimePin: installError != nil)
                }
            },
            restore: { candidate in
                let current = try await self.captureServiceCustody()
                if try custody.action(current: current) == .verifyOriginalNode { return }
                guard try await self.installedVersion(cli: candidate.cli, profile: .current) == candidate.version else {
                    throw Failure(message: "The retained Node Gateway version changed during migration. " +
                        "The current service was preserved; inspect it before retrying.")
                }
                let verified = try await self.captureServiceCustody()
                if try custody.action(current: verified) == .verifyOriginalNode { return }
                // --runtime node clears the newly selected Bun pin. PATH starts with the captured
                // Node directory; the retained package and environment are from the same version.
                var arguments = ["install", "--force", "--port", String(candidate.port), "--runtime", "node"]
                if candidate.allowUnconfigured { arguments.append("--allow-unconfigured") }
                if let error = await GatewayLaunchAgentManager
                    .runDaemonCommand(arguments, timeout: self.serviceInstallTimeout, installedCLI: candidate.cli)
                {
                    throw Failure(message: error)
                }
            },
            verifyHealth: verifyHealth)
    }
}
