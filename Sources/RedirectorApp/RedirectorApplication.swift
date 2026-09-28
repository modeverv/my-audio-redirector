import AppKit
import SwiftUI

@MainActor
final class RedirectorAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: RedirectorModel?
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Finder reads CFBundleIconFile; explicitly give the running app the
        // same multi-resolution image so Dock does not retain a generic icon.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
            NSApp.dockTile.display()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, !terminating else { return .terminateNow }
        terminating = true
        model.shutdown { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

@MainActor
struct RedirectorApplication: App {
    @NSApplicationDelegateAdaptor(RedirectorAppDelegate.self) private var delegate
    @StateObject private var model = RedirectorModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("My Redirector", id: "main") {
            MainWindow(model: model)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 270, height: 170)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .windowArrangement) {
                Button("メイン画面を表示") { openWindow(id: "main") }
            }
        }

        Settings {
            SettingsWindow(model: model)
                .onAppear { delegate.model = model; model.setSettingsVisible(true) }
                .onDisappear { model.setSettingsVisible(false) }
        }
    }
}

private struct MainWindow: View {
    @ObservedObject var model: RedirectorModel

    var body: some View {
        Button(action: model.toggleRouting) {
            Text(model.isRunning ? "ON" : "OFF")
                .font(.system(size: 48, weight: .semibold, design: .rounded))
                .frame(width: 210, height: 112)
                .foregroundStyle(model.isRunning ? Color.white : Color.primary)
                .background(model.isRunning ? Color.accentColor : Color.secondary.opacity(0.13), in: RoundedRectangle(cornerRadius: 20))
                .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .disabled(model.isTransitioning || model.isProbing || model.refreshing || model.storageBlocked)
        .accessibilityLabel(model.isRunning ? "音声転送を停止" : "音声転送を開始")
        .accessibilityValue(model.pendingAction ?? model.status.state)
        .help("設定: メニューの「設定…」または ⌘,")
        .padding(28)
        .alert("My Redirector", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
    }
}

struct SettingsWindow: View {
    @ObservedObject var model: RedirectorModel
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                Divider()
            }
            if model.storageBlocked {
                HStack {
                    Text("元の設定を退避し、すべてミュートの状態から設定を作り直せます。")
                    Button("設定を退避して再設定") { model.resetBrokenSettings() }
                }.padding()
            }
            Picker("設定画面", selection: $selectedTab) {
                Text("入出力").tag(0)
                Text("ミックス").tag(1)
                Text("動作").tag(2)
                Text("診断・取得テスト").tag(3)
            }.pickerStyle(.segmented).padding(12)
            // Create only the selected pane. SwiftUI's macOS Settings TabView
            // otherwise fits and traverses the offscreen mixer on tab changes.
            Group {
                switch selectedTab {
                case 1: MixerSettings(model: model)
                case 2: EngineSettings(model: model)
                case 3: DiagnosticSettings(model: model)
                default: RoutingSettings(model: model)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 12).padding(.bottom, 12)
        }
        .frame(minWidth: 880, idealWidth: 980, minHeight: 650, idealHeight: 740)
    }
}

private struct RoutingSettings: View {
    @ObservedObject var model: RedirectorModel

