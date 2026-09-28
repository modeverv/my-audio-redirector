import AVFoundation
import Foundation
import RedirectorBridge

// This lock only connects the CLI main RunLoop and its serial control worker.
// It is never referenced from an audio callback.
private final class MutedCheckState: @unchecked Sendable {
    private let lock = NSLock()
    private var report: [String: Any]
    private var completed = false
    private var cancelled = false
    private var deadline = ProcessInfo.processInfo.systemUptime + 30
    private var exitCode: Int32 = 1

    init(report: [String: Any]) { self.report = report }
    func update(_ values: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        report.merge(values) { _, new in new }
    }
    func setPhase(_ phase: String, timeout: Double) {
        lock.lock(); defer { lock.unlock() }
        report["phase"] = phase
        deadline = ProcessInfo.processInfo.systemUptime + timeout
    }
    func cancellationRequested() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }
    func finish(code: Int32) {
        lock.lock(); defer { lock.unlock() }
        report["completed"] = true
        completed = true
        exitCode = code
    }
    func snapshot() -> (report: [String: Any], completed: Bool, deadline: Double, code: Int32) {
        lock.lock(); defer { lock.unlock() }
        return (report, completed, deadline, exitCode)
    }
}

private final class PermissionReply: @unchecked Sendable {
    private let lock = NSLock()
    private var answer: Bool?
    func set(_ value: Bool) { lock.lock(); answer = value; lock.unlock() }
    func get() -> Bool? { lock.lock(); defer { lock.unlock() }; return answer }
}

