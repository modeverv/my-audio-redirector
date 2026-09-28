import AppKit
import Combine
import SwiftUI

struct NativeMixerView: NSViewControllerRepresentable {
    let model: RedirectorModel
    func makeNSViewController(context: Context) -> MixerTableController { MixerTableController(model: model) }
    func updateNSViewController(_ controller: MixerTableController, context: Context) { controller.scheduleConfigurationUpdate() }
    static func dismantleNSViewController(_ controller: MixerTableController, coordinator: ()) { controller.invalidate() }
}

private enum MixerItem: Equatable {
    case header(Int), empty(Int), channel(Int, Int), master, returnHeader, returnMaster, returnChannel(Int), footer
    var height: CGFloat {
        switch self {
        case .header: return 62
        case .returnHeader: return 49
        case .empty: return 34
        case .footer: return 62
        default: return 52
        }
    }
    var reuseID: NSUserInterfaceItemIdentifier {
        switch self {
        case .channel, .returnChannel: return .init("channel")
        case .master, .returnMaster: return .init("master")
        default: return .init("description")
        }
    }
}

// No bindings, layout constraints, or bridge calls run on meter ticks. The
// display timer only animates cached telemetry in instantiated, visible cells.
@MainActor
final class MixerTableController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let model: RedirectorModel
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private var items: [MixerItem] = []
    private var subscriptions = Set<AnyCancellable>()
    private var displayTimer: Timer?
    private var configurationPending = true
    private var popover: NSPopover?

    init(model: RedirectorModel) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 880, height: 650))
        scroll.frame = view.bounds
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .windowBackgroundColor
        table.headerView = nil
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.focusRingType = .none
        table.usesAutomaticRowHeights = false
        table.intercellSpacing = .zero
        table.rowHeight = 52
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.backgroundColor = .windowBackgroundColor
        table.setAccessibilityLabel("オーディオミキサー")
        let column = NSTableColumn(identifier: .init("mixer"))
        column.width = 860
        column.minWidth = 800
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        view.addSubview(scroll)
        model.objectWillChange.sink { [weak self] in self?.scheduleConfigurationUpdate() }.store(in: &subscriptions)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification, object: scroll.contentView)
            .sink { [weak self] _ in self?.visibleBoundsDidChange() }.store(in: &subscriptions)
        updateConfiguration()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        configurationPending = true
        guard displayTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, target: self, selector: #selector(displayTick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }
    override func viewDidDisappear() { super.viewDidDisappear(); stopDisplayTimer(); popover?.close() }
    override func viewDidLayout() {
        super.viewDidLayout()
        let width = max(800, scroll.contentSize.width)
        if let column = table.tableColumns.first, abs(column.width - width) > 0.5 { column.width = width }
    }
    func invalidate() { stopDisplayTimer(); subscriptions.removeAll(); popover?.close(); popover = nil }
    private func stopDisplayTimer() { displayTimer?.invalidate(); displayTimer = nil }
    func scheduleConfigurationUpdate() { configurationPending = true }

    @objc private func displayTick() {
        guard model.settingsVisible, let window = view.window, window.isVisible, !view.isHiddenOrHasHiddenAncestor else { return }
        if configurationPending { updateConfiguration() }
        paintVisibleMeters()
    }
    private func updateConfiguration() {
        configurationPending = false
        var next: [MixerItem] = []
        for source in 0...1 {
            next.append(.header(source))
            let channels = model.channels(source: source)
            if channels.isEmpty { next.append(.empty(source)) }
            next.append(contentsOf: channels.map { .channel(source, $0.channel) })
        }
        next.append(contentsOf: [.master, .returnHeader, .returnMaster, .returnChannel(0), .returnChannel(1), .footer])
        if next != items {
            popover?.close()
            items = next
            table.reloadData() // Only a device/channel structure change reloads rows.
        } else {
            forEachVisibleCell { [self] cell, item in configure(cell, item: item) }
        }
    }
    private func forEachVisibleCell(_ action: (NSView, MixerItem) -> Void) {
        let range = table.rows(in: scroll.documentVisibleRect)
        guard range.location != NSNotFound, range.length > 0 else { return }
        for row in range.location..<min(items.count, range.location + range.length) {
            if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) { action(cell, items[row]) }
        }
    }
    private func visibleBoundsDidChange() {
        // Accessibility can materialize offscreen cells which the table keeps
        // alive. They may become visible without another viewFor callback.
        // Refresh their configuration on scrolling; meter ticks remain paint-only.
        forEachVisibleCell { [self] cell, item in configure(cell, item: item) }
        paintVisibleMeters()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { items[row].height }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let cell: NSView
        if let reused = tableView.makeView(withIdentifier: item.reuseID, owner: self) { cell = reused }
        else {
            switch item {
            case .channel, .returnChannel: cell = MixerChannelCell()
            case .master, .returnMaster: cell = MixerMasterCell()
            default: cell = MixerDescriptionCell()
            }
            cell.identifier = item.reuseID
        }
        configure(cell, item: item)
        updateMeter(cell, item: item, immediate: true)
        return cell
    }

    private var controlsEnabled: Bool { !model.isProbing && !model.storageBlocked }
    private func configure(_ view: NSView, item: MixerItem) {
        if let cell = view as? MixerChannelCell {
            let source: Int, number: Int
            switch item {
            case .channel(let s, let n): source = s; number = n
            case .returnChannel(let index): source = 2; number = index + 1
            default: return
            }
            let channel = source < 2 ? model.channels(source: source).first { $0.channel == number } : nil
            let pair = number.isMultiple(of: 2) ? number - 1 : number
            let gate = currentGate(source: source, channel: number)
            let showLink = source == 2 ? number == 1 : number == pair && model.channels(source: source).contains { $0.channel == pair + 1 }
            let linked = source == 2 ? model.configuration.returnGateLinked : model.linked(source: source, pair: pair)
            cell.configure(label: channelLabel(source: source, channel: number), channel: channel, gate: gate,
                           linked: linked, showLink: showLink, enabled: controlsEnabled, linkEnabled: controlsEnabled && !model.structuralLocked)
            cell.onChange = { [weak self] field, value in
                guard let self else { return }
                switch field {
                case .gain: self.model.changeChannel(source: source, channel: number, gain: Float(value))
                case .pan: self.model.changeChannel(source: source, channel: number, pan: Float(value))
                case .mute: self.model.changeChannel(source: source, channel: number, muted: value != 0)
                case .link:
                    if source == 2 { self.model.setReturnGateLinked(value != 0) }
                    else { self.model.setLinked(source: source, pair: pair, linked: value != 0) }
                case .gate, .threshold:
                    var changed = self.currentGate(source: source, channel: number)
                    if field == .gate { changed.enabled = value != 0 } else { changed.thresholdDB = Float(value) }
                    self.model.changeGate(source: source, channel: number, gate: changed)
                }
            }
            cell.onDetails = { [weak self] anchor in self?.showGateDetails(source: source, channel: number, anchor: anchor) }
        } else if let cell = view as? MixerMasterCell {
            let returned = item == .returnMaster
            cell.configure(returned: returned, gain: returned ? model.configuration.returnGainDB : model.configuration.forwardGainDB,
                           muted: model.configuration.returnMuted, enabled: controlsEnabled)
            cell.onGain = { [weak self] gain in
                if returned { self?.model.changeMaster(returned: Float(gain)) } else { self?.model.changeMaster(forward: Float(gain)) }
            }
            cell.onMute = { [weak self] muted in self?.model.changeMaster(muted: muted) }
        } else if let cell = view as? MixerDescriptionCell {
            cell.onAction = nil
            switch item {
            case .header(let source):
                let device = (source == 0 ? model.rmeDevice?.name : model.pcDevice?.name) ?? "未選択"
                let title = source == 0 ? "RME INPUT · 物理入力" : "PC OUTPUT · PC再生出力"
                let subtitle = source == 0 ? "\(device) · \(model.channels(source: source).count) ch" : "\(device) · stream \(model.configuration.pcStreamIndex) · \(model.channels(source: source).count) ch"
                cell.configure(title: title, subtitle: subtitle, button: "Panを奇数L・偶数Rに戻す", enabled: controlsEnabled && !model.structuralLocked && !model.channels(source: source).isEmpty)
                cell.onAction = { [weak self] in
                    guard let self, !self.model.structuralLocked else { return }
                    for channel in self.model.channels(source: source) {
                        let pan: Float = channel.channel.isMultiple(of: 2) ? 1 : -1
                        if channel.pan != pan { self.model.changeChannel(source: source, channel: channel.channel, pan: pan) }
                    }
                }
            case .empty:
                cell.configure(title: "入出力タブで取得元を選択してください。", subtitle: "")
            case .returnHeader:
                cell.configure(title: "RETURN · Discrete4 → RME", subtitle: "USB \(model.configuration.d4ReturnLeft)/\(model.configuration.d4ReturnRight) → RME host \(model.configuration.rmeReturnLeft)/\(model.configuration.rmeReturnRight)")
            case .footer:
                cell.configure(title: "Link は左右の Gain・Mute・Gate を連動します。Pan は各ch独立です。", subtitle: "Gateの表示は検出状態です。入力メーターはGate・Mute前、送出メーターはASRC・Gain・Mute後です。", compact: true)
            default: break
            }
        }
    }
    private func channelLabel(source: Int, channel: Int) -> String {
        if source == 0 { return model.rmeDevice?.channelName(channel, input: true) ?? "Input \(channel)" }
        if source == 1 {
            let hardwareChannel = (model.pcStream?.startingChannel ?? 1) + channel - 1
            return "Out " + (model.pcDevice?.channelName(hardwareChannel, input: false) ?? "\(hardwareChannel)")
        }
        return "Return \(channel == 1 ? "L" : "R") · USB \(channel == 1 ? model.configuration.d4ReturnLeft : model.configuration.d4ReturnRight)"
    }
    private func currentGate(source: Int, channel: Int) -> GateConfiguration {
        if source == 2 { return model.configuration.returnGates.indices.contains(channel - 1) ? model.configuration.returnGates[channel - 1] : GateConfiguration() }
        return model.channels(source: source).first { $0.channel == channel }?.gate ?? GateConfiguration()
    }
    private func paintVisibleMeters() {
        guard isViewLoaded, view.window?.isVisible == true else { return }
        forEachVisibleCell { [self] cell, item in updateMeter(cell, item: item, immediate: false) }
    }
    private func updateMeter(_ view: NSView, item: MixerItem, immediate: Bool) {
        let levels = model.telemetry.meters
        if let cell = view as? MixerChannelCell {
            let sourceIndex: Int, index: Int
            switch item {
            case .channel(let source, let number): sourceIndex = source; index = number - 1
            case .returnChannel(let number): sourceIndex = 2; index = number
            default: return
            }
            let peaks = levels.inputPeaks.indices.contains(sourceIndex) ? levels.inputPeaks[sourceIndex] : []
            let gains = levels.gateGains.indices.contains(sourceIndex) ? levels.gateGains[sourceIndex] : []
            let peak = levels.active && peaks.indices.contains(index) ? peaks[index] : nil
            let gain = levels.active && gains.indices.contains(index) ? gains[index] : nil
            cell.setTelemetry(peak: model.settingsVisible ? peak : nil, gateGain: gain, immediate: immediate)
        } else if let cell = view as? MixerMasterCell {
            let index = item == .returnMaster ? 1 : 0
            cell.meter.update(peak: levels.active && levels.outputPeaks.indices.contains(index) ? levels.outputPeaks[index] : nil, immediate: immediate)
        }
    }
    private func showGateDetails(source: Int, channel: Int, anchor: NSView) {
        popover?.close()
        let details = GateDetailsController(title: channelLabel(source: source, channel: channel), value: currentGate(source: source, channel: channel))
        details.onChange = { [weak self] key, value in
            guard let self else { return }
            var gate = self.currentGate(source: source, channel: channel)
            gate[keyPath: key] = Float(value)
            self.model.changeGate(source: source, channel: channel, gate: gate)
        }
        let panel = NSPopover()
        panel.behavior = .transient
        panel.contentViewController = details
        panel.contentSize = NSSize(width: 350, height: 218)
        panel.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        popover = panel
    }
}

