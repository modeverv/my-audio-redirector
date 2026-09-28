#include "RealtimeCore.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <new>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

// Check C++ allocation entry points while running the realtime API. The
// vendored C allocator paths are separately auditable; this is not a malloc
// interposer and does not claim to prove absence of every platform allocation.
static thread_local bool rtGuard = false;
static std::atomic<uint64_t> rtAllocations {0};
void *operator new(std::size_t n) {
    if (rtGuard) rtAllocations.fetch_add(1);
    if (void *p = std::malloc(n ? n : 1)) return p;
    throw std::bad_alloc();
}
void *operator new[](std::size_t n) { return ::operator new(n); }
void operator delete(void *p) noexcept { std::free(p); }
void operator delete[](void *p) noexcept { std::free(p); }
void operator delete(void *p, std::size_t) noexcept { std::free(p); }
void operator delete[](void *p, std::size_t) noexcept { std::free(p); }

namespace {
void require(bool test, const char *reason) { if (!test) throw std::runtime_error(reason); }
struct Guard { Guard() { rtGuard = true; } ~Guard() { rtGuard = false; } };
struct Deleter { void operator()(MRCore *c) const { mr_core_destroy(c); } };
using Core = std::unique_ptr<MRCore, Deleter>;
MRCoreConfig config(uint32_t block = 64, int quality = 0, uint32_t target = 64) {
    MRCoreConfig c {}; c.channels[0] = c.channels[1] = c.channels[2] = 2;
    c.fifoTarget[0] = c.fifoTarget[1] = c.fifoTarget[2] = target;
    c.maxFrames = block; c.sampleRate = 48000; c.quality = quality; return c;
}
MRGateSettings gateSettings(bool enabled = true) { return {enabled ? 1 : 0, -60, .2f, 50, 30, 6}; }
Core create(MRCoreConfig c = config(), bool gatesEnabled = false) {
    char error[256]; Core core(mr_core_create(&c, error, sizeof(error)));
    if (!core) throw std::runtime_error(error);
    // The existing routing/drift tests explicitly bypass gates so their source
    // waveforms remain unchanged. Gate behavior has separate tests below.
    if (!gatesEnabled) {
        const auto gate = gateSettings(false);
        for (unsigned source = 0; source < 3; ++source)
            for (unsigned channel = 0; channel < c.channels[source]; ++channel)
                mr_core_set_gate(core.get(), source, channel, &gate);
    }
    return core;
}
MRCoreStats stats(MRCore *c) { MRCoreStats s {}; mr_core_snapshot(c, &s); return s; }
MRTime timeAt(uint64_t frame, double rate, double phase = 0) { return {double(frame), frame / rate + phase, 1}; }
struct Signals {
    uint32_t block;
    std::array<std::vector<float>, 3> data;
    std::array<std::array<MRChannelView, 2>, 3> views;
    std::vector<float> forward, back;
    explicit Signals(uint32_t b) : block(b), forward(2*b), back(2*b) {
        const float values[3][2] = {{.10f,.20f},{.05f,-.10f},{.30f,-.40f}};
        for (unsigned s=0;s<3;++s) {
            data[s].resize(2*b);
            for(unsigned f=0;f<b;++f) for(unsigned c=0;c<2;++c) data[s][2*f+c]=values[s][c];
            for(unsigned c=0;c<2;++c) views[s][c]={data[s].data()+c,2};
        }
    }
    void push(MRCore *core, unsigned s, MRTime t = {}) {
        Guard guard; mr_core_push(core,s,views[s].data(),2,block,t);
    }
    void render(MRCore *core, unsigned d, MRTime t = {}) {
        Guard guard; mr_core_render(core,d,(d?back:forward).data(),block,t);
    }
};
void enable(MRCore *c) {
    for(unsigned s=0;s<2;++s) for(unsigned ch=0;ch<2;++ch) mr_core_set_channel(c,s,ch,0,ch?1:-1,0);
    mr_core_set_master(c,0,0,0);
}
void cycle(MRCore *c, Signals &x) { for(unsigned s=0;s<3;++s)x.push(c,s); x.render(c,0);x.render(c,1); }
bool silent(const std::vector<float> &x) { return std::all_of(x.begin(),x.end(),[](float f){return f==0;}); }

void pushGateBlock(MRCore *core, unsigned source, const float *left, const float *right, unsigned frames) {
    MRChannelView views[2] = {{left,1},{right,1}};
    Guard guard; mr_core_push(core, source, views, 2, frames, {});
}
void pushGateConstant(MRCore *core, unsigned source, float left, float right, unsigned frames) {
    std::array<float,64> l, r; l.fill(left); r.fill(right);
    while (frames) { const unsigned n=std::min(frames,64u);pushGateBlock(core,source,l.data(),r.data(),n);frames-=n; }
}

void gateEnvelopeAndBlockBoundaries() {
    const MRGateSettings gate {1,-60,.5f,2,3,6}; // attack24 / hold96 / release144 samples
    std::vector<float> input(100,.0001f);
    input.insert(input.end(),37,.01f);
    input.insert(input.end(),75,.00075f); // hysteresis band, stays open after crossing
    input.insert(input.end(),260,.0001f);
    input.insert(input.end(),71,.00075f); // same band while closed must NOT open
    input.insert(input.end(),47,.01f);
    std::vector<float> right(input.size(),0), reference;
    auto core=create(config(),true);
    mr_core_set_gate(core.get(),0,0,&gate);
    for (size_t i=0;i<input.size();++i) {
        pushGateBlock(core.get(),0,&input[i],&right[i],1);
        reference.push_back(stats(core.get()).gateGain[0][0]);
    }
    require(reference[99]==0 && reference[100]>0 && reference[100]<1,"gate added lookahead or hard-switched attack");
    require(std::abs(reference[100]-1.f/24)<1e-6 && reference[123]==1,"gate attack sample count wrong");
    require(reference[211]==1 && reference[307]==1 && reference[308]<1,"hysteresis or hold sample count wrong");
    require(reference[450]>0 && reference[451]==0 && reference[542]==0,"release endpoint or closed hysteresis failed");
    for(unsigned source=0;source<3;++source)for(unsigned block:{16u,32u,64u}) {
        auto c=create(config(),true);
        if(source==2)mr_core_set_gate_link(c.get(),2,0,0);
        mr_core_set_gate(c.get(),source,0,&gate);
        for(size_t i=0;i<input.size();) {
            const auto n=unsigned(std::min(size_t(block),input.size()-i));
            pushGateBlock(c.get(),source,input.data()+i,right.data()+i,n);i+=n;
            const auto s=stats(c.get());
            require(!s.fault && s.gateGain[source][0]==reference[i-1],"gate envelope changed at callback boundary");
            require(s.gateGain[source][1]==0,"independent silent channel gate opened");
        }
    }
    std::puts("PASS gate threshold/hysteresis, sample-exact attack/hold/release and 16/32/64 block continuity");
}

void gateStereoLinks() {
    for(unsigned source=0;source<3;++source)for(bool linked:{false,true}) {
        auto core=create(config(),true);
        mr_core_set_gate_link(core.get(),source,0,linked);
        auto first=gateSettings();first.thresholdDB=-30;first.holdMS=0;first.releaseMS=1;
        auto second=first;second.thresholdDB=0; // Linked detector MUST use first settings.
        mr_core_set_gate(core.get(),source,0,&first);mr_core_set_gate(core.get(),source,1,&second);
        pushGateConstant(core.get(),source,.1f,.0001f,32);
        auto s=stats(core.get());
        require(!s.fault && s.gateGain[source][0]==1 && s.gateGain[source][1]==(linked?1:0),"stereo gate linking or first settings failed");
        for(unsigned n=0;n<48;++n) {
            pushGateConstant(core.get(),source,0,0,1);s=stats(core.get());
            if(linked)require(s.gateGain[source][0]==s.gateGain[source][1],"linked stereo image changed during release");
        }
        require(s.gateGain[source][0]==0 && s.gateGain[source][1]==0,"linked/independent gate did not fully close");
        // The right side also drives a linked detector even when the left is silent.
        pushGateConstant(core.get(),source,0,.1f,32);s=stats(core.get());
        require(s.gateGain[source][0]==(linked?1:0) && s.gateGain[source][1]==(linked?1:0),"right-side max detector failed");
    }
    auto core=create(config(),true);pushGateConstant(core.get(),2,.1f,.0001f,32);
    require(stats(core.get()).gateGain[2][1]==1,"return gate default must be linked");
    std::puts("PASS per-source stereo max detector, common gain, first-channel settings and linked return default");
}

void gateSignalAndBypass() {
    for(unsigned block:{16u,32u,64u}) {
        auto core=create(config(block,0,block),true);Signals x(block);enable(core.get());
        for(auto &v:x.data)std::fill(v.begin(),v.end(),.0001f);
        for(unsigned s=0;s<2;++s)for(unsigned c=0;c<2;++c)mr_core_set_channel(core.get(),s,c,24,c?1:-1,0);
        for(unsigned n=0;n<100;++n)cycle(core.get(),x);
        auto s=stats(core.get());
        require(!s.fault&&s.primedMask==7&&silent(x.forward)&&silent(x.back),"default gate did not close to exact zero before gain/pan");
        require(s.inputPeak[0][0]==.0001f&&s.gateGain[0][0]==0,"raw metering was gated or gain meter incorrect");
        // Gate OFF restores below-threshold audio, while other channels stay closed.
        auto bypass=gateSettings(false);mr_core_set_gate(core.get(),0,0,&bypass);
        mr_core_set_gate(core.get(),2,0,&bypass); // default linked return uses first settings
        for(unsigned n=0;n<100;++n)cycle(core.get(),x);
        s=stats(core.get());
        require(!s.fault&&x.forward[block]>.001f&&std::abs(x.forward[block+1])<1e-12,"bypass or channel isolation failed");
        require(std::abs(x.back[block]-.0001f)<1e-7&&std::abs(x.back[block+1]-.0001f)<1e-7,"return gate bypass did not preserve stereo");
        require(s.gateGain[0][0]==1&&s.gateGain[0][1]==0&&s.gateGain[2][1]==1,"bypass gain telemetry incorrect");
        auto enabled=gateSettings();enabled.holdMS=0;enabled.releaseMS=1;
        mr_core_set_gate(core.get(),0,0,&enabled);mr_core_set_gate(core.get(),2,0,&enabled);
        for(unsigned n=0;n<100;++n)cycle(core.get(),x);
        require(silent(x.forward)&&silent(x.back)&&!stats(core.get()).fault,"gate re-enable did not reach exact silence through ASRC");
    }
    // Initial bypass is exactly unity, rather than imposing a gate attack.
    auto core=create(config());pushGateConstant(core.get(),0,.0001f,0,1);
    require(stats(core.get()).gateGain[0][0]==1,"initial Gate OFF was not an exact bypass");
    std::puts("PASS default noise suppression before gain/pan, exact-zero outputs, bypass and live enable");
}

void gateFailures() {
    for(unsigned field=0;field<6;++field) {
        auto core=create(config(),true);auto g=gateSettings();
        switch(field) {
        case 0:g.enabled=2;break;
        case 1:g.thresholdDB=-97;break;
        case 2:g.attackMS=0;break;
        case 3:g.holdMS=1001;break;
        case 4:g.releaseMS=2001;break;
        default:g.hysteresisDB=std::numeric_limits<float>::quiet_NaN();break;
        }
        mr_core_set_gate(core.get(),0,0,&g);require(stats(core.get()).fault==1,"invalid gate settings accepted");
    }
    {auto core=create(config(),true);const float l=0,r=std::numeric_limits<float>::infinity();pushGateBlock(core.get(),2,&l,&r,1);
     require(stats(core.get()).fault==5&&stats(core.get()).nonFinite==1,"closed linked gate hid nonfinite audio");}
    {auto core=create(config(),true);mr_core_set_gate_link(core.get(),0,1,1);require(stats(core.get()).fault==1,"odd gate pair accepted");}
    {auto core=create(config(),true);pushGateConstant(core.get(),0,0,0,1);mr_core_set_gate_link(core.get(),0,0,1);
     require(stats(core.get()).fault==1,"live gate structure change accepted");}
    std::puts("PASS gate parameter bounds, nonfinite fail-closed and stopped-only link changes");
}

void gateLongEnvelopeAndLiveChanges() {
    auto core=create(config(32,0,32),true);Signals x(32);enable(core.get());
    for(auto &v:x.data)std::fill(v.begin(),v.end(),0);
    for(unsigned f=0;f<32;++f)x.data[0][2*f]=.01f;
    MRGateSettings gate{1,-60,50,1000,2000,24};
    mr_core_set_gate(core.get(),0,0,&gate);
    for(unsigned n=0;n<100;++n)cycle(core.get(),x);
    require(stats(core.get()).gateGain[0][0]==1,"maximum attack did not reach unity");
    std::fill(x.data[0].begin(),x.data[0].end(),0);
    float previous=1;
    for(unsigned n=0;n<4500;++n) {
        cycle(core.get(),x);const auto s=stats(core.get());const float gain=s.gateGain[0][0];
        require(!s.fault&&std::isfinite(gain)&&gain>=0&&gain<=previous,"long gate envelope drifted outside 0..1 or was not monotonic");
        if(n<1500)require(gain==1,"maximum hold duration was shortened");
        previous=gain;
    }
    require(previous==0,"maximum release did not close at exact sample endpoint");
    auto c=create(config(),true);
    pushGateConstant(c.get(),0,.0001f,0,32);require(stats(c.get()).gateGain[0][0]==0,"live change fixture was not closed");
    gate={1,-96,1,0,1,6};mr_core_set_gate(c.get(),0,0,&gate);
    pushGateConstant(c.get(),0,.0001f,0,1);float first=stats(c.get()).gateGain[0][0];
    require(first>0&&first<.03f,"live threshold update did not begin a smooth immediate attack");
    gate.attackMS=2;mr_core_set_gate(c.get(),0,0,&gate);pushGateConstant(c.get(),0,.0001f,0,1);
    require(stats(c.get()).gateGain[0][0]>first&&stats(c.get()).gateGain[0][0]-first<.02f,"live attack update stepped the envelope");
    std::puts("PASS maximum envelope times, bounded monotonic release and smooth live settings updates");
}

void gates() { gateEnvelopeAndBlockBoundaries();gateStereoLinks();gateSignalAndBypass();gateFailures();gateLongEnvelopeAndLiveChanges(); }

void gateBenchmark() {
    using Clock=std::chrono::steady_clock;
    for(unsigned block:{16u,32u,64u})for(bool enabled:{false,true}) {
        auto cfg=config(block,0,block*2);cfg.channels[0]=cfg.channels[1]=20;
        auto core=create(cfg,enabled);
        std::array<std::vector<float>,3> data;
        std::array<std::array<MRChannelView,MR_MAX_CHANNELS>,3> views{};
        std::array<std::vector<double>,3> times;
        std::vector<float> forward(block*2),back(block*2);
        for(unsigned s=0;s<3;++s) {
            data[s].resize(block*cfg.channels[s],.005f);times[s].reserve(30000);
            for(unsigned c=0;c<cfg.channels[s];++c) {
                views[s][c]={data[s].data()+c,cfg.channels[s]};
                if(s<2)mr_core_set_channel(core.get(),s,c,0,c%2?1:-1,0);
            }
        }
        mr_core_set_master(core.get(),0,0,0);
        for(unsigned n=0;n<31000;++n) {
            if(n%250==0)for(auto &samples:data)std::fill(samples.begin(),samples.end(),n%500?.00001f:.005f);
            auto started=Clock::now();
            {Guard g;mr_core_push(core.get(),0,views[0].data(),20,block,{});mr_core_render(core.get(),1,back.data(),block,{});}
            auto ended=Clock::now();if(n>=1000)times[0].push_back(std::chrono::duration<double,std::micro>(ended-started).count());
            started=Clock::now();
            {Guard g;mr_core_push(core.get(),1,views[1].data(),20,block,{});}
            ended=Clock::now();if(n>=1000)times[1].push_back(std::chrono::duration<double,std::micro>(ended-started).count());
            started=Clock::now();
            {Guard g;mr_core_push(core.get(),2,views[2].data(),2,block,{});mr_core_render(core.get(),0,forward.data(),block,{});}
            ended=Clock::now();if(n>=1000)times[2].push_back(std::chrono::duration<double,std::micro>(ended-started).count());
        }
        require(!stats(core.get()).fault&&stats(core.get()).primedMask==7,"gate benchmark faulted");
        const char *names[] = {"RME","PC","D4"};
        for(unsigned s=0;s<3;++s) {
            auto &t=times[s];double sum=0;for(auto v:t)sum+=v;std::sort(t.begin(),t.end());
            std::printf("BENCH Gate%s B%u 20+20+2 %s us mean=%.3f p50=%.3f p99=%.3f max=%.3f callbacks=%zu\n",enabled?"ON":"OFF",block,names[s],sum/t.size(),t[t.size()/2],t[t.size()*99/100],t.back(),t.size());
        }
    }
    std::puts("Offline CPU timings only: no hardware I/O, scheduling deadline, or end-to-end latency claim.");
}

void initializationAndPriming() {
    auto c=config(); c.sampleRate=44100; char error[256];
    require(!mr_core_create(&c,error,sizeof(error)) && error[0],"48 kHz contract not enforced");
    c=config(); c.channels[0]=65; require(!mr_core_create(&c,error,sizeof(error)),"channel bound missing");
    c=config(); c.maxFrames=4097;require(!mr_core_create(&c,error,sizeof(error)),"frame bound missing");
    auto core=create(); Signals x(64); enable(core.get());
    for(unsigned n=0;n<100;++n) {x.render(core.get(),0);x.render(core.get(),1);}
    auto s=stats(core.get());require(!s.fault && !s.primedMask,"initial empty FIFO is a hard fault");
    require(!s.underruns[0] && silent(x.forward),"preprime increments underruns or emits audio");
    cycle(core.get(),x); require(silent(x.forward)&&silent(x.back),"first short input should remain silent");
    for(unsigned n=0;n<100;++n)cycle(core.get(),x);
    s=stats(core.get());require(s.primedMask==7 && !s.fault,"paths did not prime");
    require(std::abs(x.forward[32]-.15f)<1e-4 && std::abs(x.forward[33]-.10f)<1e-4,"stereo mix routing failed");
    require(std::abs(x.back[32]-.30f)<1e-4 && std::abs(x.back[33]+.40f)<1e-4,"return stereo routing failed");
    require(s.fifoMin[0]>0 && s.fifoMax[0]<1024,"unexpected hidden application buffering");
}

void rampsMuteAndClipping() {
    auto core=create();Signals x(64);enable(core.get());
    float firstAudible=0; bool found=false;
    for(unsigned n=0;n<30;++n){cycle(core.get(),x);if(!found&&!silent(x.forward)){firstAudible=std::abs(x.forward[0]);found=true;}}
    require(found&&firstAudible<.02f,"audible startup did not fade in");
    const float before=x.back.back();mr_core_set_master(core.get(),0,0,1);cycle(core.get(),x);
    require(std::abs(x.back[1])>0 && std::abs(x.back[1])<=std::abs(before)+1e-4,"mute stepped instead of ramping");
    for(unsigned n=0;n<10;++n)cycle(core.get(),x);
    require(silent(x.back)&&!stats(core.get()).fault,"return mute stopped capture/priming");
    mr_core_set_channel(core.get(),0,0,0,-1,1);mr_core_set_channel(core.get(),1,0,0,-1,1);
    for(unsigned n=0;n<40;++n)cycle(core.get(),x);
    require(std::abs(x.forward[32])<1e-5 && std::abs(x.forward[33]-.10f)<1e-4,"per-channel mute leaked or affected right");
    mr_core_set_channel(core.get(),0,0,24,-1,0);mr_core_set_channel(core.get(),1,0,24,-1,0);
    for(unsigned n=0;n<40;++n)cycle(core.get(),x);
    auto s=stats(core.get());require(s.clipped>0&&!s.fault,"finite clip guard failed");
    for(float v:x.forward) require(std::isfinite(v)&&std::abs(v)<=1,"unsafe output sample");
}

void faults() {
    { auto core=create();Signals x(64);enable(core.get());for(unsigned n=0;n<30;++n)cycle(core.get(),x);
      for(unsigned n=0;n<100&&!stats(core.get()).fault;++n)x.render(core.get(),0);
      auto s=stats(core.get());require(s.fault==3&&(s.underruns[0]||s.underruns[1]),"running starvation did not latch");
      x.render(core.get(),1);require(silent(x.forward)&&silent(x.back),"fault did not silence both destinations"); }
    { auto core=create();Signals x(64);for(unsigned n=0;n<1000&&!stats(core.get()).fault;++n)x.push(core.get(),0);
      require(stats(core.get()).fault==4 && stats(core.get()).overflows[0]==1,"overflow not detected"); }
    { auto core=create();Signals x(64);x.data[1][3]=std::numeric_limits<float>::quiet_NaN();x.push(core.get(),1);
      require(stats(core.get()).fault==5 && stats(core.get()).nonFinite==1,"muted NaN did not fail silent"); }
    { auto core=create();Signals x(64);x.push(core.get(),0,timeAt(0,48000));x.push(core.get(),0,timeAt(128,48000));
      require(stats(core.get()).fault==6,"input sample discontinuity not detected"); }
    { auto core=create();Signals x(64);x.render(core.get(),0,timeAt(0,48000));x.render(core.get(),0,timeAt(64,48000));
      x.render(core.get(),1,timeAt(30000,48000)); // independent destination timeline
      require(!stats(core.get()).fault,"input/output timelines incorrectly coupled");
      x.render(core.get(),0,timeAt(192,48000));require(stats(core.get()).fault==6,"output discontinuity not detected"); }
    { auto core=create();Signals x(64);MRTime t={0,std::numeric_limits<double>::infinity(),1};x.push(core.get(),2,t);
      require(stats(core.get()).fault==6,"nonfinite timestamp accepted"); }
}

void fillPC(Signals &x, float left, float right) {
    for(unsigned f=0;f<x.block;++f){x.data[1][2*f]=left;x.data[1][2*f+1]=right;}
}
void cycleWithoutPC(MRCore *core, Signals &x) {
    x.push(core,0);x.push(core,2);x.render(core,0);x.render(core,1);
}
void requireReturnContinuous(const Signals &x) {
    for(unsigned f=0;f<x.block;++f)
        require(std::abs(x.back[2*f]-.30f)<3e-4f&&std::abs(x.back[2*f+1]+.40f)<3e-4f,
                "PC recovery interrupted or changed the independent return");
}
void requireRMEOnly(const Signals &x) {
    for(unsigned f=0;f<x.block;++f)
        require(std::abs(x.forward[2*f]-.10f)<3e-4f&&std::abs(x.forward[2*f+1]-.20f)<3e-4f,
                "PC recovery wait interrupted RME or replayed PC audio");
}
void enterPCRecovery(MRCore *core, Signals &x, double *failingRenderUS=nullptr) {
    const auto before=stats(core);
    for(unsigned n=0;n<64&&!stats(core).pcRecovering;++n){
        x.push(core,0);x.push(core,2);
        const auto started=std::chrono::steady_clock::now();
        x.render(core,0);
        const double elapsed=std::chrono::duration<double,std::micro>(std::chrono::steady_clock::now()-started).count();
        x.render(core,1);requireReturnContinuous(x);
        if(failingRenderUS&&stats(core).pcRecovering)*failingRenderUS=elapsed;
    }
    const auto after=stats(core);
    require(!after.fault&&after.pcRecovering&&after.primedMask==7,
            "PC-only starvation stopped the engine or cleared the startup barrier");
    require(after.pcRecoveryCount==before.pcRecoveryCount+1&&after.underruns[1]==before.underruns[1]+1,
            "PC starvation did not count exactly one recovery episode");
    require(after.pcLastRecoveryMissingFrames>0&&after.pcLastRecoveryMissingFrames<=x.block,
            "PC recovery missing-frame count is outside the failed block");
    require(after.pcRecoveryOutputFrames>=before.pcRecoveryOutputFrames+x.block,
            "failed PC output block was not counted as replacement audio");
}

void pcRecoveryAndFreshAudio() {
    for(unsigned block:{16u,32u,64u})for(int quality:{0,1}) {
        auto core=create(config(block,quality,block));Signals x(block);enable(core.get());
        std::array<double,100> recoveryRenderUS{};
        for(unsigned n=0;n<160;++n)cycle(core.get(),x);
        require(stats(core.get()).primedMask==7&&!stats(core.get()).fault,"PC recovery fixture did not prime");
        for(unsigned episode=0;episode<100;++episode) {
            const auto previous=stats(core.get());
            const float oldLeft=x.data[1][0],oldRight=x.data[1][1];
            enterPCRecovery(core.get(),x,&recoveryRenderUS[episode]);
            auto entered=stats(core.get());
            // A failed block can finish at any point in the 48-frame declick.
            // The PC contribution must remain on the old-to-zero segment.
            for(unsigned f=0;f<block;++f)for(unsigned ch=0;ch<2;++ch) {
                const float old=ch?oldRight:oldLeft;
                const float pc=x.forward[2*f+ch]-(ch?.20f:.10f);
                require(std::isfinite(pc)&&pc>=std::min(old,0.f)-5e-4f&&pc<=std::max(old,0.f)+5e-4f,
                        "PC declick introduced an unrelated sample or changed the RME stem");
            }
            const unsigned waitBlocks=(48+block-1)/block+3;
            for(unsigned n=0;n<waitBlocks;++n){cycleWithoutPC(core.get(),x);requireReturnContinuous(x);}
            requireRMEOnly(x);
            auto waiting=stats(core.get());
            require(!waiting.fault&&waiting.pcRecovering&&waiting.primedMask==7,
                    "PC wait changed global readiness or fault state");
            require(waiting.pcRecoveryCount==entered.pcRecoveryCount&&waiting.underruns[1]==entered.underruns[1]&&
                    waiting.pcRecoveryCompleted==previous.pcRecoveryCompleted,
                    "PC wait counted repeated episodes or premature completion");
            require(waiting.pcRecoveryOutputFrames==entered.pcRecoveryOutputFrames+uint64_t(waitBlocks)*block,
                    "PC replacement counter is not measured in destination frames");

            // Deliver a catch-up backlog ending in a NEW, opposite-polarity
            // marker. Reprime must choose its latest window and discard old
            // ring audio; src_reset must also remove the old filter history.
            for(unsigned n=0;n<8;++n)x.push(core.get(),1);
            const float newLeft=episode%2?.05f:-.12f,newRight=episode%2?-.10f:.07f;
            fillPC(x,newLeft,newRight);
            for(unsigned n=0;n<8;++n)x.push(core.get(),1);
            const auto backlog=stats(core.get());
            const unsigned required=block+unsigned(std::ceil(block/.999))+(quality?47:20)+2;
            require(backlog.fifoFrames[1]>required,"recovery fixture did not create a surplus backlog");
            cycleWithoutPC(core.get(),x);requireReturnContinuous(x);
            const auto recovered=stats(core.get());
            require(!recovered.fault&&!recovered.pcRecovering&&recovered.primedMask==7&&
                    recovered.pcRecoveryCompleted==previous.pcRecoveryCompleted+1,
                    "PC did not complete recovery on first full fresh output");
            require(recovered.pcRecoveryDiscardedFrames-backlog.pcRecoveryDiscardedFrames==backlog.fifoFrames[1]-required,
                    "PC recovery did not trim exactly the surplus unread ring frames");
            require(recovered.pcRecoveryOutputFrames==waiting.pcRecoveryOutputFrames,
                    "fresh fade-in was counted as dropped PC output");
            require(std::abs(x.forward[0]-.10f)<std::abs(newLeft)*.05f+5e-4f,
                    "PC recovery resumed with an unfaded first sample");
            for(unsigned f=0;f<block;++f)for(unsigned ch=0;ch<2;++ch) {
                const float fresh=ch?newRight:newLeft;
                const float pc=x.forward[2*f+ch]-(ch?.20f:.10f);
                require(pc*fresh>=-1e-5f&&std::abs(pc)<=std::abs(fresh)*1.2f+5e-4f,
                        "PC recovery replayed old FIFO/SRC audio instead of the fresh marker");
            }
            for(unsigned n=0;n<24;++n){cycle(core.get(),x);requireReturnContinuous(x);}
            for(unsigned f=0;f<block;++f)
                require(std::abs(x.forward[2*f]-(.10f+newLeft))<5e-4f&&
                        std::abs(x.forward[2*f+1]-(.20f+newRight))<5e-4f,
                        "PC recovery did not settle to the fresh stereo signal");
            const auto settled=stats(core.get());
            require(!settled.fault&&!settled.underruns[0]&&!settled.underruns[2]&&
                    !settled.overflows[0]&&!settled.overflows[1]&&!settled.overflows[2]&&
                    settled.pcRecoveryCount==episode+1&&settled.pcRecoveryCompleted==episode+1&&
                    settled.underruns[1]==episode+1,
                    "repeated PC recovery damaged another path or duplicated an episode");
        }
        std::sort(recoveryRenderUS.begin(),recoveryRenderUS.end());
        std::printf("PASS 100 PC-only recovery episodes B%u quality%d; fresh audio, declick, counters and continuous other paths\n",block,quality);
        std::printf("  offline failing D4 core render incl SRC reset: n=100 p50=%.3fus p99=%.3fus max=%.3fus; I/O period=%.3fus (not a realtime bound)\n",
                    recoveryRenderUS[50],recoveryRenderUS[98],recoveryRenderUS[99],block/48000.*1e6);
    }
}

void pcRecoveryFaultBoundaries() {
    {auto core=create();Signals x(64);enable(core.get());
     for(unsigned n=0;n<100;++n){cycleWithoutPC(core.get(),x);require(silent(x.forward)&&silent(x.back),"PC recovery bypassed the initial startup barrier");}
     auto s=stats(core.get());require(!s.fault&&!s.underruns[1]&&!s.pcRecoveryCount&&!s.pcRecovering,
                                    "PC initial priming was counted as running recovery");}
    for(unsigned starved:{0u,2u}) {
        auto core=create();Signals x(64);enable(core.get());for(unsigned n=0;n<100;++n)cycle(core.get(),x);
        for(unsigned n=0;n<64&&!stats(core.get()).fault;++n){
            for(unsigned source=0;source<3;++source)if(source!=starved)x.push(core.get(),source);
            x.render(core.get(),0);x.render(core.get(),1);
        }
        auto s=stats(core.get());require(s.fault==3&&s.underruns[starved]==1&&!s.pcRecoveryCount,
                                        "non-PC starvation was incorrectly made recoverable");
        x.render(core.get(),0);x.render(core.get(),1);require(silent(x.forward)&&silent(x.back),"fatal starvation did not silence both destinations");
    }
    for(unsigned failure=0;failure<5;++failure) {
        auto core=create();Signals x(64);enable(core.get());for(unsigned n=0;n<100;++n)cycle(core.get(),x);
        // Seed a valid PC clock BEFORE the outage: recovery must preserve its
        // continuity history, not silently accept a new origin on resumption.
        if(failure==1||failure==2){x.push(core.get(),1,timeAt(0,48000));x.push(core.get(),1,timeAt(64,48000));}
        enterPCRecovery(core.get(),x);
        int expected=0;
        if(failure==0){x.data[1][3]=std::numeric_limits<float>::quiet_NaN();x.push(core.get(),1);expected=5;}
        if(failure==1){x.push(core.get(),1,timeAt(192,48000));expected=6;}
        if(failure==2){x.push(core.get(),1,{128,64./48000,1});expected=6;}
        if(failure==3){x.render(core.get(),0,timeAt(0,48000));x.render(core.get(),0,timeAt(128,48000));expected=6;}
        if(failure==4){for(unsigned n=0;n<1000&&!stats(core.get()).fault;++n)x.push(core.get(),1);expected=4;}
        auto s=stats(core.get());require(s.fault==expected,"PC recovery suppressed a non-recoverable fault");
        x.render(core.get(),0);x.render(core.get(),1);require(silent(x.forward)&&silent(x.back),"PC recovery masked fatal output silence");
    }
    std::puts("PASS PC recovery preserves initial priming and fatal RME/return starvation, PC nonfinite/clock/overflow and output clock checks");
}

void pcRecoveryRapidRefill() {
    for(unsigned block:{16u,32u,64u})for(int quality:{0,1}) {
        auto core=create(config(block,quality,block));Signals x(block);enable(core.get());
        for(unsigned n=0;n<160;++n)cycle(core.get(),x);
        enterPCRecovery(core.get(),x);
        const auto entered=stats(core.get());
        fillPC(x,-.12f,.07f);
        for(unsigned n=0;n<16;++n)x.push(core.get(),1);
        const unsigned fadingBlocks=block<48?(48-block+block-1)/block:0;
        float previousGain[2]={1,1};
        for(unsigned n=0;n<fadingBlocks;++n) {
            cycleWithoutPC(core.get(),x);requireReturnContinuous(x);
            const auto s=stats(core.get());
            require(!s.fault&&s.pcRecovering&&s.pcRecoveryCompleted==entered.pcRecoveryCompleted,
                    "rapid PC refill interrupted the 48-frame fade-out");
            for(unsigned f=0;f<block;++f)for(unsigned ch=0;ch<2;++ch) {
                const float pc=x.forward[2*f+ch]-(ch?.20f:.10f);
                const float gain=pc/(ch?-.10f:.05f);
                require(gain>=-1e-3f&&gain<=previousGain[ch]+1e-3f,
                        "rapid PC refill stepped or started fresh audio during fade-out");
                previousGain[ch]=gain;
            }
        }
        cycleWithoutPC(core.get(),x);requireReturnContinuous(x);
        const auto recovered=stats(core.get());
        require(!recovered.fault&&!recovered.pcRecovering&&
                recovered.pcRecoveryCompleted==entered.pcRecoveryCompleted+1&&
                recovered.pcRecoveryOutputFrames==entered.pcRecoveryOutputFrames+uint64_t(fadingBlocks)*block,
                "rapid PC refill did not resume immediately after the full fade-out");
        for(unsigned f=0;f<block;++f)
            require(x.forward[2*f]-.10f<5e-4f&&x.forward[2*f+1]-.20f>-5e-4f,
                    "rapid refill replayed the old polarity after recovery");
        for(unsigned n=0;n<24;++n){cycle(core.get(),x);requireReturnContinuous(x);}
        require(std::abs(x.forward[block]+.02f)<5e-4f&&std::abs(x.forward[block+1]-.27f)<5e-4f,
                "rapid refill did not settle to fresh PC audio");
    }
    std::puts("PASS immediate PC catch-up waits for the full 1ms fade-out at B16/B32/B64 and both SRC qualities");
}

void pcRecoveryRepeatedBeforeFadeInCompletes() {
    for(unsigned block:{16u,32u,64u})for(int quality:{0,1}) {
        auto core=create(config(block,quality,block));Signals x(block);enable(core.get());
        for(unsigned n=0;n<160;++n)cycle(core.get(),x);
        enterPCRecovery(core.get(),x);
        for(unsigned n=0;n<(48+block-1)/block+1;++n)cycleWithoutPC(core.get(),x);
        fillPC(x,-.12f,.07f);
        const unsigned required=block+unsigned(std::ceil(block/.999))+(quality?47:20)+2;
        for(unsigned n=0;n<(required+block-1)/block;++n)x.push(core.get(),1);
        cycleWithoutPC(core.get(),x);
        require(stats(core.get()).pcRecoveryCompleted==1&&!stats(core.get()).pcRecovering,
                "short PC refill did not re-prime");
        unsigned freshBlocks=1;
        for(unsigned n=0;n<16&&!stats(core.get()).pcRecovering;++n) {
            const float previousPC=x.forward[x.forward.size()-2]-.10f;
            cycleWithoutPC(core.get(),x);requireReturnContinuous(x);
            if(stats(core.get()).pcRecovering) {
                const float firstPC=x.forward[0]-.10f;
                require(std::abs(firstPC)<=std::abs(previousPC)+5e-4f&&firstPC*previousPC>=-1e-5f,
                        "second PC outage stepped to an old full-gain sample");
            } else ++freshBlocks;
        }
        const auto s=stats(core.get());
        require(!s.fault&&s.pcRecovering&&s.pcRecoveryCount==2&&s.underruns[1]==2&&s.pcRecoveryCompleted==1,
                "back-to-back PC outages were merged, lost, or made fatal");
        if(block==16)require(freshBlocks*block<48,"B16 fixture did not interrupt the recovery fade-in");
        for(unsigned n=0;n<(48+block-1)/block+2;++n){cycleWithoutPC(core.get(),x);requireReturnContinuous(x);}
        requireRMEOnly(x);
        for(unsigned n=0;n<(required+block-1)/block;++n)x.push(core.get(),1);
        cycleWithoutPC(core.get(),x);
        require(!stats(core.get()).fault&&stats(core.get()).pcRecoveryCompleted==2&&!stats(core.get()).pcRecovering,
                "second PC episode did not recover independently");
    }
    std::puts("PASS back-to-back PC outages, including B16 starvation during the recovery fade-in");
}

void clockDiagnosticCall(Signals &signals, MRCore *core, unsigned tracker, MRTime time) {
    if (tracker < 3) signals.push(core, tracker, time);
    else signals.render(core, tracker - 3, time);
}

void clockFailureDiagnostics() {
    for (unsigned block : {16u, 32u, 64u}) for (unsigned tracker = 0; tracker < 5; ++tracker) {
        for (double extra : {112., .50001, -200.}) {
            auto core = create(config(block, 0, block)); Signals x(block);
            require(!stats(core.get()).clockFailure.valid, "new core has a clock failure record");
            const MRTime first{1000.25, 10, 1}, next{first.sampleTime + block + extra, 10.01, 1};
            clockDiagnosticCall(x, core.get(), tracker, first);
            clockDiagnosticCall(x, core.get(), tracker, next);
            const auto s = stats(core.get()); const auto &f = s.clockFailure;
            require(s.fault == 6 && f.valid && f.previousValid && f.tracker == tracker &&
                f.reason == MR_CLOCK_SAMPLE_TIME_GAP && f.previousFrames == block &&
                f.previousSampleTime == first.sampleTime && f.expectedSampleTime == first.sampleTime + block &&
                f.currentSampleTime == next.sampleTime && f.previousHostSeconds == first.hostSeconds &&
                f.currentHostSeconds == next.hostSeconds, "clock gap diagnostic identity or samples are incorrect");
            // A later callback cannot overwrite the first fault, even if it
            // has another tracker/reason. Both outputs remain fail silent.
            clockDiagnosticCall(x, core.get(), (tracker + 1) % 5, {0, -10, 1});
            x.render(core.get(), 0); x.render(core.get(), 1);
            const auto later = stats(core.get()).clockFailure;
            require(later.tracker == tracker && later.reason == f.reason && later.currentSampleTime == f.currentSampleTime &&
                silent(x.forward) && silent(x.back), "clock failure changed after latching or did not silence");
        }
        for (double hostDelta : {0., -.01}) {
            auto core = create(config(block, 0, block)); Signals x(block);
            clockDiagnosticCall(x, core.get(), tracker, {100, 10, 1});
            clockDiagnosticCall(x, core.get(), tracker, {100. + block, 10 + hostDelta, 1});
            const auto f = stats(core.get()).clockFailure;
            require(f.valid && f.tracker == tracker && f.reason == MR_CLOCK_HOST_TIME_NONINCREASING &&
                f.currentSampleTime == f.expectedSampleTime && f.currentHostSeconds == 10 + hostDelta,
                "non-increasing host time diagnostic is incorrect");
        }
        for (bool previous : {false, true}) for (bool badHost : {false, true}) {
            auto core = create(config(block, 0, block)); Signals x(block);
            if (previous) clockDiagnosticCall(x, core.get(), tracker, {100, 10, 1});
            const MRTime invalid{badHost ? 100. + block : std::numeric_limits<double>::quiet_NaN(),
                                 badHost ? std::numeric_limits<double>::infinity() : 10.01, 1};
            clockDiagnosticCall(x, core.get(), tracker, invalid);
            const auto s = stats(core.get()); const auto &f = s.clockFailure;
            require(s.fault == 6 && f.valid && f.tracker == tracker && f.previousValid == int(previous) &&
                f.reason == MR_CLOCK_NONFINITE_TIMESTAMP && (badHost ? std::isinf(f.currentHostSeconds) : std::isnan(f.currentSampleTime)),
                "nonfinite timestamp diagnostic lost invalid data or previous-valid state");
        }
        // Preserve the existing tolerance and valid-flag behavior exactly.
        auto core = create(config(block, 0, block)); Signals x(block);
        clockDiagnosticCall(x, core.get(), tracker, {100, 10, 1});
        clockDiagnosticCall(x, core.get(), tracker, {100.5 + block, 10.01, 1});
        clockDiagnosticCall(x, core.get(), tracker, {});
        clockDiagnosticCall(x, core.get(), tracker, {-10000, 20, 1});
        require(!stats(core.get()).fault && !stats(core.get()).clockFailure.valid, "clock diagnostic changed acceptance criteria");
    }
    std::puts("PASS all five clock identities, exact first-failure values/reasons, immutable record and unchanged timestamp acceptance");
}

void concurrentClockFailureDiagnostics() {
    for (unsigned repetition = 0; repetition < 100; ++repetition) {
        auto core = create(); Signals x(64);
        for (unsigned tracker = 0; tracker < 5; ++tracker)
            clockDiagnosticCall(x, core.get(), tracker, {1000. + tracker * 100, 100. + tracker, 1});
        std::atomic<bool> start{false}; std::atomic<unsigned> finished{0};
        std::array<std::thread, 5> callbacks;
        for (unsigned tracker = 0; tracker < 5; ++tracker) callbacks[tracker] = std::thread([&, tracker] {
            while (!start.load(std::memory_order_acquire)) std::this_thread::yield();
            clockDiagnosticCall(x, core.get(), tracker, {1000. + tracker * 100 + 64 + tracker + 1, 100.01 + tracker, 1});
            finished.fetch_add(1, std::memory_order_release);
        });
        bool coherent = true; int firstTracker = -1;
        auto check = [&](const MRClockFailure &f) {
            if (!f.valid) return;
            const unsigned tracker = f.tracker;
            coherent = coherent && tracker < 5 && f.previousValid && f.reason == MR_CLOCK_SAMPLE_TIME_GAP &&
                f.previousFrames == 64 && f.previousSampleTime == 1000. + tracker * 100 &&
                f.expectedSampleTime == 1064. + tracker * 100 && f.currentSampleTime == 1065. + tracker * 101 &&
                f.previousHostSeconds == 100. + tracker && f.currentHostSeconds == 100.01 + tracker;
            if (firstTracker == -1) firstTracker = int(tracker);
            else coherent = coherent && firstTracker == int(tracker);
        };
        start.store(true, std::memory_order_release);
        while (finished.load(std::memory_order_acquire) < 5) check(stats(core.get()).clockFailure);
        for (auto &thread : callbacks) thread.join();
        const auto s = stats(core.get()); check(s.clockFailure);
        require(coherent && firstTracker >= 0 && s.fault == 6, "concurrent clock-fault publication tore or replaced the first record");
    }
    std::puts("PASS concurrent clock failures and snapshots publish one complete immutable record (100 races)");
}

void negativeSampleOrigins() {
    // Apple documents that HAL sample times may be small negative numbers.
    // Each input/output timeline has its own origin and crosses zero normally.
    // A subsequent reset is still a discontinuity, not a legal running rebase.
    for(int quality:{0,1}) {
        auto core=create(config(16,quality,16));Signals x(16);enable(core.get());
        const double inputOrigins[3]={-127.5,-95.25,-31.75};
        const double outputOrigins[2]={-255.75,-63.25};
        for(unsigned n=0;n<128;++n) {
            const double frame=double(n)*16;
            for(unsigned s=0;s<3;++s)x.push(core.get(),s,{inputOrigins[s]+frame,1000+frame/48000+s*.01,1});
            for(unsigned d=0;d<2;++d)x.render(core.get(),d,{outputOrigins[d]+frame,2000+frame/48000+d*.02,1});
        }
        const auto snapshot=stats(core.get());
        require(!snapshot.fault&&snapshot.primedMask==7,"negative sample origins or zero crossing were rejected");
        require(std::abs(x.forward[16]-.15f)<1e-3&&std::abs(x.back[16]-.30f)<1e-3,"negative origins changed stereo routing");
        x.push(core.get(),1,{inputOrigins[1],1000+128.*16/48000+.01,1});
        require(stats(core.get()).fault==6,"running clock origin reset did not latch a fault");
        x.render(core.get(),0);x.render(core.get(),1);
        require(silent(x.forward)&&silent(x.back),"running clock origin reset did not fail silent");
    }
    std::puts("PASS negative sample origins, zero crossing, independent timelines and strict running reset");
}

// Event-driven model: RME I/O, PC capture and D4 I/O use independent clocks
// and callback phases. No wall-clock sleeps, no Core Audio device access.
void simulate(uint32_t block, int quality, double ppm, double phaseFraction, bool timestamps, uint32_t target=64, bool expectStarvation=false) {
    auto core=create(config(block,quality,target));Signals x(block);enable(core.get());
    const double rates[3]={48000*(1+ppm*1e-6),48000*(1-ppm*.7e-6),48000};
    const double phases[3]={0,phaseFraction*block/48000,(1-phaseFraction)*block/48000};
    std::array<uint64_t,3> count={0,0,0};
    std::array<double,3> next={phases[0],phases[1],phases[2]};
    const double duration=60;
    uint64_t events=0;
    while(true){
        unsigned i=unsigned(std::min_element(next.begin(),next.end())-next.begin());
        if(next[i]>duration)break;
        MRTime t=timestamps?timeAt(count[i],rates[i],phases[i]):MRTime{};
        if(i==0){x.push(core.get(),0,t);x.render(core.get(),1,t);}
        else if(i==1)x.push(core.get(),1,t);
        else {x.push(core.get(),2,t);x.render(core.get(),0,t);}
        count[i]+=block;next[i]=count[i]/rates[i]+phases[i];
        if((++events%1024)==0){
            auto s=stats(core.get());
            if(s.fault){
                if(expectStarvation && s.fault==3){x.render(core.get(),0);x.render(core.get(),1);require(silent(x.forward)&&silent(x.back),"unsafe low reserve did not fail silent");std::puts("  Q32/B64 phase-crossing limitation detected: fault3, no hidden target increase");return;}
                std::fprintf(stderr,"simulation fault %d B%u quality%d ppm%.0f phase%.3f time%.3f Q%u levels %u/%u/%u correction %.2f/%.2f/%.2f\n",s.fault,block,quality,ppm,phaseFraction,next[i],target,s.fifoFrames[0],s.fifoFrames[1],s.fifoFrames[2],s.correctionPPM[0],s.correctionPPM[1],s.correctionPPM[2]);throw std::runtime_error("clock simulation fault");}
        }
    }
    auto s=stats(core.get());require(!s.fault&&s.primedMask==7,"clock simulation did not run");
    require(!expectStarvation,"expected unsafe reserve case unexpectedly passed; revisit the test");
    for(unsigned i=0;i<3;++i){
        require(!s.underruns[i]&&!s.overflows[i],"clock simulation lost frames");
        require(std::abs(s.correctionPPM[i])<1000,"drift controller saturated");
        require(s.fifoMax[i]<1024,"unbounded latency accumulation");
    }
    require(std::abs(x.forward[block]-.15f)<1e-3,"drift changed steady stereo amplitude");
    std::printf("  simulated %.0fs B%u quality%d drift%+.0fppm phase%.2f timestamps%d Q%u; FIFO %u/%u/%u, ppm %.2f/%.2f/%.2f\n",duration,block,quality,ppm,phaseFraction,timestamps,target,s.fifoFrames[0],s.fifoFrames[1],s.fifoFrames[2],s.correctionPPM[0],s.correctionPPM[1],s.correctionPPM[2]);
}

void maximumDimensions() {
    auto c=config(4096,1,64);c.channels[0]=64;c.channels[1]=0;auto core=create(c);
    std::vector<float> in(size_t(4096)*64,.001f),back(8192,.001f),out(8192);
    std::array<MRChannelView,64> views;for(unsigned i=0;i<64;++i){views[i]={in.data()+i,64};mr_core_set_channel(core.get(),0,i,0,i%2?1:-1,0);}
    MRChannelView ret[2]={{back.data(),2},{back.data()+1,2}};
    for(unsigned n=0;n<20;++n){Guard g;mr_core_push(core.get(),0,views.data(),64,4096,{});mr_core_push(core.get(),2,ret,2,4096,{});mr_core_render(core.get(),0,out.data(),4096,{});mr_core_render(core.get(),1,out.data(),4096,{});}
    require(!stats(core.get()).fault && stats(core.get()).primedMask==7,"maximum dimensions or disabled source failed");
}
void startupSurplus() {
    auto core=create();Signals x(64);enable(core.get());
    // PC tap begins 200 ms before the physical devices, within fixed capacity.
    for(unsigned n=0;n<150;++n)x.push(core.get(),1);
    for(unsigned n=0;n<30;++n)cycle(core.get(),x);
    auto s=stats(core.get());require(!s.fault&&s.primedMask==7,"asynchronous startup failed");
    require(s.startupDiscardedFrames[1]>9000,"startup backlog was not trimmed");
    require(s.fifoFrames[1]<256,"old PC backlog became hidden steady latency");
    const auto discarded=s.startupDiscardedFrames[1];
    for(unsigned n=0;n<30;++n)cycle(core.get(),x);
    require(stats(core.get()).startupDiscardedFrames[1]==discarded,"steady state skipped queued audio");
}

void concurrentSPSCAndControls() {
    auto core=create(); Signals x(64); enable(core.get());
    // Prime with a deterministic initial window before introducing concurrent
    // driver scheduling. A callback-count lead is not an occupancy estimate:
    // the first consumer can discard a different surplus for each source.
    for(unsigned n=0;n<3;++n)for(unsigned s=0;s<3;++s)x.push(core.get(),s);
    x.render(core.get(),0);x.render(core.get(),1);
    require(stats(core.get()).primedMask==7&&!stats(core.get()).fault,"concurrent fixture failed to prime");
    std::array<std::atomic<unsigned>,3> produced {};
    std::atomic<unsigned> consumed {0};
    std::atomic<bool> failed {false}, stop {false};
    constexpr unsigned cycles=12000;
    MRCoreStats firstFault {};
    unsigned firstFaultIteration = cycles;
    // This checks concurrent ownership and publication, not a realtime driver
    // deadline. Pace each producer from ACTUAL unread FIFO frames, reserving
    // one output block plus Q before a consumer runs. The separate event-driven
    // clock simulations test drift and callback phase without this pacing.
    // Every wait/snapshot remains outside the realtime API.
    std::thread producer([&]{
        while(!stop.load(std::memory_order_acquire)&&!failed.load()) {
            const auto snapshot=stats(core.get());
            if(snapshot.fault) { failed.store(true);break; }
            bool progressed=false;
            for(unsigned s=0;s<3;++s)if(snapshot.fifoFrames[s]<=128) {
                x.push(core.get(),s);produced[s].fetch_add(1);progressed=true;
            }
            if(!progressed)std::this_thread::yield();
        }
    });
    std::thread consumer([&]{
        for(unsigned n=0;n<cycles;++n){
            while(!failed.load()) {
                const auto snapshot=stats(core.get());
                if(snapshot.fifoFrames[0]>=128&&snapshot.fifoFrames[1]>=128&&snapshot.fifoFrames[2]>=128)break;
                std::this_thread::yield();
            }
            if(failed.load())break;
            x.render(core.get(),0);x.render(core.get(),1);
            const auto snapshot=stats(core.get());
            if(snapshot.fault) {
                failed.store(true);
                if(firstFaultIteration==cycles) { firstFault=snapshot;firstFaultIteration=n; }
                break;
            }
            consumed.store(n+1,std::memory_order_release);
        }
        stop.store(true,std::memory_order_release);
    });
    for(unsigned n=0;!stop.load(std::memory_order_acquire)&&!failed.load();++n){
        mr_core_set_channel(core.get(),0,0,n%2?-.2f:0,-1,0);
        mr_core_set_master(core.get(),n%2?-.1f:0,0,0);
        if(n%8==0) {auto gate=gateSettings((n&16)!=0);gate.thresholdDB=n%32?-60:-40;mr_core_set_gate(core.get(),1,0,&gate);}
        auto s=stats(core.get());
        if(s.fault)failed.store(true);
        if(!std::isfinite(s.gateGain[1][0])||s.gateGain[1][0]<0||s.gateGain[1][0]>1)failed.store(true);
        std::this_thread::yield();
    }
    producer.join();consumer.join();
    if(failed.load()||stats(core.get()).fault) {
        if(!firstFault.fault)firstFault=stats(core.get());
        std::fprintf(stderr,"concurrency first fault iteration=%u fault=%d primed=%u produced=%u/%u/%u consumed=%u\n",
                     firstFaultIteration,firstFault.fault,firstFault.primedMask,
                     produced[0].load(),produced[1].load(),produced[2].load(),consumed.load());
        for(unsigned s=0;s<3;++s)std::fprintf(stderr,
            "  source%u input=%llu fifo=%u min=%u max=%u underruns=%llu overflows=%llu startupDiscarded=%llu ppm=%.3f\n",
            s,(unsigned long long)firstFault.inputFrames[s],firstFault.fifoFrames[s],firstFault.fifoMin[s],firstFault.fifoMax[s],
            (unsigned long long)firstFault.underruns[s],(unsigned long long)firstFault.overflows[s],
            (unsigned long long)firstFault.startupDiscardedFrames[s],firstFault.correctionPPM[s]);
    }
    require(!failed.load()&&!stats(core.get()).fault,"concurrent SPSC/control/snapshot failed");
    require(consumed.load()==cycles,"concurrent fixture did not complete all render calls");
}

void concurrentPCRecoveryAndControls() {
    auto core=create();Signals x(64);enable(core.get());
    for(unsigned n=0;n<160;++n)cycle(core.get(),x);
    std::atomic<bool> stop{false},failed{false},allowPC{false};
    std::atomic<unsigned> consumed{0};
    constexpr unsigned cycles=4096;
    // Only physical-path reserves pace the consumer. PC capture deliberately
    // pauses for 32 renders per 128; producer and recovery reader can overlap.
    std::thread producer([&]{
        while(!stop.load(std::memory_order_acquire)&&!failed.load()) {
            const auto s=stats(core.get());if(s.fault){failed.store(true);break;}
            bool progressed=false;
            for(unsigned source:{0u,2u})if(s.fifoFrames[source]<=128){x.push(core.get(),source);progressed=true;}
            if(allowPC.load(std::memory_order_acquire)&&s.fifoFrames[1]<=128){x.push(core.get(),1);progressed=true;}
            if(!progressed)std::this_thread::yield();
        }
    });
    std::thread consumer([&]{
        for(unsigned n=0;n<cycles&&!failed.load();++n) {
            allowPC.store(n%128>=32,std::memory_order_release);
            while(!failed.load()) {
                const auto s=stats(core.get());
                if(s.fault){failed.store(true);break;}
                if(s.fifoFrames[0]>=128&&s.fifoFrames[2]>=128)break;
                std::this_thread::yield();
            }
            if(failed.load())break;
            x.render(core.get(),0);x.render(core.get(),1);
            const auto s=stats(core.get());
            if(s.fault||s.underruns[0]||s.underruns[2])failed.store(true);
            for(unsigned f=0;f<64;++f) {
                if(!std::isfinite(x.forward[2*f])||!std::isfinite(x.forward[2*f+1])||
                   x.forward[2*f]<.10f-5e-4f||x.forward[2*f+1]<.08f||
                   std::abs(x.back[2*f]-.30f)>5e-4f||std::abs(x.back[2*f+1]+.40f)>5e-4f)failed.store(true);
            }
            consumed.store(n+1,std::memory_order_release);
        }
        stop.store(true,std::memory_order_release);
    });
    for(unsigned n=0;!stop.load(std::memory_order_acquire)&&!failed.load();++n) {
        mr_core_set_channel(core.get(),1,0,n%2?-.2f:0,-1,0);
        auto gate=gateSettings((n&16)!=0);gate.thresholdDB=n%32?-60:-40;
        mr_core_set_gate(core.get(),1,0,&gate);
        const auto s=stats(core.get());
        if(s.fault||s.pcRecovering>1||
           !std::isfinite(s.gateGain[1][0])||s.gateGain[1][0]<0||s.gateGain[1][0]>1)failed.store(true);
        std::this_thread::yield();
    }
    producer.join();consumer.join();
    const auto s=stats(core.get());
    if(failed.load()||s.fault)std::fprintf(stderr,
        "concurrent PC recovery fault=%d cycles=%u recoveries=%llu completed=%llu under=%llu/%llu/%llu levels=%u/%u/%u\n",
        s.fault,consumed.load(),(unsigned long long)s.pcRecoveryCount,(unsigned long long)s.pcRecoveryCompleted,
        (unsigned long long)s.underruns[0],(unsigned long long)s.underruns[1],(unsigned long long)s.underruns[2],
        s.fifoFrames[0],s.fifoFrames[1],s.fifoFrames[2]);
    require(!failed.load()&&!s.fault&&consumed.load()==cycles,"concurrent PC recovery/control/snapshot failed");
    require(s.pcRecoveryCount>=16&&s.pcRecoveryCompleted>=16&&s.pcRecoveryCompleted<=s.pcRecoveryCount&&s.underruns[1]==s.pcRecoveryCount,
            "concurrent fixture did not exercise repeated PC recovery");
    require(!s.overflows[0]&&!s.overflows[1]&&!s.overflows[2],"concurrent recovery overflowed a source FIFO");
    std::puts("PASS concurrent PC starvation/recovery, independent physical streams, controls and snapshots");
}
}