    var body: some View {
        Form {
            Section("RME") {
                DevicePicker(title: "RMEデバイス", selection: Binding(get: { model.configuration.rmeUID }, set: model.selectRME), devices: model.inventory.devices)
                DeviceFacts(device: model.rmeDevice)
                HStack {
                    channelPicker("復路 L", key: \.rmeReturnLeft, device: model.rmeDevice, input: false)
                    channelPicker("復路 R", key: \.rmeReturnRight, device: model.rmeDevice, input: false)
                }
                Text("復路は RME の Software Playback チャンネルを選びます。物理端子への TotalMix ルーティングは別設定です。AES 11/12 は初期候補です。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Discrete4") {
                DevicePicker(title: "Discrete4デバイス", selection: Binding(get: { model.configuration.d4UID }, set: model.selectD4), devices: model.inventory.devices)
                DeviceFacts(device: model.d4Device)
                LabeledContent("送信先", value: "Computer Play 1/2")
                HStack {
                    channelPicker("処理後入力 L", key: \.d4ReturnLeft, device: model.d4Device, input: true)
                    channelPicker("処理後入力 R", key: \.d4ReturnRight, device: model.d4Device, input: true)
                }
                Text("Discrete4 内の処理済みミックスを DAW Record Loopback へ割り当て、その USB 入力を選択します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("PC 音声") {
                DevicePicker(title: "PC の再生先", selection: Binding(get: { model.configuration.pcUID }, set: model.selectPC), devices: model.inventory.devices.filter { ($0.outputChannels ?? 0) > 0 })
                Picker("出力 stream", selection: Binding(get: { model.configuration.pcStreamIndex }, set: model.selectPCStream)) {
                    if !(model.pcDevice?.outputStreams ?? []).contains(where: { $0.index == model.configuration.pcStreamIndex }) {
                        Text("未確認: stream \(model.configuration.pcStreamIndex)").tag(model.configuration.pcStreamIndex)
                    }
                    ForEach(model.pcDevice?.outputStreams ?? [], id: \.index) { stream in
                        Text("\(stream.index): ch \(stream.startingChannel ?? 1)〜 · \(stream.channels.map(String.init) ?? "?")ch · \(stream.format ?? "形式未取得")").tag(stream.index)
                    }
                }
                Text("再生先へ送られる音をチャンネル別に取得します。RME Loopback は使用しません。自分が RME へ返す音声は取得対象から除外します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button(model.refreshing ? "取得中…" : "デバイス一覧を更新") { model.refreshInventory() }
                    Button("表示中の対応を確認") { model.confirmChannelMapping() }
                    Spacer()
                    Text(model.isActive ? "経路変更は OFF 中のみ" : "この画面の操作では音声は開始しません")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.structuralLocked || model.storageBlocked)
    }

    private func channelPicker(_ title: String, key: WritableKeyPath<RedirectorConfiguration, Int>, device: AudioDeviceInventory?, input: Bool) -> some View {
        let count = input ? device?.inputChannels ?? 0 : device?.outputChannels ?? 0
        let selected = model.configuration[keyPath: key]
        return Picker(title, selection: Binding(get: { model.configuration[keyPath: key] }, set: { model.setReturnChannel(key, value: $0) })) {
            if selected < 1 || selected > count { Text("未確認: \(selected)").tag(selected) }
            ForEach(1..<max(2, count + 1), id: \.self) { channel in
                if channel <= count { Text(device?.channelName(channel, input: input) ?? "\(channel)").tag(channel) }
            }
        }
    }
}

private struct DevicePicker: View {
    let title: String
    @Binding var selection: String
    let devices: [AudioDeviceInventory]

    var body: some View {
        Picker(title, selection: $selection) {
            Text("選択してください").tag("")
            if !selection.isEmpty && !devices.contains(where: { $0.uid == selection }) {
                Text("未接続: \(selection)").tag(selection)
            }
            ForEach(devices) { device in Text(device.name + (device.alive == false ? "（停止中）" : "")).tag(device.uid) }
        }
    }
}

private struct DeviceFacts: View {
    let device: AudioDeviceInventory?
    var body: some View {
        if let device {
            Text("入力 \(device.inputChannels.map(String.init) ?? "未取得")ch / 出力 \(device.outputChannels.map(String.init) ?? "未取得")ch · \(device.sampleRate.map { String(format: "%.1f kHz", $0 / 1000) } ?? "rate 未取得") · I/O \(device.bufferFrames.map(String.init) ?? "未取得") frames")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

private struct EngineSettings: View {
    @ObservedObject var model: RedirectorModel
    var body: some View {
        Form {
            Section("形式と待ち量") {
                LabeledContent("動作レート", value: "48 kHz")
                Text("開始時に実際の形式を確認します。機器のクロック、サンプルレート、macOS の既定出力は自動変更しません。")
                    .font(.caption).foregroundStyle(.secondary)
                framePicker("要求 I/O", key: \.bufferFrames, choices: [16, 32, 64, 128, 256, 512])
                framePicker("RME → D4 FIFO", key: \.rmeFifoFrames, choices: [16, 32, 64, 128, 256, 512, 1024])
                framePicker("PC → D4 FIFO", key: \.pcFifoFrames, choices: [16, 32, 64, 128, 256, 512, 1024])
                framePicker("D4 → RME FIFO", key: \.returnFifoFrames, choices: [16, 32, 64, 128, 256, 512, 1024])
                Picker("SRC 品質", selection: Binding(get: { model.configuration.srcQuality }, set: { value in model.editStructure { $0.srcQuality = value } })) {
                    Text("Fastest").tag("fastest")
                    Text("Medium").tag("medium")
                }
                Text("FIFO の数値は source frames。SRC 内部の先読みや機器の遅延は別です。I/O 64 は経路全体 64 samples を意味しません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("元の PC 再生音") {
                Toggle("取得中は元の process 出力を抑える", isOn: Binding(get: { model.configuration.tapMuteOriginal }, set: { value in model.editStructure { $0.tapMuteOriginal = value } }))
                Text("既定は OFF（Unmuted）です。ON は Tap の MutedWhenTapped を指定します。同じアプリの他用途への影響と、開始・停止時の元音声を確認してください。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("起動") {
                LabeledContent("起動時の転送", value: "OFF")
                Text("設定だけを復元します。音声転送や取得テストは明示操作で開始します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).disabled(model.structuralLocked || model.storageBlocked)
    }

    private func framePicker(_ title: String, key: WritableKeyPath<RedirectorConfiguration, Int>, choices: [Int]) -> some View {
        Picker(title, selection: Binding(get: { model.configuration[keyPath: key] }, set: { value in model.editStructure { $0[keyPath: key] = value } })) {
            if !choices.contains(model.configuration[keyPath: key]) {
                Text("保存値: \(model.configuration[keyPath: key]) frames").tag(model.configuration[keyPath: key])
            }
            ForEach(choices, id: \.self) { frames in
                Text("\(frames) samples / \(String(format: "%.2f", Double(frames) / 48)) ms").tag(frames)
            }
        }
    }
}
