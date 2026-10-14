#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <AVFoundation/AVFoundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include <math.h>
#include <signal.h>
#include <sys/sysctl.h>
#include <unistd.h>

static volatile sig_atomic_t cancelled = 0;
static void stop(int signal) { cancelled = 1; }
static NSLock *outputLock;
static dispatch_source_t parentWatch;
static void event(NSDictionary *event) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:event options:NSJSONWritingSortedKeys error:NULL];
    if (!data || data.length > 16 * 1024 * 1024) return;
    [outputLock lock]; fwrite(data.bytes, 1, data.length, stdout); puts(""); fflush(stdout); [outputLock unlock];
}

// Local file worker. Verified ABI and selected masks: macOS build 26A434.
// See research-notes/framework-parity/coordinator-contract.md. Never use mask zero
// for a coordinator task: the framework expands it to all analyses.
@protocol LocalAnalysisTask
+ (id)taskForURLAsset:(id)URLs withOptions:(id)options analysisTypes:(uint64_t)types
      progressHandler:(void (^)(double))progress completionHandler:(void (^)(id, NSError *))completion;
- (int)runWithCancelBlock:(BOOL (^)(void))cancel;
- (id)partialAnalysis;
@end
@protocol LocalPreAnalyzer
- (void)analyzeWithImageURL:(NSURL *)url mediaType:(NSInteger)type mediaSubtypes:(uint64_t)subtypes
         abnormalDimension:(uint64_t)abnormal completionHandler:(void (^)(int, id))completion;
@end

static BOOL match(Class cls, BOOL meta, const char *selector, const char *encoding) {
    Method method = meta ? class_getClassMethod(cls, sel_registerName(selector)) : class_getInstanceMethod(cls, sel_registerName(selector));
    return method && !strcmp(method_getTypeEncoding(method), encoding);
}
static NSString *digest(NSData *data) {
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, bytes);
    NSMutableString *text = [NSMutableString string];
    for (unsigned i = 0; i < sizeof(bytes); i++) [text appendFormat:@"%02x", bytes[i]];
    return text;
}
static id summarize(id value, unsigned depth, NSUInteger *budget) {
    if (!value || value == NSNull.null) return NSNull.null;
    if (!*budget || depth > 10) return @{@"class": NSStringFromClass([value class]), @"truncated": @YES};
    --*budget;
    if ([value isKindOfClass:NSString.class]) return [value length] <= 16384 ? value : @{@"class": @"NSString", @"prefix": [value substringToIndex:16384], @"characters": @([value length]), @"truncated": @YES};
    if ([value isKindOfClass:NSNumber.class]) return isfinite([value doubleValue]) ? value : @"non-finite";
    if ([value isKindOfClass:NSDate.class]) return @{@"class": @"NSDate", @"secondsSinceReferenceDate": @([value timeIntervalSinceReferenceDate])};
    if ([value isKindOfClass:NSData.class]) {
        NSMutableDictionary *result = [@{@"class": @"NSData", @"bytes": @([value length])} mutableCopy];
        if ([value length] <= 16 * 1024 * 1024) result[@"sha256"] = digest(value);
        if ([value length] <= 1024 * 1024) result[@"base64"] = [value base64EncodedStringWithOptions:0];
        else result[@"payloadOmitted"] = @YES;
        return result;
    }
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *items = [NSMutableArray array];
        for (id item in [value subarrayWithRange:NSMakeRange(0, MIN([value count], 512))])
            [items addObject:summarize(item, depth + 1, budget)];
        return @{@"count": @([value count]), @"items": items, @"truncated": @([value count] > 512)};
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *items = [NSMutableDictionary dictionary];
        unsigned count = 0;
        for (id key in value) {
            if (count++ >= 1024) { items[@"__truncated"] = @YES; break; }
            if ([key isKindOfClass:NSString.class]) items[[key substringToIndex:MIN([key length], 512)]] = summarize(value[key], depth + 1, budget);
            else if ([key isKindOfClass:NSNumber.class]) items[[key stringValue]] = summarize(value[key], depth + 1, budget);
            else items[[NSString stringWithFormat:@"unsupported-key-%u", count]] = @{@"keyClass": NSStringFromClass([key class])};
        }
        return items;
    }
    if ([value isKindOfClass:NSValue.class]) return @{@"class": @"NSValue", @"type": @([value objCType]), @"value": [value description]};
    if ([value isKindOfClass:NSError.class]) return @{@"class": @"NSError", @"domain": [value domain], @"code": @([value code]), @"description": [value localizedDescription]};
    return @{@"class": NSStringFromClass([value class]), @"opaque": @YES};
}
static void stage(const char *name) {}
static int emit(NSDictionary *report, int code) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:report options:0 error:NULL];
    if (!json || json.length > 15 * 1024 * 1024) {
        event(@{@"event": @"result", @"report": @{@"unavailableReason": @"Returned analysis exceeded the bounded output limit. Try a shorter video."}});
        return 8;
    }
    event(@{@"event": @"result", @"report": report});
    return code;
}
static int probe(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 5) return 2;
        NSString *path = @(argv[1]), *kind = @(argv[2]);
        char *end = NULL;
        uint64_t types = strtoull(argv[3], &end, 0);
        double deadline = strtod(argv[4], NULL);
        BOOL preanalysis = [kind isEqualToString:@"preanalysis"];
        if (!end || *end || (!types && !preanalysis) || !isfinite(deadline) || deadline < 1 || deadline > 235) return 2;
        // Named per-file analyses only; explicit selection excludes unresolved
        // lookup/rich-grounding/personal-environment families and maintenance.
        uint64_t allowed = 0;
        const unsigned bits[] = {3,7,8,9,11,12,13,14,15,16,17,18,19,21,22,23,25,30,33,34,37,43,45,47,48,49};
        for (unsigned i = 0; i < sizeof(bits) / sizeof(bits[0]); i++) allowed |= UINT64_C(1) << bits[i];
        if (types & ~allowed || ![@[@"image", @"movie", @"preanalysis"] containsObject:kind]) return 2;
        NSURL *url = [NSURL fileURLWithPath:path];
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL];
        if (![attributes[NSFileType] isEqualToString:NSFileTypeRegular] || [attributes[NSFileSize] unsignedLongLongValue] > 256 * 1024 * 1024) return 2;
        NSMutableDictionary *report = [@{@"input": path, @"kind": kind, @"analysisTypes": @(types),
            @"analysisTypesHex": [NSString stringWithFormat:@"0x%llx", (unsigned long long)types],
            @"os": NSProcessInfo.processInfo.operatingSystemVersionString, @"pid": @(getpid()),
            @"options": @{}, @"route": preanalysis ? @"local-VCPPreAnalyzer" : @"local-VCPFullAnalysisURLProcessingTask",
            @"inputContract": @"NSArray<NSURL *> verified against installed initializer; no VCPURLAsset passed",
            @"stage": @"interface"} mutableCopy];
        char build[128] = {0}; size_t buildLength = sizeof(build);
        sysctlbyname("kern.osversion", build, &buildLength, NULL, 0);
