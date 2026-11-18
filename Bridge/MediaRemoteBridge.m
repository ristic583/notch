// MediaRemoteBridge.m
//
// Small dylib that is loaded into /usr/bin/perl (see notch-mediaremote.pl).
// Since macOS 15.4 MediaRemote refuses to serve now-playing data to
// third-party processes, but Apple's own platform binaries (like perl) are
// still allowed. This is the same idea used by `mediaremote-adapter`.
//
// Protocol:
//   stdout: one JSON object per line
//     {"type":"ready"}
//     {"type":"now", "title":…, "artist":…, "album":…, "duration":…,
//      "elapsed":…, "timestamp":…, "rate":…, "playing":bool,
//      "bundleId":…, "artworkChanged":bool, "artwork":base64|null}
//   stdin: one command per line: toggle | play | pause | next | prev | seek <seconds>
//   EOF on stdin (parent quit) terminates the process.

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>

typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRGetIsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetPIDFn)(dispatch_queue_t, void (^)(int));
typedef Boolean (*MRSendCommandFn)(int, CFDictionaryRef);
typedef void (*MRSetElapsedFn)(double);

enum {
    kMRPlay = 0,
    kMRPause = 1,
    kMRTogglePlayPause = 2,
    kMRNextTrack = 4,
    kMRPreviousTrack = 5,
    kMRChangePlaybackPosition = 24,
};

static MRRegisterFn MRRegister;
static MRGetInfoFn MRGetInfo;
static MRGetIsPlayingFn MRGetIsPlaying;
static MRGetPIDFn MRGetPID;
static MRSendCommandFn MRSendCommand;
static MRSetElapsedFn MRSetElapsed;

static NSString *kOptionPlaybackPosition;
static NSString *kTitle, *kArtist, *kAlbum, *kDuration, *kElapsed, *kTimestamp, *kRate, *kArtwork;

static dispatch_queue_t gQueue;
static NSUInteger gLastArtworkHash = 0;
static NSUInteger gLastArtworkLength = 0;
static BOOL gFetchScheduled = NO;

static void emit(NSDictionary *obj) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!data) return;
    @synchronized([NSFileHandle class]) {
        fwrite(data.bytes, 1, data.length, stdout);
        fputc('\n', stdout);
        fflush(stdout);
    }
}

static NSString *stringConst(void *handle, const char *name) {
    CFStringRef *ptr = (CFStringRef *)dlsym(handle, name);
    return ptr ? (__bridge NSString *)*ptr : [NSString stringWithUTF8String:name];
}

static id orNull(id value) { return value ?: [NSNull null]; }

static void fetchNowPlaying(void) {
    MRGetInfo(gQueue, ^(CFDictionaryRef cfInfo) {
        NSDictionary *info = (__bridge NSDictionary *)cfInfo;
        MRGetIsPlaying(gQueue, ^(Boolean isPlaying) {
            MRGetPID(gQueue, ^(int pid) {
                NSString *bundleId = nil;
                if (pid > 0) {
                    bundleId = [NSRunningApplication runningApplicationWithProcessIdentifier:pid].bundleIdentifier;
                }

                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                out[@"type"] = @"now";
                out[@"playing"] = @(isPlaying ? YES : NO);
                out[@"bundleId"] = orNull(bundleId);
                out[@"title"] = orNull(info[kTitle]);
                out[@"artist"] = orNull(info[kArtist]);
                out[@"album"] = orNull(info[kAlbum]);
                out[@"duration"] = orNull(info[kDuration]);
                out[@"elapsed"] = orNull(info[kElapsed]);
                out[@"rate"] = orNull(info[kRate]);
                NSDate *ts = info[kTimestamp];
                out[@"timestamp"] = [ts isKindOfClass:[NSDate class]] ? @(ts.timeIntervalSince1970) : [NSNull null];

                NSData *art = info[kArtwork];
                if (![art isKindOfClass:[NSData class]] || art.length == 0) art = nil;
                NSUInteger hash = art ? art.hash : 0;
                NSUInteger length = art ? art.length : 0;
                BOOL changed = hash != gLastArtworkHash || length != gLastArtworkLength;
                out[@"artworkChanged"] = @(changed);
                if (changed) {
                    out[@"artwork"] = art ? [art base64EncodedStringWithOptions:0] : [NSNull null];
                    gLastArtworkHash = hash;
                    gLastArtworkLength = length;
                }
                emit(out);
            });
        });
    });
}

// MediaRemote fires several notifications per change; coalesce them.
static void scheduleFetch(void) {
    dispatch_async(gQueue, ^{
        if (gFetchScheduled) return;
        gFetchScheduled = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC), gQueue, ^{
            gFetchScheduled = NO;
            fetchNowPlaying();
        });
    });
}