private final class MixerActionButton: NSButton {
    var handler: (() -> Void)?
    init(_ title: String, checkbox: Bool = false) {
        super.init(frame: .zero)
        self.title = title
        if checkbox { setButtonType(.switch) } else { bezelStyle = .rounded }
        controlSize = .small
        font = .systemFont(ofSize: 11)
        target = self
        action = #selector(activate)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func activate() { handler?() }
}

private final class MixerSlider: NSSlider {
    var handler: ((Double) -> Void)?
    private let increment: Double
    init(_ range: ClosedRange<Double>, step: Double) {
        increment = step
        super.init(frame: .zero)
        minValue = range.lowerBound; maxValue = range.upperBound
        isContinuous = true; controlSize = .small
        target = self; action = #selector(changed)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changed() {
        let value = min(maxValue, max(minValue, (doubleValue / increment).rounded() * increment))
        doubleValue = value
        handler?(value)
    }
    override func keyDown(with event: NSEvent) {
        guard isEnabled, event.modifierFlags.intersection([.command, .control]).isEmpty else { super.keyDown(with: event); return }
        let direction: Double
        switch event.keyCode {
        case 123, 125: direction = -1 // Left / down.
        case 124, 126: direction = 1 // Right / up.
        default: super.keyDown(with: event); return
        }
        adjust(direction * (event.modifierFlags.contains(.shift) ? 10 : 1))
    }
    override func accessibilityPerformIncrement() -> Bool {
        guard isEnabled else { return false }
        adjust(1); return true
    }
    override func accessibilityPerformDecrement() -> Bool {
        guard isEnabled else { return false }
        adjust(-1); return true
    }
    private func adjust(_ steps: Double) {
        doubleValue = min(maxValue, max(minValue, doubleValue + increment * steps))
        changed()
    }
}

private func mixerLabel(_ size: CGFloat = 11, monospaced: Bool = false) -> NSTextField {
    let result = NSTextField(labelWithString: "")
    result.font = monospaced ? .monospacedDigitSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size)
    result.lineBreakMode = .byTruncatingTail
    return result
}

