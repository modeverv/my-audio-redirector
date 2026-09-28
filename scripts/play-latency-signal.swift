#!/usr/bin/env swift
// Explicit-device latency-test injector. --validate-only never creates an audio queue.
// macOS AudioQueue.h: CurrentDevice is a CFString UID; ChannelAssignments uses
// (device UID, 1-based channel). Queue PCM must be interleaved.
// https://developer.apple.com/documentation/audiotoolbox/audioqueuechannelassignment
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

struct ToolError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
func fail(_ message: String) throws -> Never { throw ToolError(message: message) }
func checked(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { try fail("\(operation) failed (OSStatus \(status)).") }
}
let usage = """
Usage: play-latency-signal.swift --device-uid UID --wav PATH
       [--seconds 0.05...120] [--gain-db -96...0] [--validate-only]

Plays 48 kHz stereo PCM WAV once, explicitly mapping L/R to device host 1/2.
--seconds selects a prefix of the WAV; it never loops or extends the file.
Gain defaults to 0 dB; the resulting absolute peak must not exceed -24 dBFS.
The system default output, device rate, and device buffer size are not changed.
--validate-only checks arguments/WAV without device lookup or audio I/O.
JSON results go to stdout. This is an injector, not a latency measurement.
"""

struct Options {
    var uid = ""
    var wav = ""
    var seconds: Double?
    var gainDB: Float = 0
    var validateOnly = false
    init(_ arguments: [String]) throws {
        var seen = Set<String>()
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard seen.insert(key).inserted else { try fail("Duplicate option: \(key)") }
            if key == "--validate-only" { validateOnly = true; index += 1; continue }
            guard ["--device-uid", "--wav", "--seconds", "--gain-db"].contains(key), index + 1 < arguments.count else {
                try fail("Unknown option or missing value: \(key)")
            }
            let value = arguments[index + 1]
            switch key {
            case "--device-uid": uid = value
            case "--wav": wav = value
            case "--seconds":
                guard let number = Double(value), number.isFinite, (0.05...120).contains(number) else {
                    try fail("--seconds must be finite and within 0.05...120.")
                }
                seconds = number
            default:
                guard let number = Float(value), number.isFinite, (-96...0).contains(number) else {
                    try fail("--gain-db must be finite and within -96...0.")
                }
                gainDB = number
            }
            index += 2
        }
        guard !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !wav.isEmpty else {
            try fail("Both --device-uid and --wav are required.")
        }
    }
}

struct Signal {
    let buffer: AVAudioPCMBuffer
    let peak: Float
    var seconds: Double { Double(buffer.frameLength) / 48_000 }
}
func loadSignal(_ options: Options) throws -> Signal {
    let url = URL(fileURLWithPath: options.wav)
    let fileHandle = try FileHandle(forReadingFrom: url)
    let header = try fileHandle.read(upToCount: 12) ?? Data()
    try fileHandle.close()
    guard header.count == 12, String(data: header.prefix(4), encoding: .ascii) == "RIFF",
          String(data: header.suffix(4), encoding: .ascii) == "WAVE" else {
        try fail("Input must be a RIFF/WAVE file.")
    }
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
    guard file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM,
          file.processingFormat.sampleRate == 48_000, file.processingFormat.channelCount == 2 else {
        try fail("WAV must contain 48000 Hz, two-channel linear PCM (integer or Float32).")
    }
    let frames = options.seconds.map { AVAudioFramePosition(($0 * 48_000).rounded(.down)) } ?? file.length
    guard frames >= 2400, frames <= 5_760_000, frames <= file.length else {
        try fail("Selected duration must be 0.05...120 seconds and must fit inside the WAV; no looping is performed.")
    }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)) else {
        try fail("Could not allocate PCM storage.")
    }
    try file.read(into: buffer, frameCount: AVAudioFrameCount(frames))
    guard buffer.frameLength == frames, buffer.format.isInterleaved, let samples = buffer.floatChannelData?[0] else {
        try fail("WAV did not decode to the complete interleaved Float32 signal.")
    }
    let gain = powf(10, options.gainDB / 20)
    var peak: Float = 0
    for index in 0..<(Int(buffer.frameLength) * 2) {
        guard samples[index].isFinite else { try fail("WAV contains a non-finite sample.") }
        samples[index] *= gain
        peak = max(peak, abs(samples[index]))
    }
    guard peak <= powf(10, -24 / 20) else {
        try fail("Resulting peak exceeds -24 dBFS; provide a quieter WAV or attenuate with --gain-db.")
    }
    return Signal(buffer: buffer, peak: peak)
}

