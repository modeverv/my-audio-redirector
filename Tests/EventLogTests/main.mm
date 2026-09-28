#include "../../Sources/RedirectorBridge/Bridge.mm"
#include <cassert>
#include <iostream>

NSArray *rows(NSString *path) {
    NSString *text=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    assert(text && [text hasSuffix:@"\n"]);
    NSMutableArray *result=[NSMutableArray array];
    for(NSString *line in [text componentsSeparatedByString:@"\n"])if(line.length){
        id row=[NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        assert([row isKindOfClass:NSDictionary.class]);[result addObject:row];
    }
    return result;
}
int main() { @autoreleasepool {
    char pattern[]="/tmp/my-redirector-event-log-tests-XXXXXX";
    char *directory=mkdtemp(pattern);assert(directory);
    std::string root=directory;
    MREngine engine;
    engine.eventLog=std::make_shared<mrlog::EventLog>(root+"/aggregate");
    engine.logRunID="synthetic-no-audio";engine.logStartedHost=mach_absolute_time();
    engine.logSessionOpen=true;engine.state="running";
    MRCoreStats stats{};stats.pcRecoveryCount=1;stats.pcRecovering=1;
    stats.pcLastRecoveryMissingFrames=32;stats.pcRecoveryOutputFrames=64;stats.underruns[1]=1;
    logRecovery(&engine,stats);assert(engine.eventLog->flush(2));
    stats.pcRecoveryCount=2;stats.pcRecoveryCompleted=1;stats.pcRecoveryDiscardedFrames=7;
    stats.pcRecoveryOutputFrames=192;stats.pcLastRecoveryMissingFrames=16;stats.underruns[1]=2;
    logRecovery(&engine,stats);assert(engine.eventLog->flush(2));
    assert([engine.eventLog->status()[@"writtenRecords"] unsignedLongLongValue]==1); // throttled
    engine.lastRecoveryLogHost=mach_absolute_time()-uint64_t(2/engine.hostScale);
    logRecovery(&engine,stats);assert(engine.eventLog->flush(2));
    stats.pcRecoveryCompleted=2;stats.pcRecovering=0;stats.pcRecoveryOutputFrames=256;
    engine.lastStats=stats;finishEventLog(&engine);assert(engine.eventLog->flush(2));
    NSArray *events=rows([NSString stringWithUTF8String:engine.eventLog->path().c_str()]);
    assert(events.count==4);
    assert([events[0][@"delta"][@"count"] intValue]==1);
    assert([events[1][@"delta"][@"count"] intValue]==1);
    assert([events[1][@"delta"][@"completed"] intValue]==1);
    assert([events[2][@"delta"][@"completed"] intValue]==1);
    assert([events[2][@"recovery"][@"recovering"] boolValue]==false);
    assert([events[3][@"event"] isEqualToString:@"session_end"]);
    NSDictionary *status=snapshot(&engine); // inactive, no HAL lookup or audio I/O
    assert([status[@"pcRecoveryCount"] intValue]==2 && [status[@"pcRecoveryCompleted"] intValue]==2);
    assert([status[@"pcRecoveryDiscardedFrames"] intValue]==7 && [status[@"pcRecoveryOutputFrames"] intValue]==256);
    assert([status[@"eventLog"][@"lastRecordReadbackVerified"] boolValue]);
    assert(status[@"eventLog"][@"error"]==NSNull.null);

    auto rotated=std::make_shared<mrlog::EventLog>(root+"/rotate",512);
    for(int n=0;n<30;++n){rotated->append(@{@"index":@(n),@"payload":[@"x" stringByPaddingToLength:160 withString:@"x" startingAtIndex:0]});assert(rotated->flush(2));}
    for(int n=0;n<4;++n) {
        std::string path=root+"/rotate/events"+(n?"."+std::to_string(n):"")+".jsonl";
        struct stat info{};assert(stat(path.c_str(),&info)==0 && info.st_size<=512);
        assert(rows([NSString stringWithUTF8String:path.c_str()]).count>0);
    }
    assert(access((root+"/rotate/events.4.jsonl").c_str(),F_OK)!=0);
    assert([rotated->status()[@"writtenRecords"] intValue]==30);

    NSString *blocked=[NSString stringWithUTF8String:(root+"/blocked").c_str()];
    assert([@"file" writeToFile:blocked atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    auto broken=std::make_shared<mrlog::EventLog>(root+"/blocked");
    broken->append(@{@"event":@"test"});assert(broken->flush(2));
    assert([broken->status()[@"writeFailures"] intValue]==1 && [broken->status()[@"droppedRecords"] intValue]==1);
    assert(broken->status()[@"error"]!=NSNull.null && engine.state=="running");
    assert([[NSFileManager defaultManager] removeItemAtPath:blocked error:nil]);
    broken->append(@{@"event":@"recovered-writer"});assert(broken->flush(2));
    assert([broken->status()[@"lastRecordReadbackVerified"] boolValue]);
    assert(broken->status()[@"error"]!=NSNull.null); // failure history survives

    int lock=open((root+"/rotate/events.lock").c_str(),O_RDWR);assert(lock>=0 && flock(lock,LOCK_EX|LOCK_NB)==0);
    rotated->append(@{@"event":@"competing-process"});assert(rotated->flush(2));
    assert([rotated->status()[@"writeFailures"] intValue]==1);
    flock(lock,LOCK_UN);close(lock);
    assert([rows([NSString stringWithUTF8String:rotated->path().c_str()]) lastObject][@"index"]!=nil);
    std::cout<<"PASS: synthetic recovery deltas, 1-second aggregation, forced stop drain, snapshot fields, JSON readback, four-file rotation, write failure, failure retention, lock contention; audioStarted=false; directory="<<root<<"\n";
} }
