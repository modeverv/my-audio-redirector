#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#include <mach/mach_time.h>
#include <unistd.h>
#include <atomic>
#include <array>
#include <vector>
#include <string>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <cstdlib>
#include <thread>
#include <chrono>
#include <memory>
#include "RedirectorBridge.h"
#include "RealtimeCore.h"

namespace {
constexpr double kRate = 48000.0;
constexpr double kStartTimeout = 8.0;
constexpr double kHeartbeatTimeout = 2.0;
static_assert(std::atomic<uint64_t>::is_always_lock_free, "RT counters require lock-free atomics");
static_assert(std::atomic<float>::is_always_lock_free, "RT meters require lock-free atomics");

AudioObjectPropertyAddress address(AudioObjectPropertySelector sel, AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal, AudioObjectPropertyElement element = kAudioObjectPropertyElementMain) { return {sel, scope, element}; }
template<class T> bool get(AudioObjectID id, AudioObjectPropertySelector sel, T &value, AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal, AudioObjectPropertyElement element = kAudioObjectPropertyElementMain) {
    auto a = address(sel, scope, element); UInt32 size = sizeof(T);
    return AudioObjectGetPropertyData(id, &a, 0, nullptr, &size, &value) == noErr && size == sizeof(T);
}
template<class T> std::vector<T> list(AudioObjectID id, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    auto a = address(sel, scope); UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(id, &a, 0, nullptr, &size) != noErr || size % sizeof(T)) return {};
    std::vector<T> values(size / sizeof(T));
    if (size && AudioObjectGetPropertyData(id, &a, 0, nullptr, &size, values.data()) != noErr) return {};
    values.resize(size / sizeof(T)); return values;
}
NSString *stringProperty(AudioObjectID id, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal, AudioObjectPropertyElement element = kAudioObjectPropertyElementMain) {
    CFStringRef result = nullptr;
    if (!get(id, sel, result, scope, element) || !result) return nil;
    return CFBridgingRelease(result);
}
std::string utf8(NSString *s) { const char *p = s.UTF8String; return p ? p : ""; }
NSString *ns(const std::string &s) { return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] ?: @"Invalid UTF-8"; }
std::string statusError(const char *what, OSStatus status) { return std::string(what) + " (OSStatus " + std::to_string(status) + ")"; }
void errorOut(char *out, size_t size, const std::string &error) { if (out && size) { size_t n = std::min(size - 1, error.size()); memcpy(out, error.data(), n); out[n] = 0; } }
char *jsonString(id object) {
    NSError *error = nil; NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:&error];
    if (!data) return strdup("{\"state\":\"fault\",\"error\":\"JSON serialization failed\"}");
    char *result = static_cast<char *>(malloc(data.length + 1)); if (!result) return nullptr;
    memcpy(result, data.bytes, data.length); result[data.length] = 0; return result;
}
UInt32 channelCount(AudioObjectID device, AudioObjectPropertyScope scope) {
    auto a = address(kAudioDevicePropertyStreamConfiguration, scope); UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &a, 0, nullptr, &size) != noErr || size < offsetof(AudioBufferList, mBuffers)) return 0;
    std::vector<uint8_t> bytes(size);
    if (AudioObjectGetPropertyData(device, &a, 0, nullptr, &size, bytes.data()) != noErr) return 0;
    auto *abl = reinterpret_cast<AudioBufferList *>(bytes.data());
    if (abl->mNumberBuffers > (size - offsetof(AudioBufferList, mBuffers)) / sizeof(AudioBuffer)) return 0;
    UInt32 channels = 0; for (UInt32 i = 0; i < abl->mNumberBuffers; ++i) channels += abl->mBuffers[i].mNumberChannels;
    return channels;
}
bool float32(const AudioStreamBasicDescription &f) {
    return f.mFormatID == kAudioFormatLinearPCM && (f.mFormatFlags & kAudioFormatFlagIsFloat) && !(f.mFormatFlags & kAudioFormatFlagIsBigEndian) && f.mBitsPerChannel == 32 && f.mChannelsPerFrame > 0 && f.mChannelsPerFrame <= MR_MAX_CHANNELS && f.mFramesPerPacket == 1 && f.mBytesPerFrame == sizeof(float) * ((f.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 1 : f.mChannelsPerFrame);
}
NSDictionary *formatJSON(const AudioStreamBasicDescription &f) {
    return @{ @"channels": @(f.mChannelsPerFrame), @"sampleRate": @(f.mSampleRate), @"format": float32(f) ? @"Float32" : @"unsupported", @"formatID": @(f.mFormatID), @"formatFlags": @(f.mFormatFlags), @"bytesPerFrame": @(f.mBytesPerFrame), @"nonInterleaved": @((f.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0) };
}
std::string transportName(UInt32 v) {
    switch (v) { case kAudioDeviceTransportTypeUSB: return "USB"; case kAudioDeviceTransportTypeBuiltIn: return "BuiltIn"; case kAudioDeviceTransportTypeAggregate: return "Aggregate"; case kAudioDeviceTransportTypeVirtual: return "Virtual"; default: break; }
    char text[5] = {char((v >> 24) & 255), char((v >> 16) & 255), char((v >> 8) & 255), char(v & 255), 0};
    for (int i = 0; i < 4; ++i) if (text[i] < 32 || text[i] > 126) return std::to_string(v);
    return text;
}
AudioObjectID findDevice(NSString *uid) {
    for (auto id : list<AudioObjectID>(kAudioObjectSystemObject, kAudioHardwarePropertyDevices)) if ([stringProperty(id, kAudioDevicePropertyDeviceUID) isEqualToString:uid]) return id;
    return kAudioObjectUnknown;
}
NSArray *names(AudioObjectID id, AudioObjectPropertyScope scope, UInt32 count) {
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:count];
    for (UInt32 ch = 1; ch <= count; ++ch) [result addObject:stringProperty(id, kAudioObjectPropertyElementName, scope, ch) ?: @""];
    return result;
}
bool bufferFrameRange(AudioObjectID device,AudioValueRange &range) {
    return get(device,kAudioDevicePropertyBufferFrameSizeRange,range) && std::isfinite(range.mMinimum) && std::isfinite(range.mMaximum) && range.mMinimum>0 && range.mMaximum>=range.mMinimum;
}
bool validateBufferRange(AudioObjectID device,const std::string &uid,uint32_t requested,std::string &error) {
    AudioValueRange range{};
    if(bufferFrameRange(device,range) && (requested<range.mMinimum || requested>range.mMaximum)){
        error="Requested buffer "+std::to_string(requested)+" frames is outside supported range "+utf8([@(range.mMinimum) stringValue])+"–"+utf8([@(range.mMaximum) stringValue])+" frames (deviceUID: "+uid+")";return false;
    }
    return true;
}
NSDictionary *inventoryDevice(AudioObjectID objectID) {
    NSMutableDictionary *r = [NSMutableDictionary dictionary]; r[@"id"] = @(objectID);
    r[@"uid"] = stringProperty(objectID, kAudioDevicePropertyDeviceUID) ?: (id)NSNull.null;
    r[@"name"] = stringProperty(objectID, kAudioObjectPropertyName) ?: (id)NSNull.null;
    Float64 rate; UInt32 buffer, alive, transport, running;
    r[@"sampleRate"] = get(objectID, kAudioDevicePropertyNominalSampleRate, rate) ? @(rate) : (id)NSNull.null;
    r[@"actualSampleRate"] = get(objectID, kAudioDevicePropertyActualSampleRate, rate) ? @(rate) : (id)NSNull.null;
    r[@"runningSomewhere"] = get(objectID, kAudioDevicePropertyDeviceIsRunningSomewhere, running) ? @(running != 0) : (id)NSNull.null;
    r[@"bufferFrames"] = get(objectID, kAudioDevicePropertyBufferFrameSize, buffer) ? @(buffer) : (id)NSNull.null;
    AudioValueRange bufferRange{};bool hasBufferRange=bufferFrameRange(objectID,bufferRange);
    r[@"bufferFrameMin"]=hasBufferRange?(id)@(bufferRange.mMinimum):NSNull.null;r[@"bufferFrameMax"]=hasBufferRange?(id)@(bufferRange.mMaximum):NSNull.null;
    r[@"alive"] = get(objectID, kAudioDevicePropertyDeviceIsAlive, alive) ? @(alive != 0) : (id)NSNull.null;
    r[@"transport"] = get(objectID, kAudioDevicePropertyTransportType, transport) ? ns(transportName(transport)) : (id)NSNull.null;
    auto in = channelCount(objectID, kAudioObjectPropertyScopeInput), out = channelCount(objectID, kAudioObjectPropertyScopeOutput);
    r[@"inputChannels"] = @(in); r[@"outputChannels"] = @(out); r[@"inputNames"] = names(objectID, kAudioObjectPropertyScopeInput, in); r[@"outputNames"] = names(objectID, kAudioObjectPropertyScopeOutput, out);
    NSMutableArray *streams = [NSMutableArray array]; uint32_t index = 0;
    for (auto stream : list<AudioObjectID>(objectID, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)) {
        AudioStreamBasicDescription f{}; UInt32 start = 0;
        NSMutableDictionary *s = [NSMutableDictionary dictionaryWithDictionary:@{@"index": @(index++), @"id": @(stream)}];
        if (get(stream, kAudioStreamPropertyVirtualFormat, f)) [s addEntriesFromDictionary:formatJSON(f)];
        s[@"startingChannel"] = get(stream, kAudioStreamPropertyStartingChannel, start) ? @(start) : (id)NSNull.null;
        [streams addObject:s];
    }
    r[@"outputStreams"] = streams; return r;
}
MRGateSettings defaultGate() { return {1, -60, 0.2f, 50, 30, 6}; }
bool sameGate(const MRGateSettings &a, const MRGateSettings &b) {
    return a.enabled==b.enabled && a.thresholdDB==b.thresholdDB && a.attackMS==b.attackMS &&
           a.holdMS==b.holdMS && a.releaseMS==b.releaseMS && a.hysteresisDB==b.hysteresisDB;
}
struct ChannelSetting { uint32_t channel; float gain, pan; bool muted; MRGateSettings gate = defaultGate(); };
struct Config {
    std::string rmeUID, d4UID, pcUID;
    uint32_t pcStream = 0, buffer = 64, fifo[3] = {64,64,64}, rmeLeft = 11, rmeRight = 12, d4Left = 1, d4Right = 2;
    float forward = 0, returning = 0; bool returnMuted = true, tapMute = false; int quality = 0;
    std::vector<ChannelSetting> channels[2];
    std::vector<uint32_t> gateLinks[2];
    MRGateSettings returnGates[2] = {defaultGate(), defaultGate()};
    bool returnGateLinked = true;
};
bool number(id object) { return [object isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)object) != CFBooleanGetTypeID(); }
bool boolean(id object) { return [object isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)object) == CFBooleanGetTypeID(); }
bool uintField(NSDictionary *d, NSString *key, uint32_t &result, uint32_t low, uint32_t high, bool required, std::string &error) {
    id value = d[key]; if (!value && !required) return true;
    if (!number(value) || !std::isfinite([value doubleValue]) || [value doubleValue] != std::floor([value doubleValue]) || [value doubleValue] < low || [value doubleValue] > high) { error = "Invalid integer field: " + utf8(key); return false; }
    result = [value unsignedIntValue]; return true;
}
bool floatField(NSDictionary *d, NSString *key, float &result, float low, float high, std::string &error) {
    id value = d[key]; if (!value) return true;
    // Configuration controls are Float values. Compare at that same precision:
    // JSON 0.1 must not be rejected against the rounded Float bound 0.1f.
    if (!number(value) || !std::isfinite([value doubleValue]) || !std::isfinite([value floatValue]) || [value floatValue] < low || [value floatValue] > high) { error = "Invalid numeric field: " + utf8(key); return false; }
    result = [value floatValue]; return true;
}
bool boolField(NSDictionary *d, NSString *key, bool &result, std::string &error) {
    id value = d[key]; if (!value) return true;
    if (!boolean(value)) { error = "Invalid boolean field: " + utf8(key); return false; } result = [value boolValue]; return true;
}
bool uidField(NSDictionary *d, NSString *key, std::string &result, std::string &error) {
    id value = d[key]; if (![value isKindOfClass:NSString.class] || [value length] == 0 || [value length] > 1024) { error = "Explicit device UID required: " + utf8(key); return false; }
    result = utf8(value); return true;
}
bool parseGate(id value, MRGateSettings &gate, std::string &error) {
    if (!value) return true;
    if (![value isKindOfClass:NSDictionary.class]) { error = "Gate must be an object"; return false; }
    for (NSString *key in value) if (![@[@"enabled",@"thresholdDB",@"attackMS",@"holdMS",@"releaseMS",@"hysteresisDB"] containsObject:key]) { error = "Unknown gate setting: " + utf8(key); return false; }
    bool enabled = gate.enabled != 0;
    if (!boolField(value,@"enabled",enabled,error) || !floatField(value,@"thresholdDB",gate.thresholdDB,-96,0,error) ||
        !floatField(value,@"attackMS",gate.attackMS,0.1f,50,error) || !floatField(value,@"holdMS",gate.holdMS,0,1000,error) ||
        !floatField(value,@"releaseMS",gate.releaseMS,1,2000,error) || !floatField(value,@"hysteresisDB",gate.hysteresisDB,0,24,error)) return false;
    gate.enabled = enabled; return true;
}
bool parseLinks(id value, std::vector<uint32_t> &links, std::string &error) {
    if (!value) return true;
    if (![value isKindOfClass:NSArray.class] || [value count] > MR_MAX_CHANNELS/2) { error = "Invalid stereo link list"; return false; }
    bool used[MR_MAX_CHANNELS]{};
    for (id entry in value) {
        if (!number(entry) || !std::isfinite([entry doubleValue]) || [entry doubleValue] != std::floor([entry doubleValue]) ||
            [entry doubleValue] < 1 || [entry doubleValue] >= MR_MAX_CHANNELS || [entry intValue]%2 != 1 || used[[entry intValue]-1]) {
            error = "Stereo link requires a unique odd channel number with a right peer"; return false;
        }
        used[[entry intValue]-1] = true; links.push_back([entry unsignedIntValue]-1);
    }
    return true;
}
bool parse(const char *json, Config &c, bool probe, std::string &error) {
    if (!json || strnlen(json, 1024 * 1024 + 1) > 1024 * 1024) { error = "Missing or oversized configuration"; return false; }
    NSError *err = nil; id value = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:json length:strlen(json)] options:0 error:&err];
    if (![value isKindOfClass:NSDictionary.class]) { error = "Configuration must be a JSON object"; return false; }
    NSDictionary *d = value; uint32_t version = 0;
    NSSet *keys = [NSSet setWithArray:@[@"schemaVersion",@"rmeUID",@"d4UID",@"pcUID",@"pcStreamIndex",@"bufferFrames",@"rmeFifoFrames",@"pcFifoFrames",@"returnFifoFrames",@"srcQuality",@"rmeReturnLeft",@"rmeReturnRight",@"d4ReturnLeft",@"d4ReturnRight",@"forwardGainDB",@"returnGainDB",@"returnMuted",@"tapMuteOriginal",@"rmeChannels",@"pcChannels",@"rmeStereoLinks",@"pcStereoLinks",@"returnGates",@"returnGateLinked"]];
    for (NSString *key in d) if (![keys containsObject:key]) { error = "Unknown configuration field: " + utf8(key); return false; }
    if (!uintField(d,@"schemaVersion",version,1,1,true,error) || !uidField(d,@"pcUID",c.pcUID,error) || !uintField(d,@"pcStreamIndex",c.pcStream,0,63,true,error) || !uintField(d,@"bufferFrames",c.buffer,16,MR_MAX_FRAMES,false,error) || !boolField(d,@"tapMuteOriginal",c.tapMute,error)) return false;
    if (probe) { if (c.tapMute) { error = "Capture-only probe requires tapMuteOriginal=false"; return false; } return true; }
    if (!uidField(d,@"rmeUID",c.rmeUID,error) || !uidField(d,@"d4UID",c.d4UID,error)) return false;
    if (c.rmeUID == c.d4UID) { error = "RME and Discrete4 must be distinct physical devices"; return false; }
    NSString *fifos[] = {@"rmeFifoFrames",@"pcFifoFrames",@"returnFifoFrames"};
    for (int i = 0; i < 3; ++i) if (!uintField(d,fifos[i],c.fifo[i],16,MR_MAX_FRAMES,false,error)) return false;
    if (!uintField(d,@"rmeReturnLeft",c.rmeLeft,1,MR_MAX_CHANNELS,false,error) || !uintField(d,@"rmeReturnRight",c.rmeRight,1,MR_MAX_CHANNELS,false,error) || !uintField(d,@"d4ReturnLeft",c.d4Left,1,MR_MAX_CHANNELS,false,error) || !uintField(d,@"d4ReturnRight",c.d4Right,1,MR_MAX_CHANNELS,false,error) || !floatField(d,@"forwardGainDB",c.forward,-96,12,error) || !floatField(d,@"returnGainDB",c.returning,-96,12,error) || !boolField(d,@"returnMuted",c.returnMuted,error)) return false;
    if (c.rmeLeft == c.rmeRight || c.d4Left == c.d4Right) { error = "Stereo return channels must be distinct"; return false; }
    if (!parseLinks(d[@"rmeStereoLinks"],c.gateLinks[0],error) || !parseLinks(d[@"pcStereoLinks"],c.gateLinks[1],error) ||
        !boolField(d,@"returnGateLinked",c.returnGateLinked,error)) return false;
    id returnGates = d[@"returnGates"];
    if (returnGates) {
        if (![returnGates isKindOfClass:NSArray.class] || [returnGates count] != 2) { error = "RETURN requires two gate settings"; return false; }
        for (int i=0;i<2;++i) if (!parseGate(returnGates[i],c.returnGates[i],error)) return false;
    }
    id q = d[@"srcQuality"];
    if (q) { if ([q isEqual:@"fastest"]) c.quality = 0; else if ([q isEqual:@"medium"]) c.quality = 1; else { error = "srcQuality must be fastest or medium"; return false; } }
    NSString *fields[] = {@"rmeChannels", @"pcChannels"};
    for (int source = 0; source < 2; ++source) {
        id rows = d[fields[source]]; if (!rows) continue;
        if (![rows isKindOfClass:NSArray.class] || [rows count] > MR_MAX_CHANNELS) { error = "Invalid source channel list"; return false; }
        bool used[MR_MAX_CHANNELS]{};
        for (id row in rows) {
            if (![row isKindOfClass:NSDictionary.class]) { error = "Channel row must be an object"; return false; }
            for (NSString *key in row) if (![@[@"channel",@"gainDB",@"pan",@"muted",@"gate"] containsObject:key]) { error = "Unknown channel setting: " + utf8(key); return false; }
            ChannelSetting s{0,0,0,true};
            if (!uintField(row,@"channel",s.channel,1,MR_MAX_CHANNELS,true,error) || !floatField(row,@"gainDB",s.gain,-96,12,error) || !floatField(row,@"pan",s.pan,-1,1,error) || !boolField(row,@"muted",s.muted,error)) return false;
            if (!parseGate(row[@"gate"],s.gate,error)) return false;
            if (used[s.channel-1]) { error = "Duplicate source channel"; return false; } used[s.channel-1] = true; --s.channel; c.channels[source].push_back(s);
        }
    }
    for(int source=0;source<2;++source)for(uint32_t pair:c.gateLinks[source]) {
        MRGateSettings left=defaultGate(),right=defaultGate();
        for(const auto &row:c.channels[source]) { if(row.channel==pair)left=row.gate; if(row.channel==pair+1)right=row.gate; }
        if(!sameGate(left,right)) { error="Linked channels require identical gate settings"; return false; }
    }
    if(c.returnGateLinked&&!sameGate(c.returnGates[0],c.returnGates[1])) { error="Linked RETURN channels require identical gate settings"; return false; }
    return true;
}
struct StreamRecord { AudioObjectID id; AudioStreamBasicDescription format; };
struct DeviceRecord {
    AudioObjectID id = 0; std::string uid; uint32_t inputs = 0, outputs = 0, buffer = 0, originalBuffer = 0; bool bufferChanged = false;
    std::vector<StreamRecord> streams;
};
struct ListenerSignals { std::atomic<bool> dirty{false};std::atomic<int> rtFault{0}; };
struct Listener { AudioObjectID id;AudioObjectPropertyAddress a;AudioObjectPropertyListenerBlock block; };
}

