#pragma once
#import <Foundation/Foundation.h>
#include <atomic>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <memory>
#include <mutex>
#include <string>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>
#include "RealtimeCore.h"

// Control/utility threads only. Nothing here is reachable from an audio IOProc.
// Each queued block owns the logger, never the engine or any callback memory.
namespace mrlog {
class EventLog : public std::enable_shared_from_this<EventLog> {
    std::string directory_, path_;
    size_t limit_;
    dispatch_queue_t queue_ = dispatch_queue_create("my-redirector.event-log", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    std::atomic<uint32_t> pending_{0};
    std::atomic<uint64_t> written_{0}, dropped_{0}, failures_{0};
    std::atomic<bool> readback_{false};
    std::mutex errorMutex_;
    std::string error_;
    void error(const std::string &text) { std::lock_guard<std::mutex> lock(errorMutex_); error_=text; }
    static std::string systemError(const char *operation) { return std::string(operation)+": "+strerror(errno); }
    bool write(NSData *data, std::string &why) {
        NSError *directoryError=nil;
        NSString *directory=[NSString stringWithUTF8String:directory_.c_str()];
        if(![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&directoryError]) {
            why="Create log directory: "+std::string(directoryError.localizedDescription.UTF8String ?: "unknown error");return false;
        }
        int lockFD=open((directory_+"/events.lock").c_str(),O_CREAT|O_RDWR|O_CLOEXEC|O_NOFOLLOW,0600);
        if(lockFD<0){why=systemError("Open log lock");return false;}
        // A second CLI/GUI process must not race append/rotation. Never wait on
        // another process indefinitely; a failed event remains visible in status.
        if(flock(lockFD,LOCK_EX|LOCK_NB)<0){why=systemError("Acquire log lock");close(lockFD);return false;}
        struct LockGuard { int fd;~LockGuard(){flock(fd,LOCK_UN);close(fd);} } lock{lockFD};
        struct stat info{};
        if(stat(path_.c_str(),&info)==0 && uint64_t(info.st_size)+data.length>limit_) {
            for(int index=3;index>=1;--index) {
                std::string from=index==1 ? path_ : directory_+"/events."+std::to_string(index-1)+".jsonl";
                std::string to=directory_+"/events."+std::to_string(index)+".jsonl";
                if(rename(from.c_str(),to.c_str())<0 && errno!=ENOENT){why=systemError("Rotate event log");return false;}
            }
        }
        int fd=open(path_.c_str(),O_CREAT|O_RDWR|O_APPEND|O_CLOEXEC|O_NOFOLLOW,0600);
        if(fd<0){why=systemError("Open event log");return false;}
        struct FileGuard { int fd;~FileGuard(){close(fd);} } file{fd};
        off_t offset=lseek(fd,0,SEEK_END);
        if(offset<0){why=systemError("Locate event log end");return false;}
        const char *bytes=static_cast<const char *>(data.bytes);size_t size=data.length,done=0;
        while(done<size) {
            ssize_t count=::write(fd,bytes+done,size-done);
            if(count<0 && errno==EINTR)continue;
            if(count<=0){why=systemError("Append event log");if(ftruncate(fd,offset)<0)why+="; partial record could not be removed";return false;}done+=size_t(count);
        }
        // Verify the just-appended bytes under the same lock. This is readback,
        // not a claim of power-loss durability; no fsync occurs during routing.
        std::vector<char> back(size);done=0;
        while(done<size) {
            ssize_t count=pread(fd,back.data()+done,size-done,offset+off_t(done));
            if(count<0 && errno==EINTR)continue;
            if(count<=0){why=systemError("Read back event log");return false;}done+=size_t(count);
        }
        if(memcmp(back.data(),bytes,size)){why="Event log readback did not match appended bytes";return false;}
        return true;
    }
public:
    explicit EventLog(std::string directory,size_t limit=2*1024*1024):directory_(std::move(directory)),path_(directory_+"/events.jsonl"),limit_(limit) {}
    const std::string &path() const { return path_; }
    bool append(NSDictionary *record) {
        if(pending_.fetch_add(1)>=32){pending_.fetch_sub(1);dropped_.fetch_add(1);error("Event log backlog limit reached; record dropped");return false;}
        auto self=shared_from_this();NSDictionary *immutable=[record copy];
        dispatch_async(queue_, ^{
            @autoreleasepool {
                NSError *jsonError=nil;
                NSData *json=[NSJSONSerialization dataWithJSONObject:immutable options:NSJSONWritingSortedKeys error:&jsonError];
                std::string why;
                bool ok=false;
                if(!json)why="Encode event log JSON: "+std::string(jsonError.localizedDescription.UTF8String ?: "unknown error");
                else if(json.length+1>64*1024 || json.length+1>self->limit_)why="Event log record exceeds bounded record size";
                else {
                    NSMutableData *line=[json mutableCopy];const char newline='\n';[line appendBytes:&newline length:1];
                    ok=self->write(line,why);
                }
                self->readback_.store(ok);
                if(ok){self->written_.fetch_add(1);}
                else {self->failures_.fetch_add(1);self->dropped_.fetch_add(1);self->error(why);}
                self->pending_.fetch_sub(1);
            }
        });
        return true;
    }
    // Call after stopping callbacks. A timed-out writer keeps its own lifetime.
    bool flush(double seconds=0.25) {
        dispatch_semaphore_t done=dispatch_semaphore_create(0);
        dispatch_async(queue_, ^{ dispatch_semaphore_signal(done); });
        bool completed=dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,int64_t(seconds*1e9)))==0;
        if(!completed)error("Event log flush timed out; pending writes are not confirmed");
        return completed;
    }
    NSDictionary *status() {
        std::string why;{std::lock_guard<std::mutex> lock(errorMutex_);why=error_;}
        return @{@"path":[NSString stringWithUTF8String:path_.c_str()],@"pendingRecords":@(pending_.load()),
                 @"writtenRecords":@(written_.load()),@"droppedRecords":@(dropped_.load()),@"writeFailures":@(failures_.load()),
                 @"lastRecordReadbackVerified":@(readback_.load()),@"error":why.empty()?(id)NSNull.null:[NSString stringWithUTF8String:why.c_str()],
                 @"fileLimitBytes":@(limit_),@"backupFiles":@3};
    }
};

