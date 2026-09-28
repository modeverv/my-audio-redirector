import Foundation
import RedirectorBridge

@main
enum RedirectorEntry {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if !arguments.isEmpty {
            exit(runCommandLine(arguments))
        }
        RedirectorApplication.main()
    }

    @MainActor
    private static func runCommandLine(_ arguments: [String]) -> Int32 {
        let queue = DispatchQueue(label: "local.my-redirector.cli-control")
        if arguments.first == "--measure-latency" {
            guard arguments.count == 6, arguments[2] == "--output", arguments[4] == "--seconds",
                  let seconds = Double(arguments[5]), seconds.isFinite, (1...8).contains(seconds) else {
                writeError("Use --measure-latency CONFIG --output CAPTURE.json --seconds 1...8. Runs the saved audible route; use a separate quiet signal player.")
                return 2
            }
            return LatencyCheck.run(path: arguments[1], output: arguments[3], seconds: seconds)
        }
        if arguments.first == "--check-muted-route", arguments.count >= 2 {
            var seconds = 10.0
            var stressGates = false
            var hasSeconds = false
            var index = 2
            while index < arguments.count {
                if arguments[index] == "--stress-gates", !stressGates {
                    stressGates = true
                    index += 1
                } else if arguments[index] == "--seconds", !hasSeconds, index + 1 < arguments.count,
                          let value = Double(arguments[index + 1]), value.isFinite, (0.2...60).contains(value) {
                    seconds = value
                    hasSeconds = true
                    index += 2
                } else {
                    writeError("Use --check-muted-route PATH [--seconds 0.2...60] [--stress-gates].")
                    return 2
                }
            }
            return MutedRouteCheck.run(path: arguments[1], seconds: seconds, stressGates: stressGates)
        }
        if arguments == ["--inventory"] {
            return queue.sync {
                guard let pointer = mr_inventory_json() else { writeError("Inventory returned no JSON."); return 1 }
                defer { mr_string_free(pointer) }
                print(String(cString: pointer))
                return 0
            }
        }
        if arguments == ["--self-test-config"] {
            do {
                var config = RedirectorConfiguration()
                config.rmeChannels = (1...20).map(ChannelConfiguration.init)
                config.pcChannels = (1...20).map(ChannelConfiguration.init)
                config.rmeStereoLinks = [1, 3]
                config.rmeReturnLabels = ["11: AES L", "12: AES R"]
                let roundTrip = try JSONDecoder().decode(RedirectorConfiguration.self, from: Data(config.json().utf8))
                guard roundTrip == config, config.rmeChannels.allSatisfy(\.muted), config.returnMuted else {
                    throw ConfigurationError.invalid("Configuration round-trip or mute defaults failed.")
                }
                guard config.rmeChannels[0].pan == -1, config.rmeChannels[1].pan == 1 else {
                    throw ConfigurationError.invalid("Stereo pan defaults failed.")
                }
                let engine = try JSONSerialization.jsonObject(with: Data(config.engineJSON().utf8)) as! [String: Any]
                guard engine["rmeReturnLabels"] == nil, engine["rmeChannels"] != nil,
                      engine["rmeStereoLinks"] as? [Int] == [1, 3],
                      engine["pcStereoLinks"] as? [Int] == [],
                      engine["returnGateLinked"] as? Bool == true,
                      (engine["returnGates"] as? [[String: Any]])?.count == 2,
                      ((engine["rmeChannels"] as? [[String: Any]])?.first?["gate"] as? [String: Any])?["enabled"] as? Bool == true else {
                    throw ConfigurationError.invalid("Engine JSON contains UI-only state.")
                }
                func expectRejection(_ name: String, _ operation: () throws -> Void) throws {
                    var rejected = false
                    do { try operation() } catch { rejected = true }
                    guard rejected else { throw ConfigurationError.invalid("Invalid \(name) was accepted.") }
                }
                // Older schema-1 saves have no Gate keys. Preserve every existing field.
                var legacyExpected = config
                legacyExpected.rmeUID = "test-rme"
                legacyExpected.d4UID = "test-d4"
                legacyExpected.pcUID = "test-pc"
                legacyExpected.rmeReturnLeft = 9
                legacyExpected.rmeReturnRight = 10
                legacyExpected.d4ReturnLeft = 7
                legacyExpected.d4ReturnRight = 8
                legacyExpected.returnMuted = false
                legacyExpected.pcStereoLinks = [1]
                legacyExpected.rmeChannels[0].gainDB = 0.1
                legacyExpected.rmeChannels[0].pan = 1
                legacyExpected.rmeChannels[0].muted = false
                legacyExpected.pcChannels[1].gainDB = -18
                legacyExpected.pcChannels[1].pan = 0.25
                legacyExpected.pcChannels[1].muted = false
                var legacyObject = try JSONSerialization.jsonObject(with: Data(legacyExpected.json().utf8)) as! [String: Any]
                legacyObject.removeValue(forKey: "returnGates")
                legacyObject.removeValue(forKey: "returnGateLinked")
                for key in ["rmeChannels", "pcChannels"] {
                    legacyObject[key] = (legacyObject[key] as! [[String: Any]]).map { channel in
                        channel.filter { $0.key != "gate" }
                    }
                }
                let migrated = try JSONDecoder().decode(RedirectorConfiguration.self,
                    from: JSONSerialization.data(withJSONObject: legacyObject))
                guard migrated == legacyExpected,
                      migrated.rmeChannels.allSatisfy({ $0.gate == GateConfiguration() }),
                      migrated.pcChannels.allSatisfy({ $0.gate == GateConfiguration() }),
                      migrated.returnGates == [GateConfiguration(), GateConfiguration()], migrated.returnGateLinked else {
                    throw ConfigurationError.invalid("Legacy Gate migration changed routing or mixer settings.")
                }
                var custom = legacyExpected
                custom.rmeChannels[0].gate = GateConfiguration(enabled: false, thresholdDB: -48,
                    attackMS: 1.5, holdMS: 75, releaseMS: 120, hysteresisDB: 9)
                custom.rmeChannels[1].gate = custom.rmeChannels[0].gate
                custom.pcChannels[1].gate = GateConfiguration(thresholdDB: -72)
                custom.pcChannels[0].gate = custom.pcChannels[1].gate
                custom.returnGates = [custom.rmeChannels[0].gate, custom.pcChannels[1].gate]
                custom.returnGateLinked = false
                let customRoundTrip = try JSONDecoder().decode(RedirectorConfiguration.self, from: Data(custom.json().utf8))
                guard customRoundTrip == custom else { throw ConfigurationError.invalid("Gate values were not preserved.") }
                let customEngine = try JSONSerialization.jsonObject(with: Data(custom.engineJSON().utf8)) as! [String: Any]
                guard let pcGate = (customEngine["pcChannels"] as? [[String: Any]])?[1]["gate"] as? [String: Any],
                      pcGate["thresholdDB"] as? Double == -72,
                      customEngine["returnGateLinked"] as? Bool == false,
                      (customEngine["returnGates"] as? [[String: Any]])?[0]["enabled"] as? Bool == false else {
                    throw ConfigurationError.invalid("Engine JSON lost Gate settings.")
                }
                let gateFields: [(WritableKeyPath<GateConfiguration, Float>, ClosedRange<Float>)] = [
                    (\.thresholdDB, GateConfiguration.thresholdRange), (\.attackMS, GateConfiguration.attackRange),
                    (\.holdMS, GateConfiguration.holdRange), (\.releaseMS, GateConfiguration.releaseRange),
                    (\.hysteresisDB, GateConfiguration.hysteresisRange)
                ]
                for (keyPath, range) in gateFields {
                    for value in [range.lowerBound, range.upperBound] {
                        var gate = GateConfiguration()
                        gate[keyPath: keyPath] = value
                        try gate.validate()
                    }
                    for value in [range.lowerBound.nextDown, range.upperBound.nextUp, Float.nan, .infinity, -.infinity] {
                        var gate = GateConfiguration(enabled: false)
                        gate[keyPath: keyPath] = value
                        try expectRejection("Gate range/non-finite") { try gate.validate() }
                    }
                }
                for count in [0, 1, 3] {
                    var invalid = config
                    invalid.returnGates = Array(repeating: GateConfiguration(), count: count)
                    try expectRejection("RETURN Gate count") { try invalid.validateStorage() }
                }
                for source in 0..<3 {
                    var invalid = legacyExpected
                    switch source {
                    case 0: invalid.rmeChannels[1].gate.thresholdDB = -45
                    case 1: invalid.pcChannels[1].gate.thresholdDB = -45
                    default: invalid.returnGates[1].thresholdDB = -45
                    }
                    try expectRejection("linked Gate mismatch") { try invalid.validateStorage() }
                }
                var invalid = config
                invalid.pcChannels[0].gate.thresholdDB = .nan
                try expectRejection("PC Gate non-finite") { _ = try invalid.engineJSON() }
                invalid = config
                invalid.returnGates[1].releaseMS = .infinity
                try expectRejection("RETURN Gate non-finite") { _ = try invalid.json() }
                let invalidJSON = [
                    #"{"schemaVersion":1,"returnGates":null}"#,
                    #"{"schemaVersion":1,"returnGates":[{"thresholdDB":1},{}]}"#,
                    #"{"schemaVersion":1,"returnGateLinked":"true"}"#,
                    #"{"schemaVersion":1,"rmeChannels":[{"channel":1,"gainDB":0,"pan":-1,"muted":true,"gate":null}]}"#,
                    #"{"schemaVersion":1,"returnGates":[{"enabled":null},{}]}"#
                ]
                for json in invalidJSON {
                    try expectRejection("saved Gate JSON") {
                        _ = try JSONDecoder().decode(RedirectorConfiguration.self, from: Data(json.utf8))
                    }
                }
                func validateBridge(_ json: String) throws {
                    var error = [CChar](repeating: 0, count: 1024)
                    let result = json.withCString { mr_validate_config_json($0, &error, 1024) }
                    guard result == 0 else { throw ConfigurationError.invalid("Bridge validation: \(String(cString: error))") }
                }
                try validateBridge(migrated.engineJSON())
                try validateBridge(custom.engineJSON())
                for useMaximum in [false, true] {
                    var boundary = legacyExpected
                    var gate = GateConfiguration()
                    for (keyPath, range) in gateFields { gate[keyPath: keyPath] = useMaximum ? range.upperBound : range.lowerBound }
                    for index in boundary.rmeChannels.indices { boundary.rmeChannels[index].gate = gate }
                    for index in boundary.pcChannels.indices { boundary.pcChannels[index].gate = gate }
                    boundary.returnGates = [gate, gate]
                    // In particular, Swift encodes the valid Float attack minimum as 0.1.
                    try validateBridge(boundary.engineJSON())
                }
                let validBridgeObject = try JSONSerialization.jsonObject(with: Data(legacyExpected.engineJSON().utf8)) as! [String: Any]
                var legacyBridgeObject = validBridgeObject
                for key in ["returnGates", "returnGateLinked", "rmeStereoLinks", "pcStereoLinks"] { legacyBridgeObject.removeValue(forKey: key) }
                for key in ["rmeChannels", "pcChannels"] {
                    legacyBridgeObject[key] = (legacyBridgeObject[key] as! [[String: Any]]).map { $0.filter { $0.key != "gate" } }
                }
                try validateBridge(String(decoding: JSONSerialization.data(withJSONObject: legacyBridgeObject), as: UTF8.self))
                func rejectBridgeMutation(_ name: String, _ mutate: (inout [String: Any]) -> Void) throws {
                    var object = validBridgeObject
                    mutate(&object)
                    let json = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
                    try expectRejection(name) { try validateBridge(json) }
                }
                let malformedGates: [[String: Any]] = [
                    ["attackMS": 0.099], ["releaseMS": 2001], ["thresholdDB": 1e300],
                    ["thresholdDB": "NaN"], ["enabled": 1], ["holdMS": NSNull()], ["unknownGateField": 1]
                ]
                for gate in malformedGates {
                    try rejectBridgeMutation("Bridge Gate parameter") { object in
                        var channels = object["pcChannels"] as! [[String: Any]]
                        channels[0]["gate"] = gate
                        object["pcChannels"] = channels
                    }
                }
                for links: [Any] in [[0], [2], [1, 1], [64], [65], [1.5], [true]] {
                    try rejectBridgeMutation("Bridge stereo links") { $0["rmeStereoLinks"] = links }
                }
                for count in [0, 1, 3] {
                    try rejectBridgeMutation("Bridge RETURN Gate count") { $0["returnGates"] = Array(repeating: [String: Any](), count: count) }
                }
                try rejectBridgeMutation("Bridge null RETURN Gate") { $0["returnGates"] = NSNull() }
                try rejectBridgeMutation("Bridge RETURN link type") { $0["returnGateLinked"] = 1 }
                for source in ["rmeChannels", "pcChannels"] {
                    try rejectBridgeMutation("Bridge linked Gate mismatch") { object in
                        var channels = object[source] as! [[String: Any]]
                        var gate = channels[1]["gate"] as! [String: Any]
                        gate["thresholdDB"] = -45
                        channels[1]["gate"] = gate
                        object[source] = channels
                    }
                }
                try rejectBridgeMutation("Bridge linked RETURN Gate mismatch") { object in
                    var gates = object["returnGates"] as! [[String: Any]]
                    gates[1]["thresholdDB"] = -45
                    object["returnGates"] = gates
                }
                // Meter source/channel offsets and zeroing are checked without an engine or HAL I/O.
                var rawMeters = MRMeterLevels()
                rawMeters.active = 1
                withUnsafeMutableBytes(of: &rawMeters.channelCounts) { bytes in
                    let values = bytes.bindMemory(to: UInt32.self)
                    values[0] = 20; values[1] = 20; values[2] = 2
                }
                withUnsafeMutableBytes(of: &rawMeters.inputPeaks) { bytes in
                    let values = bytes.bindMemory(to: Float.self)
                    values[0] = 0.125; values[Int(MR_METER_CHANNELS) + 1] = 0.25; values[2 * Int(MR_METER_CHANNELS) + 1] = 0.5
                }
                withUnsafeMutableBytes(of: &rawMeters.gateGains) { $0.bindMemory(to: Float.self)[2 * Int(MR_METER_CHANNELS) + 1] = 1 }
                withUnsafeMutableBytes(of: &rawMeters.outputPeaks) { bytes in
                    let values = bytes.bindMemory(to: Float.self); values[0] = 0.25; values[1] = 0.5
                }
                let meterCopy = MeterLevels(&rawMeters)
                guard meterCopy.active, meterCopy.inputPeaks.map(\.count) == [20, 20, 2],
                      meterCopy.inputPeaks[0][0] == 0.125, meterCopy.inputPeaks[1][1] == 0.25,
                      meterCopy.inputPeaks[2][1] == 0.5, meterCopy.gateGains[2][1] == 1,
                      meterCopy.outputPeaks == [0.25, 0.5] else {
                    throw ConfigurationError.invalid("Meter source/channel layout failed.")
                }
                mr_engine_copy_meters(nil, &rawMeters)
                let clearedMeters = MeterLevels(&rawMeters)
                guard !clearedMeters.active, clearedMeters.inputPeaks.allSatisfy(\.isEmpty), clearedMeters.outputPeaks == [0, 0] else {
                    throw ConfigurationError.invalid("Inactive meter copy was not cleared.")
                }
                let oldStats = SourceStatistics(["name": "RME", "peaks": [0.2]])
                let gateStats = SourceStatistics(["name": "PC", "gateGains": [0.25, 1.0]])
                guard oldStats.gateGains.isEmpty, gateStats.gateGains == [0.25, 1] else {
                    throw ConfigurationError.invalid("Gate telemetry compatibility failed.")
                }
                do {
                    _ = try JSONDecoder().decode(RedirectorConfiguration.self, from: Data("{\"schemaVersion\":2}".utf8))
                    throw ConfigurationError.invalid("Unknown schema was accepted.")
                } catch DecodingError.dataCorrupted { }
                catch ConfigurationError.invalid(let message) {
                    guard message.hasPrefix("未対応の設定バージョン") else { throw ConfigurationError.invalid(message) }
                }
                print("{\"selfTestConfig\":\"passed\",\"audioStarted\":false}")
                return 0
            } catch { writeError(error.localizedDescription); return 1 }
        }
        if arguments.first == "--probe-config", arguments.count >= 2 {
            let seconds: Double
            if arguments.count == 2 { seconds = 5 }
            else if arguments.count == 4, arguments[2] == "--seconds", let value = Double(arguments[3]), value.isFinite, (0.2...60).contains(value) { seconds = value }
            else { writeError("Use --probe-config PATH [--seconds 0.2...60]."); return 2 }
            do {
                let config = try JSONDecoder().decode(RedirectorConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
                let json = try config.engineJSON()
                return queue.sync {
                    guard let engine = mr_engine_create() else { writeError("Could not create engine."); return 1 }
                    defer { mr_engine_stop(engine); mr_engine_destroy(engine) }
                    var error = [CChar](repeating: 0, count: 4096)
                    let result = json.withCString { mr_engine_probe_start(engine, $0, &error, error.count) }
                    guard result == 0 else { writeError(String(cString: error)); return 1 }
                    let deadline = ProcessInfo.processInfo.systemUptime + seconds
                    var latest = "{}"
                    var failed = false
                    repeat {
                        if let pointer = mr_engine_status_json(engine) {
                            latest = String(cString: pointer)
                            mr_string_free(pointer)
                            if let state = try? EngineStatus(json: latest), state.state == "fault" {
                                failed = true
                                break
                            }
                        }
                        Thread.sleep(forTimeInterval: min(0.2, max(0, deadline - ProcessInfo.processInfo.systemUptime)))
                    } while ProcessInfo.processInfo.systemUptime < deadline
                    // Include callbacks delivered during the last polling interval.
                    if let pointer = mr_engine_status_json(engine) {
                        latest = String(cString: pointer)
                        mr_string_free(pointer)
                    }
                    if let finalStatus = try? EngineStatus(json: latest) {
                        if finalStatus.state == "fault" { failed = true }
                        if finalStatus.probeCallbacks == 0 {
                            writeError("PC capture delivered no callbacks within \(seconds) seconds. Capture remains unverified; check permission, device and stream. Status JSON follows on stdout.")
                            failed = true
                        }
                    } else {
                        writeError("Could not confirm capture callbacks from the final probe status.")
                        failed = true
                    }
                    print(latest)
                    return failed ? 1 : 0
                }
            } catch { writeError(error.localizedDescription); return 1 }
        }
        writeError("My Redirector: --inventory | --self-test-config | --probe-config PATH [--seconds 0.2...60] | --check-muted-route PATH [--seconds 0.2...60] [--stress-gates]")
        return arguments == ["--help"] ? 0 : 2
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