func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func deviceString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var property = address(selector), value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value) == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}
func findDevice(_ uid: String) throws -> (id: AudioDeviceID, name: String, bufferFrames: UInt32) {
    var property = address(kAudioHardwarePropertyDevices), size: UInt32 = 0
    try checked(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size), "Reading device list size")
    var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard !devices.isEmpty else { try fail("No audio devices are available.") }
    try checked(devices.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, $0.baseAddress!) }, "Reading device list")
    guard let id = devices.first(where: { deviceString($0, kAudioDevicePropertyDeviceUID) == uid }) else {
        try fail("Exact output device UID was not found: \(uid). No default-device fallback.")
    }
    var rate: Float64 = 0
    property = address(kAudioDevicePropertyNominalSampleRate); size = UInt32(MemoryLayout<Float64>.size)
    try checked(AudioObjectGetPropertyData(id, &property, 0, nil, &size, &rate), "Reading device rate")
    guard rate == 48_000 else { try fail("Selected device rate is \(rate), not 48000 Hz. The tool will not change it.") }
    property = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
    try checked(AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size), "Reading output layout size")
    guard size >= MemoryLayout<AudioBufferList>.size else { try fail("Device has no output buffer layout.") }
    let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { memory.deallocate() }
    try checked(AudioObjectGetPropertyData(id, &property, 0, nil, &size, memory), "Reading output layout")
    let buffers = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
    guard buffers.reduce(0, { $0 + Int($1.mNumberChannels) }) >= 2 else { try fail("Device has fewer than two output channels.") }
    var frames: UInt32 = 0
    property = address(kAudioDevicePropertyBufferFrameSize); size = UInt32(MemoryLayout<UInt32>.size)
    try checked(AudioObjectGetPropertyData(id, &property, 0, nil, &size, &frames), "Reading device buffer size")
    return (id, deviceString(id, kAudioObjectPropertyName) ?? uid, frames)
}

// Callbacks use the current/main CFRunLoop, which also drives the completion loop.
// No disk reads, allocation, refills or channel mapping happen in the callback.
final class PlaybackState {
    var consumed = false
    var shutdown = false
    var stopStatus: OSStatus = noErr
}
func completedBuffer(_ user: UnsafeMutableRawPointer?, _ queue: AudioQueueRef, _ buffer: AudioQueueBufferRef) {
    guard let user else { return }
    let state = Unmanaged<PlaybackState>.fromOpaque(user).takeUnretainedValue()
    guard !state.shutdown, !state.consumed else { return }
    state.consumed = true
    // A consumed buffer can precede physical playback completion; false drains it.
    state.stopStatus = AudioQueueStop(queue, false)
}

