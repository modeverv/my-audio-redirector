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

// The mixer owns a reusable AppKit table. Telemetry never reconstructs a
// SwiftUI tree of sliders; only cells already visible in the table are painted.
struct MixerSettings: View {
    let model: RedirectorModel
    var body: some View { NativeMixerView(model: model) }
}

// Keep the accessibility hierarchy to ordinary stacks and text. GroupBox's
// generated macOS accessibility subtree caused inspection failures here.
private struct DiagnosticCard<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18), lineWidth: 1))
    }
}

struct DiagnosticSettings: View {
    @ObservedObject var model: RedirectorModel
    @ObservedObject private var telemetry: RedirectorTelemetry

    init(model: RedirectorModel) {
        self.model = model
        self.telemetry = model.telemetry
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label(stateLabel, systemImage: model.isRunning ? "waveform" : "circle")
                        .font(.headline)
                    Spacer()
                    Button("診断を書き出す…") { model.exportDiagnostics() }
                }
                DiagnosticCard("実際の I/O") {
                    Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
                        GridRow { Text("RME"); Text(frames(telemetry.status.rmeBufferFrames)) }
                        GridRow { Text("PC capture"); Text(frames(telemetry.status.pcBufferFrames)) }
                        GridRow { Text("Discrete4"); Text(frames(telemetry.status.d4BufferFrames)) }
                        GridRow { Text("Clip / 非有限値"); Text("\(telemetry.status.clipped) / \(telemetry.status.nonFinite)") }
                    }.monospacedDigit().frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                DiagnosticCard("経路の状態") {
                    VStack(alignment: .leading, spacing: 10) {
                        if telemetry.status.sources.isEmpty { Text("まだ経路の計測値はありません。").foregroundStyle(.secondary) }
                        ForEach(telemetry.status.sources) { source in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.name).font(.headline)
                                Text("callbacks \(source.callbacks) · frames \(source.frames) · FIFO \(source.fifoFrames.map(String.init) ?? "未取得") · \(source.ppm.map { String(format: "%.2f ppm", $0) } ?? "ppm 未取得")")
                                Text("不足 \(source.underruns) / 超過 \(source.overflows)").foregroundStyle((source.underruns + source.overflows) > 0 ? .red : .secondary)
                            }.font(.caption.monospacedDigit())
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                DiagnosticCard("PC 取得テスト") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("選択した PC device / stream の取得だけを開始します。RME・Discrete4 の物理 I/O を開かず、音声を出力しません。システム音声の取得許可が必要です。")
                        Text("元音声を抑える設定が ON の場合は、このテスト中も元の process 出力に影響します。")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(model.isProbing ? "取得テストを停止" : "PC取得テスト") {
                                if model.isProbing { model.stop() } else { model.startProbe() }
                            }.disabled((model.isActive && !model.isProbing) || model.refreshing || model.storageBlocked || model.pendingAction == "stopping")
                            Text("callbacks \(telemetry.status.probeCallbacks) / frames \(telemetry.status.probeFrames)")
                                .font(.caption.monospacedDigit())
                        }
                        if let format = telemetry.status.probeFormat {
                            Text(format).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        if !telemetry.status.probePeaks.isEmpty {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 175))], alignment: .leading) {
                                ForEach(Array(telemetry.status.probePeaks.enumerated()), id: \.offset) { index, peak in
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
        switch telemetry.status.state {
        case "running": return "ON · 転送中"
        case "priming": return "準備中"
        case "starting": return "開始中"
        case "probe": return "PC 取得テスト中"
        case "fault": return "OFF · エラー"
        default: return "OFF"
        }
    }
}