struct RecoveryCounters {
    uint64_t count=0, completed=0, discarded=0, output=0;
    uint32_t recovering=0, missing=0;
    RecoveryCounters() = default;
    explicit RecoveryCounters(const MRCoreStats &stats):count(stats.pcRecoveryCount),completed(stats.pcRecoveryCompleted),
        discarded(stats.pcRecoveryDiscardedFrames),output(stats.pcRecoveryOutputFrames),
        recovering(stats.pcRecovering),missing(stats.pcLastRecoveryMissingFrames) {}
    bool operator==(const RecoveryCounters &other) const {
        return count==other.count && completed==other.completed && discarded==other.discarded && output==other.output && recovering==other.recovering && missing==other.missing;
    }
    NSDictionary *json() const {
        return @{@"count":@(count),@"completed":@(completed),@"discardedInputFrames":@(discarded),
                 @"replacedOutputFrames":@(output),@"recovering":@(recovering!=0),@"lastMissingFrames":@(missing)};
    }
    NSDictionary *delta(const RecoveryCounters &previous) const {
        auto difference=[](uint64_t a,uint64_t b){return a>=b?a-b:a;};
        return @{@"count":@(difference(count,previous.count)),@"completed":@(difference(completed,previous.completed)),
                 @"discardedInputFrames":@(difference(discarded,previous.discarded)),@"replacedOutputFrames":@(difference(output,previous.output))};
    }
};
}
