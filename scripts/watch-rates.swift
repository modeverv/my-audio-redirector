#!/usr/bin/env swift
// Read-only rate/device monitoring. No I/O, tap, permission request or property writes.
import Foundation
import CoreAudio

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}
func scalar<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
    var a = address(selector), value = initial, size = UInt32(MemoryLayout<T>.size)
    guard AudioObjectHasProperty(id, &a) else { return nil }
    let result = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0) }
    return result == noErr ? value : nil
}
func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var a = address(selector), value: Unmanaged<CFString>? = nil, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectHasProperty(id, &a) else { return nil }
    let result = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0) }
    guard result == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}
func objects(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
    var a = address(selector), size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr else { return [] }
    var values = [AudioObjectID](repeating: 0, count: Int(size)/MemoryLayout<AudioObjectID>.size)
    guard size > 0 else { return [] }
    let result = values.withUnsafeMutableBytes { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0.baseAddress!) }
    return result == noErr ? values : []
}
func u32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? { scalar(id, selector, UInt32(0)) }
func f64(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Double? { scalar(id, selector, Float64(0)) }
func snapshot() -> [[String: Any]] {
    objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).compactMap { id in
        let name = string(id, kAudioObjectPropertyName) ?? "Unknown"
        guard name.localizedCaseInsensitiveContains("Discrete") || name.localizedCaseInsensitiveContains("Fireface") else { return nil }
        var x: [String: Any] = ["id": id, "name": name]
        x["uid"] = string(id, kAudioDevicePropertyDeviceUID)
        x["nominalRate"] = f64(id, kAudioDevicePropertyNominalSampleRate)
        x["actualRate"] = f64(id, kAudioDevicePropertyActualSampleRate)
        x["bufferFrames"] = u32(id, kAudioDevicePropertyBufferFrameSize)
        x["runningSomewhere"] = u32(id, kAudioDevicePropertyDeviceIsRunningSomewhere)
        x["alive"] = u32(id, kAudioDevicePropertyDeviceIsAlive)
        return x
    }
}
let seconds = max(1, min(3600, Double(CommandLine.arguments.dropFirst().first ?? "30") ?? 30))
let started = Date()
var previous = Data()
var count = 0
repeat {
    let devices = snapshot()
    let value = try JSONSerialization.data(withJSONObject: devices, options: [.sortedKeys])
    if value != previous {
        let record: [String: Any] = ["time": ISO8601DateFormatter().string(from: Date()), "elapsedSeconds": Date().timeIntervalSince(started), "event": previous.isEmpty ? "initial" : "change", "devices": devices]
        let line = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        FileHandle.standardOutput.write(line); FileHandle.standardOutput.write(Data([10]))
        previous = value; count += 1
    }
    Thread.sleep(forTimeInterval: 0.25)
} while Date().timeIntervalSince(started) < seconds
let record: [String: Any] = ["time": ISO8601DateFormatter().string(from: Date()), "event": "finished", "elapsedSeconds": Date().timeIntervalSince(started), "snapshots": count, "pollIntervalSeconds": 0.25]
let line = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
FileHandle.standardOutput.write(line); FileHandle.standardOutput.write(Data([10]))