private final class MixerPeakView: NSView {
    private var displayedDB: Double?
    private var valueText = "—"
    private var quantizedWidth = -1
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel("入力ピーク dBFS")
        setAccessibilityMinValue(NSNumber(value: -96))
        setAccessibilityMaxValue(NSNumber(value: 0))
        setAccessibilityValue(nil)
        setAccessibilityValueDescription("未取得")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(peak: Double?, immediate: Bool) {
        let target = peak.flatMap { $0.isFinite ? max(-96, 20 * log10(max(0.00001585, $0))) : nil }
        if let target {
            displayedDB = immediate ? target : max(target, (displayedDB ?? target) - 1.6)
        } else { displayedDB = nil }
        let text = displayedDB.map { $0 <= -95.9 ? "−∞" : String(format: "%.1f", $0) } ?? "—"
        let width = Int((max(0, min(1, ((displayedDB ?? -96) + 60) / 60)) * max(1, bounds.width - 39)).rounded())
        guard width != quantizedWidth || valueText != text else { return }
        quantizedWidth = width; valueText = text
        // A level indicator exposes a numeric AXValue. Its visual bar saturates
        // at 0 dBFS; the description still reports peaks above that limit.
        setAccessibilityValue(displayedDB.map { NSNumber(value: max(-96, min(0, $0))) })
        setAccessibilityValueDescription(displayedDB == nil ? "未取得" : "\(text) dBFS")
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let bar = NSRect(x: 0, y: 3, width: max(1, bounds.width - 39), height: max(3, bounds.height - 6))
        NSColor.quaternaryLabelColor.setFill(); NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
        let fraction = max(0, min(1, ((displayedDB ?? -96) + 60) / 60))
        if fraction > 0 {
            ((displayedDB ?? -96) >= 0 ? NSColor.systemRed : NSColor.systemGreen).setFill()
            NSBezierPath(rect: NSRect(x: bar.minX, y: bar.minY, width: bar.width * fraction, height: bar.height)).fill()
        }
        (valueText as NSString).draw(in: NSRect(x: bar.maxX + 4, y: 0, width: 35, height: bounds.height), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor])
    }
}

