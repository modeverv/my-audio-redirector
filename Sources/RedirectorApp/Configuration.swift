import Foundation

struct ChannelConfiguration: Codable, Equatable, Identifiable {
    var channel: Int
    var gainDB: Float = 0
    var pan: Float
    var muted = true
    var id: Int { channel }

    init(channel: Int) {
        self.channel = channel
        self.pan = channel.isMultiple(of: 2) ? 1 : -1
    }
}

struct RedirectorConfiguration: Codable, Equatable {
    var schemaVersion = 1
    var rmeUID = ""
    var d4UID = ""
    var pcUID = ""
    var pcStreamIndex = 0
    var bufferFrames = 64
    var rmeFifoFrames = 64
    var pcFifoFrames = 64
    var returnFifoFrames = 64
    var srcQuality = "fastest"
    var rmeReturnLeft = 11
    var rmeReturnRight = 12
    var d4ReturnLeft = 1
    var d4ReturnRight = 2
    var forwardGainDB: Float = 0
    var returnGainDB: Float = 0
    var returnMuted = true
    var tapMuteOriginal = false
    var rmeChannels: [ChannelConfiguration] = []
    var pcChannels: [ChannelConfiguration] = []
    // UI-only state; bridge configuration tolerates additional fields.
    var rmeStereoLinks: [Int] = []
    var pcStereoLinks: [Int] = []
    var rmeReturnLabels: [String] = []
    var d4ReturnLabels: [String] = []
    var rmeReturnStreamIndices: [Int] = []
    var rmeReturnStreamStarts: [Int] = []
    var pcStreamChannelCount: Int?
    var pcStreamStartingChannel: Int?

    enum CodingKeys: String, CodingKey {
        case schemaVersion, rmeUID, d4UID, pcUID, pcStreamIndex
        case bufferFrames, rmeFifoFrames, pcFifoFrames, returnFifoFrames, srcQuality
        case rmeReturnLeft, rmeReturnRight, d4ReturnLeft, d4ReturnRight
        case forwardGainDB, returnGainDB, returnMuted, tapMuteOriginal
        case rmeChannels, pcChannels, rmeStereoLinks, pcStereoLinks
        case rmeReturnLabels, d4ReturnLabels, rmeReturnStreamIndices, rmeReturnStreamStarts
        case pcStreamChannelCount, pcStreamStartingChannel
    }