// Same path as the Control Center scrubber; SetElapsedTime is the older fallback.
static void seek(double seconds) {
    NSDictionary *options = @{ kOptionPlaybackPosition: @(seconds) };
    Boolean sent = MRSendCommand(kMRChangePlaybackPosition, (__bridge CFDictionaryRef)options);
    if (!sent && MRSetElapsed) MRSetElapsed(seconds);
    // Some players don't post a change notification after seeking.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), gQueue, ^{ scheduleFetch(); });
}

static void handleCommand(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    NSString *cmd = parts.firstObject;
    if ([cmd isEqualToString:@"toggle"]) MRSendCommand(kMRTogglePlayPause, NULL);
    else if ([cmd isEqualToString:@"play"]) MRSendCommand(kMRPlay, NULL);
    else if ([cmd isEqualToString:@"pause"]) MRSendCommand(kMRPause, NULL);
    else if ([cmd isEqualToString:@"next"]) MRSendCommand(kMRNextTrack, NULL);
    else if ([cmd isEqualToString:@"prev"]) MRSendCommand(kMRPreviousTrack, NULL);
    else if ([cmd isEqualToString:@"seek"] && parts.count > 1) seek(parts[1].doubleValue);
    else if ([cmd isEqualToString:@"refresh"]) { gLastArtworkHash = 0; gLastArtworkLength = 0; scheduleFetch(); }
}

static void readCommands(void) {
    [NSThread detachNewThreadWithBlock:^{
        char buf[256];
        while (fgets(buf, sizeof buf, stdin)) {
            NSString *line = [[NSString stringWithUTF8String:buf]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (line.length) dispatch_async(gQueue, ^{ handleCommand(line); });
        }
        exit(0); // parent went away
    }];
}

// Called from perl through DynaLoader::dl_install_xsub. It never returns,
// so the XSUB arguments (interpreter, CV) are irrelevant.
__attribute__((visibility("default")))
void NotchBridgeMain(void *unusedInterpreter, void *unusedCV) {
    @autoreleasepool {
        void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        if (!mr) {
            fprintf(stderr, "notch-bridge: cannot load MediaRemote\n");
            exit(2);
        }
        MRRegister = (MRRegisterFn)dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
        MRGetInfo = (MRGetInfoFn)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
        MRGetIsPlaying = (MRGetIsPlayingFn)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        MRGetPID = (MRGetPIDFn)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationPID");
        MRSendCommand = (MRSendCommandFn)dlsym(mr, "MRMediaRemoteSendCommand");
        MRSetElapsed = (MRSetElapsedFn)dlsym(mr, "MRMediaRemoteSetElapsedTime");
        if (!MRRegister || !MRGetInfo || !MRGetIsPlaying || !MRGetPID || !MRSendCommand) {
            fprintf(stderr, "notch-bridge: MediaRemote symbols missing\n");
            exit(3);
        }

        kTitle = stringConst(mr, "kMRMediaRemoteNowPlayingInfoTitle");
        kArtist = stringConst(mr, "kMRMediaRemoteNowPlayingInfoArtist");
        kAlbum = stringConst(mr, "kMRMediaRemoteNowPlayingInfoAlbum");
        kDuration = stringConst(mr, "kMRMediaRemoteNowPlayingInfoDuration");
        kElapsed = stringConst(mr, "kMRMediaRemoteNowPlayingInfoElapsedTime");
        kTimestamp = stringConst(mr, "kMRMediaRemoteNowPlayingInfoTimestamp");
        kRate = stringConst(mr, "kMRMediaRemoteNowPlayingInfoPlaybackRate");
        kArtwork = stringConst(mr, "kMRMediaRemoteNowPlayingInfoArtworkData");
        kOptionPlaybackPosition = stringConst(mr, "kMRMediaRemoteOptionPlaybackPosition");

        gQueue = dispatch_queue_create("notch.mediaremote", DISPATCH_QUEUE_SERIAL);
        MRRegister(gQueue);

        const char *names[] = {
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationClientStateDidChange",
        };
        for (size_t i = 0; i < sizeof names / sizeof *names; i++) {
            NSString *name = stringConst(mr, names[i]);
            [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil
                                                          usingBlock:^(NSNotification *note) { scheduleFetch(); }];
        }

        emit(@{ @"type": @"ready" });
        readCommands();
        scheduleFetch();

        // Keep the run loop alive forever (MediaRemote delivers through it).
        [NSTimer scheduledTimerWithTimeInterval:1e9 repeats:YES block:^(NSTimer *t) {}];
        CFRunLoopRun();
        exit(0);
    }
}