private final class MixerChannelCell: NSView {
    enum Field: Equatable { case gain, pan, mute, link, gate, threshold }
    var onChange: ((Field, Double) -> Void)?
    var onDetails: ((NSView) -> Void)?
    private let name = mixerLabel(11)
    private let gain = MixerSlider(-90...12, step: 0.1)
    private let gainText = mixerLabel(11, monospaced: true)
    private let mute = MixerActionButton("Mute", checkbox: true)
    private let pan = MixerSlider(-1...1, step: 0.01)
    private let panText = mixerLabel(10, monospaced: true)
    private let link = MixerActionButton("Link", checkbox: true)
    private let gate = MixerActionButton("Gate", checkbox: true)
    private let threshold = MixerSlider(-96...0, step: 0.1)
    private let thresholdText = mixerLabel(11, monospaced: true)
    private let gateState = mixerLabel(9, monospaced: true)
    private let details = MixerActionButton("…")
    private let inputNote = mixerLabel(10)
    private let gainCaption = mixerLabel(9)
    private let panCaption = mixerLabel(9)
    private let thresholdCaption = mixerLabel(9)
    private let meter = MixerPeakView(frame: .zero)
    private var gateEnabled = false
    private var lastGatePercent: Int?
    private struct Presentation: Equatable {
        let label: String
        let channel: ChannelConfiguration?
        let gate: GateConfiguration
        let linked: Bool, showLink: Bool, enabled: Bool, linkEnabled: Bool
    }
    private var presentation: Presentation?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        [name, gain, gainText, mute, pan, panText, link, gate, threshold, thresholdText, gateState, details, meter, inputNote, gainCaption, panCaption, thresholdCaption].forEach(addSubview)
        inputNote.stringValue = "USB入力 · Gate前"; inputNote.textColor = .secondaryLabelColor
        gainCaption.stringValue = "Gain · dB"; panCaption.stringValue = "Pan · L C R"; thresholdCaption.stringValue = "Threshold · dBFS"
        [gainCaption, panCaption, thresholdCaption].forEach { $0.textColor = .secondaryLabelColor }
        gainText.alignment = .right; thresholdText.alignment = .right
        gain.handler = { [weak self] value in self?.gainText.stringValue = String(format: "%.1f", value); self?.onChange?(.gain, value) }
        pan.handler = { [weak self] value in self?.panText.stringValue = Self.panLabel(value); self?.onChange?(.pan, value) }
        threshold.handler = { [weak self] value in self?.thresholdText.stringValue = String(format: "%.1f", value); self?.onChange?(.threshold, value) }
        mute.handler = { [weak self] in guard let self else { return }; onChange?(.mute, mute.state == .on ? 1 : 0) }
        link.handler = { [weak self] in guard let self else { return }; onChange?(.link, link.state == .on ? 1 : 0) }
        gate.handler = { [weak self] in guard let self else { return }; onChange?(.gate, gate.state == .on ? 1 : 0) }
        details.handler = { [weak self] in guard let self else { return }; onDetails?(details) }
        pan.toolTip = "Pan: L=左、C=中央、R=右。Link中も各ch独立です。"
        link.toolTip = "左右のGain・Mute・Gateを連動します。OFF中のみ変更できます。"
        gate.toolTip = "入力ノイズゲートのON/OFF"
        threshold.toolTip = "Gate threshold（dBFS）: −96〜0"
        details.toolTip = "GateのAttack・Hold・Release・Hysteresis"
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(label: String, channel: ChannelConfiguration?, gate value: GateConfiguration, linked: Bool, showLink: Bool, enabled: Bool, linkEnabled: Bool) {
        let next = Presentation(label: label, channel: channel, gate: value, linked: linked, showLink: showLink, enabled: enabled, linkEnabled: linkEnabled)
        guard next != presentation else { return }
        presentation = next
        if name.stringValue != label { name.stringValue = label; name.toolTip = label }
        gain.doubleValue = Double(channel?.gainDB ?? 0); gainText.stringValue = String(format: "%.1f", channel?.gainDB ?? 0)
        pan.doubleValue = Double(channel?.pan ?? 0); panText.stringValue = Self.panLabel(pan.doubleValue)
        mute.state = channel?.muted == true ? .on : .off
        link.state = linked ? .on : .off; link.isHidden = !showLink; link.isEnabled = linkEnabled
        gate.state = value.enabled ? .on : .off; gateEnabled = value.enabled
        threshold.doubleValue = Double(value.thresholdDB); thresholdText.stringValue = String(format: "%.1f", value.thresholdDB)
        for control in [gain, pan, mute, gate, threshold, details] as [NSControl] { control.isEnabled = enabled }
        [gain, gainText, pan, panText, mute, gainCaption, panCaption].forEach { $0.isHidden = channel == nil }
        inputNote.isHidden = channel != nil
        link.toolTip = channel == nil ? "Return左右のGate設定と検出を連動します。OFF中のみ変更できます。" : "左右のGain・Mute・Gateを連動します。OFF中のみ変更できます。"
        gain.setAccessibilityLabel("\(label) Gain dB"); pan.setAccessibilityLabel("\(label) Pan")
        mute.setAccessibilityLabel("\(label) Mute"); gate.setAccessibilityLabel("\(label) Gate ON")
        threshold.setAccessibilityLabel("\(label) Gate threshold dBFS"); details.setAccessibilityLabel("\(label) Gate詳細")
        link.setAccessibilityLabel("\(label) Stereo Link")
        meter.setAccessibilityLabel("\(label) 入力ピーク dBFS（Gate・Mute前）")
        gateState.setAccessibilityLabel("\(label) Gate状態")
    }
    func setTelemetry(peak: Double?, gateGain: Double?, immediate: Bool) {
        meter.update(peak: peak, immediate: immediate)
        let text: String
        let color: NSColor
        if !gateEnabled { text = "OFF"; color = .tertiaryLabelColor }
        else if let gateGain, gateGain.isFinite {
            text = gateGain >= 0.999 ? "OPEN" : "抑制"; color = gateGain >= 0.999 ? .systemGreen : .systemOrange
        } else { text = "—"; color = .secondaryLabelColor }
        if gateState.stringValue != text { gateState.stringValue = text; gateState.textColor = color }
        let percent = gateGain.flatMap { $0.isFinite ? Int(($0 * 1000).rounded()) : nil }
        if percent != lastGatePercent {
            lastGatePercent = percent
            gateState.toolTip = percent.map { String(format: "Gate利得 %.1f%%（直近callback末尾）", Double($0) / 10) }
        }
    }
    override func layout() {
        super.layout()
        let extra = max(0, bounds.width - 810)
        let nameWidth = 128 + extra * 0.4
        name.frame = NSRect(x: 10, y: 5, width: nameWidth, height: 17)
        meter.frame = NSRect(x: 10, y: 29, width: nameWidth, height: 14)
        var x = nameWidth + 17
        gain.frame = NSRect(x: x, y: 13, width: 91 + extra * 0.3, height: 22)
        inputNote.frame = NSRect(x: x, y: 17, width: 285 + extra * 0.3, height: 18)
        x += gain.frame.width + 3
        gainText.frame = NSRect(x: x, y: 17, width: 42, height: 18); x += 46
        mute.frame = NSRect(x: x, y: 13, width: 53, height: 24); x += 56
        pan.frame = NSRect(x: x, y: 13, width: 59, height: 22); x += 62
        panText.frame = NSRect(x: x, y: 17, width: 34, height: 18); x += 36
        link.frame = NSRect(x: x, y: 13, width: 48, height: 24); x += 51
        gate.frame = NSRect(x: x, y: 13, width: 53, height: 24); x += 56
        threshold.frame = NSRect(x: x, y: 13, width: 82 + extra * 0.3, height: 22); x += threshold.frame.width + 2
        thresholdText.frame = NSRect(x: x, y: 17, width: 44, height: 18); x += 49
        gateState.frame = NSRect(x: x, y: 18, width: 33, height: 17); x += 34
        details.frame = NSRect(x: x, y: 12, width: 31, height: 25)
        gainCaption.frame = NSRect(x: gain.frame.minX, y: 1, width: gain.frame.width + 46, height: 12)
        panCaption.frame = NSRect(x: pan.frame.minX, y: 1, width: 100, height: 12)
        thresholdCaption.frame = NSRect(x: threshold.frame.minX, y: 1, width: threshold.frame.width + 51, height: 12)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.35).setFill()
        NSRect(x: 10, y: bounds.height - 1, width: max(0, bounds.width - 20), height: 0.5).fill()
    }
    private static func panLabel(_ pan: Double) -> String { abs(pan) < 0.005 ? "C" : "\(pan < 0 ? "L" : "R")\(Int((abs(pan) * 100).rounded()))" }
}