int main(int argc, char **argv) {
    try {
        if(argc>1) {
            if(argc==2&&std::strcmp(argv[1],"--pc-recovery-only")==0) {
                pcRecoveryAndFreshAudio();pcRecoveryRapidRefill();pcRecoveryRepeatedBeforeFadeInCompletes();pcRecoveryFaultBoundaries();concurrentPCRecoveryAndControls();
                require(rtAllocations.load()==0,"C++ allocation occurred in a realtime API");
                std::puts("PASS PC recovery suite; no C++ realtime allocations");return 0;
            }
            if(argc==2&&std::strcmp(argv[1],"--clock-diagnostics-only")==0) {
                clockFailureDiagnostics();concurrentClockFailureDiagnostics();faults();negativeSampleOrigins();
                require(rtAllocations.load()==0,"C++ allocation occurred in realtime API");
                return 0;
            }
            if(argc==2&&(std::strcmp(argv[1],"--gate-only")==0||std::strcmp(argv[1],"--gate-benchmark")==0)) {
                if(std::strcmp(argv[1],"--gate-only")==0)gates();else gateBenchmark();
                require(rtAllocations.load()==0,"C++ allocation occurred in realtime API");
                return 0;
            }
            if(argc==2&&std::strcmp(argv[1],"--small-block-only")==0) {
                negativeSampleOrigins();
                for(double ppm:{-100.,100.})for(double phase:{.07,.47,.93})simulate(16,0,ppm,phase,true,16);
                require(rtAllocations.load()==0,"C++ allocation occurred in realtime API");
                std::puts("PASS 16-frame offline regressions; no hardware stability or latency claim");
                return 0;
            }
            require(std::strcmp(argv[1],"--concurrency-only")==0 && argc<=3,"usage: CoreTests [--concurrency-only [repetitions] | --pc-recovery-only | --small-block-only | --gate-only | --gate-benchmark | --clock-diagnostics-only]");
            char *end=nullptr;
            const unsigned long repetitions=argc==3?std::strtoul(argv[2],&end,10):1;
            require(repetitions>0&&repetitions<=100&&(argc!=3||*end=='\0'),"repetitions must be 1..100");
            for(unsigned long n=0;n<repetitions;++n) {
                concurrentSPSCAndControls();
                std::printf("PASS concurrent SPSC, controls and telemetry (%lu/%lu)\n",n+1,repetitions);
            }
            require(rtAllocations.load()==0,"C++ allocation occurred in realtime API");
            return 0;
        }
        gates();
        initializationAndPriming();std::puts("PASS configuration, safe priming, stereo routing");
        rampsMuteAndClipping();std::puts("PASS gain/master ramps, mute, finite clipping");
        faults();std::puts("PASS underflow, overflow, nonfinite and timestamp fault silence");
        pcRecoveryAndFreshAudio();pcRecoveryRapidRefill();pcRecoveryRepeatedBeforeFadeInCompletes();pcRecoveryFaultBoundaries();concurrentPCRecoveryAndControls();
        clockFailureDiagnostics();concurrentClockFailureDiagnostics();
        negativeSampleOrigins();
        for(unsigned block:{32u,64u})for(double ppm:{-100.,100.})for(double phase:{.07,.47,.93})simulate(block,0,ppm,phase,true);
        simulate(32,1,100,.37,true);simulate(64,1,-100,.79,true);
        simulate(64,0,100,.37,false);simulate(64,0,-100,.79,false);
        for(double ppm:{-100.,100.})for(double phase:{.07,.47,.93})simulate(32,0,ppm,phase,true,32);
        for(double ppm:{-100.,100.})for(double phase:{.07,.47,.93})simulate(16,0,ppm,phase,true,16);
        simulate(64,0,100,.37,true,32,true);
        startupSurplus();std::puts("PASS bounded startup backlog discard, no steady skips");
        maximumDimensions();std::puts("PASS maximum channel/frame bounds");
        concurrentSPSCAndControls();std::puts("PASS concurrent SPSC, controls and telemetry");
        require(rtAllocations.load()==0,"C++ allocation occurred in realtime API");
        std::puts("PASS realtime C++ allocation guard (C allocator audit separate)");
        std::puts("All offline tests passed. Simulated intervals are not hardware stability measurements.");
        return 0;
    } catch(const std::exception&e){std::fprintf(stderr,"FAIL: %s\n",e.what());return 1;}
}
