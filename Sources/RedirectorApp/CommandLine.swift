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
        if arguments.first == "--check-muted-route", arguments.count >= 2 {
            let seconds: Double
            if arguments.count == 2 { seconds = 10 }
            else if arguments.count == 4, arguments[2] == "--seconds", let value = Double(arguments[3]), value.isFinite, (0.2...60).contains(value) { seconds = value }
            else { writeError("Use --check-muted-route PATH [--seconds 0.2...60]."); return 2 }
            return MutedRouteCheck.run(path: arguments[1], seconds: seconds)
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
                guard engine["rmeStereoLinks"] == nil, engine["rmeReturnLabels"] == nil, engine["rmeChannels"] != nil else {
                    throw ConfigurationError.invalid("Engine JSON contains UI-only state.")
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
        writeError("My Redirector: --inventory | --self-test-config | --probe-config PATH [--seconds 0.2...60] | --check-muted-route PATH [--seconds 0.2...60]")
        return arguments == ["--help"] ? 0 : 2
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