#if !defined(__arm64__)
        report[@"unavailableReason"] = @"Local analysis has only been verified on Apple silicon.";
        return emit(report, 3);
#endif
        if (strcmp(build, "26A434")) {
            report[@"unavailableReason"] = @"Local analysis is currently verified only on macOS build 26A434. This system needs a compatibility update.";
            return emit(report, 3);
        }
        if ([kind isEqualToString:@"movie"]) {
            AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{}];
            double duration = CMTimeGetSeconds(asset.duration);
            NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
            if (!isfinite(duration) || duration <= 0 || duration > 120 || !tracks.count) {
                report[@"unavailableReason"] = @"Choose a video with a video track and a duration of at most two minutes.";
                return emit(report, 4);
            }
            for (AVAssetTrack *track in tracks) {
                CGSize size = track.naturalSize;
                if (!isfinite(size.width) || !isfinite(size.height) || size.width <= 0 || size.height <= 0 || size.width * size.height > 40000000) {
                    report[@"unavailableReason"] = @"Video dimensions exceed the 40-megapixel input limit.";
                    return emit(report, 4);
                }
            }
            report[@"inputDuration"] = @(duration);
        } else {
            CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
            NSDictionary *properties = source ? CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL)) : nil;
            if (source) CFRelease(source);
            uint64_t width = [properties[(id)kCGImagePropertyPixelWidth] unsignedLongLongValue];
            uint64_t height = [properties[(id)kCGImagePropertyPixelHeight] unsignedLongLongValue];
            if (!width || !height || width > 40000000 || height > 40000000 / width) { report[@"unavailableReason"] = @"Image is unreadable or exceeds the 40-megapixel input limit."; return emit(report, 4); }
            report[@"inputWidth"] = @(width); report[@"inputHeight"] = @(height);
        }
        stage("interface");
        if (!dlopen("/System/Library/PrivateFrameworks/MediaAnalysis.framework/MediaAnalysis", RTLD_LAZY | RTLD_LOCAL)) { report[@"unavailableReason"] = @"MediaAnalysis.framework could not be loaded."; return emit(report, 3); }
        if (preanalysis) {
            Class cls = NSClassFromString(@"VCPPreAnalyzer");
            if (!cls || !match(cls, NO, "init", "@16@0:8") ||
                !match(cls, NO, "analyzeWithImageURL:mediaType:mediaSubtypes:abnormalDimension:completionHandler:", "v56@0:8@16q24Q32Q40@?48")) { report[@"unavailableReason"] = @"The installed image preanalysis interface is incompatible."; return emit(report, 3); }
            report[@"inputContract"] = @"NSURL, mediaType=1, subtypes=0, abnormalDimension=0; installed preanalysis contract";
            report[@"configuration"] = @"Default installed preanalysis stages; this method has no analysis mask/options argument";
            stage("factory");
            id<LocalPreAnalyzer> analyzer = [[cls alloc] init];
            if (!analyzer) return emit(report, 5);
            dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
            __block id analysis = nil;
            __block int status = -999;
            double start = NSProcessInfo.processInfo.systemUptime;
            stage("run");
            [analyzer analyzeWithImageURL:url mediaType:1 mediaSubtypes:0 abnormalDimension:0 completionHandler:^(int value, id result) {
                status = value;
                analysis = result;
                dispatch_semaphore_signal(semaphore);
            }];
            BOOL received = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(deadline * NSEC_PER_SEC))) == 0;
            NSUInteger budget = 20000;
            report[@"completionReceived"] = @(received);
            report[@"completedAnalysis"] = received ? summarize(analysis, 0, &budget) : NSNull.null;
            report[@"status"] = received ? @(status) : [NSNull null];
            report[@"elapsedMilliseconds"] = @((NSProcessInfo.processInfo.systemUptime - start) * 1000);
            report[@"stage"] = @"complete";
            stage("serialize");
            return emit(report, received && status == 0 ? 0 : 1);
        }
        Class cls = NSClassFromString(@"VCPFullAnalysisURLProcessingTask");
        if (!cls || !match(cls, YES, "taskForURLAsset:withOptions:analysisTypes:progressHandler:completionHandler:", "@56@0:8@16@24Q32@?40@?48") ||
            !match(cls, NO, "runWithCancelBlock:", "i24@0:8@?16") || !match(cls, NO, "partialAnalysis", "@16@0:8")) { report[@"unavailableReason"] = @"The installed file analysis interface is incompatible."; return emit(report, 3); }
        __block id completed = nil;
        __block NSError *completionError = nil;
        __block BOOL completionReceived = NO;
        __block double lastProgress = -1;
        __block unsigned progressEvents = 0;
        NSLock *lock = [NSLock new];
        double start = NSProcessInfo.processInfo.systemUptime;
        stage("factory"); report[@"stage"] = @"factory";
        id<LocalAnalysisTask> task = [(id<LocalAnalysisTask>)cls taskForURLAsset:@[url] withOptions:@{} analysisTypes:types
            progressHandler:^(double progress) {
                [lock lock]; lastProgress = progress; progressEvents++; [lock unlock];
                if (isfinite(progress)) event(@{@"event": @"progress", @"fraction": @(fmax(0, fmin(1, progress / 100)))});
            } completionHandler:^(id analysis, NSError *error) {
                [lock lock]; completed = analysis; completionError = error; completionReceived = YES; [lock unlock];
            }];
        if (!task) { report[@"unavailableReason"] = @"Task factory returned nil"; return emit(report, 5); }
        stage("run"); report[@"stage"] = @"run";
        int status = [task runWithCancelBlock:^BOOL { return cancelled || NSProcessInfo.processInfo.systemUptime - start > deadline; }];
        stage("serialize");
        id partial = [task partialAnalysis];
        [lock lock];
        NSUInteger budget = 20000;
        report[@"completedAnalysis"] = summarize(completed, 0, &budget);
        report[@"completionError"] = summarize(completionError, 0, &budget);
        report[@"completionReceived"] = @(completionReceived);
        report[@"lastProgress"] = @(lastProgress); report[@"progressEvents"] = @(progressEvents);
        [lock unlock];
        report[@"partialAnalysis"] = summarize(partial, 0, &budget);
        report[@"status"] = @(status); report[@"elapsedMilliseconds"] = @((NSProcessInfo.processInfo.systemUptime - start) * 1000);
        report[@"stage"] = @"complete";
        return emit(report, status == 0 && !completionError ? 0 : 1);
    }
}
int main(int argc, const char **argv) {
    outputLock = [NSLock new];
    signal(SIGTERM, stop); signal(SIGINT, stop);
    alarm(240);
    pid_t parent = getppid();
    parentWatch = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(parentWatch, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 4);
    dispatch_source_set_event_handler(parentWatch, ^{ if (getppid() != parent) _exit(125); });
    dispatch_resume(parentWatch);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ exit(probe(argc, argv)); });
    CFRunLoopRun();
    return 9;
}