    init() {}

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == 1 else {
            throw ConfigurationError.invalid("未対応の設定バージョンです: \(schemaVersion)")
        }
        rmeUID = try c.decodeIfPresent(String.self, forKey: .rmeUID) ?? ""
        d4UID = try c.decodeIfPresent(String.self, forKey: .d4UID) ?? ""
        pcUID = try c.decodeIfPresent(String.self, forKey: .pcUID) ?? ""
        pcStreamIndex = try c.decodeIfPresent(Int.self, forKey: .pcStreamIndex) ?? 0
        bufferFrames = try c.decodeIfPresent(Int.self, forKey: .bufferFrames) ?? 64
        rmeFifoFrames = try c.decodeIfPresent(Int.self, forKey: .rmeFifoFrames) ?? 64
        pcFifoFrames = try c.decodeIfPresent(Int.self, forKey: .pcFifoFrames) ?? 64
        returnFifoFrames = try c.decodeIfPresent(Int.self, forKey: .returnFifoFrames) ?? 64
        srcQuality = try c.decodeIfPresent(String.self, forKey: .srcQuality) ?? "fastest"
        rmeReturnLeft = try c.decodeIfPresent(Int.self, forKey: .rmeReturnLeft) ?? 11
        rmeReturnRight = try c.decodeIfPresent(Int.self, forKey: .rmeReturnRight) ?? 12
        d4ReturnLeft = try c.decodeIfPresent(Int.self, forKey: .d4ReturnLeft) ?? 1
        d4ReturnRight = try c.decodeIfPresent(Int.self, forKey: .d4ReturnRight) ?? 2
        forwardGainDB = try c.decodeIfPresent(Float.self, forKey: .forwardGainDB) ?? 0
        returnGainDB = try c.decodeIfPresent(Float.self, forKey: .returnGainDB) ?? 0
        returnMuted = try c.decodeIfPresent(Bool.self, forKey: .returnMuted) ?? true
        tapMuteOriginal = try c.decodeIfPresent(Bool.self, forKey: .tapMuteOriginal) ?? false
        rmeChannels = try c.decodeIfPresent([ChannelConfiguration].self, forKey: .rmeChannels) ?? []
        pcChannels = try c.decodeIfPresent([ChannelConfiguration].self, forKey: .pcChannels) ?? []
        rmeStereoLinks = try c.decodeIfPresent([Int].self, forKey: .rmeStereoLinks) ?? []
        pcStereoLinks = try c.decodeIfPresent([Int].self, forKey: .pcStereoLinks) ?? []
        rmeReturnLabels = try c.decodeIfPresent([String].self, forKey: .rmeReturnLabels) ?? []
        d4ReturnLabels = try c.decodeIfPresent([String].self, forKey: .d4ReturnLabels) ?? []
        rmeReturnStreamIndices = try c.decodeIfPresent([Int].self, forKey: .rmeReturnStreamIndices) ?? []
        rmeReturnStreamStarts = try c.decodeIfPresent([Int].self, forKey: .rmeReturnStreamStarts) ?? []
        pcStreamChannelCount = try c.decodeIfPresent(Int.self, forKey: .pcStreamChannelCount)
        pcStreamStartingChannel = try c.decodeIfPresent(Int.self, forKey: .pcStreamStartingChannel)
        try validateStorage()
    }

    func validateStorage() throws {
        guard schemaVersion == 1, pcStreamIndex >= 0,
              [bufferFrames, rmeFifoFrames, pcFifoFrames, returnFifoFrames].allSatisfy({ (1...8192).contains($0) }),
              [rmeReturnLeft, rmeReturnRight, d4ReturnLeft, d4ReturnRight].allSatisfy({ $0 > 0 }),
              ["fastest", "medium"].contains(srcQuality),
              [forwardGainDB, returnGainDB].allSatisfy({ $0.isFinite && (-90...12).contains($0) }) else {
            throw ConfigurationError.invalid("設定値の形式または範囲が不正です。")
        }
        for channels in [rmeChannels, pcChannels] {
            guard Set(channels.map(\.channel)).count == channels.count,
                  channels.allSatisfy({ $0.channel > 0 && $0.gainDB.isFinite && (-90...12).contains($0.gainDB) && $0.pan.isFinite && (-1...1).contains($0.pan) }) else {
                throw ConfigurationError.invalid("入力チャンネルの設定が不正です。")
            }
        }
    }

    func json() throws -> String {
        try validateStorage()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    func engineJSON() throws -> String {
        let keys: Set<String> = ["schemaVersion", "rmeUID", "d4UID", "pcUID", "pcStreamIndex",
                                 "bufferFrames", "rmeFifoFrames", "pcFifoFrames", "returnFifoFrames", "srcQuality",
                                 "rmeReturnLeft", "rmeReturnRight", "d4ReturnLeft", "d4ReturnRight",
                                 "forwardGainDB", "returnGainDB", "returnMuted", "tapMuteOriginal", "rmeChannels", "pcChannels"]
        let object = try JSONSerialization.jsonObject(with: Data(json().utf8)) as! [String: Any]
        let selected = object.filter { keys.contains($0.key) }
        return String(decoding: try JSONSerialization.data(withJSONObject: selected, options: [.sortedKeys]), as: UTF8.self)
    }
}

enum ConfigurationError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

struct AudioStreamInventory: Decodable, Identifiable {
    var index: Int
    var id: Int?
    var startingChannel: Int?
    var channels: Int?
    var sampleRate: Double?
    var format: String?
}