private final class MixerMasterCell: NSView {
    var onGain: ((Double) -> Void)?
    var onMute: ((Bool) -> Void)?
    let meter = MixerPeakView(frame: .zero)
    private let title = mixerLabel(12)
    private let slider = MixerSlider(-90...12, step: 0.1)
    private let value = mixerLabel(11, monospaced: true)
    private let mute = MixerActionButton("Mute", checkbox: true)
    private let note = mixerLabel(10)
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        [title, slider, value, mute, meter, note].forEach(addSubview)
        slider.handler = { [weak self] gain in self?.value.stringValue = String(format: "%.1f dB", gain); self?.onGain?(gain) }
        mute.handler = { [weak self] in guard let self else { return }; onMute?(mute.state == .on) }
        note.textColor = .secondaryLabelColor
        meter.setAccessibilityLabel("送出ピーク dBFS")
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(returned: Bool, gain: Float, muted: Bool, enabled: Bool) {
        title.stringValue = returned ? "Return Master" : "2MIX → Computer 1/2"
        slider.doubleValue = Double(gain); value.stringValue = String(format: "%.1f dB", gain)
        mute.isHidden = !returned; mute.state = muted ? .on : .off
        slider.isEnabled = enabled; mute.isEnabled = enabled
        note.stringValue = returned ? "RME送出 · L/R最大（Gain・Mute後）" : "Discrete4へ送出 · L/R最大"
        slider.setAccessibilityLabel(returned ? "Return Master Gain dB" : "Forward Master Gain dB")
        mute.setAccessibilityLabel("Return Master Mute")
        meter.setAccessibilityLabel(returned ? "Return RME送出ピーク dBFS（Gain・Mute後）" : "Discrete4送出ピーク dBFS（Gain後）")
    }
    override func layout() {
        super.layout()
        title.frame = NSRect(x: 10, y: 16, width: 167, height: 20)
        slider.frame = NSRect(x: 181, y: 12, width: 185, height: 25)
        value.frame = NSRect(x: 372, y: 17, width: 69, height: 18)
        mute.frame = NSRect(x: 445, y: 12, width: 58, height: 25)
        meter.frame = NSRect(x: 518, y: 18, width: 117, height: 15)
        note.frame = NSRect(x: 646, y: 17, width: max(0, bounds.width - 656), height: 18)
    }
}

