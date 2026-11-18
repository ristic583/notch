// notch-agent-hook.m
//
// Claude Code hook: tells Notch which session did what. Claude Code pipes the
// whole event in on stdin, prompts and tool output included; Notch only needs
// to know which session it was, what happened and in which folder (plus the
// one-line text of a notification), so that is all that reaches the log the
// app watches.
//
// Compiled rather than a script: it runs on every event, and an interpreter
// would add ~150 ms each time. It never fails the session it runs in.

#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <unistd.h>

int main(void) {
    @autoreleasepool {
        NSData *input = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
        id event = input.length ? [NSJSONSerialization JSONObjectWithData:input options:0 error:nil] : nil;
        if (![event isKindOfClass:[NSDictionary class]]) return 0;

        NSMutableDictionary *kept = [NSMutableDictionary dictionary];
        for (NSString *key in @[@"session_id", @"hook_event_name", @"cwd"]) {
            id value = event[key];
            if ([value isKindOfClass:[NSString class]] && [value length] <= 4096) kept[key] = value;
        }
        if (!kept[@"session_id"] || !kept[@"hook_event_name"]) return 0;
        // "Claude needs your permission to use Bash": shown when hovering the bubble.
        id message = event[@"message"];
        if ([kept[@"hook_event_name"] isEqual:@"Notification"] && [message isKindOfClass:[NSString class]]) {
            kept[@"message"] = [message length] > 300 ? [message substringToIndex:300] : message;
        }

        NSMutableData *line = [[NSJSONSerialization dataWithJSONObject:kept options:0 error:nil] mutableCopy];
        if (!line) return 0;
        [line appendBytes:"\n" length:1];

        NSString *directory = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Notch"];
        [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *log = [directory stringByAppendingPathComponent:@"agent-events.jsonl"];
        int fd = open(log.fileSystemRepresentation, O_WRONLY | O_APPEND | O_CREAT, 0600);
        if (fd < 0) return 0;
        // One write, so lines from sessions running side by side never interleave.
        (void)write(fd, line.bytes, line.length);
        close(fd);
    }
    return 0;
}
