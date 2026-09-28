#include "RealtimeCore.h"
#include <algorithm>
#include <array>
#include <atomic>
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
Core create(MRCoreConfig c = config()) {
    char error[256]; Core core(mr_core_create(&c, error, sizeof(error)));
    if (!core) throw std::runtime_error(error);
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
        auto s=stats(core.get());
        if(s.fault)failed.store(true);
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
}

int main(int argc, char **argv) {
    try {
        if(argc>1) {
            if(argc==2&&std::strcmp(argv[1],"--small-block-only")==0) {
                negativeSampleOrigins();
                for(double ppm:{-100.,100.})for(double phase:{.07,.47,.93})simulate(16,0,ppm,phase,true,16);
                require(rtAllocations.load()==0,"C++ allocation occurred in realtime API");
                std::puts("PASS 16-frame offline regressions; no hardware stability or latency claim");
                return 0;
            }
            require(std::strcmp(argv[1],"--concurrency-only")==0 && argc<=3,"usage: CoreTests [--concurrency-only [repetitions] | --small-block-only]");
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
        initializationAndPriming();std::puts("PASS configuration, safe priming, stereo routing");
        rampsMuteAndClipping();std::puts("PASS gain/master ramps, mute, finite clipping");
        faults();std::puts("PASS underflow, overflow, nonfinite and timestamp fault silence");
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