private final class MixerDescriptionCell: NSView {
    var onAction: (() -> Void)?
    private let title = mixerLabel(12)
    private let subtitle = mixerLabel(10)
    private let button = MixerActionButton("")
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        [title, subtitle, button].forEach(addSubview)
        subtitle.textColor = .secondaryLabelColor
        button.handler = { [weak self] in self?.onAction?() }
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(title: String, subtitle: String, button: String? = nil, enabled: Bool = false, compact: Bool = false) {
        self.title.stringValue = title; self.subtitle.stringValue = subtitle
        self.title.font = .systemFont(ofSize: compact ? 10 : 12, weight: compact ? .regular : .semibold)
        self.button.title = button ?? ""; self.button.isHidden = button == nil; self.button.isEnabled = enabled
    }
    override func layout() {
        super.layout()
        title.frame = NSRect(x: 10, y: 9, width: max(0, bounds.width - (button.isHidden ? 20 : 215)), height: 18)
        subtitle.frame = NSRect(x: 10, y: 32, width: max(0, bounds.width - 20), height: 17)
        button.frame = NSRect(x: bounds.width - 208, y: 6, width: 198, height: 26)
    }
}

private final class GateDetailsController: NSViewController {
    var onChange: ((WritableKeyPath<GateConfiguration, Float>, Double) -> Void)?
    private let channelTitle: String
    private let initial: GateConfiguration
    init(title: String, value: GateConfiguration) { channelTitle = title; initial = value; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 350, height: 218))
        let title = mixerLabel(12); title.stringValue = "\(channelTitle) · Gate"
        title.frame = NSRect(x: 14, y: 184, width: 322, height: 20); view.addSubview(title)
        let parameters: [(String, WritableKeyPath<GateConfiguration, Float>, ClosedRange<Double>, Double, String)] = [
            ("Attack", \.attackMS, 0.1...50, 0.1, "ms"), ("Hold", \.holdMS, 0...1000, 1, "ms"),
            ("Release", \.releaseMS, 1...2000, 1, "ms"), ("Hysteresis", \.hysteresisDB, 0...24, 0.1, "dB")
        ]
        for (index, parameter) in parameters.enumerated() {
            let (name, key, range, step, unit) = parameter
            let y = CGFloat(143 - index * 34)
            let label = mixerLabel(11); label.stringValue = name; label.frame = NSRect(x: 14, y: y, width: 78, height: 20)
            let slider = MixerSlider(range, step: step); slider.doubleValue = Double(initial[keyPath: key]); slider.frame = NSRect(x: 95, y: y - 2, width: 157, height: 25)
            let value = mixerLabel(11, monospaced: true); value.stringValue = String(format: step < 1 ? "%.1f %@" : "%.0f %@", slider.doubleValue, unit)
            value.frame = NSRect(x: 260, y: y, width: 78, height: 20)
            slider.setAccessibilityLabel("\(channelTitle) Gate \(name) \(unit)")
            slider.handler = { [weak self, weak value] number in
                value?.stringValue = String(format: step < 1 ? "%.1f %@" : "%.0f %@", number, unit)
                self?.onChange?(key, number)
            }
            [label, slider, value].forEach(view.addSubview)
        }
        let explanation = mixerLabel(10); explanation.stringValue = "GateはGain・Pan・Muteの前で処理します。"
        explanation.textColor = .secondaryLabelColor; explanation.frame = NSRect(x: 14, y: 12, width: 322, height: 18); view.addSubview(explanation)
    }
}
