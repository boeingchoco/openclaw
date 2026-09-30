import Foundation

extension GatewayProcessManager {
    func loadRetainedNodeServiceForResume() throws {
        guard self.retainedNodeServiceCLI == nil,
              let stored = AppDefaults.standard.object(forKey: ManagedNodeGatewayMigration.resumeCommandKey)
        else { return }
        guard let data = stored as? Data else {
            throw GatewayHostingError(message: "The retained Node Gateway command could not be read.")
        }
        self.retainedNodeServiceCLI = try ManagedNodeGatewayMigration.resumeCLI(
            from: data, stateDirectory: AppProfile.current.stateDirectoryURL())
    }

    func clearCompletedNodeResumeCommand(pid: Int32?, generation: UInt64) async {
        guard self.isCurrentGatewayStart(generation),
              self.retainedNodeServiceCLI != nil, self.installation == .managed,
              let pid,
              pid != self.childSupervisor.processIdentifier,
              let snapshot = GatewayLaunchAgentManager.launchdConfigSnapshot()
        else { return }
        let state = AppProfile.current.stateDirectoryURL()
        let artifacts = GatewayLaunchAgentManager.generatedEnvironmentArtifacts(
            directory: state.appendingPathComponent("service-env"), profile: .current)
        guard let cli = GatewayLaunchAgentManager.installedServiceCLI(
            snapshot: snapshot, environmentFile: artifacts.environment, environmentWrapper: artifacts.wrapper),
            GatewayLaunchAgentManager.bundledRuntimeReplacementError(
                appManaged: true, installedRuntimePath: cli.prefix.first, stateDirectory: state) == nil
        else { return }
        guard await GatewayLaunchAgentManager.runningGatewayPID() == pid,
              self.isCurrentGatewayStart(generation),
              GatewayLaunchAgentManager.launchdConfigSnapshot() == snapshot
        else { return }
        self.retainedNodeServiceCLI = nil
    }

    func retainManagedNodeServiceForResume() {
        guard self.installation == .managed,
              let snapshot = GatewayLaunchAgentManager.launchdConfigSnapshot()
        else { return }
        let state = AppProfile.current.stateDirectoryURL()
        let artifacts = GatewayLaunchAgentManager.generatedEnvironmentArtifacts(
            directory: state.appendingPathComponent("service-env"), profile: .current)
        guard let cli = GatewayLaunchAgentManager.installedServiceCLI(
            snapshot: snapshot, environmentFile: artifacts.environment, environmentWrapper: artifacts.wrapper),
            let executable = cli.prefix.first,
            ManagedNodeGatewayMigration.isManagedNode(executable, stateDirectory: state)
        else { return }
        self.retainedNodeServiceCLI = cli
    }

    func attemptManagedNodeMigration(generation: UInt64) async {
        guard BundledRuntime.isBundledApp, !self.nodeMigrationAttempted,
              self.isCurrentGatewayStart(generation)
        else { return }
        self.nodeMigrationAttempted = true
        do {
            guard let candidate = try await ManagedNodeGatewayMigration.candidate(
                onboardingSeen: AppStateStore.shared.onboardingSeen,
                installPolicy: CLIInstallPolicy.storedPolicy(),
                gatewayUpdateChannel: OpenClawConfigFile.gatewayUpdateChannel())
            else { return }
            guard self.isCurrentGatewayStart(generation) else { return }
            self.retainedNodeServiceCLI = candidate.cli
            let result = await self.enableLaunchAgentIfNeeded(
                port: candidate.port, generation: generation, nodeMigration: candidate)
            if self.isCurrentGatewayStart(generation), let error = result.error {
                self.nodeMigrationFailure = error
            }
        } catch {
            if self.isCurrentGatewayStart(generation) {
                self.nodeMigrationFailure = error.localizedDescription
            }
        }
    }

