import SwiftUI

private struct PeakMeter: View {
    let peak: Double?
    var body: some View {
        HStack(spacing: 5) {
            ProgressView(value: min(1, max(0, peak ?? 0)))
                .tint((peak ?? 0) >= 1 ? .red : .green)
                .frame(width: 65)
            Text(peak.map { $0 > 0.0000316 ? String(format: "%.1f", 20 * log10($0)) : "−∞" } ?? "—")
                .font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
        }.accessibilityLabel(peak.map { "ピーク \($0)" } ?? "ピーク未取得")
    }
}

struct MixerSettings: View {
    @ObservedObject var model: RedirectorModel
    var body: some View {
        ScrollView {
            // Keep channel rows as direct lazy children. A GroupBox around an
            // eager VStack forces every slider row through ideal-size fitting
            // when the tab is selected, even while most rows are offscreen.
            LazyVStack(alignment: .leading, spacing: 6) {
                channelGroup("RME INPUT", source: 0)
                channelGroup("PC OUTPUT", source: 1)
                GroupBox("2MIX → Discrete4 Computer Play 1/2") {
                    HStack {
                        Text("Master").frame(width: 150, alignment: .leading)
                        Slider(value: Binding(get: { Double(model.configuration.forwardGainDB) }, set: { model.changeMaster(forward: Float($0)) }), in: -90...12, step: 0.1)
                        Text(String(format: "%.1f dB", model.configuration.forwardGainDB)).monospacedDigit().frame(width: 76)
                        PeakMeter(peak: model.settingsVisible ? model.status.outputPeaks.max() : nil)
                    }.padding(8)
                }
                GroupBox("RETURN → 選択した RME 出力") {
                    HStack {
                        Text("Return").frame(width: 150, alignment: .leading)
                        Slider(value: Binding(get: { Double(model.configuration.returnGainDB) }, set: { model.changeMaster(returned: Float($0)) }), in: -90...12, step: 0.1)
                        Text(String(format: "%.1f dB", model.configuration.returnGainDB)).monospacedDigit().frame(width: 76)
                        Toggle("Mute", isOn: Binding(get: { model.configuration.returnMuted }, set: { model.changeMaster(muted: $0) })).toggleStyle(.checkbox)
                    }.padding(8)
                }
                Text("各入力と復路は初期状態で Mute です。Stereo Link は隣り合う L/R の gain と mute を連動し、左右の pan は保持します。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding()
        }.disabled(model.isProbing || model.storageBlocked)
    }

    private func channelGroup(_ title: String, source: Int) -> some View {
        Section {
            if model.channels(source: source).isEmpty {
                Text("入出力タブで取得元を選択してください。")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            ForEach(model.channels(source: source)) { channel in
                channelRow(channel, source: source)
                    .padding(.horizontal, 8)
                    .frame(height: 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .bottom) {
                        if channel.channel.isMultiple(of: 2) { Divider() }
                    }
            }
        } header: {
            Text(title).font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func channelRow(_ channel: ChannelConfiguration, source: Int) -> some View {
        let pair = channel.channel.isMultiple(of: 2) ? channel.channel - 1 : channel.channel
        let peerExists = model.channels(source: source).contains { $0.channel == pair + 1 }
        let stat = model.status.sources.first { $0.name.caseInsensitiveCompare(source == 0 ? "RME" : "PC") == .orderedSame }
        let peak = model.settingsVisible && (stat?.peaks.indices.contains(channel.channel - 1) ?? false) ? stat?.peaks[channel.channel - 1] : nil
        let label = channelLabel(source: source, channel: channel.channel)
        return HStack(spacing: 10) {
            Text(label).lineLimit(1).help(label)
                .frame(width: 155, alignment: .leading)
            Slider(value: Binding(get: { Double(channel.gainDB) }, set: { model.changeChannel(source: source, channel: channel.channel, gain: Float($0)) }), in: -90...12, step: 0.1)
                .frame(width: 145).accessibilityLabel("\(label) gain")
            Text(String(format: "%.1f", channel.gainDB)).monospacedDigit().frame(width: 43, alignment: .trailing)
            Text("dB").foregroundStyle(.secondary)
            Toggle("Mute", isOn: Binding(get: { channel.muted }, set: { model.changeChannel(source: source, channel: channel.channel, muted: $0) })).toggleStyle(.checkbox)
            Slider(value: Binding(get: { Double(channel.pan) }, set: { model.changeChannel(source: source, channel: channel.channel, pan: Float($0)) }), in: -1...1, step: 0.01)
                .frame(width: 68).accessibilityLabel("\(label) pan")
                .help("Pan: −1 = L、0 = 中央、1 = R")
            if channel.channel == pair && peerExists {
                Toggle("Link", isOn: Binding(get: { model.linked(source: source, pair: pair) }, set: { model.setLinked(source: source, pair: pair, linked: $0) }))
                    .toggleStyle(.checkbox).frame(width: 55).disabled(model.structuralLocked)
            } else { Color.clear.frame(width: 55, height: 16) }
            PeakMeter(peak: peak)
        }
    }

    private func channelLabel(source: Int, channel: Int) -> String {
        if source == 0 { return model.rmeDevice?.channelName(channel, input: true) ?? "Input \(channel)" }
        let hardwareChannel = (model.pcStream?.startingChannel ?? 1) + channel - 1
        return "Out " + (model.pcDevice?.channelName(hardwareChannel, input: false) ?? "\(hardwareChannel)")
    }
}

struct DiagnosticSettings: View {
    @ObservedObject var model: RedirectorModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label(stateLabel, systemImage: model.isRunning ? "waveform" : "circle")
                        .font(.headline)
                    Spacer()
                    Button("診断を書き出す…") { model.exportDiagnostics() }
                }
                GroupBox("実際の I/O") {
                    Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
                        GridRow { Text("RME"); Text(frames(model.status.rmeBufferFrames)) }
                        GridRow { Text("PC capture"); Text(frames(model.status.pcBufferFrames)) }
                        GridRow { Text("Discrete4"); Text(frames(model.status.d4BufferFrames)) }
                        GridRow { Text("Clip / 非有限値"); Text("\(model.status.clipped) / \(model.status.nonFinite)") }
                    }.monospacedDigit().frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                GroupBox("経路の状態") {
                    VStack(alignment: .leading, spacing: 10) {
                        if model.status.sources.isEmpty { Text("まだ経路の計測値はありません。").foregroundStyle(.secondary) }
                        ForEach(model.status.sources) { source in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.name).font(.headline)
                                Text("callbacks \(source.callbacks) · frames \(source.frames) · FIFO \(source.fifoFrames.map(String.init) ?? "未取得") · \(source.ppm.map { String(format: "%.2f ppm", $0) } ?? "ppm 未取得")")
                                Text("不足 \(source.underruns) / 超過 \(source.overflows)").foregroundStyle((source.underruns + source.overflows) > 0 ? .red : .secondary)
                            }.font(.caption.monospacedDigit())
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                GroupBox("PC 取得テスト") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("選択した PC device / stream の取得だけを開始します。RME・Discrete4 の物理 I/O を開かず、音声を出力しません。システム音声の取得許可が必要です。")
                        Text("元音声を抑える設定が ON の場合は、このテスト中も元の process 出力に影響します。")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(model.isProbing ? "取得テストを停止" : "PC取得テスト") {
                                if model.isProbing { model.stop() } else { model.startProbe() }
                            }.disabled((model.isActive && !model.isProbing) || model.refreshing || model.storageBlocked || model.pendingAction == "stopping")
                            Text("callbacks \(model.status.probeCallbacks) / frames \(model.status.probeFrames)")
                                .font(.caption.monospacedDigit())
                        }
                        if let format = model.status.probeFormat {
                            Text(format).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        if !model.status.probePeaks.isEmpty {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 175))], alignment: .leading) {
                                ForEach(Array(model.status.probePeaks.enumerated()), id: \.offset) { index, peak in
                                    HStack { Text("ch \(index + 1)").frame(width: 40); PeakMeter(peak: peak) }
                                }
                            }
                        }
                        Text("メーターが動くことと、正しいチャンネル対応・低遅延・長時間安定は別に確認します。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                Text("設定: \(model.configurationURL.path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("診断は 200 ms 間隔で更新します。音声内容は保存しません。表示される内部統計は実測の往復遅延ではありません。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding()
        }
    }

    private func frames(_ value: Int?) -> String { value.map { "\($0) frames" } ?? "未取得" }
    private var stateLabel: String {
        if let action = model.pendingAction {
            return action == "stopping" ? "停止中" : (action == "permission" ? "入力の許可を確認中" : "開始中")
        }
        switch model.status.state {
        case "running": return "ON · 転送中"
        case "priming": return "準備中"
        case "starting": return "開始中"
        case "probe": return "PC 取得テスト中"
        case "fault": return "OFF · エラー"
        default: return "OFF"
        }
    }
}
