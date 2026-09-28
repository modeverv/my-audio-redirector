import AppKit
import AVFoundation
import Combine
import Foundation
import RedirectorBridge

final class BridgeController: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.my-redirector.bridge-control", qos: .userInitiated)
    private var engine: OpaquePointer?
    private var timer: DispatchSourceTimer?
    var onStatus: ((String) -> Void)?

    private func takeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
        guard let pointer else { return "{}" }
        defer { mr_string_free(pointer) }
        return String(cString: pointer)
    }

    func inventory(completion: @escaping (String) -> Void) {
        queue.async { completion(self.takeString(mr_inventory_json())) }
    }

    func start(json: String, probe: Bool, completion: @escaping (String?) -> Void) {
        queue.async {
            if self.engine == nil { self.engine = mr_engine_create() }
            guard let engine = self.engine else {
                completion("音声エンジンを作成できませんでした。")
                return
            }
            var error = [CChar](repeating: 0, count: 4096)
            let result = json.withCString { configuration in
                if probe { return mr_engine_probe_start(engine, configuration, &error, error.count) }
                return mr_engine_start(engine, configuration, &error, error.count)
            }
            let message = String(cString: error)
            completion(result == 0 ? nil : (message.isEmpty ? "音声の開始に失敗しました。" : message))
            self.onStatus?(self.takeString(mr_engine_status_json(engine)))
            self.startTimer()
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200), leeway: .milliseconds(20))
        source.setEventHandler { [weak self] in
            guard let self, let engine = self.engine else { return }
            self.onStatus?(self.takeString(mr_engine_status_json(engine)))
        }
        timer = source
        source.resume()
    }

    func stop(completion: @escaping () -> Void = {}) {
        queue.async {
            if let engine = self.engine {
                mr_engine_stop(engine)
                self.onStatus?(self.takeString(mr_engine_status_json(engine)))
            }
            completion()
        }
    }

    func setChannels(source: Int, channels: [ChannelConfiguration]) {
        queue.async {
            guard let engine = self.engine else { return }
            for channel in channels where channel.channel > 0 {
                mr_engine_set_channel(engine, UInt32(source), UInt32(channel.channel - 1), channel.gainDB, channel.pan, channel.muted ? 1 : 0)
            }
        }
    }

    func setMaster(forward: Float, returned: Float, muted: Bool) {
        queue.async {
            guard let engine = self.engine else { return }
            mr_engine_set_master(engine, forward, returned, muted ? 1 : 0)
        }
    }

    func shutdown(completion: @escaping () -> Void) {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            if let engine = self.engine {
                mr_engine_stop(engine)
                mr_engine_destroy(engine)
                self.engine = nil
            }
            completion()
        }
    }
}

@MainActor
final class RedirectorModel: ObservableObject {
    @Published var configuration = RedirectorConfiguration()
    @Published private(set) var inventory = AudioInventory.empty
    @Published private(set) var status = EngineStatus()
    @Published private(set) var refreshing = false
    @Published private(set) var pendingAction: String?
    @Published var alertMessage: String?
    @Published private(set) var lastError: String?
    @Published private(set) var settingsVisible = false
    @Published private(set) var storageBlocked = false

    private let bridge = BridgeController()
    private let persistenceQueue = DispatchQueue(label: "local.my-redirector.configuration", qos: .utility)
    private var saveWork: DispatchWorkItem?
    private var lastStatusJSON = "{}"
    private var lastInventoryJSON = "{}"
    private var lastFaultMessage: String?
    private var shuttingDown = false
    let configurationURL: URL

    var isRunning: Bool { status.state == "running" }
    var isProbing: Bool { status.state == "probe" || pendingAction == "probe" }
    var isTransitioning: Bool { pendingAction != nil || ["starting", "priming"].contains(status.state) }
    var isActive: Bool { pendingAction != nil || ["starting", "priming", "running", "probe"].contains(status.state) }
    var structuralLocked: Bool { isActive || refreshing }
    var rmeDevice: AudioDeviceInventory? { device(configuration.rmeUID) }
    var d4Device: AudioDeviceInventory? { device(configuration.d4UID) }
    var pcDevice: AudioDeviceInventory? { device(configuration.pcUID) }
    var pcStream: AudioStreamInventory? { pcDevice?.outputStreams?.first { $0.index == configuration.pcStreamIndex } }

    init() {
        configurationURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("My Redirector", isDirectory: true).appendingPathComponent("configuration.json")
        if FileManager.default.fileExists(atPath: configurationURL.path) {
            do { configuration = try JSONDecoder().decode(RedirectorConfiguration.self, from: Data(contentsOf: configurationURL)) }
            catch {
                storageBlocked = true
                lastError = "保存設定を読み込めません。元ファイルを保持しています。設定画面で再設定してください。\n\(error.localizedDescription)"
                alertMessage = lastError
            }
        }
        bridge.onStatus = { [weak self] json in
            Task { @MainActor [weak self] in self?.receiveStatus(json) }
        }
        refreshInventory()
    }