enum MutedRouteCheck {
    @MainActor
    static func run(path: String, seconds: Double, stressGates: Bool = false) -> Int32 {
        var report: [String: Any] = [
            "diagnostic": "muted-route", "requestedSeconds": seconds,
            "startedAt": ISO8601DateFormatter().string(from: Date()),
            "success": false, "completed": false, "runningObserved": false,
            "configurationFileModified": false,
            "gateStressEnabled": stressGates, "gateControlRequestedHz": stressGates ? 50 : 0,
            "gateControlBatches": 0, "gateControlCalls": 0,
            "gateStressPreservesEnabled": true,
            "note": "This check forces every source and return mute. It does not verify signal content, channel identity, self-exclusion, audible routing or end-to-end latency."
        ]
        let mutedConfiguration: RedirectorConfiguration
        do {
            var configuration = try JSONDecoder().decode(RedirectorConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            for index in configuration.rmeChannels.indices { configuration.rmeChannels[index].muted = true }
            for index in configuration.pcChannels.indices { configuration.pcChannels[index].muted = true }
            configuration.returnMuted = true
            configuration.tapMuteOriginal = false
            mutedConfiguration = configuration
            report["effectiveConfiguration"] = try JSONSerialization.jsonObject(with: Data(configuration.engineJSON().utf8))
            report["forcedSafety"] = ["allRMESourcesMuted": true, "allPCSourcesMuted": true, "returnMuted": true, "tapMuteOriginal": false, "absentSourceSettingsRemainMuted": true]
        } catch {
            report["error"] = error.localizedDescription
            report["phase"] = "configuration"
            report["completed"] = true
            report["cleanup"] = ["notRequired": true, "reason": "No engine was created."]
            return emit(report, code: 1)
        }

        let permission = microphonePermission(timeout: 60)
        report["microphonePermission"] = permission.report
        guard permission.allowed else {
            report["error"] = permission.error ?? "Microphone permission was not granted."
            report["phase"] = "permission"
            report["completed"] = true
            report["cleanup"] = ["notRequired": true, "reason": "No engine was created."]
            return emit(report, code: 1)
        }

        let state = MutedCheckState(report: report)
        let queue = DispatchQueue(label: "local.my-redirector.muted-route-check", qos: .userInitiated)
        queue.async { perform(configuration: mutedConfiguration, seconds: seconds, stressGates: stressGates, state: state) }

        var timeoutObservedAt: Double?
        while true {
            let current = state.snapshot()
            if current.completed {
                var result = current.report
                if timeoutObservedAt != nil {
                    result["success"] = false
                    result["error"] = "A control phase exceeded its deadline; cleanup results are retained below."
                    return emit(result, code: 1)
                }
                return emit(result, code: current.code)
            }
            let now = ProcessInfo.processInfo.systemUptime
            if timeoutObservedAt == nil, now > current.deadline {
                timeoutObservedAt = now
                state.cancel()
                state.update(["deadlineExceeded": true])
            }
            if let timeoutObservedAt, now - timeoutObservedAt >= 10 {
                var result = state.snapshot().report
                result["success"] = false
                result["completed"] = false
                result["error"] = "The audio control call did not finish within its deadline and cleanup grace period. Cleanup is unconfirmed."
                result["cleanup"] = ["confirmed": false, "controlCallReturned": false]
                // The process exits with failure. Do not destroy live callback state
                // concurrently with the blocked serial control call.
                return emit(result, code: 1)
            }
            serviceMainRunLoop()
        }
    }

    @MainActor
    private static func microphonePermission(timeout: Double) -> (allowed: Bool, report: [String: Any], error: String?) {
        let initial = AVCaptureDevice.authorizationStatus(for: .audio)
        let started = ProcessInfo.processInfo.systemUptime
        var record: [String: Any] = ["initialStatus": permissionName(initial), "timeoutSeconds": timeout, "requested": false]
        if initial == .authorized {
            record["finalStatus"] = "authorized"
            return (true, record, nil)
        }
        guard initial == .notDetermined else {
            record["finalStatus"] = permissionName(initial)
            return (false, record, "Microphone/audio-input access is denied or restricted. Allow this app in System Settings → Privacy & Security → Microphone before retrying.")
        }
        record["requested"] = true
        FileHandle.standardError.write(Data("Waiting for macOS microphone/audio-input permission (up to 60 seconds). No audio engine has started.\n".utf8))
        let reply = PermissionReply()
        AVCaptureDevice.requestAccess(for: .audio) { reply.set($0) }
        while reply.get() == nil && ProcessInfo.processInfo.systemUptime - started < timeout { serviceMainRunLoop() }
        record["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
        record["finalStatus"] = permissionName(AVCaptureDevice.authorizationStatus(for: .audio))
        guard let allowed = reply.get() else {
            record["timedOut"] = true
            return (false, record, "Timed out waiting for microphone/audio-input permission. No audio engine was started.")
        }
        return (allowed, record, allowed ? nil : "Microphone/audio-input permission was denied. No audio engine was started.")
    }

    private static func permissionName(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    @MainActor
    private static func serviceMainRunLoop() {
        let began = ProcessInfo.processInfo.systemUptime
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.04))
        if ProcessInfo.processInfo.systemUptime - began < 0.005 { Thread.sleep(forTimeInterval: 0.005) }
    }

    private static func perform(configuration: RedirectorConfiguration, seconds: Double, stressGates: Bool, state: MutedCheckState) {
        state.setPhase("starting", timeout: 30)
        guard let engine = mr_engine_create() else {
            state.update(["error": "Could not create engine.", "cleanup": ["notRequired": true]])
            state.finish(code: 1)
            return
        }
        let started = ProcessInfo.processInfo.systemUptime
        var snapshots: [[String: Any]] = []
        var rateReadings: [[String: Any]] = []
        var rateChanges: [[String: Any]] = []
        var lastRates: [String: Any]?
        var runningObserved = false
        var observedPrimedMask = 0
        var producerFrames = ["RME": UInt64(0), "PC": UInt64(0), "Return": UInt64(0)]
        var failure: String?
        var preStop: [String: Any] = [:]
        var outputSilenceConfirmed = true
        var gateTargets: [(source: UInt32, channel: UInt32, gate: GateConfiguration)] = []
        var gateControlBatches = 0
        var gateControlCalls = 0
        var firstGateControlElapsed: Double?
        var lastGateControlElapsed: Double?
        var maximumGateControlBatchSeconds = 0.0
        var maximumGateControlIntervalSeconds = 0.0
        var faultObservedElapsed: Double?

        func gateControlSummary() -> [String: Any] {
            let span = (lastGateControlElapsed ?? 0) - (firstGateControlElapsed ?? 0)
            return ["gateControlBatches": gateControlBatches, "gateControlCalls": gateControlCalls,
                    "gateControlFirstElapsedSeconds": firstGateControlElapsed as Any? ?? NSNull(),
                    "gateControlLastElapsedSeconds": lastGateControlElapsed as Any? ?? NSNull(),
                    "gateControlObservedHz": span > 0 ? Double(gateControlBatches - 1) / span : 0,
                    "gateControlMaxBatchMicroseconds": maximumGateControlBatchSeconds * 1_000_000,
                    "gateControlMaxIntervalMilliseconds": maximumGateControlIntervalSeconds * 1_000]
        }

        func updateGates() {
            let began = ProcessInfo.processInfo.systemUptime
            let elapsed = began - started
            // Deterministic, valid parameter changes. Enabled and hysteresis stay
            // as configured so Gate-on/off copies receive the same API workload.
            let phase = Float(gateControlBatches % 101) / 100
            for target in gateTargets {
                mr_engine_set_gate(engine, target.source, target.channel, target.gate.enabled ? 1 : 0,
                                   -90 + 84 * phase, 0.1 + 9.9 * phase,
                                   200 * phase, 1 + 499 * phase, target.gate.hysteresisDB)
            }
            gateControlBatches += 1
            gateControlCalls += gateTargets.count
            if let previous = lastGateControlElapsed {
                maximumGateControlIntervalSeconds = max(maximumGateControlIntervalSeconds, elapsed - previous)
            }
            if firstGateControlElapsed == nil { firstGateControlElapsed = elapsed }
            lastGateControlElapsed = elapsed
            maximumGateControlBatchSeconds = max(maximumGateControlBatchSeconds, ProcessInfo.processInfo.systemUptime - began)
        }

        func recordRates(_ phase: String) {
            guard let inventory = readJSON(mr_inventory_json()) else {
                rateReadings.append(["phase": phase, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started, "error": "Inventory unavailable"])
                return
            }
            let devices = inventory["devices"] as? [[String: Any]] ?? []
            var selected: [String: Any] = [:]
            var signature: [String: Any] = [:]
            for (role, uid) in [("RME", configuration.rmeUID), ("Discrete4", configuration.d4UID), ("PC", configuration.pcUID)] {
                if let device = devices.first(where: { $0["uid"] as? String == uid }) {
                    selected[role] = device.filter { ["uid", "name", "sampleRate", "actualSampleRate", "bufferFrames", "alive", "runningSomewhere"].contains($0.key) }
                    signature[role] = device.filter { ["uid", "sampleRate", "actualSampleRate", "alive"].contains($0.key) }
                } else {
                    selected[role] = ["uid": uid, "missing": true]
                    signature[role] = ["uid": uid, "missing": true]
                }
            }
            let reading: [String: Any] = ["phase": phase, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started, "devices": selected]
            rateReadings.append(reading)
            if let previous = lastRates, !NSDictionary(dictionary: previous).isEqual(to: signature) { rateChanges.append(reading) }
            lastRates = signature
            state.update(["rateReadings": rateReadings, "observedRateChanges": rateChanges])
        }

        func recordStatus() {
            guard let current = readJSON(mr_engine_status_json(engine)) else {
                failure = "Engine status was unavailable."
                return
            }
            preStop = current
            let currentState = current["state"] as? String ?? "unknown"
            observedPrimedMask |= current["primedMask"] as? Int ?? 0
            if currentState == "running" { runningObserved = true }
            for source in current["sources"] as? [[String: Any]] ?? [] {
                if let name = source["name"] as? String, let frames = source["frames"] as? NSNumber, producerFrames[name] != nil {
                    producerFrames[name] = max(producerFrames[name] ?? 0, frames.uint64Value)
                }
            }
            if let peaks = current["outputPeaks"] as? [NSNumber], !peaks.isEmpty,
               peaks.contains(where: { !$0.doubleValue.isFinite || abs($0.doubleValue) > 0.0000001 }) {
                outputSilenceConfirmed = false
                failure = "Unexpected nonzero output peak during the forced-mute check."
            }
            if currentState == "fault" || ((current["fault"] as? NSNumber)?.intValue ?? 0) != 0 {
                failure = current["error"] as? String ?? "Audio engine reported a fault."
                if faultObservedElapsed == nil {
                    faultObservedElapsed = ProcessInfo.processInfo.systemUptime - started
                    state.update(["faultObservedElapsedSeconds": faultObservedElapsed!,
                                  "faultObservedAt": ISO8601DateFormatter().string(from: Date()),
                                  "gateControlBatchesAtFaultObservation": gateControlBatches])
                }
            }
            var compact = current.filter { ["state", "error", "fault", "primedMask", "unsafeTeardown", "rmeBufferFrames", "pcBufferFrames", "d4BufferFrames", "outputPeaks"].contains($0.key) }
            compact["sources"] = (current["sources"] as? [[String: Any]] ?? []).map { source in
                source.filter { ["name", "callbacks", "frames", "fifoFrames", "underruns", "overflows", "ppm"].contains($0.key) }
            }
            snapshots.append(["elapsedSeconds": ProcessInfo.processInfo.systemUptime - started, "status": compact,
                              "gateControlBatches": gateControlBatches, "gateControlCalls": gateControlCalls])
            state.update(["statusSnapshots": snapshots, "runningObserved": runningObserved, "observedPrimedMask": observedPrimedMask,
                          "producerFrames": producerFrames, "lastStatus": current, "outputPeaksRemainedZero": outputSilenceConfirmed])
            state.update(gateControlSummary())
        }

        recordRates("beforeStart")
        if state.cancellationRequested() { failure = "Cancelled before starting audio." }
        if failure == nil {
            do {
                let json = try configuration.engineJSON()
                var error = [CChar](repeating: 0, count: 4096)
                let code = json.withCString { mr_engine_start(engine, $0, &error, error.count) }
                state.update(["startResult": Int(code)])
                if code != 0 { failure = String(cString: error) }
            } catch { failure = error.localizedDescription }
        }
        recordStatus()
        recordRates("afterStart")
        if failure == nil && stressGates {
            let sources = preStop["sources"] as? [[String: Any]] ?? []
            var counts: [String: Int] = [:]
            var enabledCounts: [String: Int] = [:]
            for (sourceIndex, name) in ["RME", "PC", "Return"].enumerated() {
                let count = (sources.first { $0["name"] as? String == name }?["peaks"] as? [NSNumber])?.count ?? 0
                guard count > 0, count <= Int(MR_METER_CHANNELS), sourceIndex != 2 || count == 2 else {
                    failure = "Gate stress could not determine the actual \(name) channel count."
                    break
                }
                counts[name] = count
                for channel in 0..<count {
                    let gate: GateConfiguration
                    if sourceIndex == 2 { gate = configuration.returnGates[channel] }
                    else {
                        let channels = sourceIndex == 0 ? configuration.rmeChannels : configuration.pcChannels
                        gate = channels.first { $0.channel == channel + 1 }?.gate ?? GateConfiguration()
                    }
                    gateTargets.append((UInt32(sourceIndex), UInt32(channel), gate))
                    enabledCounts[name, default: 0] += gate.enabled ? 1 : 0
                }
            }
            state.update(["gateControlChannelCounts": counts, "gateControlEnabledCounts": enabledCounts,
                          "gateControlChannelsPerBatch": gateTargets.count])
        }
        if failure == nil {
            state.setPhase("mutedRouting", timeout: seconds + 1)
            let routeStarted = ProcessInfo.processInfo.systemUptime
            let routeDeadline = routeStarted + seconds
            var nextRates = routeStarted + 1
            var nextStatus = routeStarted + 0.2
            var nextGateControl = stressGates ? routeStarted : Double.infinity
            while ProcessInfo.processInfo.systemUptime < routeDeadline && failure == nil && !state.cancellationRequested() {
                if ProcessInfo.processInfo.systemUptime >= nextGateControl {
                    updateGates()
                    // No catch-up bursts after a delayed control call. The 50 Hz
                    // Gate schedule is independent of the 200 ms status polling.
                    nextGateControl = ProcessInfo.processInfo.systemUptime + 0.02
                }
                if ProcessInfo.processInfo.systemUptime >= nextStatus {
                    recordStatus()
                    nextStatus = ProcessInfo.processInfo.systemUptime + 0.2
                }
                if failure == nil && ProcessInfo.processInfo.systemUptime >= nextRates {
                    recordRates("mutedRouting")
                    nextRates = ProcessInfo.processInfo.systemUptime + 1
                }
                let nextWake = min(routeDeadline, nextStatus, nextRates, nextGateControl)
                if failure == nil { Thread.sleep(forTimeInterval: max(0, nextWake - ProcessInfo.processInfo.systemUptime)) }
            }
            if failure == nil { recordStatus() }
        }
        if state.cancellationRequested() { failure = failure ?? "A control phase exceeded its deadline." }
        if !runningObserved { failure = failure ?? "The engine never reached running within the requested interval." }
        let allProducersAdvanced = producerFrames.values.allSatisfy { $0 > 0 }
        if !allProducersAdvanced { failure = failure ?? "One or more source producers delivered no frames." }
        if stressGates && gateControlBatches == 0 { failure = failure ?? "No Gate stress control batch was executed." }

        state.setPhase("stopping", timeout: 10)
        state.update(["beforeStop": preStop])
        mr_engine_stop(engine)
        let afterStop = readJSON(mr_engine_status_json(engine)) ?? [:]
        let stopped = afterStop["state"] as? String == "off"
        let tapGone = afterStop["tapActive"] as? Bool == false
        let aggregateGone = afterStop["aggregateActive"] as? Bool == false
        let safeTeardown = afterStop["unsafeTeardown"] as? Bool == false
        let teardownText = afterStop["teardownDiagnostic"] as? String
        let cleanupConfirmed = stopped && tapGone && aggregateGone && safeTeardown && (teardownText?.isEmpty ?? true)
        let cleanup: [String: Any] = ["confirmed": cleanupConfirmed, "stopCallReturned": true,
                                     "stateOff": stopped, "tapInactive": tapGone, "aggregateInactive": aggregateGone,
                                     "unsafeTeardownFalse": safeTeardown, "afterStop": afterStop]
        if !cleanupConfirmed { failure = failure ?? "Stop/cleanup could not be fully confirmed; inspect cleanup.afterStop." }
        recordRates("afterStop")
        state.update(["cleanup": cleanup])
        state.update(gateControlSummary())
        // Destruction stays on the same queue and follows the backend's teardown checks.
        mr_engine_destroy(engine)
        let success = failure == nil && runningObserved && allProducersAdvanced && cleanupConfirmed && outputSilenceConfirmed
        state.update(["phase": "finished", "success": success, "runningObserved": runningObserved,
                      "allProducersAdvanced": allProducersAdvanced, "producerFrames": producerFrames,
                      "observedPrimedMask": observedPrimedMask, "error": failure as Any? ?? NSNull(),
                      "elapsedControlSeconds": ProcessInfo.processInfo.systemUptime - started,
                      "statusSnapshots": snapshots, "rateReadings": rateReadings, "observedRateChanges": rateChanges,
                      "outputPeaksRemainedZero": outputSilenceConfirmed, "destroyCallReturned": true])
        state.finish(code: success ? 0 : 1)
    }

    private static func readJSON(_ pointer: UnsafeMutablePointer<CChar>?) -> [String: Any]? {
        guard let pointer else { return nil }
        defer { mr_string_free(pointer) }
        return (try? JSONSerialization.jsonObject(with: Data(String(cString: pointer).utf8))) as? [String: Any]
    }

    private static func emit(_ report: [String: Any], code: Int32) -> Int32 {
        if code != 0, let error = report["error"] as? String { FileHandle.standardError.write(Data((error + "\n").utf8)) }
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data(("Could not encode diagnostic JSON: \(error.localizedDescription)\n").utf8))
            return 1
        }
        return code
    }
}