func play(_ signal: Signal, options: Options, report: inout [String: Any]) throws {
    let device = try findDevice(options.uid)
    report["deviceName"] = device.name
    report["deviceBufferFramesBefore"] = device.bufferFrames
    let state = PlaybackState()
    let retainedState = Unmanaged.passRetained(state)
    var queue: AudioQueueRef?
    defer {
        state.shutdown = true
        if let queue {
            let stopStatus = AudioQueueStop(queue, true)
            let disposeStatus = AudioQueueDispose(queue, true)
            report["cleanup"] = ["stopStatus": stopStatus, "disposeStatus": disposeStatus, "confirmed": disposeStatus == noErr]
            // If disposal fails, retain callback state until process exit.
            if disposeStatus == noErr { retainedState.release() }
        } else { retainedState.release() }
    }
    var format = signal.buffer.format.streamDescription.pointee
    try checked(AudioQueueNewOutput(&format, completedBuffer, retainedState.toOpaque(), CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue, 0, &queue), "Creating output queue")
    guard let audioQueue = queue else { try fail("AudioQueueNewOutput returned no queue.") }
    let uid = options.uid as CFString
    var uidReference = Unmanaged.passUnretained(uid)
    try checked(AudioQueueSetProperty(audioQueue, kAudioQueueProperty_CurrentDevice, &uidReference, UInt32(MemoryLayout<Unmanaged<CFString>>.size)), "Selecting explicit output device")
    var assignments = [AudioQueueChannelAssignment(mDeviceUID: .passUnretained(uid), mChannelNumber: 1),
                       AudioQueueChannelAssignment(mDeviceUID: .passUnretained(uid), mChannelNumber: 2)]
    try checked(assignments.withUnsafeMutableBytes { AudioQueueSetProperty(audioQueue, kAudioQueueProperty_ChannelAssignments, $0.baseAddress!, UInt32($0.count)) }, "Assigning host channels 1/2")
    var actualUID: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try checked(AudioQueueGetProperty(audioQueue, kAudioQueueProperty_CurrentDevice, &actualUID, &size), "Verifying output device")
    guard let actualUID, (actualUID.takeUnretainedValue() as String) == options.uid else {
        try fail("Queue device UID readback differs; refusing playback.")
    }
    var buffer: AudioQueueBufferRef?
    let bytes = UInt32(signal.buffer.frameLength) * 2 * UInt32(MemoryLayout<Float>.size)
    try checked(AudioQueueAllocateBuffer(audioQueue, bytes, &buffer), "Allocating output buffer")
    guard let buffer, let samples = signal.buffer.floatChannelData?[0] else { try fail("Output buffer is unavailable.") }
    memcpy(buffer.pointee.mAudioData, samples, Int(bytes))
    buffer.pointee.mAudioDataByteSize = bytes
    try checked(AudioQueueEnqueueBuffer(audioQueue, buffer, 0, nil), "Enqueuing test signal")
    let began = ProcessInfo.processInfo.systemUptime
    try checked(AudioQueueStart(audioQueue, nil), "Starting test signal")
    report["audioStarted"] = true
    report["startedAt"] = ISO8601DateFormatter().string(from: Date())
    let deadline = began + signal.seconds + 10
    while true {
        CFRunLoopRunInMode(.defaultMode, 0.05, false)
        try checked(state.stopStatus, "Draining completed signal")
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        try checked(AudioQueueGetProperty(audioQueue, kAudioQueueProperty_IsRunning, &running, &size), "Reading queue state")
        if state.consumed && running == 0 { break }
        if ProcessInfo.processInfo.systemUptime > deadline { try fail("Timed out waiting for playback to drain.") }
    }
    report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - began
    state.shutdown = true
    try checked(AudioQueueDispose(audioQueue, true), "Disposing completed queue")
    queue = nil
    report["cleanup"] = ["confirmed": true, "disposeStatus": 0]
    report["deviceBufferFramesAfter"] = try findDevice(options.uid).bufferFrames
}

var report: [String: Any] = ["tool": "latency-signal-injector", "success": false, "audioStarted": false,
                            "systemDefaultOutputChanged": false, "deviceRateWritten": false,
                            "deviceBufferWritten": false, "outputHostChannels": [1, 2], "sampleRate": 48_000]
do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--help"] || arguments == ["-h"] { print(usage); exit(0) }
    let options = try Options(arguments)
    let signal = try loadSignal(options)
    report.merge(["deviceUID": options.uid, "wav": URL(fileURLWithPath: options.wav).path,
                  "frames": signal.buffer.frameLength, "signalSeconds": signal.seconds,
                  "gainDB": options.gainDB, "peak": signal.peak, "peakLimitDBFS": -24,
                  "validateOnly": options.validateOnly]) { _, new in new }
    if options.validateOnly { report["deviceChecked"] = false }
    else { try play(signal, options: options, report: &report) }
    report["success"] = true
} catch {
    report["error"] = error.localizedDescription
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
}
if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
}
exit(report["success"] as? Bool == true ? 0 : 1)