    func device(_ uid: String) -> AudioDeviceInventory? { inventory.devices.first { $0.uid == uid } }

    func refreshInventory() {
        guard !isActive, !refreshing else { return }
        refreshing = true
        bridge.inventory { [weak self] json in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshing = false
                self.lastInventoryJSON = json
                do {
                    self.inventory = try JSONDecoder().decode(AudioInventory.self, from: Data(json.utf8))
                    if let error = self.inventory.error { self.report(error) }
                    self.fillMissingChannels()
                } catch { self.report("デバイス一覧を取得できませんでした。\n\(error.localizedDescription)") }
            }
        }
    }

    private func receiveStatus(_ json: String) {
        lastStatusJSON = json
        do {
            let next = try EngineStatus(json: json)
            if status != next { status = next }
            if let error = next.error, !error.isEmpty, next.state == "fault", error != lastFaultMessage {
                lastFaultMessage = error
                report(error)
            }
        } catch { report("エンジン状態の解析に失敗しました。\n\(error.localizedDescription)") }
    }

    func report(_ message: String) {
        lastError = message
        alertMessage = message
    }

    func setSettingsVisible(_ visible: Bool) { settingsVisible = visible }

    func editStructure(_ change: (inout RedirectorConfiguration) -> Void, refreshChannels: Bool = false) {
        guard !structuralLocked else { return }
        change(&configuration)
        if refreshChannels { fillMissingChannels() }
        saveConfiguration()
    }

    func selectRME(_ uid: String) {
        editStructure({ config in
            config.rmeUID = uid
            config.rmeChannels = []
            config.rmeStereoLinks = []
            config.rmeReturnLabels = []
            config.rmeReturnStreamIndices = []
            config.rmeReturnStreamStarts = []
        }, refreshChannels: true)
        confirmChannelMapping(rme: true, d4: false, pc: false)
    }

    func selectD4(_ uid: String) {
        editStructure { $0.d4UID = uid; $0.d4ReturnLabels = [] }
        confirmChannelMapping(rme: false, d4: true, pc: false)
    }

    func selectPC(_ uid: String) {
        editStructure({ config in
            config.pcUID = uid
            config.pcStreamIndex = 0
            config.pcChannels = []
            config.pcStereoLinks = []
            config.pcStreamChannelCount = nil
            config.pcStreamStartingChannel = nil
        }, refreshChannels: true)
        confirmChannelMapping(rme: false, d4: false, pc: true)
    }

    func selectPCStream(_ index: Int) {
        editStructure({ config in
            config.pcStreamIndex = index
            config.pcChannels = []
            config.pcStereoLinks = []
            config.pcStreamChannelCount = nil
            config.pcStreamStartingChannel = nil
        }, refreshChannels: true)
        confirmChannelMapping(rme: false, d4: false, pc: true)
    }

    private func fillMissingChannels() {
        func filled(_ existing: [ChannelConfiguration], count: Int) -> [ChannelConfiguration] {
            guard count > 0 else { return existing }
            var result = existing
            let known = Set(existing.map(\.channel))
            for channel in 1...count where !known.contains(channel) { result.append(ChannelConfiguration(channel: channel)) }
            return result.sorted { $0.channel < $1.channel }
        }
        configuration.rmeChannels = filled(configuration.rmeChannels, count: rmeDevice?.inputChannels ?? 0)
        configuration.pcChannels = filled(configuration.pcChannels, count: pcStream?.channels ?? 0)
    }

    func confirmChannelMapping(rme: Bool = true, d4: Bool = true, pc: Bool = true) {
        guard !structuralLocked else { return }
        if rme, let rme = rmeDevice {
            let channels = [configuration.rmeReturnLeft, configuration.rmeReturnRight]
            configuration.rmeReturnLabels = channels.map { rme.channelName($0, input: false) }
            let streams = channels.map { channel in
                rme.outputStreams?.first { stream in
                    guard let start = stream.startingChannel, let count = stream.channels else { return false }
                    return channel >= start && channel < start + count
                }
            }
            configuration.rmeReturnStreamIndices = streams.map { $0?.index ?? -1 }
            configuration.rmeReturnStreamStarts = streams.map { $0?.startingChannel ?? -1 }
        }
        if d4, let d4 = d4Device {
            configuration.d4ReturnLabels = [configuration.d4ReturnLeft, configuration.d4ReturnRight].map { d4.channelName($0, input: true) }
        }
        if pc {
            configuration.pcStreamChannelCount = pcStream?.channels
            configuration.pcStreamStartingChannel = pcStream?.startingChannel
        }
        saveConfiguration()
    }

    func setReturnChannel(_ key: WritableKeyPath<RedirectorConfiguration, Int>, value: Int) {
        editStructure { $0[keyPath: key] = value }
        let changesRME = key == \.rmeReturnLeft || key == \.rmeReturnRight
        confirmChannelMapping(rme: changesRME, d4: !changesRME, pc: false)
    }

    func channels(source: Int) -> [ChannelConfiguration] { source == 0 ? configuration.rmeChannels : configuration.pcChannels }
    func linked(source: Int, pair: Int) -> Bool {
        (source == 0 ? configuration.rmeStereoLinks : configuration.pcStereoLinks).contains(pair)
    }

    func setLinked(source: Int, pair: Int, linked: Bool) {
        guard !structuralLocked else { return }
        var links = source == 0 ? configuration.rmeStereoLinks : configuration.pcStereoLinks
        links.removeAll { $0 == pair }
        if linked { links.append(pair) }
        if source == 0 { configuration.rmeStereoLinks = links } else { configuration.pcStereoLinks = links }
        if linked, let first = channels(source: source).first(where: { $0.channel == pair }) {
            changeChannel(source: source, channel: pair, gain: first.gainDB, muted: first.muted)
        } else { saveConfiguration() }
    }

    func changeChannel(source: Int, channel: Int, gain: Float? = nil, pan: Float? = nil, muted: Bool? = nil) {
        guard !isProbing else { return }
        var list = channels(source: source)
        let pair = channel.isMultiple(of: 2) ? channel - 1 : channel
        let group = linked(source: source, pair: pair) && (gain != nil || muted != nil) ? [pair, pair + 1] : [channel]
        var changes: [ChannelConfiguration] = []
        for index in list.indices where group.contains(list[index].channel) {
            if let gain { list[index].gainDB = gain }
            if let muted { list[index].muted = muted }
            if list[index].channel == channel, let pan { list[index].pan = pan }
            changes.append(list[index])
        }
        if source == 0 { configuration.rmeChannels = list } else { configuration.pcChannels = list }
        bridge.setChannels(source: source, channels: changes)
        saveConfiguration()
    }

    func changeMaster(forward: Float? = nil, returned: Float? = nil, muted: Bool? = nil) {
        guard !isProbing else { return }
        if let forward { configuration.forwardGainDB = forward }
        if let returned { configuration.returnGainDB = returned }
        if let muted { configuration.returnMuted = muted }
        bridge.setMaster(forward: configuration.forwardGainDB, returned: configuration.returnGainDB, muted: configuration.returnMuted)
        saveConfiguration()
    }

    private func validateSelection(probe: Bool) throws {
        guard !storageBlocked else { throw ConfigurationError.invalid("保存設定の読み込みエラーを設定画面で解決してください。") }
        try configuration.validateStorage()
        guard let pc = pcDevice, pc.alive != false, let stream = pcStream, let pcCount = stream.channels, pcCount > 0 else {
            throw ConfigurationError.invalid("PC取得デバイスと出力streamを選択してください。保存された選択が見つからない場合は再選択が必要です。")
        }
        guard configuration.pcStreamChannelCount == pcCount, configuration.pcStreamStartingChannel == stream.startingChannel else {
            throw ConfigurationError.invalid("PC streamの対応が未確認、または変更されています。設定画面の「表示中の対応を確認」を実行してください。")
        }
        if probe { return }
        guard let rme = rmeDevice, let d4 = d4Device, rme.alive != false, d4.alive != false, rme.uid != d4.uid else {
            throw ConfigurationError.invalid("接続中のRMEとDiscrete4をそれぞれ選択してください。")
        }
        let rmeLR = [configuration.rmeReturnLeft, configuration.rmeReturnRight]
        let d4LR = [configuration.d4ReturnLeft, configuration.d4ReturnRight]
        guard rmeLR[0] != rmeLR[1], d4LR[0] != d4LR[1],
              rmeLR.allSatisfy({ $0 <= (rme.outputChannels ?? 0) }),
              d4LR.allSatisfy({ $0 <= (d4.inputChannels ?? 0) }), (d4.outputChannels ?? 0) >= 2 else {
            throw ConfigurationError.invalid("復路の左右チャンネルが重複、範囲外、または機器に存在しません。別チャンネルへ自動変更はしません。")
        }
        guard configuration.rmeReturnLabels == rmeLR.map({ rme.channelName($0, input: false) }),
              configuration.d4ReturnLabels == d4LR.map({ d4.channelName($0, input: true) }) else {
            throw ConfigurationError.invalid("保存したチャンネル名と現在の対応が異なります。出力先を確認してから「表示中の対応を確認」を実行してください。")
        }
        let streamPairs = rmeLR.map { channel in
            rme.outputStreams?.first { item in
                guard let start = item.startingChannel, let count = item.channels else { return false }
                return channel >= start && channel < start + count
            }
        }
        guard streamPairs.allSatisfy({ $0 != nil }),
              configuration.rmeReturnStreamIndices == streamPairs.map({ $0?.index ?? -1 }),
              configuration.rmeReturnStreamStarts == streamPairs.map({ $0?.startingChannel ?? -1 }) else {
            throw ConfigurationError.invalid("RME復路のstream mappingが変わりました。設定画面で再確認してください。")
        }
        guard configuration.rmeChannels.allSatisfy({ $0.channel <= (rme.inputChannels ?? 0) }),
              configuration.pcChannels.allSatisfy({ $0.channel <= pcCount }) else {
            throw ConfigurationError.invalid("保存された入力チャンネルが現在の形式にありません。取得元を再選択してください。")
        }
    }

    func toggleRouting() {
        if isRunning { stop() } else if !isActive { requestRouting() }
    }

    private func requestRouting() {
        do { try validateSelection(probe: false) } catch { report(error.localizedDescription); return }
        pendingAction = "permission"
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: begin(probe: false)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if allowed { self.begin(probe: false) }
                    else { self.pendingAction = nil; self.report("マイク／音声入力の許可が必要です。システム設定のプライバシーとセキュリティで確認してください。") }
                }
            }
        default:
            pendingAction = nil
            report("マイク／音声入力の許可がありません。システム設定のプライバシーとセキュリティで許可してください。")
        }
    }

    func startProbe() {
        guard !isActive else { return }
        do { try validateSelection(probe: true); begin(probe: true) }
        catch { report(error.localizedDescription) }
    }

    private func begin(probe: Bool) {
        guard !shuttingDown else { pendingAction = nil; return }
        do {
            let json = try configuration.engineJSON()
            pendingAction = probe ? "probe" : "routing"
            lastFaultMessage = nil
            lastError = nil
            bridge.start(json: json, probe: probe) { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.pendingAction = nil
                    if let error { self?.report(error) }
                }
            }
        } catch { pendingAction = nil; report(error.localizedDescription) }
    }

    func stop() {
        guard pendingAction != "stopping" else { return }
        pendingAction = "stopping"
        bridge.stop { [weak self] in Task { @MainActor [weak self] in self?.pendingAction = nil } }
    }

    func resetBrokenSettings() {
        guard !isActive else { return }
        do {
            if FileManager.default.fileExists(atPath: configurationURL.path) {
                let suffix = String(Int(Date().timeIntervalSince1970))
                try FileManager.default.moveItem(at: configurationURL, to: configurationURL.deletingLastPathComponent().appendingPathComponent("configuration.invalid-\(suffix).json"))
            }
            configuration = RedirectorConfiguration()
            storageBlocked = false
            lastError = nil
            saveConfiguration()
        } catch { report("元の設定を退避できませんでした。\n\(error.localizedDescription)") }
    }

    private func saveConfiguration() {
        guard !storageBlocked else { return }
        do {
            let data = Data(try configuration.json().utf8)
            let url = configurationURL
            saveWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                } catch {
                    Task { @MainActor [weak self] in self?.report("設定を保存できませんでした。\n\(error.localizedDescription)") }
                }
            }
            saveWork = work
            persistenceQueue.asyncAfter(deadline: .now() + .milliseconds(350), execute: work)
        } catch { report(error.localizedDescription) }
    }

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "my-redirector-diagnostics.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let content: [String: Any] = [
                "exportedAt": ISO8601DateFormatter().string(from: Date()),
                "configuration": try JSONSerialization.jsonObject(with: Data(configuration.json().utf8)),
                "inventory": try JSONSerialization.jsonObject(with: Data(lastInventoryJSON.utf8)),
                "status": try JSONSerialization.jsonObject(with: Data(lastStatusJSON.utf8)),
                "lastError": lastError as Any? ?? NSNull(),
                "note": "音声データは含みません。内部統計は物理経路の実測遅延ではありません。"
            ]
            let data = try JSONSerialization.data(withJSONObject: content, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch { report("診断を書き出せませんでした。\n\(error.localizedDescription)") }
    }

    func shutdown(completion: @escaping () -> Void) {
        shuttingDown = true
        saveWork?.cancel()
        if !storageBlocked, let json = try? configuration.json() {
            let url = configurationURL
            persistenceQueue.async {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data(json.utf8).write(to: url, options: .atomic)
            }
        }
        let persistenceQueue = self.persistenceQueue
        bridge.shutdown { persistenceQueue.async { DispatchQueue.main.async(execute: completion) } }
    }
}
