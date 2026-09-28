import Foundation
import RedirectorBridge

private final class LatencyCheckState: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Int32?
    private var cancelled = false
    func finish(_ code: Int32) { lock.lock(); result = code; lock.unlock() }
    func status() -> (Int32?, Bool) { lock.lock(); defer { lock.unlock() }; return (result, cancelled) }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

// Deliberately a CLI-only diagnostic: normal GUI routing never allocates a recorder.
// Audio is collected into bounded RAM by the bridge, then serialized after stop.
enum LatencyCheck {
    @MainActor
    static func run(path: String, output: String, seconds: Double) -> Int32 {
        do {
            guard URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
                    != URL(fileURLWithPath: output).standardizedFileURL.resolvingSymlinksInPath() else {
                log("Capture output must not overwrite the configuration file."); return 2
            }
            let config = try JSONDecoder().decode(RedirectorConfiguration.self,
                from: Data(contentsOf: URL(fileURLWithPath: path)))
            let json = try config.engineJSON()
            let permission = MutedRouteCheck.microphonePermission(timeout: 60)
            guard permission.allowed else {
                log(permission.error ?? "Audio input permission is required.")
                return 1
            }
            let state = LatencyCheckState()
            DispatchQueue(label: "local.my-redirector.latency-check", qos: .userInitiated).async {
                state.finish(perform(json: json, output: output, seconds: seconds, state: state))
            }
            let deadline = ProcessInfo.processInfo.systemUptime + seconds + 35
            while state.status().0 == nil {
                if ProcessInfo.processInfo.systemUptime > deadline { state.cancel() }
                if ProcessInfo.processInfo.systemUptime > deadline + 10 {
                    log("Latency diagnostic timed out; cleanup is unconfirmed. No measurements should be accepted.")
                    return 1
                }
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            }
            return state.status().0 ?? 1
        } catch { log(error.localizedDescription); return 1 }
    }

    private static func perform(json: String, output: String, seconds: Double, state: LatencyCheckState) -> Int32 {
        guard let engine = mr_engine_create() else { log("Engine allocation failed."); return 1 }
        defer { mr_engine_destroy(engine) }
        var failure: String?
        var beforeStop: [String: Any] = [:]
        var report: [String: Any] = ["diagnostic": "signal-latency", "startedAt": ISO8601DateFormatter().string(from: Date()),
                                   "requestedSeconds": seconds, "configurationFileModified": false,
                                   "effectiveConfiguration": (try? JSONSerialization.jsonObject(with: Data(json.utf8))) ?? NSNull()]
        if mr_engine_prepare_latency_capture(engine, seconds + 1) != 0 {
            log("Could not preallocate bounded latency capture."); return 1
        }
        var error = [CChar](repeating: 0, count: 4096)
        let code = json.withCString { mr_engine_start(engine, $0, &error, error.count) }
        if code != 0 { failure = String(cString: error) }
        let began = ProcessInfo.processInfo.systemUptime
        var armTime: Double?
        var runningSince: Double?
        var nextPoll = began
        while failure == nil && !state.status().1 {
            let now = ProcessInfo.processInfo.systemUptime
            if now >= nextPoll {
                beforeStop = readJSON(mr_engine_status_json(engine)) ?? [:]
                if beforeStop["state"] as? String == "fault" || beforeStop.isEmpty {
                    failure = beforeStop["error"] as? String ?? "Audio status unavailable."
                    break
                }
                if beforeStop["state"] as? String == "running", runningSince == nil { runningSince = now }
                if armTime == nil, let runningSince, now - runningSince >= 2, beforeStop["state"] as? String == "running" {
                    if mr_engine_arm_latency_capture(engine) != 0 { failure = "Could not arm a primed, healthy engine."; break }
                    armTime = now
                    log("Latency capture armed; route and Gate settings stay fixed.")
                }
                nextPoll = now + 0.25
            }
            if let armTime, now - armTime >= seconds { break }
            if armTime == nil && now - began > 9 { failure = "Audio route did not prime for measurement."; break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        mr_engine_disarm_latency_capture(engine)
        if state.status().1 { failure = "Latency diagnostic cancelled at its deadline." }
        if failure == nil { beforeStop = readJSON(mr_engine_status_json(engine)) ?? [:] }
        if beforeStop["state"] as? String != "running" || (beforeStop["fault"] as? Int ?? 1) != 0 {
            failure = failure ?? (beforeStop["error"] as? String ?? "Route was not healthy at capture end.")
        }
        report["beforeStop"] = beforeStop
        mr_engine_stop(engine)
        let stopped = readJSON(mr_engine_status_json(engine)) ?? [:]
        report["afterStop"] = stopped
        let sourceFault = (stopped["sources"] as? [[String: Any]] ?? []).contains {
            ($0["underruns"] as? Int ?? 1) != 0 || ($0["overflows"] as? Int ?? 1) != 0
        }
        if (stopped["fault"] as? Int ?? 1) != 0 || (stopped["nonFinite"] as? Int ?? 1) != 0
            || (stopped["clipped"] as? Int ?? 1) != 0 || sourceFault {
            failure = failure ?? "Capture run encountered a fault, FIFO error, non-finite sample or clipping."
        }
        let cleaned = stopped["state"] as? String == "off" && stopped["unsafeTeardown"] as? Bool == false
            && stopped["tapActive"] as? Bool == false && stopped["aggregateActive"] as? Bool == false
            && (stopped["teardownDiagnostic"] is NSNull)
        if !cleaned { failure = failure ?? "Audio cleanup could not be confirmed." }
        if let capture = readJSON(mr_engine_latency_capture_json(engine)) {
            for (key, value) in capture { report[key] = value }
            let streams = capture["streams"] as? [[String: Any]] ?? []
            if streams.count != 4 || streams.contains(where: { ($0["frames"] as? Int ?? 0) < Int(seconds * 48000 * 0.95) || $0["capacityExceeded"] as? Bool != false }) {
                failure = failure ?? "Capture was short or exceeded its bounded capacity."
            }
        } else { failure = failure ?? "Capture could not be exported after stop." }
        report["success"] = failure == nil
        report["error"] = failure as Any? ?? NSNull()
        report["cleanupConfirmed"] = cleaned
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            try data.write(to: URL(fileURLWithPath: output), options: .atomic)
            log("Latency capture saved: \(output)")
        } catch { log(error.localizedDescription); return 1 }
        if let failure { log(failure); return 1 }
        return 0
    }

    private static func readJSON(_ pointer: UnsafeMutablePointer<CChar>?) -> [String: Any]? {
        guard let pointer else { return nil }
        defer { mr_string_free(pointer) }
        return (try? JSONSerialization.jsonObject(with: Data(String(cString: pointer).utf8))) as? [String: Any]
    }
    private static func log(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
}
