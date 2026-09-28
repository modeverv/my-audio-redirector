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

private enum MixerRow: Identifiable {
    case sourceHeader(Int)
    case emptySource(Int)
    case channel(source: Int, value: ChannelConfiguration)
    case master
    case returned
    case explanation

    var id: String {
        switch self {
        case .sourceHeader(let source): return "source-\(source)-header"
        case .emptySource(let source): return "source-\(source)-empty"
        case .channel(let source, let channel): return "source-\(source)-channel-\(channel.channel)"
        case .master: return "master"
        case .returned: return "return"
        case .explanation: return "explanation"
        }
    }
}

struct MixerSettings: View {
    @ObservedObject var model: RedirectorModel

    private var rows: [MixerRow] {
        var result: [MixerRow] = []
        for source in 0...1 {
            result.append(.sourceHeader(source))
            let channels = model.channels(source: source)
            if channels.isEmpty { result.append(.emptySource(source)) }
            result.append(contentsOf: channels.map { .channel(source: source, value: $0) })
        }
        result.append(contentsOf: [.master, .returned, .explanation])
        return result
    }

    var body: some View {
        ScrollView {
            // A single flat collection gives every lazy child a unique identity,
            // including when both sources have the same channel numbers/device.
            // Fixed channel dimensions avoid eager fitting of all slider rows.
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(rows) { row in mixerRow(row) }
            }.padding()
        }.disabled(model.isProbing || model.storageBlocked)
    }

    @ViewBuilder
    private func mixerRow(_ row: MixerRow) -> some View {
        switch row {
        case .sourceHeader(let source):
            sourceHeader(source)
        case .emptySource:
            Text("入出力タブで取得元を選択してください。")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding()
        case .channel(let source, let channel):
            channelRow(channel, source: source)
                .padding(.horizontal, 8)
                .frame(height: 40)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) {
                    if channel.channel.isMultiple(of: 2) { Divider() }
                }
        case .master:
            GroupBox("2MIX → Discrete4 Computer Play 1/2") {
                HStack {
                    Text("Master").frame(width: 150, alignment: .leading)
                    Slider(value: Binding(get: { Double(model.configuration.forwardGainDB) }, set: { model.changeMaster(forward: Float($0)) }), in: -90...12, step: 0.1)
                        .frame(width: 145)
                    Text(String(format: "%.1f dB", model.configuration.forwardGainDB)).monospacedDigit().frame(width: 76)
                    PeakMeter(peak: model.settingsVisible ? model.status.outputPeaks.first : nil)
                }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 36).padding(8)
            }
        case .returned:
            GroupBox("RETURN → 選択した RME 出力") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Return").frame(width: 150, alignment: .leading)
                        Slider(value: Binding(get: { Double(model.configuration.returnGainDB) }, set: { model.changeMaster(returned: Float($0)) }), in: -90...12, step: 0.1)
                            .frame(width: 145)
                        Text(String(format: "%.1f dB", model.configuration.returnGainDB)).monospacedDigit().frame(width: 76)
                        Toggle("Mute", isOn: Binding(get: { model.configuration.returnMuted }, set: { model.changeMaster(muted: $0) })).toggleStyle(.checkbox)
                    }.frame(height: 36)
                    Text("Discrete4 USB \(model.configuration.d4ReturnLeft)/\(model.configuration.d4ReturnRight) → RME host \(model.configuration.rmeReturnLeft)/\(model.configuration.rmeReturnRight)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(height: 16)
                    HStack {
                        Text("USB入力（Mute前）").frame(width: 150, alignment: .leading)
                        Text("L / ch \(model.configuration.d4ReturnLeft)").frame(width: 60)
                        PeakMeter(peak: returnInputPeak(0))
                        Text("R / ch \(model.configuration.d4ReturnRight)").frame(width: 60)
                        PeakMeter(peak: returnInputPeak(1))
                    }.font(.caption).frame(height: 22)
                        .help("選択したDiscrete4 USB入力を取得した直後の値です。ASRC・Return gain・Muteより前のL/Rを表示します。")
                    HStack {
                        Text("RME送出（L/R最大）").frame(width: 150, alignment: .leading)
                        PeakMeter(peak: returnOutputPeak)
                        Text("ASRC・gain・Mute後").foregroundStyle(.secondary)
                    }.font(.caption).frame(height: 22)
                        .help("アプリ側の復路出力バッファのピークです。TotalMixの物理出力へ届いたことを示すメーターではありません。")
                }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 114).padding(8)
            }
        case .explanation:
            Text("初期状態は全入力・復路が Mute、pan は奇数=L・偶数=Rです。Link は隣り合うペアの gain と Mute を連動します。Pan は各ch独立で、L=左、C=中央、R=右です。保存した Pan を自動で変更することはありません。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func returnInputPeak(_ index: Int) -> Double? {
        guard model.settingsVisible,
              let source = model.status.sources.first(where: { $0.name.caseInsensitiveCompare("Return") == .orderedSame }),
              source.peaks.indices.contains(index) else { return nil }
        return source.peaks[index]
    }

    private var returnOutputPeak: Double? {
        guard model.settingsVisible, model.status.outputPeaks.indices.contains(1) else { return nil }
        return model.status.outputPeaks[1]
    }

    private func sourceHeader(_ source: Int) -> some View {
        let channels = model.channels(source: source)
        let deviceName = (source == 0 ? model.rmeDevice?.name : model.pcDevice?.name) ?? "未選択"
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(source == 0 ? "RME INPUT — 物理入力" : "PC OUTPUT — PC再生出力").font(.headline)
                Text("\(channels.count) ch").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Panを奇数L・偶数Rに戻す") { resetPan(source: source) }
                    .controlSize(.small)
                    .disabled(model.structuralLocked || channels.isEmpty)
                    .help("この取得元の Pan だけを初期配置へ戻します。Gain、Mute、Link は変更しません。OFF中のみ操作できます。")
            }
            Text(source == 0
                 ? "\(deviceName) の入力端子から来る音。PCの再生音は下の PC OUTPUT で調整します。"
                 : "\(deviceName) / stream \(model.configuration.pcStreamIndex) へアプリ・DAWが送る音。RME INPUTとは別の取得元です。")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private func resetPan(source: Int) {
        guard !model.structuralLocked else { return }
        for channel in model.channels(source: source) {
            let defaultPan: Float = channel.channel.isMultiple(of: 2) ? 1 : -1
            if channel.pan != defaultPan {
                model.changeChannel(source: source, channel: channel.channel, pan: defaultPan)
            }
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
                .frame(width: 125).accessibilityLabel("\(label) gain")
            Text(String(format: "%.1f", channel.gainDB)).monospacedDigit().frame(width: 43, alignment: .trailing)
            Text("dB").foregroundStyle(.secondary)
            Toggle("Mute", isOn: Binding(get: { channel.muted }, set: { model.changeChannel(source: source, channel: channel.channel, muted: $0) })).toggleStyle(.checkbox)
            VStack(spacing: 0) {
                Text("Pan  L · C · R").font(.caption2).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Slider(value: Binding(get: { Double(channel.pan) }, set: { model.changeChannel(source: source, channel: channel.channel, pan: Float($0)) }), in: -1...1, step: 0.01)
                        .frame(width: 68).accessibilityLabel("\(label) Pan")
                        .accessibilityValue(panLabel(channel.pan))
                    Text(panLabel(channel.pan)).font(.caption2.monospacedDigit()).frame(width: 36, alignment: .trailing)
                }
            }.frame(width: 108, height: 34)
                .help("L = 左、C = 中央、R = 右。数字は左右への振り幅（%）です。")
            if channel.channel == pair && peerExists {
                Toggle("Link", isOn: Binding(get: { model.linked(source: source, pair: pair) }, set: { model.setLinked(source: source, pair: pair, linked: $0) }))
                    .toggleStyle(.checkbox).frame(width: 55).disabled(model.structuralLocked)
            } else { Color.clear.frame(width: 55, height: 16) }
            PeakMeter(peak: peak)
        }
    }

    private func panLabel(_ pan: Float) -> String {
        if abs(pan) < 0.005 { return "C" }
        return "\(pan < 0 ? "L" : "R") \(Int((abs(pan) * 100).rounded()))"
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