    func performManagedNodeMigration(
        _ candidate: ManagedNodeGatewayMigration.Candidate,
        generation: UInt64) async -> LaunchAgentEnableResult
    {
        do {
            guard let targetVersion = GatewayEnvironment.appVersionString() else {
                throw GatewayHostingError(message: "The bundled Gateway version could not be read.")
            }
            let operations = ManagedNodeGatewayMigration.liveOperations(
                checkCurrent: {
                    guard self.isCurrentGatewayStart(generation) else { throw CancellationError() }
                },
                verifyHealth: {
                    await (self.connection).shutdown()
                    let pid = await GatewayLaunchAgentManager.reusableLoadedGatewayPID(
                        port: candidate.port, allowUnconfigured: candidate.allowUnconfigured)
                    let context = self.gatewayReadinessContext(
                        purpose: .launchd,
                        port: candidate.port,
                        generation: generation,
                        readinessPID: pid,
                        launchAgentInstalled: true,
                        migrationDrain: true)
                    let terminal = await self.observeGatewayReadiness(
                        context: context,
                        deadlinePolicy: .fixed(timeout: GatewayLaunchAgentManager.startupMigrationTolerance),
                        clock: self.readinessClock)
                    guard case let .ready(instance, _, _) = terminal,
                          let pid, instance?.pid == pid
                    else { throw GatewayHostingError(message: "The migrated Gateway did not become healthy.") }
                },
                setServiceHosting: { self.storeHosting(.service) },
                statusHandler: { self.appendLog("[gateway] \($0)\n") })
            switch try await ManagedNodeGatewayMigration.run(
                candidate: candidate, targetVersion: targetVersion, operations: operations)
            {
            case .versionUpdated:
                self.nodeMigrationVersionUpdated = true
            case .migrated:
                self.nodeMigrationVersionUpdated = false
                self.nodeMigrationCompleted = true
                self.retainedNodeServiceCLI = nil
                do { try await BundledRuntime.garbageCollectAfterHealthy() } catch {
                    self.appendLog("[gateway] old runtime cleanup deferred: \(error.localizedDescription)\n")
                }
            }
            return .installedService
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func retryManagedNodeMigration() async throws {
        await self.waitForStartupAttempt()
        guard !self.isTerminating, self.desiredActive else { throw CancellationError() }
        self.nodeMigrationAttempted = false
        self.nodeMigrationFailure = nil
        self.nodeMigrationVersionUpdated = false
        self.nodeMigrationCompleted = false
        self.status = .stopped
        self.startIfNeeded()
        await self.waitForStartupAttempt()
        if let failure = self.nodeMigrationFailure { throw GatewayHostingError(message: failure) }
    }

    func setKeepGatewayRunning(_ enabled: Bool) async throws {
        guard !self.isTerminating else { throw CancellationError() }
        let previous = self.hostingChangeTask
        let id = UUID()
        let task = Task { @MainActor in
            _ = try? await previous?.value
            try await self.performHostingChange(to: enabled ? .service : .app)
        }
        self.hostingChangeTask = task
        self.hostingChangeID = id
        defer {
            if self.hostingChangeID == id {
                self.hostingChangeTask = nil
                self.hostingChangeID = nil
                self.startIfNeeded()
            }
        }
        try await task.value
    }

    private func storeHosting(_ hosting: GatewayHosting) {
        AppDefaults.standard.set(hosting.rawValue, forKey: GatewayHosting.defaultsKey)
        self.hostingRevision &+= 1
    }

    private func performHostingChange(to hosting: GatewayHosting) async throws {
        _ = try? await self.bundledUpdateTask?.value
        await self.waitForStartupAttempt()
        guard !self.isTerminating else { throw CancellationError() }
        guard self.keepGatewayRunningAvailable else {
            throw GatewayHostingError(message: "This Gateway is not hosted by OpenClaw.app.")
        }
        guard self.gatewayHosting != hosting else { return }
        self.hostingChangeInProgress = true
        defer { self.hostingChangeInProgress = false }
        let generation = self.gatewayStartGeneration
        let service = GatewayLaunchAgentManager.launchdConfigSnapshot()
        // Complete preparation while the existing Gateway is still available.
        _ = try await BundledRuntime.seed()
        guard !self.isTerminating, generation == self.gatewayStartGeneration else { throw CancellationError() }
        guard self.keepGatewayRunningAvailable, GatewayLaunchAgentManager.launchdConfigSnapshot() == service else {
            throw GatewayHostingError(message: "Gateway ownership changed during setup; retry.")
        }
        self.stop(preservingActivationIntent: true)
        let stopGeneration = self.gatewayStartGeneration
        await self.waitForPendingLaunchAgentDisable()
        guard !self.isTerminating, self.gatewayStartGeneration == stopGeneration else { throw CancellationError() }
        if let failure = self.lastFailureReason { throw GatewayHostingError(message: failure) }
        self.storeHosting(hosting)
        guard self.desiredActive, !AppStateStore.shared.isPaused else { return }
        self.hostingChangeInProgress = false
        self.startIfNeeded()
        guard await self.waitForGatewayReady(timeout: GatewayLaunchAgentManager.startupMigrationTolerance) else {
            throw GatewayHostingError(message: self.lastFailureReason ?? "The Gateway did not become ready.")
        }
    }

    func startAppHostedGateway(startGeneration: UInt64) async {
        guard self.isCurrentGatewayStart(startGeneration) else { return }
        guard self.installation == .managed else {
            let reason = self.installation == .unreadable
                ? Installation.ownershipFailure
                : "This Gateway is externally managed. Start it with its installation owner."
            self.status = .failed(reason)
            self.lastFailureReason = reason
            return
        }
        do {
            let runtime = try await BundledRuntime.seed()
            guard self.isCurrentGatewayStart(startGeneration) else { return }
            let port = GatewayEnvironment.gatewayPort()
            if await PortGuardian.shared.describe(port: port) != nil {
                _ = await self.attachExistingGatewayIfAvailable(port: port, startGeneration: startGeneration)
                return
            }
            guard self.isCurrentGatewayStart(startGeneration) else { return }
            var environment = ProcessInfo.processInfo.environment
            environment.merge(runtime.environment) { _, runtimeValue in runtimeValue }
            environment["PATH"] = ([runtime.bun.deletingLastPathComponent().path] +
                CommandResolver.preferredPaths()).joined(separator: ":")
            environment["OPENCLAW_PROFILE"] = AppProfile.current.name ?? "default"
            // The selected profile owns state even when the app was opened from an operator shell.
            environment["OPENCLAW_STATE_DIR"] = AppProfile.current.stateDirectoryURL().path
            environment["OPENCLAW_CONFIG_PATH"] = AppProfile.current.stateDirectoryURL()
                .appendingPathComponent("openclaw.json").path
            let pid = try await self.childSupervisor.start(configuration: .init(
                bun: runtime.bun,
                packageRoot: runtime.packageRoot,
                environment: environment,
                logPath: GatewayLaunchAgentManager.launchdGatewayLogPath(),
                port: port,
                allowUnconfigured: self.hostsLocalGatewayWithRemotePrimary))
            { [weak self] event in
                self?.handleChildEvent(event, port: port, generation: startGeneration)
            }
            guard self.isCurrentGatewayStart(startGeneration) else { return }
            await self.observeChildReadiness(pid: pid, port: port, generation: startGeneration)
        } catch {
            guard self.isCurrentGatewayStart(startGeneration) else { return }
            self.status = .failed(error.localizedDescription)
            self.lastFailureReason = error.localizedDescription
            self.appendLog("[gateway] \(error.localizedDescription)\n")
            self.logger.error("gateway child launch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleChildEvent(_ event: GatewayChildSupervisor.Event, port: Int, generation: UInt64) {
        guard self.isCurrentGatewayStart(generation) else { return }
        self.setLaunchAgentReadinessState(candidate: nil, failure: nil)
        self.gatewayStartTask?.cancel()
        switch event {
        case let .started(pid):
            self.status = .starting
            self.beginGatewayStartTask(generation: generation) { [weak self] in
                await self?.observeChildReadiness(pid: pid, port: port, generation: generation)
            }
        case let .restarting(delay):
            self.status = .starting
            self.appendLog("[gateway] child exited; restarting in \(delay)\n")
        case let .failed(reason):
            self.status = .failed(reason)
            self.lastFailureReason = reason
            self.appendLog("[gateway] \(reason)\n")
        }
    }

    private func observeChildReadiness(pid: Int32, port: Int, generation: UInt64) async {
        let context = self.gatewayReadinessContext(
            purpose: .child, port: port, generation: generation, readinessPID: pid)
        let terminal = await self.observeGatewayReadiness(
            context: context,
            deadlinePolicy: .migration(window: 6, tolerance: GatewayLaunchAgentManager.startupMigrationTolerance),
            clock: self.readinessClock)
        if await self.publishGatewayReadinessTerminal(terminal, context: context) {
            do { try await BundledRuntime.garbageCollectAfterHealthy() } catch {
                self.appendLog("[gateway] old runtime cleanup deferred: \(error.localizedDescription)\n")
            }
        }
    }

    func shutdownAppHostedGateway() async {
        self.isTerminating = true
        _ = try? await self.hostingChangeTask?.value
        // Already-admitted service writes and a pending pause settle before app exit.
        // Quitting otherwise leaves the always-on service alone.
        _ = await self.launchAgentEnableTask?.value
        await self.waitForPendingLaunchAgentDisable()
        guard self.childSupervisor.isActive || self.gatewayStartTask != nil || self.bundledUpdateTask != nil else {
            return
        }
        guard self.gatewayHosting == .app || self.childSupervisor.isActive else { return }
        let updateTask = self.bundledUpdateTask
        updateTask?.cancel()
        self.desiredActive = false
        self.gatewayStartGeneration &+= 1
        self.gatewayStartTask?.cancel()
        await self.childSupervisor.stop()
        await self.gatewayStartTask?.value
        _ = try? await updateTask?.value
        self.status = .stopped
    }

    func prepareBundledRuntimeAfterUpdate() async throws {
        guard !self.isTerminating else { throw CancellationError() }
        if let task = self.bundledUpdateTask { return try await task.value }
        _ = try? await self.hostingChangeTask?.value
        guard !self.isTerminating else { throw CancellationError() }
        if let task = self.bundledUpdateTask { return try await task.value }
        let task = Task { @MainActor in try await self.performBundledRuntimeUpdate() }
        self.bundledUpdateTask = task
        defer {
            self.bundledUpdateTask = nil
            self.startIfNeeded()
        }
        try await task.value
    }

    private func performBundledRuntimeUpdate() async throws {
        await self.waitForStartupAttempt()
        guard !self.isTerminating, !Task.isCancelled else { throw CancellationError() }
        let updateGeneration = self.gatewayStartGeneration
        guard self.usesSeededGateway else { return }
        let runtime = try await BundledRuntime.seed()
        guard !self.isTerminating, !Task.isCancelled,
              self.gatewayStartGeneration == updateGeneration else { throw CancellationError() }
        if AppStateStore.shared.isPaused { return }
        if self.gatewayHosting == .app {
            // Recovery may request activation while the old child drains. Keep that intent,
            // but let this transition own the restart just as a hosting-mode change does.
            self.hostingChangeInProgress = true
            defer { self.hostingChangeInProgress = false }
            self.stop(preservingActivationIntent: true)
            let stopGeneration = self.gatewayStartGeneration
            await self.waitForPendingLaunchAgentDisable()
            guard !self.isTerminating, !Task.isCancelled,
                  self.gatewayStartGeneration == stopGeneration else { throw CancellationError() }
            if AppStateStore.shared.isPaused { return }
            self.hostingChangeInProgress = false
            self.startIfNeeded()
        } else {
            self.desiredActive = true
            self.gatewayStartGeneration &+= 1
            let generation = self.gatewayStartGeneration
            self.status = .starting
            let result = await self.enableLaunchAgentIfNeeded(
                port: GatewayEnvironment.gatewayPort(), generation: generation, runtimeForUpdate: runtime)
            guard self.isCurrentGatewayStart(generation) else { throw CancellationError() }
            if let error = result.error {
                self.status = .failed(error)
                self.lastFailureReason = error
                throw GatewayHostingError(message: error)
            }
        }
        guard await self.waitForGatewayReady(timeout: GatewayLaunchAgentManager.startupMigrationTolerance) else {
            throw GatewayHostingError(message: self.lastFailureReason ?? "The updated Gateway did not become ready.")
        }
        do { try await BundledRuntime.garbageCollectAfterHealthy() } catch {
            self.appendLog("[gateway] old runtime cleanup deferred: \(error.localizedDescription)\n")
        }
    }
}