struct MREngine;
namespace {
constexpr uint32_t kTimestampTraceCapacity = 512;
struct TimestampTrace {
    double arrivalHostSeconds = 0, inputSampleTime = 0, inputHostSeconds = 0, outputSampleTime = 0, outputHostSeconds = 0;
    uint32_t inputFlags = 0, outputFlags = 0;
    int32_t inputFrames = 0, outputFrames = 0;
    bool inputTimePresent = false, outputTimePresent = false, armed = false, stopping = false;
};
struct IOContext {
    MREngine *engine = nullptr; int role = 0; AudioObjectID device = 0; AudioDeviceIOProcID io = nullptr; bool started = false;
    uint32_t inputChannels = 0, outputChannels = 0, left = 0, right = 1;
    std::atomic<uint64_t> callbacks{0}, frames{0}, heartbeat{0}, completedOutputFrames{0};
    uint64_t previousArmedArrival = 0; // Sole writer: this IOProc; reset only after callback teardown.
    std::atomic<uint64_t> armedCallbacks{0}, maxCallbackIntervalTicks{0}, maxProcessingTicks{0};
    std::atomic<uint32_t> minInputFrames{UINT32_MAX}, maxInputFrames{0}, minOutputFrames{UINT32_MAX}, maxOutputFrames{0};
    std::array<TimestampTrace,kTimestampTraceCapacity> timestampTrace{};
    std::atomic<uint32_t> timestampTraceCount{0};
    std::array<float, MR_MAX_FRAMES * 2> stereo{};
};
}
struct MREngine {
    Config config; MRCore *core = nullptr; MRCoreStats lastStats{}; DeviceRecord rme, d4, pc;
    AudioObjectID tap = 0, aggregate = 0; std::string tapUID, aggregateUID; AudioStreamBasicDescription tapFormat{};
    uint32_t tapChannels = 0, tapBuffer = 0;
    IOContext io[3]; std::vector<Listener> listeners;
    std::shared_ptr<ListenerSignals> signals=std::make_shared<ListenerSignals>();
    dispatch_queue_t notificationQueue=dispatch_queue_create("my-redirector.audio-notifications",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INTERACTIVE,0));
    std::atomic<bool> stopping{true}, captureArmed{false}; std::atomic<uint32_t> inFlight{0};
    std::array<std::atomic<float>, MR_MAX_CHANNELS> probePeaks{}; std::atomic<uint64_t> probeNonFinite{0};
    std::array<float, MR_MAX_FRAMES> zeros{};
    double hostScale = 0; uint64_t startHost = 0;
    bool probe = false, active = false, unsafeTeardown = false; std::string state = "off", error, teardownDiagnostic;
    MREngine() { if(!notificationQueue)throw std::bad_alloc();mach_timebase_info_data_t tb{}; mach_timebase_info(&tb); hostScale = double(tb.numer) / double(tb.denom) / 1.0e9; for (int i=0;i<3;++i) { io[i].engine=this; io[i].role=i; } }
};
namespace {
void fault(MREngine *e, int code) { int zero=0; e->signals->rtFault.compare_exchange_strong(zero,code,std::memory_order_relaxed); }
MRTime timeAt(MREngine *e, const AudioTimeStamp *ts) {
    if (!ts) return {0,0,0};
    bool valid = (ts->mFlags & kAudioTimeStampSampleTimeValid) && (ts->mFlags & kAudioTimeStampHostTimeValid);
    return {ts->mSampleTime, double(ts->mHostTime)*e->hostScale, valid ? 1 : 0};
}
// Diagnostic estimate only: -1 denotes malformed or unequal buffer lengths, 0 no frames.
int32_t traceFrameCount(const AudioBufferList *abl) {
    if(!abl)return 0;
    if(abl->mNumberBuffers>MR_MAX_CHANNELS)return -1;
    uint32_t frames=0;
    for(UInt32 b=0;b<abl->mNumberBuffers;++b){
        const AudioBuffer &buffer=abl->mBuffers[b];uint32_t channels=buffer.mNumberChannels;
        if(!channels || channels>MR_MAX_CHANNELS || buffer.mDataByteSize%(sizeof(float)*channels))return -1;
        uint32_t count=buffer.mDataByteSize/(sizeof(float)*channels);
        if(!count && !buffer.mData)continue;
        if(count>MR_MAX_FRAMES || (frames && count!=frames))return -1;
        frames=count;
    }
    return int32_t(frames);
}
void traceTimestamp(IOContext *io,uint64_t arrival,const AudioBufferList *input,const AudioTimeStamp *inputTime,const AudioBufferList *output,const AudioTimeStamp *outputTime) {
    uint32_t index=io->timestampTraceCount.load(std::memory_order_relaxed);
    if(index>=kTimestampTraceCapacity)return;
    auto &row=io->timestampTrace[index];double scale=io->engine->hostScale;
    row.armed=io->engine->captureArmed.load(std::memory_order_acquire);row.stopping=io->engine->stopping.load(std::memory_order_acquire);
    row.arrivalHostSeconds=double(arrival)*scale;row.inputFrames=traceFrameCount(input);row.inputTimePresent=inputTime!=nullptr;
    if(inputTime){row.inputSampleTime=inputTime->mSampleTime;row.inputHostSeconds=double(inputTime->mHostTime)*scale;row.inputFlags=inputTime->mFlags;}
    row.outputFrames=io->role==2?0:traceFrameCount(output);row.outputTimePresent=io->role!=2 && outputTime!=nullptr;
    if(row.outputTimePresent){row.outputSampleTime=outputTime->mSampleTime;row.outputHostSeconds=double(outputTime->mHostTime)*scale;row.outputFlags=outputTime->mFlags;}
    // This IOProc is the sole writer. Published rows are immutable until callbacks stop.
    io->timestampTraceCount.store(index+1,std::memory_order_release);
}
void silence(AudioBufferList *abl) {
    if (!abl) return;
    for (UInt32 b=0;b<abl->mNumberBuffers;++b) if (abl->mBuffers[b].mData && abl->mBuffers[b].mDataByteSize) memset(abl->mBuffers[b].mData,0,abl->mBuffers[b].mDataByteSize);
}
bool inputViews(const AudioBufferList *abl, uint32_t wanted, const float *zeros, MRChannelView *views, uint32_t &frames) {
    if (!abl || abl->mNumberBuffers > MR_MAX_CHANNELS || wanted == 0 || wanted > MR_MAX_CHANNELS) return false;
    uint32_t channels=0; frames=UINT32_MAX;
    for (UInt32 b=0;b<abl->mNumberBuffers;++b) {
        const AudioBuffer &buffer=abl->mBuffers[b]; uint32_t n=buffer.mNumberChannels;
        if (!n || n>MR_MAX_CHANNELS || channels+n>MR_MAX_CHANNELS || buffer.mDataByteSize % (sizeof(float)*n)) return false;
        uint32_t f=buffer.mDataByteSize/(sizeof(float)*n);
        if(!f && !buffer.mData){for(uint32_t c=0;c<n;++c)views[channels+c]={zeros,1};channels+=n;continue;}
        if (!f || f>MR_MAX_FRAMES) return false;
        if(frames!=UINT32_MAX && frames!=f) return false; frames=f;
        for (uint32_t c=0;c<n;++c) views[channels+c] = {buffer.mData ? static_cast<const float *>(buffer.mData)+c : zeros,buffer.mData ? n : 1};
        channels+=n;
    }
    return channels==wanted && frames>0 && frames<=MR_MAX_FRAMES;
}
bool outputViews(AudioBufferList *abl, uint32_t wanted, uint32_t left, uint32_t right, float *&l, float *&r, uint32_t &ls, uint32_t &rs, uint32_t &frames) {
    if (!abl || abl->mNumberBuffers>MR_MAX_CHANNELS) return false;
    uint32_t channels=0; frames=UINT32_MAX; l=r=nullptr;
    for (UInt32 b=0;b<abl->mNumberBuffers;++b) {
        AudioBuffer &buffer=abl->mBuffers[b]; uint32_t n=buffer.mNumberChannels;
        if (!n || n>MR_MAX_CHANNELS || channels+n>MR_MAX_CHANNELS || buffer.mDataByteSize%(sizeof(float)*n)) return false;
        uint32_t f=buffer.mDataByteSize/(sizeof(float)*n);
        if(!f && !buffer.mData){channels+=n;continue;}
        if (!f || f>MR_MAX_FRAMES) return false; if(frames!=UINT32_MAX && frames!=f) return false; frames=f;
        if (left>=channels && left<channels+n && buffer.mData) { l=static_cast<float *>(buffer.mData)+(left-channels); ls=n; }
        if (right>=channels && right<channels+n && buffer.mData) { r=static_cast<float *>(buffer.mData)+(right-channels); rs=n; }
        channels+=n;
    }
    return channels==wanted && l && r && frames>0 && frames<=MR_MAX_FRAMES;
}
// Each counter has one callback writer; snapshots only load it on the control queue.
template<class T> void recordMaximum(std::atomic<T> &maximum,T value) {
    if(value>maximum.load(std::memory_order_relaxed))maximum.store(value,std::memory_order_relaxed);
}
void recordFrameRange(std::atomic<uint32_t> &minimum,std::atomic<uint32_t> &maximum,uint32_t frames) {
    if(frames<minimum.load(std::memory_order_relaxed))minimum.store(frames,std::memory_order_relaxed);
    recordMaximum(maximum,frames);
}
OSStatus callback(AudioObjectID, const AudioTimeStamp *, const AudioBufferList *input, const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    auto *io=static_cast<IOContext *>(context); auto *e=io->engine;
    uint64_t arrival=mach_absolute_time();bool armedAtEntry=e->captureArmed.load(std::memory_order_acquire);
    e->inFlight.fetch_add(1,std::memory_order_acq_rel);
    struct Guard { MREngine *e;IOContext *io;uint64_t arrival;bool measure=false;~Guard(){if(measure)recordMaximum(io->maxProcessingTicks,mach_absolute_time()-arrival);e->inFlight.fetch_sub(1,std::memory_order_release);} } guard{e,io,arrival};
    silence(output);
    io->heartbeat.store(arrival,std::memory_order_relaxed);io->callbacks.fetch_add(1,std::memory_order_relaxed);
    traceTimestamp(io,arrival,input,inputTime,output,outputTime);
    if(e->stopping.load(std::memory_order_acquire) || !armedAtEntry)return noErr;
    guard.measure=true;io->armedCallbacks.fetch_add(1,std::memory_order_relaxed);
    if(io->previousArmedArrival && arrival>=io->previousArmedArrival)recordMaximum(io->maxCallbackIntervalTicks,arrival-io->previousArmedArrival);
    io->previousArmedArrival=arrival;
    if(e->signals->rtFault.load(std::memory_order_relaxed))return noErr;
    MRChannelView views[MR_MAX_CHANNELS]{}; uint32_t frames=0;
    if (!inputViews(input,io->inputChannels,e->zeros.data(),views,frames)) { fault(e,1); return noErr; }
    recordFrameRange(io->minInputFrames,io->maxInputFrames,frames);
    io->frames.fetch_add(frames,std::memory_order_relaxed);
    if (io->role==2 && e->probe) {
        for(uint32_t c=0;c<io->inputChannels;++c) {
            float peak=0; for(uint32_t f=0;f<frames;++f) { float v=views[c].data[size_t(f)*views[c].stride]; if(std::isfinite(v)) peak=std::max(peak,std::fabs(v)); else e->probeNonFinite.fetch_add(1,std::memory_order_relaxed); }
            e->probePeaks[c].store(peak,std::memory_order_relaxed);
        }
        return noErr;
    }
    if (!e->core) { fault(e,2); return noErr; }
    if(io->role==0) mr_core_push(e->core,0,views,io->inputChannels,frames,timeAt(e,inputTime));
    else if(io->role==1) {
        MRChannelView selected[2]={views[e->config.d4Left-1],views[e->config.d4Right-1]};
        mr_core_push(e->core,2,selected,2,frames,timeAt(e,inputTime));
    } else mr_core_push(e->core,1,views,io->inputChannels,frames,timeAt(e,inputTime));
    if(io->role==2) return noErr;
    float *left=nullptr,*right=nullptr; uint32_t ls=0,rs=0,outputFrames=0;
    if(!outputViews(output,io->outputChannels,io->left,io->right,left,right,ls,rs,outputFrames)) { fault(e,3); return noErr; }
    recordFrameRange(io->minOutputFrames,io->maxOutputFrames,outputFrames);
    mr_core_render(e->core,io->role==0 ? 1 : 0,io->stereo.data(),outputFrames,timeAt(e,outputTime));
    if(e->signals->rtFault.load(std::memory_order_relaxed) || e->stopping.load(std::memory_order_acquire) || !e->captureArmed.load(std::memory_order_acquire)) return noErr;
    for(uint32_t f=0;f<outputFrames;++f) { left[size_t(f)*ls]=io->stereo[2*f]; right[size_t(f)*rs]=io->stereo[2*f+1]; }
    io->completedOutputFrames.fetch_add(outputFrames,std::memory_order_release);
    return noErr;
}
bool addListener(MREngine *e, AudioObjectID id, AudioObjectPropertySelector selector, std::string &error, AudioObjectPropertyScope scope=kAudioObjectPropertyScopeGlobal) {
    auto a=address(selector,scope);
    if(!AudioObjectHasProperty(id,&a))return true;
    // The PC tap may observe the same RME device already watched by the physical route.
    for(const auto &l:e->listeners)if(l.id==id && l.a.mSelector==a.mSelector && l.a.mScope==a.mScope && l.a.mElement==a.mElement)return true;
    // The block retains only this run's atomic signals, never the engine or its IO/core state.
    // Already queued notifications can therefore finish safely after stop/destruction/reset.
    auto signals=e->signals;
    AudioObjectPropertyListenerBlock block=^(UInt32,const AudioObjectPropertyAddress *){
        signals->dirty.store(true,std::memory_order_relaxed);int zero=0;
        signals->rtFault.compare_exchange_strong(zero,4,std::memory_order_relaxed);
    };
    // Allocate tracking storage before registering so allocation failure cannot orphan a listener.
    e->listeners.push_back({id,a,block});
    OSStatus s=AudioObjectAddPropertyListenerBlock(id,&a,e->notificationQueue,e->listeners.back().block);
    if(s!=noErr){e->listeners.pop_back();error=statusError("Registering required audio property monitor",s)+" (object "+std::to_string(id)+", selector "+std::to_string(selector)+")";return false;}
    return true;
}
bool inspectDevice(DeviceRecord &d, const std::string &uid, bool physical, bool needInput, bool needOutput, std::string &error) {
    d.id=findDevice(ns(uid)); d.uid=uid;
    if(!d.id) {error="Configured audio device is unavailable: "+uid;return false;}
    UInt32 alive=0,transport=0; AudioClassID cls=0; Float64 rate=0;
    if(!get(d.id,kAudioDevicePropertyDeviceIsAlive,alive)||!alive) {error="Device is not alive: "+uid;return false;}
    if(physical && (!get(d.id,kAudioDevicePropertyTransportType,transport) || !get(d.id,kAudioObjectPropertyClass,cls) || transport==kAudioDeviceTransportTypeAggregate || transport==kAudioDeviceTransportTypeVirtual || cls==kAudioAggregateDeviceClassID)) {error="RME/Discrete4 selections must be physical devices, not Aggregate/virtual devices";return false;}
    if(!get(d.id,kAudioDevicePropertyNominalSampleRate,rate)||std::fabs(rate-kRate)>0.01) {error="Device must already report 48000 Hz; clock/sample rate will not be changed: "+uid;return false;}
    if(!get(d.id,kAudioDevicePropertyBufferFrameSize,d.buffer)||d.buffer==0||d.buffer>MR_MAX_FRAMES) {error="Unsupported device buffer size: "+uid;return false;}
    d.originalBuffer=d.buffer; d.inputs=channelCount(d.id,kAudioObjectPropertyScopeInput); d.outputs=channelCount(d.id,kAudioObjectPropertyScopeOutput);
    if((needInput && (!d.inputs||d.inputs>MR_MAX_CHANNELS)) || (needOutput && (!d.outputs||d.outputs>MR_MAX_CHANNELS))) {error="Unsupported audio channel count: "+uid;return false;}
    d.streams.clear();
    AudioObjectPropertyScope scopes[]={kAudioObjectPropertyScopeInput,kAudioObjectPropertyScopeOutput};
    for(int dir=0;dir<2;++dir) {
        if((dir==0&&!needInput)||(dir==1&&!needOutput)) continue;
        auto streams=list<AudioObjectID>(d.id,kAudioDevicePropertyStreams,scopes[dir]);
        if(streams.empty()){error="Audio device has no requested streams";return false;}
        for(auto stream:streams) {AudioStreamBasicDescription f{};if(!get(stream,kAudioStreamPropertyVirtualFormat,f)||!float32(f)||std::fabs(f.mSampleRate-kRate)>0.01){error="Only 48000 Hz Float32 virtual streams are supported: "+uid;return false;} d.streams.push_back({stream,f});}
    }
    return true;
}
bool requestBuffer(DeviceRecord &d, uint32_t requested, std::string &error) {
    if(!validateBufferRange(d.id,d.uid,requested,error))return false;
    std::string context=" (deviceUID: "+d.uid+", requested "+std::to_string(requested)+" frames)";
    if(d.buffer!=requested) {
        auto a=address(kAudioDevicePropertyBufferFrameSize); Boolean settable=false;
        OSStatus s=AudioObjectIsPropertySettable(d.id,&a,&settable);
        if(s!=noErr){error=statusError("Checking device buffer writability",s)+context;return false;}
        if(!settable){error="Device buffer size is not writable"+context;return false;}
        s=AudioObjectSetPropertyData(d.id,&a,0,nullptr,sizeof(requested),&requested);
        if(s!=noErr){error=statusError("Setting device buffer",s)+context;return false;}
        d.bufferChanged=true;d.buffer=requested;
    }
    if(!get(d.id,kAudioDevicePropertyBufferFrameSize,d.buffer)||!d.buffer||d.buffer>MR_MAX_FRAMES){error="Cannot read back a supported device buffer size"+context;return false;}
    if(d.buffer!=requested){error="Device buffer request was not honored: actual "+std::to_string(d.buffer)+" frames"+context;return false;}
    return true;
}
bool restoreBuffer(DeviceRecord &d, std::string &diagnostic) {
    if(!d.bufferChanged||!d.id)return true;
    NSString *currentUID=stringProperty(d.id,kAudioDevicePropertyDeviceUID);
    if(!currentUID){diagnostic="Cannot verify device identity before buffer restoration: "+d.uid;return false;}
    if(![currentUID isEqualToString:ns(d.uid)]){d.bufferChanged=false;diagnostic="Buffer not restored because device identity changed: "+d.uid;return true;}
    UInt32 current=0;
    if(!get(d.id,kAudioDevicePropertyBufferFrameSize,current)){diagnostic="Cannot read device buffer before restoration: "+d.uid;return false;}
    if(current==d.originalBuffer){d.bufferChanged=false;return true;}
    if(current!=d.buffer){d.bufferChanged=false;diagnostic="Buffer not restored because another client changed it: "+d.uid+" (current "+std::to_string(current)+" frames)";return true;}
    auto a=address(kAudioDevicePropertyBufferFrameSize);
    OSStatus s=AudioObjectSetPropertyData(d.id,&a,0,nullptr,sizeof(d.originalBuffer),&d.originalBuffer);
    if(s!=noErr){diagnostic=statusError("Restoring device buffer",s)+": "+d.uid;return false;}
    if(!get(d.id,kAudioDevicePropertyBufferFrameSize,current)||current!=d.originalBuffer){diagnostic="Device buffer restoration could not be verified: "+d.uid+" (requested "+std::to_string(d.originalBuffer)+", reported "+std::to_string(current)+" frames)";return false;}
    d.bufferChanged=false;return true;
}
bool tapSetup(MREngine *e, std::string &error) {
    if(!inspectDevice(e->pc,e->config.pcUID,false,false,true,error)) return false;
    auto streams=list<AudioObjectID>(e->pc.id,kAudioDevicePropertyStreams,kAudioObjectPropertyScopeOutput);
    if(e->config.pcStream>=streams.size()){error="PC stream index is outside the selected device's output streams";return false;}
    AudioStreamBasicDescription sourceFormat{};
    if(!get(streams[e->config.pcStream],kAudioStreamPropertyVirtualFormat,sourceFormat)||!float32(sourceFormat)||std::fabs(sourceFormat.mSampleRate-kRate)>0.01){error="Selected PC stream must be 48000 Hz Float32";return false;}
    pid_t pid=getpid();AudioObjectID process=0;UInt32 size=sizeof(process);auto a=address(kAudioHardwarePropertyTranslatePIDToProcessObject);
    OSStatus s=AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,sizeof(pid),&pid,&size,&process);
    if(s!=noErr||!process){error="Cannot resolve this process for mandatory Tap feedback exclusion";return false;}
    if(@available(macOS 14.2,*)) {
        CATapDescription *description=[[CATapDescription alloc] initExcludingProcesses:@[@(process)] andDeviceUID:ns(e->config.pcUID) withStream:e->config.pcStream];
        description.name=@"My Redirector PC Capture";description.privateTap=YES;description.mixdown=NO;description.mono=NO;description.exclusive=YES;
        description.muteBehavior=e->config.tapMute ? CATapMutedWhenTapped : CATapUnmuted;
        s=AudioHardwareCreateProcessTap(description,&e->tap);
        if(s!=noErr||!e->tap){error=statusError("Creating device/stream process Tap",s);return false;}
        CFTypeRef rawDescription=nullptr;
        if(!get(e->tap,kAudioTapPropertyDescription,rawDescription)||!rawDescription){error="Cannot verify created Tap description";return false;}
        CATapDescription *actual=CFBridgingRelease(rawDescription);
        if(![actual isKindOfClass:CATapDescription.class] || !actual.isExclusive || actual.isMixdown || !actual.isPrivate || ![actual.deviceUID isEqualToString:ns(e->config.pcUID)] || !actual.stream || actual.stream.unsignedIntegerValue!=e->config.pcStream || ![actual.processes containsObject:@(process)]) {error="Created Tap did not preserve mandatory self-process exclusion/device stream/non-mixdown/private settings";return false;}
        CFStringRef uid=nullptr;
        if(!get(e->tap,kAudioTapPropertyUID,uid)||!uid){error="Tap UID is unavailable";return false;}
        e->tapUID=utf8(CFBridgingRelease(uid));
        if(!get(e->tap,kAudioTapPropertyFormat,e->tapFormat)||!float32(e->tapFormat)||std::fabs(e->tapFormat.mSampleRate-kRate)>0.01){error="Tap did not provide a supported 48000 Hz Float32 format";return false;}
        e->tapChannels=e->tapFormat.mChannelsPerFrame;
        if(e->tapChannels!=sourceFormat.mChannelsPerFrame){error="Non-mixdown Tap channel count differs from source stream; stereo fallback is forbidden";return false;}
        e->aggregateUID="my-redirector.capture."+utf8(NSUUID.UUID.UUIDString);
        NSDictionary *composition=@{ @kAudioAggregateDeviceNameKey:@"My Redirector Private Tap Capture", @kAudioAggregateDeviceUIDKey:ns(e->aggregateUID), @kAudioAggregateDeviceIsPrivateKey:@YES, @kAudioAggregateDeviceTapAutoStartKey:@NO, @kAudioAggregateDeviceSubDeviceListKey:@[], @kAudioAggregateDeviceTapListKey:@[@{@kAudioSubTapUIDKey:ns(e->tapUID), @kAudioSubTapDriftCompensationKey:@NO}] };
        s=AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)composition,&e->aggregate);
        if(s!=noErr||!e->aggregate){error=statusError("Creating tap-only private capture Aggregate; no hardware anchor will be added",s);return false;}
        CFArrayRef subdevices=nullptr;
        if(!get(e->aggregate,kAudioAggregateDevicePropertyFullSubDeviceList,subdevices)||!subdevices){error="Cannot verify capture Aggregate has no physical subdevices";return false;}
        bool empty=CFArrayGetCount(subdevices)==0;CFRelease(subdevices);
        if(!empty){error="Capture Aggregate unexpectedly contains hardware subdevices";return false;}
        // Property publication may lag aggregate creation; all waiting occurs on the control queue.
        for(int attempt=0;attempt<50;++attempt){
            uint32_t count=channelCount(e->aggregate,kAudioObjectPropertyScopeInput);
            if(count==e->tapChannels && get(e->aggregate,kAudioDevicePropertyBufferFrameSize,e->tapBuffer) && e->tapBuffer>0) break;
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        if(channelCount(e->aggregate,kAudioObjectPropertyScopeInput)!=e->tapChannels){error="Tap-only Aggregate did not publish expected input channels; anchor requirement remains unresolved";return false;}
        if(!validateBufferRange(e->aggregate,e->aggregateUID,e->config.buffer,error))return false;
        std::string bufferContext=" (deviceUID: "+e->aggregateUID+", requested "+std::to_string(e->config.buffer)+" frames)";
        auto bufferAddress=address(kAudioDevicePropertyBufferFrameSize);Boolean writable=false;
        s=AudioObjectIsPropertySettable(e->aggregate,&bufferAddress,&writable);
        if(s!=noErr){error=statusError("Checking private Tap capture buffer writability",s)+bufferContext;return false;}
        if(writable){UInt32 requested=e->config.buffer;s=AudioObjectSetPropertyData(e->aggregate,&bufferAddress,0,nullptr,sizeof(requested),&requested);if(s!=noErr){error=statusError("Setting private Tap capture buffer",s)+bufferContext;return false;}}
        if(!get(e->aggregate,kAudioDevicePropertyBufferFrameSize,e->tapBuffer)||!e->tapBuffer||e->tapBuffer>MR_MAX_FRAMES){error="Unsupported Tap capture buffer size"+bufferContext;return false;}
        if(e->tapBuffer!=e->config.buffer){error="Tap capture buffer request was not honored: actual "+std::to_string(e->tapBuffer)+" frames; no fallback"+bufferContext;return false;}
        for(auto stream:list<AudioObjectID>(e->aggregate,kAudioDevicePropertyStreams,kAudioObjectPropertyScopeInput)) {AudioStreamBasicDescription f{};if(!get(stream,kAudioStreamPropertyVirtualFormat,f)||!float32(f)||std::fabs(f.mSampleRate-kRate)>0.01){error="Tap Aggregate exposes an unsupported input stream format";return false;}}
        e->io[2].device=e->aggregate;e->io[2].inputChannels=e->tapChannels;e->io[2].outputChannels=0;
        return true;
    }
    error="Core Audio process taps require macOS 14.2 or later";return false;
}
bool registerIO(IOContext &io,std::string &error) {
    OSStatus s=AudioDeviceCreateIOProcID(io.device,callback,&io,&io.io);
    if(s!=noErr){error=statusError("Creating HAL IOProc",s);return false;}return true;
}
bool startIO(IOContext &io,std::string &error) {
    OSStatus s=AudioDeviceStart(io.device,io.io);if(s!=noErr){error=statusError("Starting HAL I/O",s);return false;}io.started=true;return true;
}
bool installWatch(MREngine *e,const DeviceRecord &d,std::string &error) {
    if(!addListener(e,d.id,kAudioDevicePropertyDeviceIsAlive,error)||!addListener(e,d.id,kAudioDevicePropertyNominalSampleRate,error)||!addListener(e,d.id,kAudioDevicePropertyBufferFrameSize,error))return false;
    if(!addListener(e,d.id,kAudioDevicePropertyStreamConfiguration,error,kAudioObjectPropertyScopeInput)||!addListener(e,d.id,kAudioDevicePropertyStreamConfiguration,error,kAudioObjectPropertyScopeOutput))return false;
    for(const auto &stream:d.streams)if(!addListener(e,stream.id,kAudioStreamPropertyVirtualFormat,error))return false;
    return true;
}
void fadeBeforeStop(MREngine *e) {
    if(!e->active || e->probe || !e->core || e->signals->rtFault.load(std::memory_order_relaxed) || e->stopping.load(std::memory_order_acquire)) return;
    MRCoreStats initial{};mr_core_snapshot(e->core,&initial);if(initial.fault || initial.primedMask!=7)return;
    mr_core_set_master(e->core,-144,-144,1);
    uint64_t rmeCompleted=e->io[0].completedOutputFrames.load(std::memory_order_acquire),d4Completed=e->io[1].completedOutputFrames.load(std::memory_order_acquire);
    // Core outputFrames counts render entry. Wait for copied output instead and allow one
    // already-running block to have read the old master value before this command.
    uint64_t rmeRequired=240+e->rme.buffer,d4Required=240+e->d4.buffer;
    uint64_t started=mach_absolute_time();
    while(double(mach_absolute_time()-started)*e->hostScale<0.030){
        MRCoreStats current{};mr_core_snapshot(e->core,&current);
        if(current.fault || e->signals->rtFault.load(std::memory_order_relaxed))break;
        if(e->io[0].completedOutputFrames.load(std::memory_order_acquire)-rmeCompleted>=rmeRequired && e->io[1].completedOutputFrames.load(std::memory_order_acquire)-d4Completed>=d4Required)break;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
}
void retainTeardownDiagnostic(MREngine *e,const std::string &message) {
    if(!message.empty() && e->teardownDiagnostic.find(message)==std::string::npos){if(!e->teardownDiagnostic.empty())e->teardownDiagnostic+="; ";e->teardownDiagnostic+=message;}
}
bool teardownFailed(MREngine *e,const std::string &message) {
    retainTeardownDiagnostic(e,message);e->unsafeTeardown=true;e->state="fault";
    if(e->error.empty())e->error=message;else if(e->error.find(message)==std::string::npos)e->error+="; "+message;
    return false;
}
bool stop(MREngine *e) {
    e->captureArmed.store(false,std::memory_order_release);e->stopping.store(true,std::memory_order_release);bool safe=true;
    for(auto &io:e->io){
        if(io.io){
            if(io.started){OSStatus s=AudioDeviceStop(io.device,io.io);if(s!=noErr)retainTeardownDiagnostic(e,statusError("Stopping HAL IOProc",s));}
            OSStatus s=AudioDeviceDestroyIOProcID(io.device,io.io);
            if(s!=noErr){safe=false;retainTeardownDiagnostic(e,statusError("Destroying HAL IOProc; identifier retained for retry",s));continue;}
            io.io=nullptr;io.started=false;
        }
    }
    if(safe){for(int i=0;i<100&&e->inFlight.load(std::memory_order_acquire);++i)std::this_thread::sleep_for(std::chrono::milliseconds(1));safe=e->inFlight.load(std::memory_order_acquire)==0;}
    if(!safe)return teardownFailed(e,"HAL callback teardown could not be confirmed; state retained to avoid freeing live callback memory");
    e->unsafeTeardown=false;
    for(size_t i=0;i<e->listeners.size();){const auto &l=e->listeners[i];OSStatus s=AudioObjectRemovePropertyListenerBlock(l.id,&l.a,e->notificationQueue,l.block);if(s==noErr)e->listeners.erase(e->listeners.begin()+i);else{++i;retainTeardownDiagnostic(e,statusError("Removing audio property monitor; registration retained for retry",s));}}
    if(!e->listeners.empty())return teardownFailed(e,"HAL listener teardown could not be confirmed; callback context retained");
    if(e->core){mr_core_snapshot(e->core,&e->lastStats);mr_core_destroy(e->core);e->core=nullptr;}
    if(e->aggregate){OSStatus s=AudioHardwareDestroyAggregateDevice(e->aggregate);if(s==noErr)e->aggregate=0;else{safe=false;retainTeardownDiagnostic(e,statusError("Destroying private capture Aggregate; identifier retained for retry",s));}}
    // A live aggregate still owns its tap reference; release the tap only after it is gone.
    if(!e->aggregate && e->tap){if(@available(macOS 14.2,*)){OSStatus s=AudioHardwareDestroyProcessTap(e->tap);if(s==noErr)e->tap=0;else{safe=false;retainTeardownDiagnostic(e,statusError("Destroying process Tap; identifier retained for retry",s));}}}
    std::string restoreDiagnostic;
    if(!restoreBuffer(e->d4,restoreDiagnostic))safe=false;retainTeardownDiagnostic(e,restoreDiagnostic);restoreDiagnostic.clear();
    if(!restoreBuffer(e->rme,restoreDiagnostic))safe=false;retainTeardownDiagnostic(e,restoreDiagnostic);
    e->active=false;
    if(!safe)return teardownFailed(e,e->teardownDiagnostic);
    return true;
}
void reset(MREngine *e) {
    // Replace rather than clear: delayed old notifications must not fault a subsequent run.
    auto nextSignals=std::make_shared<ListenerSignals>();e->signals=std::move(nextSignals);
    e->rme={};e->d4={};e->pc={};e->tapUID.clear();e->aggregateUID.clear();e->tapFormat={};e->tapChannels=e->tapBuffer=0;e->error.clear();e->teardownDiagnostic.clear();
    e->captureArmed.store(false,std::memory_order_release);e->probeNonFinite.store(0);e->lastStats={};
    for(auto &v:e->probePeaks)v.store(0);
    for(auto &io:e->io){io.device=0;io.inputChannels=io.outputChannels=0;io.left=0;io.right=1;io.callbacks.store(0);io.frames.store(0);io.heartbeat.store(0);io.completedOutputFrames.store(0);io.timestampTraceCount.store(0);io.timestampTrace={};io.previousArmedArrival=0;io.armedCallbacks.store(0);io.maxCallbackIntervalTicks.store(0);io.maxProcessingTicks.store(0);io.minInputFrames.store(UINT32_MAX);io.maxInputFrames.store(0);io.minOutputFrames.store(UINT32_MAX);io.maxOutputFrames.store(0);}
}
bool begin(MREngine *e,const char *json,bool probe,std::string &error) {
    if(!stop(e)){error=e->error;return false;}reset(e);e->state="starting";e->probe=probe;
    Config c;if(!parse(json,c,probe,error))return false;e->config=std::move(c);
    if(!probe){
        if(!inspectDevice(e->rme,e->config.rmeUID,true,true,true,error)||!inspectDevice(e->d4,e->config.d4UID,true,true,true,error))return false;
        if(e->rme.id==e->d4.id){error="RME and Discrete4 resolve to the same device";return false;}
        if(e->config.rmeLeft>e->rme.outputs||e->config.rmeRight>e->rme.outputs||e->config.d4Left>e->d4.inputs||e->config.d4Right>e->d4.inputs||e->d4.outputs<2){error="Configured route exceeds device channel count";return false;}
        for(const auto &s:e->config.channels[0])if(s.channel>=e->rme.inputs){error="RME channel setting exceeds input channel count";return false;}
        if(!requestBuffer(e->rme,e->config.buffer,error)||!requestBuffer(e->d4,e->config.buffer,error))return false;
    }
    if(!tapSetup(e,error))return false;
    if(!probe){
        uint32_t minimumFIFO[3]={std::max(e->rme.buffer,e->d4.buffer),std::max(e->tapBuffer,e->d4.buffer),std::max(e->d4.buffer,e->rme.buffer)};
        const char *fifoNames[3]={"rmeFifoFrames","pcFifoFrames","returnFifoFrames"};
        for(int i=0;i<3;++i)if(e->config.fifo[i]<minimumFIFO[i]){error=std::string(fifoNames[i])+" requested "+std::to_string(e->config.fifo[i])+" frames; must be at least "+std::to_string(minimumFIFO[i])+" for the actual source/destination buffers; no automatic resize";return false;}
        for(const auto &s:e->config.channels[1])if(s.channel>=e->tapChannels){error="PC channel setting exceeds actual Tap channel count";return false;}
        MRCoreConfig cc{};cc.channels[0]=e->rme.inputs;cc.channels[1]=e->tapChannels;cc.channels[2]=2;cc.maxFrames=MR_MAX_FRAMES;cc.sampleRate=kRate;cc.quality=e->config.quality;
        for(int i=0;i<3;++i)cc.fifoTarget[i]=e->config.fifo[i];char coreError[512]{};e->core=mr_core_create(&cc,coreError,sizeof(coreError));
        if(!e->core){error=std::string("Realtime core creation failed: ")+coreError;return false;}
        for(uint32_t source=0;source<2;++source)for(uint32_t ch=0;ch<cc.channels[source];++ch)mr_core_set_channel(e->core,source,ch,0,(ch%2)?1:-1,1);
        for(uint32_t source=0;source<2;++source) {
            for(const auto &s:e->config.channels[source]) {
                mr_core_set_channel(e->core,source,s.channel,s.gain,s.pan,s.muted);
                mr_core_set_gate(e->core,source,s.channel,&s.gate);
            }
            for(uint32_t pair:e->config.gateLinks[source]) {
                if(pair+1>=cc.channels[source]) { error="Stereo gate link exceeds source channel count"; return false; }
                mr_core_set_gate_link(e->core,source,pair,1);
            }
        }
        for(uint32_t ch=0;ch<2;++ch)mr_core_set_gate(e->core,2,ch,&e->config.returnGates[ch]);
        mr_core_set_gate_link(e->core,2,0,e->config.returnGateLinked);
        mr_core_set_master(e->core,e->config.forward,e->config.returning,e->config.returnMuted);
        e->io[0].device=e->rme.id;e->io[0].inputChannels=e->rme.inputs;e->io[0].outputChannels=e->rme.outputs;e->io[0].left=e->config.rmeLeft-1;e->io[0].right=e->config.rmeRight-1;
        e->io[1].device=e->d4.id;e->io[1].inputChannels=e->d4.inputs;e->io[1].outputChannels=e->d4.outputs;
        if(!registerIO(e->io[0],error)||!registerIO(e->io[1],error))return false;
        if(!installWatch(e,e->rme,error)||!installWatch(e,e->d4,error))return false;
    }
    if(!registerIO(e->io[2],error)||!installWatch(e,e->pc,error))return false;
    if(!addListener(e,e->tap,kAudioTapPropertyFormat,error)||!addListener(e,e->aggregate,kAudioDevicePropertyBufferFrameSize,error))return false;
    e->startHost=mach_absolute_time();e->stopping.store(false,std::memory_order_release);
    // Starting physical hardware can reset a tap's sample-time origin. Establish both
    // physical clocks first and keep all callbacks diagnostic-only until every start returns.
    if(!probe && (!startIO(e->io[0],error)||!startIO(e->io[1],error)))return false;
    if(!startIO(e->io[2],error))return false;
    e->active=true;e->state=probe?"probe":"priming";e->captureArmed.store(true,std::memory_order_release);return true;
}
bool unchanged(const DeviceRecord &d,bool withInput,bool withOutput,std::string &error){
    if(!d.id)return true;UInt32 alive=0,buffer=0;Float64 rate=0;
    if(!get(d.id,kAudioDevicePropertyDeviceIsAlive,alive)||!alive||![stringProperty(d.id,kAudioDevicePropertyDeviceUID) isEqualToString:ns(d.uid)]){error="Audio device disappeared or changed identity";return false;}
    if(!get(d.id,kAudioDevicePropertyNominalSampleRate,rate)||std::fabs(rate-kRate)>0.01){error="Device sample rate changed during operation: "+d.uid+" (reported "+std::to_string(rate)+" Hz)";return false;}
    if(!get(d.id,kAudioDevicePropertyBufferFrameSize,buffer)||buffer!=d.buffer){error="Device buffer size changed during operation";return false;}
    if((withInput&&channelCount(d.id,kAudioObjectPropertyScopeInput)!=d.inputs)||(withOutput&&channelCount(d.id,kAudioObjectPropertyScopeOutput)!=d.outputs)){error="Device channel layout changed during operation";return false;}
    for(const auto &stream:d.streams){AudioStreamBasicDescription f{};if(!get(stream.id,kAudioStreamPropertyVirtualFormat,f)||memcmp(&f,&stream.format,sizeof(f))){error="Device virtual stream format changed during operation";return false;}}
    return true;
}
const char *rtError(int code){switch(code){case 1:return "Input buffer layout/frame count is unsupported";case 2:return "Realtime core missing in callback";case 3:return "Output channel buffer is unavailable or malformed";case 4:return "Audio device format/rate/layout/buffer property changed; output muted immediately";default:return "Realtime callback fault";}}
const char *clockTrackerName(uint32_t tracker){
    static const char *names[]={"RME input","PC input","Return input","Discrete4 output","RME output"};
    return tracker<5?names[tracker]:"unknown clock";
}
std::string coreError(const MRCoreStats &stats){
    const auto &clock=stats.clockFailure;
    if(stats.fault!=6||!clock.valid)return "Realtime DSP/FIFO fault: "+std::to_string(stats.fault);
    std::string why="Audio timestamp discontinuity: ";why+=clockTrackerName(clock.tracker);
    if(clock.reason==2)why+=" sample gap "+std::to_string(clock.currentSampleTime-clock.expectedSampleTime)+" frames";
    else if(clock.reason==3)why+=" host time did not advance";
    else why+=" invalid timestamp";
    return why+"; output stopped (fault 6)";
}
void poll(MREngine *e,MRCoreStats &stats){
    if(e->core){mr_core_snapshot(e->core,&stats);e->lastStats=stats;}else stats=e->lastStats;
    if(!e->active)return;std::string why;int code=e->signals->rtFault.load(std::memory_order_relaxed);
    if(code && code!=4)why=rtError(code);else if(stats.fault)why=coreError(stats);
    if(why.empty()&&!e->probe){if(!unchanged(e->rme,true,true,why)||!unchanged(e->d4,true,true,why)){} }
    if(why.empty())unchanged(e->pc,false,true,why);
    if(why.empty()){
        AudioStreamBasicDescription f{};UInt32 buffer=0;
        if(!get(e->tap,kAudioTapPropertyFormat,f)||memcmp(&f,&e->tapFormat,sizeof(f)))why="Tap format changed or Tap disappeared";
        else if(!get(e->aggregate,kAudioDevicePropertyBufferFrameSize,buffer)||buffer!=e->tapBuffer)why="Tap capture buffer changed";
    }
    if(why.empty()&&code==4)why=rtError(code);
    uint64_t now=mach_absolute_time();double elapsed=double(now-e->startHost)*e->hostScale;
    if(why.empty())for(int i=e->probe?2:0;i<3;++i){uint64_t h=e->io[i].heartbeat.load(std::memory_order_relaxed);if((!h&&elapsed>kStartTimeout)||(h&&now>h&&double(now-h)*e->hostScale>kHeartbeatTimeout)){why=i==2?"PC Tap callback timeout; tap-only clock/start viability is unproven for this output stream":"Physical audio callback timeout";break;}}
    if(why.empty()&&!e->probe){if((stats.primedMask&7)==7)e->state="running";else if(elapsed>kStartTimeout)why="Audio sources did not prime within eight seconds";}
    if(!why.empty()){fault(e,100);e->error=why;e->state="fault";stop(e);}
    e->signals->dirty.store(false,std::memory_order_relaxed);
}
NSArray *timestampTraceJSON(MREngine *e){
    NSMutableArray *streams=[NSMutableArray arrayWithCapacity:3];NSString *names[]={@"RME",@"Discrete4",@"PC Tap"};
    for(int i=0;i<3;++i){
        const auto &io=e->io[i];uint32_t count=std::min(io.timestampTraceCount.load(std::memory_order_acquire),kTimestampTraceCapacity);
        NSMutableArray *rows=[NSMutableArray arrayWithCapacity:count];
        for(uint32_t n=0;n<count;++n){
            const auto &row=io.timestampTrace[n];
            id inputSample=std::isfinite(row.inputSampleTime)?(id)@(row.inputSampleTime):NSNull.null;
            id outputSample=std::isfinite(row.outputSampleTime)?(id)@(row.outputSampleTime):NSNull.null;
            [rows addObject:@{@"callback":@(n+1),@"armed":@(row.armed),@"stopping":@(row.stopping),@"arrivalHostSeconds":@(row.arrivalHostSeconds),@"inputFrames":@(row.inputFrames),@"inputTimePresent":@(row.inputTimePresent),@"inputSampleTime":inputSample,@"inputHostSeconds":@(row.inputHostSeconds),@"inputFlags":@(row.inputFlags),@"outputFrames":@(row.outputFrames),@"outputTimePresent":@(row.outputTimePresent),@"outputSampleTime":outputSample,@"outputHostSeconds":@(row.outputHostSeconds),@"outputFlags":@(row.outputFlags)}];
        }
        [streams addObject:@{@"io":names[i],@"deviceID":@(io.device),@"capacity":@(kTimestampTraceCapacity),@"capturedCallbacks":@(count),@"totalCallbacks":@(io.callbacks.load(std::memory_order_relaxed)),@"rows":rows}];
    }
    return streams;
}
NSArray *ioTimingJSON(MREngine *e){
    NSMutableArray *timing=[NSMutableArray arrayWithCapacity:3];NSString *names[]={@"RME",@"Discrete4",@"PC Tap"};
    for(int i=0;i<3;++i){
        const auto &io=e->io[i];uint64_t callbacks=io.armedCallbacks.load(std::memory_order_relaxed);
        uint32_t inputMin=io.minInputFrames.load(std::memory_order_relaxed),outputMin=io.minOutputFrames.load(std::memory_order_relaxed);
        [timing addObject:@{@"io":names[i],@"armedCallbacks":@(callbacks),@"maxCallbackIntervalUS":callbacks>1?(id)@(double(io.maxCallbackIntervalTicks.load(std::memory_order_relaxed))*e->hostScale*1.0e6):NSNull.null,@"maxProcessingUS":callbacks?(id)@(double(io.maxProcessingTicks.load(std::memory_order_relaxed))*e->hostScale*1.0e6):NSNull.null,@"inputFramesMin":inputMin!=UINT32_MAX?(id)@(inputMin):NSNull.null,@"inputFramesMax":inputMin!=UINT32_MAX?(id)@(io.maxInputFrames.load(std::memory_order_relaxed)):NSNull.null,@"outputFramesMin":outputMin!=UINT32_MAX?(id)@(outputMin):NSNull.null,@"outputFramesMax":outputMin!=UINT32_MAX?(id)@(io.maxOutputFrames.load(std::memory_order_relaxed)):NSNull.null}];
    }
    return timing;
}
NSDictionary *snapshot(MREngine *e){
    MRCoreStats stats{};poll(e,stats);
    NSMutableDictionary *result=[NSMutableDictionary dictionaryWithDictionary:@{@"state":ns(e->state),@"error":e->error.empty()?(id)NSNull.null:ns(e->error),@"rmeBufferFrames":e->rme.id?@(e->rme.buffer):(id)NSNull.null,@"d4BufferFrames":e->d4.id?@(e->d4.buffer):(id)NSNull.null,@"pcBufferFrames":e->tapBuffer?@(e->tapBuffer):(id)NSNull.null,@"pcChannels":@(e->tapChannels),@"tapUID":e->tapUID.empty()?(id)NSNull.null:ns(e->tapUID),@"aggregateUID":e->aggregateUID.empty()?(id)NSNull.null:ns(e->aggregateUID),@"clipped":@(stats.clipped),@"nonFinite":@(stats.nonFinite+e->probeNonFinite.load()),@"fault":@(stats.fault?stats.fault:e->signals->rtFault.load()),@"probeCallbacks":@(e->probe?e->io[2].callbacks.load():0),@"probeFrames":@(e->probe?e->io[2].frames.load():0),@"probeFormat":e->tapChannels?formatJSON(e->tapFormat):(id)NSNull.null,@"captureContainer":@"private-tap-only",@"pcDeviceUID":ns(e->config.pcUID),@"pcStreamIndex":@(e->config.pcStream),@"selfProcessExcluded":@(!e->tapUID.empty()),@"requestedBufferFrames":@(e->config.buffer),@"unsafeTeardown":@(e->unsafeTeardown),@"tapActive":@(e->tap!=0),@"aggregateActive":@(e->aggregate!=0)}];
    NSMutableArray *sources=[NSMutableArray array];NSString *sourceNames[]={@"RME",@"PC",@"Return"};uint32_t counts[]={e->rme.inputs,e->tapChannels,2};int ios[]={0,2,1};
    for(int i=0;i<3;++i){NSMutableArray *peaks=[NSMutableArray array], *gates=[NSMutableArray array];for(uint32_t ch=0;ch<counts[i]&&ch<MR_MAX_CHANNELS;++ch){[peaks addObject:@(stats.inputPeak[i][ch])];[gates addObject:@(stats.gateGain[i][ch])];}[sources addObject:@{@"name":sourceNames[i],@"callbacks":@(e->io[ios[i]].callbacks.load()),@"frames":@(stats.inputFrames[i]),@"fifoFrames":@(stats.fifoFrames[i]),@"fifoMin":@(stats.fifoMin[i]),@"fifoMax":@(stats.fifoMax[i]),@"underruns":@(stats.underruns[i]),@"overflows":@(stats.overflows[i]),@"startupDiscardedFrames":@(stats.startupDiscardedFrames[i]),@"ppm":@(stats.correctionPPM[i]),@"peaks":peaks,@"gateGains":gates}];}
    result[@"sources"]=sources;result[@"outputPeaks"]=@[@(stats.outputPeak[0]),@(stats.outputPeak[1])];result[@"primedMask"]=@(stats.primedMask);result[@"teardownDiagnostic"]=e->teardownDiagnostic.empty()?(id)NSNull.null:ns(e->teardownDiagnostic);
    result[@"ioTiming"]=ioTimingJSON(e);
    if(stats.clockFailure.valid){
        const auto &clock=stats.clockFailure;auto finiteNumber=[](double value)->id{return std::isfinite(value)?(id)@(value):NSNull.null;};
        result[@"clockFailure"]=@{@"tracker":@(clock.tracker),@"trackerName":ns(clockTrackerName(clock.tracker)),@"reason":@(clock.reason),@"previousValid":@(clock.previousValid),@"previousFrames":@(clock.previousFrames),@"previousSampleTime":finiteNumber(clock.previousSampleTime),@"expectedSampleTime":finiteNumber(clock.expectedSampleTime),@"currentSampleTime":finiteNumber(clock.currentSampleTime),@"previousHostSeconds":finiteNumber(clock.previousHostSeconds),@"currentHostSeconds":finiteNumber(clock.currentHostSeconds)};
    }
    if(e->state=="fault")result[@"timestampTrace"]=timestampTraceJSON(e);
    NSMutableArray *peaks=[NSMutableArray array];if(e->probe)for(uint32_t ch=0;ch<e->tapChannels;++ch)[peaks addObject:@(e->probePeaks[ch].load())];result[@"probePeaks"]=peaks;return result;
}
}
extern "C" char *mr_inventory_json(void){@autoreleasepool{NSMutableArray *devices=[NSMutableArray array];for(auto id:list<AudioObjectID>(kAudioObjectSystemObject,kAudioHardwarePropertyDevices))[devices addObject:inventoryDevice(id)];AudioObjectID output=0,system=0;get(kAudioObjectSystemObject,kAudioHardwarePropertyDefaultOutputDevice,output);get(kAudioObjectSystemObject,kAudioHardwarePropertyDefaultSystemOutputDevice,system);return jsonString(@{@"devices":devices,@"defaultOutputUID":stringProperty(output,kAudioDevicePropertyDeviceUID)?:(id)NSNull.null,@"systemOutputUID":stringProperty(system,kAudioDevicePropertyDeviceUID)?:(id)NSNull.null,@"error":NSNull.null});}}
extern "C" void mr_string_free(char *p){free(p);}
extern "C" int mr_validate_config_json(const char *json,char *error,size_t size){@autoreleasepool{Config config;std::string why;bool ok=false;try{ok=parse(json,config,false,why);}catch(const std::exception &x){why=x.what();}catch(...){why="Unexpected configuration validation error";}errorOut(error,size,why);return ok?0:1;}}
extern "C" MREngine *mr_engine_create(void){try{return new MREngine;}catch(...){return nullptr;}}
extern "C" void mr_engine_destroy(MREngine *e){if(!e)return;@autoreleasepool{fadeBeforeStop(e);if(stop(e))delete e;}}
extern "C" int mr_engine_start(MREngine *e,const char *json,char *error,size_t size){if(!e){errorOut(error,size,"Engine is null");return 1;}@autoreleasepool{std::string why;bool ok=false;try{ok=begin(e,json,false,why);}catch(const std::exception &x){why=x.what();}catch(...){why="Unexpected engine setup error";}if(!ok){e->error=why;stop(e);e->state="fault";errorOut(error,size,e->error);return 1;}errorOut(error,size,"");return 0;}}
extern "C" int mr_engine_probe_start(MREngine *e,const char *json,char *error,size_t size){if(!e){errorOut(error,size,"Engine is null");return 1;}@autoreleasepool{std::string why;bool ok=false;try{ok=begin(e,json,true,why);}catch(const std::exception &x){why=x.what();}catch(...){why="Unexpected Tap setup error";}if(!ok){e->error=why;stop(e);e->state="fault";errorOut(error,size,e->error);return 1;}errorOut(error,size,"");return 0;}}
extern "C" void mr_engine_stop(MREngine *e){if(!e)return;@autoreleasepool{fadeBeforeStop(e);if(stop(e)){e->state="off";e->error=e->teardownDiagnostic;}}}
extern "C" void mr_engine_set_channel(MREngine *e,uint32_t source,uint32_t channel,float gain,float pan,int muted){if(!e||!e->core||source>1||!std::isfinite(gain)||gain<-96||gain>12||!std::isfinite(pan)||pan<-1||pan>1)return;uint32_t count=source==0?e->rme.inputs:e->tapChannels;if(channel>=count)return;mr_core_set_channel(e->core,source,channel,gain,pan,muted!=0);}
extern "C" void mr_engine_set_master(MREngine *e,float forward,float returning,int muted){if(!e||!e->core||!std::isfinite(forward)||forward<-96||forward>12||!std::isfinite(returning)||returning<-96||returning>12)return;mr_core_set_master(e->core,forward,returning,muted!=0);}
extern "C" char *mr_engine_status_json(MREngine *e){@autoreleasepool{if(!e)return jsonString(@{@"state":@"fault",@"error":@"Engine is null"});return jsonString(snapshot(e));}}