struct AudioDeviceInventory: Decodable, Identifiable {
    var id: Int
    var uid: String
    var name: String
    var sampleRate: Double?
    var bufferFrames: Int?
    var inputChannels: Int?
    var outputChannels: Int?
    var alive: Bool?
    var transport: String?
    var inputNames: [String]?
    var outputNames: [String]?
    var outputStreams: [AudioStreamInventory]?

    func channelName(_ channel: Int, input: Bool) -> String {
        let names = input ? inputNames : outputNames
        if let names, names.indices.contains(channel - 1), !names[channel - 1].isEmpty {
            return "\(channel): \(names[channel - 1])"
        }
        return "\(channel)"
    }
}

struct AudioInventory: Decodable {
    var devices: [AudioDeviceInventory]
    var defaultOutputUID: String?
    var systemOutputUID: String?
    var error: String?
    static let empty = AudioInventory(devices: [])
}

struct SourceStatistics: Equatable, Identifiable {
    var name: String
    var callbacks: UInt64
    var frames: UInt64
    var fifoFrames: Int?
    var underruns: UInt64
    var overflows: UInt64
    var ppm: Double?
    var peaks: [Double]
    var id: String { name }

    init(_ value: [String: Any]) {
        name = value["name"] as? String ?? "Unknown"
        callbacks = (value["callbacks"] as? NSNumber)?.uint64Value ?? 0
        frames = (value["frames"] as? NSNumber)?.uint64Value ?? 0
        fifoFrames = value["fifoFrames"] as? Int
        underruns = (value["underruns"] as? NSNumber)?.uint64Value ?? 0
        overflows = (value["overflows"] as? NSNumber)?.uint64Value ?? 0
        ppm = value["ppm"] as? Double
        peaks = (value["peaks"] as? [NSNumber] ?? []).map(\.doubleValue)
    }
}

struct EngineStatus: Equatable {
    var state = "off"
    var error: String?
    var rmeBufferFrames: Int?
    var d4BufferFrames: Int?
    var pcBufferFrames: Int?
    var pcChannels: Int?
    var sources: [SourceStatistics] = []
    var outputPeaks: [Double] = []
    var probePeaks: [Double] = []
    var probeCallbacks: UInt64 = 0
    var probeFrames: UInt64 = 0
    var probeFormat: String?
    var clipped: UInt64 = 0
    var nonFinite: UInt64 = 0

    init() {}
    init(json: String) throws {
        guard let value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw ConfigurationError.invalid("エンジン状態を読み取れませんでした。")
        }
        state = value["state"] as? String ?? "off"
        error = value["error"] as? String
        rmeBufferFrames = value["rmeBufferFrames"] as? Int
        d4BufferFrames = value["d4BufferFrames"] as? Int
        pcBufferFrames = value["pcBufferFrames"] as? Int
        pcChannels = value["pcChannels"] as? Int
        sources = (value["sources"] as? [[String: Any]] ?? []).map(SourceStatistics.init)
        outputPeaks = (value["outputPeaks"] as? [NSNumber] ?? []).map(\.doubleValue)
        probePeaks = (value["probePeaks"] as? [NSNumber] ?? []).map(\.doubleValue)
        probeCallbacks = (value["probeCallbacks"] as? NSNumber)?.uint64Value ?? 0
        probeFrames = (value["probeFrames"] as? NSNumber)?.uint64Value ?? 0
        clipped = (value["clipped"] as? NSNumber)?.uint64Value ?? 0
        nonFinite = (value["nonFinite"] as? NSNumber)?.uint64Value ?? 0
        if let format = value["probeFormat"], !(format is NSNull) {
            if let text = format as? String { probeFormat = text }
            else if JSONSerialization.isValidJSONObject(format), let data = try? JSONSerialization.data(withJSONObject: format, options: [.sortedKeys]) {
                probeFormat = String(decoding: data, as: UTF8.self)
            }
        }
    }
}