extern "C" void mr_engine_set_gate(MREngine *e,uint32_t source,uint32_t channel,int enabled,float threshold,float attack,float hold,float release,float hysteresis){
    if(!e||!e->core||source>2)return;
    uint32_t count=source==0?e->rme.inputs:(source==1?e->tapChannels:2);if(channel>=count)return;
    // Reject malformed external control values before they can fault an active core.
    if(!std::isfinite(threshold)||threshold<-96||threshold>0||!std::isfinite(attack)||attack<0.1f||attack>50||
       !std::isfinite(hold)||hold<0||hold>1000||!std::isfinite(release)||release<1||release>2000||
       !std::isfinite(hysteresis)||hysteresis<0||hysteresis>24)return;
    MRGateSettings gate{enabled!=0,threshold,attack,hold,release,hysteresis};mr_core_set_gate(e->core,source,channel,&gate);
}
extern "C" void mr_engine_copy_meters(MREngine *e,MRMeterLevels *out){
    static_assert(MR_METER_CHANNELS==MR_MAX_CHANNELS,"meter ABI channel count");
    if(!out)return;std::memset(out,0,sizeof(*out));if(!e||!e->active)return;
    out->channelCounts[0]=e->rme.inputs;out->channelCounts[1]=e->tapChannels;out->channelCounts[2]=2;
    if(e->probe){out->active=1;for(uint32_t c=0;c<e->tapChannels&&c<MR_METER_CHANNELS;++c)out->inputPeaks[MR_METER_CHANNELS+c]=e->probePeaks[c].load(std::memory_order_relaxed);return;}
    if(!e->core)return;MRCoreStats stats{};mr_core_snapshot(e->core,&stats);
    if(stats.fault||e->signals->rtFault.load(std::memory_order_relaxed))return;
    out->active=1;
    std::memcpy(out->inputPeaks,stats.inputPeak,sizeof(out->inputPeaks));
    std::memcpy(out->gateGains,stats.gateGain,sizeof(out->gateGains));
    std::memcpy(out->outputPeaks,stats.outputPeak,sizeof(out->outputPeaks));
}
