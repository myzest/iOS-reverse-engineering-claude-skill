# Dylib Injection Plugin Generation Guide

Techniques for generating Logos/Theos dylib injection plugins from reverse-engineered iOS app code. Every generated tweak includes four built-in systems: crash logging, file-based hook tracing, JSON hook configuration, and unified network protocol capture.

## Enhanced Dylib Architecture

Every AI-generated tweak ships with these four integrated systems:

| System | Purpose | Output Location |
|--------|---------|-----------------|
| **Crash Logger** | Captures ObjC exceptions + POSIX signals (SIGABRT, SIGSEGV, SIGBUS, SIGTRAP) with full stack traces | `Documents/<TweakName>_crash.log` |
| **Hook Logger** | Records every hook invocation with timestamps, class/method, original vs. modified values | `Documents/<TweakName>_hook.log` |
| **JSON Config** | Clean key-value hook configuration, editable without recompiling | `Documents/<TweakName>_config.json` |
| **Network Capture** | Unified REQUEST/RESPONSE JSON Lines capture for protocol analysis | `Documents/<TweakName>_network.jsonl` |
| **Delayed Loading** | NSClassFromString polling with retry for classes in embedded frameworks | (internal — enables hooks) |
| **Block Wrapping** | Intercepts completion/callback blocks to capture response data from network calls | (internal — feeds Network Capture) |

The log file paths are auto-detected via `NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, ...)`, so no hardcoded paths.

## Logos Syntax Reference

Logos is a preprocessor for Objective-C that simplifies MobileSubstrate tweak development. It compiles to standard ObjC + libsubstrate calls.

### Core Directives

| Directive | Purpose |
|-----------|---------|
| `%hook ClassName` / `%end` | Hook all methods within the block on ClassName |
| `%group GroupName` / `%end` | Group hooks for conditional initialization |
| `%new` | Mark a method as newly added (not overriding) |
| `%orig` | Call the original implementation (with optional args) |
| `%ctor` | Constructor, runs on dylib load |
| `%dtor` | Destructor, runs on dylib unload |
| `%init(GroupName)` | Initialize (activate) hooks in a group |
| `%subclass ClassName : SuperClass` / `%end` | Create a new subclass at runtime |

### Common Hook Patterns

#### Return a fixed BOOL value
```objc
%hook UserInfoManager
- (BOOL)isVip {
    return YES;
}
%end
```

#### Return a fixed integer value
```objc
%hook ConfigManager
- (int)vipLevel {
    return 99;
}
%end
```

#### Return a fixed string value
```objc
%hook AccountManager
- (NSString *)userToken {
    return @"injected_token_value";
}
%end
```

#### Hook and call original, then modify
```objc
%hook PaymentValidator
- (BOOL)validateReceipt:(NSString *)receipt {
    %orig;
    return YES;
}
%end
```

#### Modify arguments before calling original
```objc
%hook NetworkManager
- (void)sendRequest:(NSMutableURLRequest *)request {
    [request setValue:@"hacked" forHTTPHeaderField:@"X-Custom"];
    %orig;
}
%end
```

#### Hook a void method (skip original entirely)
```objc
%hook AnalyticsTracker
- (void)trackEvent:(NSString *)event params:(NSDictionary *)params {
    return;
}
%end
```

#### Hook a class method (+)
```objc
%hook AppConfig
+ (BOOL)isDebugMode {
    return NO;
}
%end
```

#### Hook a property getter
```objc
%hook UserProfile
- (NSString *)displayName {
    return @"HookedName";
}
%end
```

#### Hook with instance variable access (MSHookIvar)
```objc
%hook MyViewController
- (void)viewDidLoad {
    %orig;
    UILabel *label = MSHookIvar<UILabel *>(self, "_titleLabel");
    label.text = @"Hooked";
}
%end
```

### Constructor Patterns

```objc
%ctor {
    NSLog(@"=== MyTweak loaded ===");
    %init;
}
```

### Conditional Hook Activation

```objc
%group BasicHooks
%hook ClassA
- (void)method1 { /* ... */ }
%end
%end

%group PremiumHooks
%hook ClassB
- (void)method2 { /* ... */ }
%end
%end

%ctor {
    %init(BasicHooks);
    NSInteger level = [[[ConfigManager shared] vipLevel] intValue];
    if (level >= 3) {
        %init(PremiumHooks);
    }
}
```

## Theos Project Structure

A full-featured tweak project contains:

```
tweak-name/
├── Makefile              # Build configuration
├── Tweak.xm              # Logos source (hooks + built-in utilities)
├── control               # Package metadata (.deb)
├── <bundle-id>.plist     # Injection target filter
├── config.default.json   # Default JSON config (AI documents it; runtime writes to Documents)
└── README.md             # Hook documentation, log locations, config guide
```

### Makefile Template

```makefile
ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0

INSTALL_TARGET_PROCESSES = <TargetAppName>

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = <TweakName>
<TweakName>_FILES = Tweak.xm
<TweakName>_CFLAGS = -fobjc-arc
<TweakName>_FRAMEWORKS = UIKit Foundation
<TweakName>_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
```

Note `substrate` in `_LIBRARIES` — required for `MSHookIvar` and related APIs.

### control Template

```
Package: com.ai.<tweakname>
Name: <TweakName>
Version: 1.0
Architecture: iphoneos-arm
Description: <One-line description of what this tweak hooks>
Maintainer: AI Generated
Author: AI Generated
Section: Tweaks
Depends: mobilesubstrate
```

### Filter plist Template

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Filter</key>
    <dict>
        <key>Bundles</key>
        <array>
            <string>com.example.targetapp</string>
        </array>
    </dict>
</dict>
</plist>
```

---

## System 1: Crash Logging

Captures all crashes — both ObjC exceptions and native signals — and writes a detailed crash report to `Documents/<TweakName>_crash.log`. This is the first thing initialized in `%ctor`, before any hooks activate.

### Crash Handler Code (placed at top of Tweak.xm, before any %hook blocks)

```objc
#import <sys/signal.h>
#import <execinfo.h>
#import <mach/mach.h>

static NSString *_crashLogPath = nil;

// ---- Signal handler for native crashes ----
static void signalHandler(int sig, siginfo_t *info, void *uap) {
    NSMutableString *report = [NSMutableString string];
    [report appendFormat:@"\n========================================\n"];
    [report appendFormat:@"CRASH REPORT — %@\n", [NSDate date]];
    [report appendFormat:@"Signal: %s (%d)\n", strsignal(sig), sig];
    [report appendFormat:@"Fault address: %p\n", info->si_addr];

    // Stack trace
    void *callstack[128];
    int frames = backtrace(callstack, 128);
    char **symbols = backtrace_symbols(callstack, frames);
    [report appendString:@"\nStack trace:\n"];
    for (int i = 0; i < frames; i++) {
        [report appendFormat:@"  %2d: %s\n", i, symbols[i]];
    }
    free(symbols);
    [report appendString:@"========================================\n"];

    // Flush to file immediately — after a signal we can't rely on autorelease/dealloc
    if (_crashLogPath) {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:_crashLogPath];
        if (!fh) {
            [report writeToFile:_crashLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[report dataUsingEncoding:NSUTF8StringEncoding]];
            [fh synchronizeFile];
            [fh closeFile];
        }
    }

    // Re-raise default handler
    signal(sig, SIG_DFL);
    raise(sig);
}

// ---- ObjC uncaught exception handler ----
static void uncaughtExceptionHandler(NSException *exception) {
    NSMutableString *report = [NSMutableString string];
    [report appendFormat:@"\n========================================\n"];
    [report appendFormat:@"CRASH REPORT (ObjC Exception) — %@\n", [NSDate date]];
    [report appendFormat:@"Name: %@\n", exception.name];
    [report appendFormat:@"Reason: %@\n", exception.reason];
    [report appendFormat:@"UserInfo: %@\n", exception.userInfo];
    [report appendFormat:@"Call stack:\n%@\n", exception.callStackSymbols];
    [report appendString:@"========================================\n"];

    if (_crashLogPath) {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:_crashLogPath];
        if (!fh) {
            [report writeToFile:_crashLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[report dataUsingEncoding:NSUTF8StringEncoding]];
            [fh synchronizeFile];
            [fh closeFile];
        }
    }
}

// Call this first in %ctor
static void setupCrashHandler(NSString *crashLogPath) {
    _crashLogPath = [crashLogPath copy];

    // ObjC exceptions
    NSSetUncaughtExceptionHandler(&uncaughtExceptionHandler);

    // POSIX signals
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = &signalHandler;
    sa.sa_flags = SA_SIGINFO;

    int signals[] = {SIGABRT, SIGSEGV, SIGBUS, SIGTRAP, SIGILL, SIGFPE, SIGSYS};
    for (int i = 0; i < sizeof(signals)/sizeof(signals[0]); i++) {
        sigaction(signals[i], &sa, NULL);
    }
}
```

**Important notes**:
- The crash handler must be set up as the very first thing in `%ctor`, before any hooks or config loading.
- Signal handlers cannot allocate memory safely — the code above does minimal work and uses `NSFileHandle` for buffered writes.
- On crash, the report is appended to the crash log file (not overwritten), so multiple crash sessions accumulate.

---

## System 2: File-Based Hook Logger

Every hook invocation records a structured log entry to `Documents/<TweakName>_hook.log`. The logger uses a ring buffer and flushes periodically.

### Logger Code (placed after crash handler, before any %hook blocks)

```objc
@interface HKTweakLogger : NSObject {
    NSFileHandle *_fileHandle;
    NSDateFormatter *_dateFormatter;
    dispatch_queue_t _queue;
}

+ (instancetype)shared;
- (void)setupWithPath:(NSString *)path;
- (void)logInfo:(NSString *)format, ...;
- (void)logHookEnter:(NSString *)className selector:(NSString *)selector args:(NSString *)args;
- (void)logHookLeave:(NSString *)className selector:(NSString *)selector originalResult:(id)orig newResult:(id)new;
- (void)logHookVoid:(NSString *)className selector:(NSString *)selector skipped:(BOOL)skipped;
- (void)logEvent:(NSString *)event detail:(NSString *)detail;
- (NSString *)logFilePath;
- (void)flush;
@end

@implementation HKTweakLogger

+ (instancetype)shared {
    static HKTweakLogger *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (void)setupWithPath:(NSString *)path {
    _dateFormatter = [[NSDateFormatter alloc] init];
    _dateFormatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    _dateFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    _queue = dispatch_queue_create("com.hktweak.logger", DISPATCH_QUEUE_SERIAL);

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        [fm createFileAtPath:path contents:nil attributes:nil];
    }
    _fileHandle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (_fileHandle) {
        [_fileHandle seekToEndOfFile];
    }

    [self logInfo:@"========== Dylib Loaded (PID: %d) ==========", getpid()];
}

- (NSString *)timestamp {
    return [_dateFormatter stringFromDate:[NSDate date]];
}

- (void)writeLine:(NSString *)line {
    // NSLog dual-output for real-time idevicesyslog monitoring
    NSLog(@"[SOUL_HOOK] %@", line);

    dispatch_async(_queue, ^{
        NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", [self timestamp], line];
        NSData *data = [entry dataUsingEncoding:NSUTF8StringEncoding];
        if (self->_fileHandle) {
            @try {
                [self->_fileHandle writeData:data];
            } @catch (NSException *e) {
                // File handle invalid — re-open
                self->_fileHandle = [NSFileHandle fileHandleForWritingAtPath:self.logFilePath];
                if (self->_fileHandle) {
                    [self->_fileHandle seekToEndOfFile];
                    [self->_fileHandle writeData:data];
                }
            }
        }
    });
}

- (void)logInfo:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    [self writeLine:[NSString stringWithFormat:@"[INFO] %@", msg]];
}

- (void)logHookEnter:(NSString *)className selector:(NSString *)selector args:(NSString *)args {
    [self writeLine:[NSString stringWithFormat:@"[HOOK:ENTER] %@ %@ | args: %@", className, selector, args ?: @"(none)"]];
}

- (void)logHookLeave:(NSString *)className selector:(NSString *)selector originalResult:(id)orig newResult:(id)new {
    [self writeLine:[NSString stringWithFormat:@"[HOOK:LEAVE] %@ %@ | original=%@ | modified=%@", className, selector, orig ?: @"(void)", new ?: @"(void)"]];
}

- (void)logHookVoid:(NSString *)className selector:(NSString *)selector skipped:(BOOL)skipped {
    [self writeLine:[NSString stringWithFormat:@"[HOOK:VOID] %@ %@ | %@", className, selector, skipped ? @"SKIPPED (original not called)" : @"PASS-THROUGH"]];
}

- (void)logEvent:(NSString *)event detail:(NSString *)detail {
    [self writeLine:[NSString stringWithFormat:@"[EVENT:%@] %@", event, detail]];
}

- (NSString *)logFilePath {
    return nil; // overridden via setupWithPath: stored internally
}

- (void)flush {
    dispatch_sync(_queue, ^{
        if (self->_fileHandle) {
            [self->_fileHandle synchronizeFile];
        }
    });
}

@end
```

### How hooks use the logger

Every generated hook wraps its logic with log calls:

```objc
%hook UserInfoManager
- (BOOL)isVip {
    [[HKTweakLogger shared] logHookEnter:@"UserInfoManager" selector:@"-isVip" args:nil];
    BOOL result = YES;
    [[HKTweakLogger shared] logHookLeave:@"UserInfoManager" selector:@"-isVip" originalResult:@"(not called)" new:@(result)];
    return result;
}
%end
```

For hooks that call `%orig`:

```objc
%hook PaymentValidator
- (BOOL)validateReceipt:(NSString *)receipt {
    [[HKTweakLogger shared] logHookEnter:@"PaymentValidator" selector:@"-validateReceipt:" args:receipt];
    BOOL origResult = %orig;
    BOOL newResult = YES;
    [[HKTweakLogger shared] logHookLeave:@"PaymentValidator" selector:@"-validateReceipt:" originalResult:@(origResult) new:@(newResult)];
    return newResult;
}
%end
```

---

## System 3: JSON Hook Configuration

The dylib writes a clean JSON config file to `Documents/<TweakName>_config.json` on first launch. The user can edit this JSON to change hook behavior without recompiling. On subsequent launches, the dylib reads the config and applies settings.

### Config File Format

```json
{
  "tweak": {
    "name": "<TweakName>",
    "version": "1.0",
    "description": "<User's hook description>"
  },
  "created_at": "2026-05-19T10:30:00+0800",
  "enabled": true,
  "hooks": [
    {
      "id": "hook_001",
      "class": "UserInfoManager",
      "method": "- (BOOL)isVip",
      "description": "Force VIP status to always return YES",
      "returnType": "BOOL",
      "returnValue": true,
      "enabled": true
    }
  ]
}
```

### JSON Config Loader Code

```objc
@interface HKTweakConfig : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *version;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, strong) NSArray<NSDictionary *> *hooks;

+ (instancetype)shared;
- (void)loadFromPath:(NSString *)configPath defaults:(NSDictionary *)defaults;
- (nullable NSDictionary *)hookForId:(NSString *)hookId;
- (BOOL)isHookEnabled:(NSString *)hookId;
- (nullable id)returnValueForHook:(NSString *)hookId;
@end

@implementation HKTweakConfig

+ (instancetype)shared {
    static HKTweakConfig *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (void)loadFromPath:(NSString *)configPath defaults:(NSDictionary *)defaults {
    self.enabled = YES;
    NSFileManager *fm = [NSFileManager defaultManager];

    if (![fm fileExistsAtPath:configPath]) {
        // First launch — write default config
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:defaults
            options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
        [jsonData writeToFile:configPath atomically:YES];
        self.hooks = defaults[@"hooks"];
    } else {
        // Reload from edited config
        NSData *data = [NSData dataWithContentsOfFile:configPath];
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        self.enabled = [dict[@"enabled"] boolValue];
        self.hooks = dict[@"hooks"];
    }
    self.name = defaults[@"tweak"][@"name"];
    self.version = defaults[@"tweak"][@"version"];
}

- (nullable NSDictionary *)hookForId:(NSString *)hookId {
    for (NSDictionary *hook in self.hooks) {
        if ([hook[@"id"] isEqualToString:hookId]) return hook;
    }
    return nil;
}

- (BOOL)isHookEnabled:(NSString *)hookId {
    if (!self.enabled) return NO;
    NSDictionary *hook = [self hookForId:hookId];
    return hook ? [hook[@"enabled"] boolValue] : YES; // default enabled
}

- (nullable id)returnValueForHook:(NSString *)hookId {
    NSDictionary *hook = [self hookForId:hookId];
    return hook[@"returnValue"];
}

@end
```

### Using config in hooks

```objc
%hook UserInfoManager
- (BOOL)isVip {
    [[HKTweakLogger shared] logHookEnter:@"UserInfoManager" selector:@"-isVip" args:nil];

    if (![[HKTweakConfig shared] isHookEnabled:@"hook_vip"]) {
        return %orig;
    }

    BOOL result = [[[HKTweakConfig shared] returnValueForHook:@"hook_vip"] boolValue];
    [[HKTweakLogger shared] logHookLeave:@"UserInfoManager" selector:@"-isVip" originalResult:@"(config)" new:@(result)];
    return result;
}
%end
```

---

## System 4: Unified Network Protocol Capture

When hooking network communication methods (URLSession, Alamofire, custom socket protocols, etc.), the dylib captures request and response data in a unified JSON Lines (`.jsonl`) format in `Documents/<TweakName>_network.jsonl`.

### Network Capture Format

Each line is a self-contained JSON object:

**Outbound (REQUEST)**:
```json
{"direction":"REQUEST","timestamp":1716123456.789,"protocol":"HTTP","method":"POST","url":"https://api.example.com/v1/auth/login","headers":{"Content-Type":"application/json","Authorization":"Bearer eyJ..."},"body":"{\"phone\":\"138****1234\",\"code\":\"****\"}","caller":"-[AuthService loginWithPhone:code:]"}
```

**Inbound (RESPONSE)**:
```json
{"direction":"RESPONSE","timestamp":1716123456.890,"protocol":"HTTP","statusCode":200,"url":"https://api.example.com/v1/auth/login","headers":{"Content-Type":"application/json"},"body":"{\"token\":\"eyJ...\",\"userId\":12345}","caller":"-[AuthService loginWithPhone:code:]"}
```

### Network Capture Writer Code

```objc
@interface HKTweakNetworkCapture : NSObject
+ (instancetype)shared;
- (void)setupWithPath:(NSString *)path;
- (void)captureRequest:(NSString *)url
                method:(NSString *)method
               headers:(NSDictionary *)headers
                  body:(id)body
                caller:(NSString *)caller;
- (void)captureResponse:(NSString *)url
             statusCode:(NSInteger)statusCode
                headers:(NSDictionary *)headers
                   body:(id)body
                 caller:(NSString *)caller;
@end

@implementation HKTweakNetworkCapture {
    NSFileHandle *_fileHandle;
    dispatch_queue_t _queue;
    NSString *_path;
}

+ (instancetype)shared {
    static HKTweakNetworkCapture *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (void)setupWithPath:(NSString *)path {
    _path = path;
    _queue = dispatch_queue_create("com.hktweak.netcapture", DISPATCH_QUEUE_SERIAL);
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        [fm createFileAtPath:path contents:nil attributes:nil];
    }
    _fileHandle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (_fileHandle) [_fileHandle seekToEndOfFile];
}

- (NSString *)sanitizedBody:(id)body {
    if (!body) return nil;
    if ([body isKindOfClass:[NSData class]]) {
        NSString *utf8 = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
        if (utf8) return utf8;
        return [NSString stringWithFormat:@"<binary %lu bytes>", (unsigned long)[body length]];
    }
    if ([body isKindOfClass:[NSDictionary class]] || [body isKindOfClass:[NSArray class]]) {
        NSData *json = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
        return [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    }
    return [body description];
}

- (void)writeEntry:(NSDictionary *)entry {
    dispatch_async(_queue, ^{
        NSData *json = [NSJSONSerialization dataWithJSONObject:entry options:0 error:nil];
        if (!json) return;
        NSMutableData *line = [NSMutableData dataWithData:json];
        [line appendData:[NSData dataWithBytes:"\n" length:1]];
        if (self->_fileHandle) {
            @try {
                [self->_fileHandle writeData:line];
            } @catch (NSException *e) {
                self->_fileHandle = [NSFileHandle fileHandleForWritingAtPath:self->_path];
                if (self->_fileHandle) {
                    [self->_fileHandle seekToEndOfFile];
                    [self->_fileHandle writeData:line];
                }
            }
        }
    });
}

- (void)captureRequest:(NSString *)url
                method:(NSString *)method
               headers:(NSDictionary *)headers
                  body:(id)body
                caller:(NSString *)caller {
    [self writeEntry:@{
        @"direction": @"REQUEST",
        @"timestamp": @([[NSDate date] timeIntervalSince1970]),
        @"protocol": @"HTTP",
        @"method": method ?: @"GET",
        @"url": url ?: @"",
        @"headers": headers ?: @{},
        @"body": [self sanitizedBody:body] ?: [NSNull null],
        @"caller": caller ?: @"unknown"
    }];
}

- (void)captureResponse:(NSString *)url
             statusCode:(NSInteger)statusCode
                headers:(NSDictionary *)headers
                   body:(id)body
                 caller:(NSString *)caller {
    [self writeEntry:@{
        @"direction": @"RESPONSE",
        @"timestamp": @([[NSDate date] timeIntervalSince1970]),
        @"protocol": @"HTTP",
        @"statusCode": @(statusCode),
        @"url": url ?: @"",
        @"headers": headers ?: @{},
        @"body": [self sanitizedBody:body] ?: [NSNull null],
        @"caller": caller ?: @"unknown"
    }];
}

@end
```

### Network hook example

```objc
%hook AFHTTPSessionManager
- (NSURLSessionDataTask *)POST:(NSString *)URLString
                    parameters:(id)parameters
                       headers:(NSDictionary<NSString *,NSString *> *)headers
                       success:(void (^)(NSURLSessionDataTask *, id))success
                       failure:(void (^)(NSURLSessionDataTask *, NSError *))failure {
    [[HKTweakLogger shared] logHookEnter:@"AFHTTPSessionManager" selector:@"-POST:parameters:headers:success:failure:" args:[NSString stringWithFormat:@"URL=%@ params=%@", URLString, parameters]];

    // Capture the request
    [[HKTweakNetworkCapture shared] captureRequest:URLString
                                            method:@"POST"
                                           headers:headers
                                              body:parameters
                                            caller:NSStringFromSelector(_cmd)];

    // Wrap the success callback to capture the response
    void (^wrappedSuccess)(NSURLSessionDataTask *, id) = ^(NSURLSessionDataTask *task, id responseObject) {
        [[HKTweakNetworkCapture shared] captureResponse:URLString
                                             statusCode:200
                                                headers:nil
                                                   body:responseObject
                                                 caller:NSStringFromSelector(_cmd)];
        [[HKTweakLogger shared] logEvent:@"NETWORK_RESPONSE" detail:[NSString stringWithFormat:@"URL=%@ bodyClass=%@", URLString, NSStringFromClass([responseObject class])]];
        if (success) success(task, responseObject);
    };

    return %orig(URLString, parameters, headers, wrappedSuccess, failure);
}
%end
```

---

---

## System 5: Delayed Class Loading with Retry

When the target class lives in an embedded framework — not the main binary — it may not be loaded yet when the dylib's `%ctor` runs. This is common with third-party SDKs (FlyVerify, ZZT, etc.). The solution is a retry mechanism that polls `NSClassFromString` at intervals before attempting the hook.

### Retry Loader Code

```objc
// Place this BEFORE the %ctor, after all utility class @implementations

static void tryInstallHooks(void);

static void retryAfterDelay(NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        tryInstallHooks();
    });
}

static BOOL hooksInstalled = NO;

static void tryInstallHooks(void) {
    if (hooksInstalled) return;

    // Check if all required classes are available
    Class flyeSDK = NSClassFromString(@"FLYEASDK");
    Class flyVerifyService = NSClassFromString(@"FlyVerifyService");

    if (!flyeSDK || !flyVerifyService) {
        static int retryCount = 0;
        retryCount++;
        if (retryCount == 1) {
            [[HKTweakLogger shared] logInfo:@"Target classes not loaded yet — retrying in 0.5s (attempt %d)", retryCount];
            retryAfterDelay(0.5);
        } else if (retryCount <= 10) {
            [[HKTweakLogger shared] logInfo:@"Still waiting... retrying in 3s (attempt %d)", retryCount];
            retryAfterDelay(3.0);
        } else {
            [[HKTweakLogger shared] logInfo:@"Gave up after %d retries — classes never loaded", retryCount];
        }
        return;
    }

    hooksInstalled = YES;
    [[HKTweakLogger shared] logInfo:@"All target classes loaded — activating hooks now"];

    // Now it's safe to swizzle. Dispatch to main queue for UIKit safety.
    dispatch_async(dispatch_get_main_queue(), ^{
        // %init would go here in Logos, or manual swizzling calls
        [[HKTweakLogger shared] logInfo:@"Hooks activated on main queue"];
    });
}
```

### How to integrate delayed loading

In `%ctor`, replace the immediate `%init` with a deferred approach:

```objc
%ctor {
    // 1. Crash handler FIRST
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    setupCrashHandler([docs stringByAppendingPathComponent:@TWEAK_NAME "_crash.log"]);

    // 2. Logger
    [[HKTweakLogger shared] setupWithPath:[docs stringByAppendingPathComponent:@TWEAK_NAME "_hook.log"]];
    [[HKTweakLogger shared] logInfo:@"Dylib loaded (PID: %d)", getpid()];

    // 3. Config
    NSString *cfgPath = [docs stringByAppendingPathComponent:@TWEAK_NAME "_config.json"];
    [[HKTweakConfig shared] loadFromPath:cfgPath defaults:defaultConfig];

    // 4. Attempt hook installation — will retry if classes not loaded
    tryInstallHooks();
}
```

**Critical**: The hook code inside `%hook` blocks runs when `%init` executes. If `%init` is called inside a Logos `%ctor`, it runs immediately. For delayed loading, you must either:
- (A) **Logos approach**: Move all `%hook` blocks into a `%group DelayedHooks`, and call `%init(DelayedHooks)` from inside `tryInstallHooks` on the main queue.
- (B) **Pure ObjC approach**: Skip Logos entirely, use manual `class_getClassMethod` + `method_exchangeImplementations` inside `tryInstallHooks`. See the "Pure ObjC Method Swizzling Alternative" section below.

### Group-based delayed loading (Logos)

```objc
%group DelayedHooks

%hook FLYEASDK
+ (void)initWithSelfKey:(NSString *)selfKey appSecret:(NSString *)appSecret {
    @try {
        [[HKTweakLogger shared] logHookEnter:@"FLYEASDK" selector:@"+initWithSelfKey:appSecret:"
                                        args:[NSString stringWithFormat:@"selfKey=%@ appSecret=%@", selfKey, appSecret]];
    } @catch (NSException *e) {}

    %orig;

    @try {
        [[HKTweakLogger shared] logHookVoid:@"FLYEASDK" selector:@"+initWithSelfKey:appSecret:" skipped:NO];
    } @catch (NSException *e) {}
}
%end

// ... more hooks ...

%end // DelayedHooks

%ctor {
    // ... crash, logger, config setup ...
    tryInstallHooks(); // This calls %init(DelayedHooks) when classes are ready
}
```

---

## System 6: Completion Block Wrapping for Network Response Capture

When hooking a method that takes a completion/callback block (e.g., `completion:(void (^)(NSDictionary *, NSError *))completion`), you must wrap the block to intercept the response data before it reaches the original caller.

### Block Wrapping Pattern

```objc
%hook FlyVerifyService
+ (void)getInitConfigAppKey:(NSString *)appKey
                     secret:(NSString *)secret
                       duid:(NSString *)duid
                completion:(void (^)(NSDictionary *response, NSError *error))completion {

    [[HKTweakLogger shared] logHookEnter:@"FlyVerifyService"
                                selector:@"+getInitConfigAppKey:secret:duid:completion:"
                                    args:[NSString stringWithFormat:@"appKey=%@ duid=%@", appKey, duid]];

    // Capture the request parameters immediately
    [[HKTweakNetworkCapture shared] captureRequest:@"api-auth.zztfly.com/api/bd/initSec"
                                            method:@"POST"
                                           headers:nil
                                              body:@{@"appKey": appKey ?: @"", @"duid": duid ?: @""}
                                            caller:@"FlyVerifyService.getInitConfig"];

    // Wrap the completion block to intercept the response
    void (^wrappedCompletion)(NSDictionary *, NSError *) = ^(NSDictionary *response, NSError *error) {
        @try {
            if (response) {
                [[HKTweakLogger shared] logEvent:@"INITSEC_RESPONSE"
                                          detail:[NSString stringWithFormat:@"accessKey=%@ channel=%@ deviceType=%@",
                                                  response[@"accessKey"], response[@"channel"], response[@"deviceType"]]];

                // Save full response to a dedicated JSON file
                NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                      NSUserDomainMask, YES) firstObject];
                NSString *respPath = [docs stringByAppendingPathComponent:@TWEAK_NAME "_initsec_response.json"];
                NSData *json = [NSJSONSerialization dataWithJSONObject:response
                                    options:NSJSONWritingPrettyPrinted error:nil];
                [json writeToFile:respPath atomically:YES];

                // Capture response in network log
                [[HKTweakNetworkCapture shared] captureResponse:@"api-auth.zztfly.com/api/bd/initSec"
                                                     statusCode:200
                                                        headers:nil
                                                           body:response
                                                         caller:@"FlyVerifyService.getInitConfig"];
            }
            if (error) {
                [[HKTweakLogger shared] logEvent:@"INITSEC_ERROR"
                                          detail:[NSString stringWithFormat:@"code=%ld domain=%@",
                                                  (long)error.code, error.domain]];
            }
        } @catch (NSException *e) {
            [[HKTweakLogger shared] logEvent:@"CAPTURE_ERROR"
                                      detail:[NSString stringWithFormat:@"%@", e.reason]];
        }

        // ALWAYS call the original completion — never swallow it
        if (completion) completion(response, error);
    };

    // Call original with wrapped completion
    %orig(appKey, secret, duid, wrappedCompletion);
}
%end
```

### Key rules for block wrapping

1. **Never skip calling the original completion** — this will hang the app's UI or break initialization
2. **Capture request params before %orig** — they are available synchronously
3. **Wrap response handling in @try/@catch** — response parsing can throw (unexpected NSNull, type mismatch)
4. **Copy the block to heap** — the wrapped block must outlive the method scope (ARC handles this automatically when assigned to a local variable captured by the block itself; for manual retain, use `[wrappedCompletion copy]`)
5. **Save response to a named JSON file** — makes it easier to find than scanning the full hook log

---

## Complete Enhanced Tweak.xm Template

The full template that the AI generates, with all six systems wired together:

```objc
// ============================================================
//  <TweakName> — <one-line description>
//  Generated by AI on <date>
//  Target: <AppName> (<BundleID>)
//
//  Log files (in App Documents):
//    - <TweakName>_hook.log     Hook invocation trace
//    - <TweakName>_crash.log    Crash/exception reports
//    - <TweakName>_config.json  Editable hook configuration
//    - <TweakName>_network.jsonl Network I/O capture
// ============================================================

#import <substrate.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <sys/signal.h>
#import <execinfo.h>

#define TWEAK_NAME @"<TweakName>"

// ============================================================
//  SYSTEM 1: Crash Handler
// ============================================================

static NSString *_crashLogPath = nil;

static void signalHandler(int sig, siginfo_t *info, void *uap) {
    NSMutableString *report = [NSMutableString string];
    [report appendFormat:@"\n========================================\n"];
    [report appendFormat:@"CRASH REPORT — %@\n", [NSDate date]];
    [report appendFormat:@"Signal: %s (%d)\n", strsignal(sig), sig];
    [report appendFormat:@"Fault address: %p\n", info->si_addr];
    void *callstack[128];
    int frames = backtrace(callstack, 128);
    char **symbols = backtrace_symbols(callstack, frames);
    [report appendString:@"\nStack trace:\n"];
    for (int i = 0; i < frames; i++) {
        [report appendFormat:@"  %2d: %s\n", i, symbols[i]];
    }
    free(symbols);
    [report appendString:@"========================================\n"];
    if (_crashLogPath) {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:_crashLogPath];
        if (!fh) {
            [report writeToFile:_crashLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[report dataUsingEncoding:NSUTF8StringEncoding]];
            [fh synchronizeFile];
            [fh closeFile];
        }
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

static void uncaughtExceptionHandler(NSException *exception) {
    NSMutableString *report = [NSMutableString string];
    [report appendFormat:@"\n========================================\n"];
    [report appendFormat:@"CRASH REPORT (ObjC Exception) — %@\n", [NSDate date]];
    [report appendFormat:@"Name: %@\n", exception.name];
    [report appendFormat:@"Reason: %@\n", exception.reason];
    [report appendFormat:@"UserInfo: %@\n", exception.userInfo];
    [report appendFormat:@"Call stack:\n%@\n", exception.callStackSymbols];
    [report appendString:@"========================================\n"];
    if (_crashLogPath) {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:_crashLogPath];
        if (!fh) {
            [report writeToFile:_crashLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[report dataUsingEncoding:NSUTF8StringEncoding]];
            [fh synchronizeFile];
            [fh closeFile];
        }
    }
}

static void setupCrashHandler(NSString *crashLogPath) {
    _crashLogPath = [crashLogPath copy];
    NSSetUncaughtExceptionHandler(&uncaughtExceptionHandler);
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = &signalHandler;
    sa.sa_flags = SA_SIGINFO;
    int signals[] = {SIGABRT, SIGSEGV, SIGBUS, SIGTRAP, SIGILL, SIGFPE, SIGSYS};
    for (int i = 0; i < sizeof(signals)/sizeof(signals[0]); i++) {
        sigaction(signals[i], &sa, NULL);
    }
}

// ============================================================
//  SYSTEM 2: File-Based Hook Logger
// ============================================================

@interface HKTweakLogger : NSObject { NSFileHandle *_fh; NSDateFormatter *_df; dispatch_queue_t _q; NSString *_path; }
+ (instancetype)shared;
- (void)setupWithPath:(NSString *)path;
- (void)logInfo:(NSString *)format, ...;
- (void)logHookEnter:(NSString *)cls selector:(NSString *)sel args:(NSString *)args;
- (void)logHookLeave:(NSString *)cls selector:(NSString *)sel originalResult:(id)orig new:(id)new;
- (void)logHookVoid:(NSString *)cls selector:(NSString *)sel skipped:(BOOL)skipped;
- (void)logEvent:(NSString *)event detail:(NSString *)detail;
- (void)flush;
@end

@implementation HKTweakLogger
+ (instancetype)shared {
    static HKTweakLogger *i = nil;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ i = [[self alloc] init]; });
    return i;
}
- (void)setupWithPath:(NSString *)path {
    _path = path;
    _df = [[NSDateFormatter alloc] init];
    _df.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    _df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    _q = dispatch_queue_create("com.hktweak.logger", DISPATCH_QUEUE_SERIAL);
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
    _fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (_fh) [_fh seekToEndOfFile];
    [self logInfo:@"========== Dylib Loaded (PID: %d) ==========", getpid()];
}
- (NSString *)ts { return [_df stringFromDate:[NSDate date]]; }
- (void)writeLine:(NSString *)line {
    // NSLog dual-output for real-time idevicesyslog monitoring
    NSLog(@"[SOUL_HOOK] %@", line);

    dispatch_async(_q, ^{
        NSString *s = [NSString stringWithFormat:@"[%@] %@\n", [self ts], line];
        NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
        if (self->_fh) {
            @try { [self->_fh writeData:d]; }
            @catch (NSException *e) {
                self->_fh = [NSFileHandle fileHandleForWritingAtPath:self->_path];
                if (self->_fh) { [self->_fh seekToEndOfFile]; [self->_fh writeData:d]; }
            }
        }
    });
}
- (void)logInfo:(NSString *)f, ... {
    va_list a; va_start(a, f);
    [self writeLine:[NSString stringWithFormat:@"[INFO] %@", [[NSString alloc] initWithFormat:f arguments:a]]];
    va_end(a);
}
- (void)logHookEnter:(NSString *)cls selector:(NSString *)sel args:(NSString *)args {
    [self writeLine:[NSString stringWithFormat:@"[HOOK:ENTER] %@ %@ | args: %@", cls, sel, args ?: @"(none)"]];
}
- (void)logHookLeave:(NSString *)cls selector:(NSString *)sel originalResult:(id)orig new:(id)new {
    [self writeLine:[NSString stringWithFormat:@"[HOOK:LEAVE] %@ %@ | original=%@ | modified=%@", cls, sel, orig ?: @"(void)", new ?: @"(void)"]];
}
- (void)logHookVoid:(NSString *)cls selector:(NSString *)sel skipped:(BOOL)skipped {
    [self writeLine:[NSString stringWithFormat:@"[HOOK:VOID] %@ %@ | %@", cls, sel, skipped ? @"SKIPPED" : @"PASS-THROUGH"]];
}
- (void)logEvent:(NSString *)event detail:(NSString *)detail {
    [self writeLine:[NSString stringWithFormat:@"[EVENT:%@] %@", event, detail]];
}
- (void)flush {
    dispatch_sync(_q, ^{ if (self->_fh) [self->_fh synchronizeFile]; });
}
@end

// ============================================================
//  SYSTEM 3: JSON Configuration
// ============================================================

@interface HKTweakConfig : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *version;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, strong) NSArray<NSDictionary *> *hooks;
+ (instancetype)shared;
- (void)loadFromPath:(NSString *)configPath defaults:(NSDictionary *)defaults;
- (nullable NSDictionary *)hookForId:(NSString *)hookId;
- (BOOL)isHookEnabled:(NSString *)hookId;
- (nullable id)returnValueForHook:(NSString *)hookId;
@end

@implementation HKTweakConfig
+ (instancetype)shared {
    static HKTweakConfig *i = nil;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ i = [[self alloc] init]; });
    return i;
}
- (void)loadFromPath:(NSString *)configPath defaults:(NSDictionary *)defaults {
    self.enabled = YES;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:configPath]) {
        NSData *d = [NSJSONSerialization dataWithJSONObject:defaults
            options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
        [d writeToFile:configPath atomically:YES];
        self.hooks = defaults[@"hooks"];
    } else {
        NSData *d = [NSData dataWithContentsOfFile:configPath];
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        self.enabled = [dict[@"enabled"] boolValue];
        self.hooks = dict[@"hooks"];
    }
    self.name = defaults[@"tweak"][@"name"];
    self.version = defaults[@"tweak"][@"version"];
}
- (NSDictionary *)hookForId:(NSString *)hid {
    for (NSDictionary *h in self.hooks) { if ([h[@"id"] isEqualToString:hid]) return h; }
    return nil;
}
- (BOOL)isHookEnabled:(NSString *)hid {
    if (!self.enabled) return NO;
    NSDictionary *h = [self hookForId:hid];
    return h ? [h[@"enabled"] boolValue] : YES;
}
- (id)returnValueForHook:(NSString *)hid {
    return [self hookForId:hid][@"returnValue"];
}
@end

// ============================================================
//  SYSTEM 4: Network Capture (only included if needed)
// ============================================================

@interface HKTweakNetworkCapture : NSObject { NSFileHandle *_fh; dispatch_queue_t _q; NSString *_path; }
+ (instancetype)shared;
- (void)setupWithPath:(NSString *)path;
- (void)captureRequest:(NSString *)url method:(NSString *)method headers:(NSDictionary *)hdrs body:(id)body caller:(NSString *)caller;
- (void)captureResponse:(NSString *)url statusCode:(NSInteger)sc headers:(NSDictionary *)hdrs body:(id)body caller:(NSString *)caller;
@end

@implementation HKTweakNetworkCapture
+ (instancetype)shared {
    static HKTweakNetworkCapture *i = nil;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ i = [[self alloc] init]; });
    return i;
}
- (void)setupWithPath:(NSString *)path {
    _path = path;
    _q = dispatch_queue_create("com.hktweak.netcapture", DISPATCH_QUEUE_SERIAL);
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
    _fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (_fh) [_fh seekToEndOfFile];
}
- (NSString *)sanitize:(id)body {
    if (!body) return nil;
    if ([body isKindOfClass:[NSData class]]) {
        NSString *s = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
        return s ?: [NSString stringWithFormat:@"<binary %lu bytes>", (unsigned long)[body length]];
    }
    if ([body isKindOfClass:[NSDictionary class]] || [body isKindOfClass:[NSArray class]]) {
        NSData *j = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
        return [[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding];
    }
    return [body description];
}
- (void)writeEntry:(NSDictionary *)e {
    dispatch_async(_q, ^{
        NSData *j = [NSJSONSerialization dataWithJSONObject:e options:0 error:nil];
        if (!j) return;
        NSMutableData *l = [NSMutableData dataWithData:j];
        [l appendData:[NSData dataWithBytes:"\n" length:1]];
        if (self->_fh) {
            @try { [self->_fh writeData:l]; }
            @catch (NSException *ex) {
                self->_fh = [NSFileHandle fileHandleForWritingAtPath:self->_path];
                if (self->_fh) { [self->_fh seekToEndOfFile]; [self->_fh writeData:l]; }
            }
        }
    });
}
- (void)captureRequest:(NSString *)url method:(NSString *)method headers:(NSDictionary *)hdrs body:(id)body caller:(NSString *)caller {
    [self writeEntry:@{@"direction":@"REQUEST",@"timestamp":@([[NSDate date] timeIntervalSince1970]),@"protocol":@"HTTP",@"method":method?:@"GET",@"url":url?:@"",@"headers":hdrs?:@{},@"body":[self sanitize:body]?:[NSNull null],@"caller":caller?:@"unknown"}];
}
- (void)captureResponse:(NSString *)url statusCode:(NSInteger)sc headers:(NSDictionary *)hdrs body:(id)body caller:(NSString *)caller {
    [self writeEntry:@{@"direction":@"RESPONSE",@"timestamp":@([[NSDate date] timeIntervalSince1970]),@"protocol":@"HTTP",@"statusCode":@(sc),@"url":url?:@"",@"headers":hdrs?:@{},@"body":[self sanitize:body]?:[NSNull null],@"caller":caller?:@"unknown"}];
}
@end

// ============================================================
//  %ctor — Initialize All Systems, Then Activate Hooks
// ============================================================

%ctor {
    // 1. Determine Documents directory
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (!docs) return; // safety: can't proceed without Documents

    // 2. SETUP CRASH HANDLER FIRST — before anything else
    setupCrashHandler([docs stringByAppendingPathComponent:@TWEAK_NAME "_crash.log"]);

    // 3. Setup hook logger
    [[HKTweakLogger shared] setupWithPath:[docs stringByAppendingPathComponent:@TWEAK_NAME "_hook.log"]];

    // 4. Load config (writes defaults on first launch)
    NSString *configPath = [docs stringByAppendingPathComponent:@TWEAK_NAME "_config.json"];
    NSDictionary *defaultConfig = <JSON_CONFIG_PLACEHOLDER>;
    [[HKTweakConfig shared] loadFromPath:configPath defaults:defaultConfig];

    // 5. Setup network capture (only if this tweak hooks network methods)
    // [[HKTweakNetworkCapture shared] setupWithPath:[docs stringByAppendingPathComponent:@TWEAK_NAME "_network.jsonl"]];

    [[HKTweakLogger shared] logInfo:@"All systems initialized"];

    // 6. Check if target classes are available. If in embedded frameworks, retry.
    //    tryInstallHooks() polls NSClassFromString with backoff and calls %init on main queue.
    tryInstallHooks();
}
```

**The `tryInstallHooks` function** (placed before `%ctor`, after all utility @implementation blocks):

```objc
static BOOL hooksInstalled = NO;

static void tryInstallHooks(void) {
    if (hooksInstalled) return;

    // Check for required classes (add all classes that may be in embedded frameworks)
    Class requiredClass = NSClassFromString(@"<HardestToFindClass>");
    if (!requiredClass) {
        static int retryCount = 0;
        retryCount++;
        if (retryCount == 1) {
            [[HKTweakLogger shared] logInfo:@"Target class not loaded yet — retrying in 0.5s (attempt %d)", retryCount];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ tryInstallHooks(); });
        } else if (retryCount <= 10) {
            [[HKTweakLogger shared] logInfo:@"Still waiting... retrying in 3s (attempt %d)", retryCount];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ tryInstallHooks(); });
        } else {
            [[HKTweakLogger shared] logInfo:@"Gave up after %d retries — class never loaded", retryCount];
        }
        return;
    }

    hooksInstalled = YES;
    [[HKTweakLogger shared] logInfo:@"All target classes loaded — activating hooks on main queue"];

    // Activate hooks on main queue for UIKit thread safety
    dispatch_async(dispatch_get_main_queue(), ^{
        %init;
        [[HKTweakLogger shared] logInfo:@"All hooks activated on main queue"];
    });
}
```

// ============================================================
//  HOOKS  (every hook wraps logging in @try/@catch)
// ============================================================
<HOOKS_PLACEHOLDER>
```

**Every hook must follow this @try/@catch pattern**:

```objc
%hook SomeClass
- (ReturnType)someMethod:(id)arg {
    @try {
        [[HKTweakLogger shared] logHookEnter:@"SomeClass" selector:@"-someMethod:"
                                        args:[NSString stringWithFormat:@"arg=%@", arg]];
    } @catch (NSException *e) {}

    // Hook logic here — always call %orig
    ReturnType result = %orig;

    @try {
        [[HKTweakLogger shared] logHookLeave:@"SomeClass" selector:@"-someMethod:"
                                originalResult:result new:result];
    } @catch (NSException *e) {}

    return result;
}
%end
```

---

---

## Pure ObjC Method Swizzling Alternative (Non-Logos)

When the user's SPEC requires a standalone `.m` file that compiles directly with `clang` (no Theos dependency), use pure ObjC with `#include <objc/runtime.h>` and manual method swizzling. This approach also enables more control over delayed loading and thread safety.

### Pure ObjC Swizzling Pattern

```objc
#include <objc/runtime.h>
#include <dlfcn.h>

// ---- Swizzle a class method (+) ----
static void swizzleClassMethod(Class cls, SEL original, SEL replacement) {
    Method origMethod = class_getClassMethod(cls, original);
    Method replMethod = class_getClassMethod(cls, replacement);
    if (origMethod && replMethod) {
        method_exchangeImplementations(origMethod, replMethod);
    }
}

// ---- Swizzle an instance method (-) ----
static void swizzleInstanceMethod(Class cls, SEL original, SEL replacement) {
    Method origMethod = class_getInstanceMethod(cls, original);
    Method replMethod = class_getInstanceMethod(cls, replacement);
    if (origMethod && replMethod) {
        method_exchangeImplementations(origMethod, replMethod);
    }
}

// ---- Alternative: Use imp_implementationWithBlock for simpler hooks ----
// Best when you don't need to call the original implementation
static void hookClassMethod(Class cls, SEL selector, id block) {
    Method method = class_getClassMethod(cls, selector);
    if (method) {
        IMP newImp = imp_implementationWithBlock(block);
        method_setImplementation(method, newImp);
    }
}
```

### Pure ObjC Hook Example (matching the Logos patterns)

```objc
// ---- Replacement for +[FLYEASDK initWithSelfKey:appSecret:] ----
static void (*orig_FLYEASDK_initWithSelfKey_appSecret)(id self, SEL _cmd, NSString *selfKey, NSString *appSecret);

static void repl_FLYEASDK_initWithSelfKey_appSecret(id self, SEL _cmd, NSString *selfKey, NSString *appSecret) {
    @try {
        [[HKTweakLogger shared] logHookEnter:@"FLYEASDK"
                                    selector:@"+initWithSelfKey:appSecret:"
                                        args:[NSString stringWithFormat:@"selfKey=%@ appSecret=%@", selfKey, appSecret]];

        // Save keys to dedicated JSON file
        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSString *keysPath = [docs stringByAppendingPathComponent:@TWEAK_NAME "_flyverify_keys.json"];
        NSDictionary *keys = @{
            @"selfKey": selfKey ?: @"",
            @"appSecret": appSecret ?: @"",
            @"timestamp": @([[NSDate date] timeIntervalSince1970])
        };
        NSData *json = [NSJSONSerialization dataWithJSONObject:keys
                            options:NSJSONWritingPrettyPrinted error:nil];
        [json writeToFile:keysPath atomically:YES];
        [[HKTweakLogger shared] logEvent:@"KEYS_SAVED" detail:[NSString stringWithFormat:@"path=%@", keysPath]];
    } @catch (NSException *e) {
        [[HKTweakLogger shared] logEvent:@"HOOK_ERROR" detail:[NSString stringWithFormat:@"%@: %@", e.name, e.reason]];
    }

    // ALWAYS call original
    if (orig_FLYEASDK_initWithSelfKey_appSecret) {
        orig_FLYEASDK_initWithSelfKey_appSecret(self, _cmd, selfKey, appSecret);
    }
}

// ---- Installation with delayed loading ----
static void installFLYEASDKHook(void) {
    Class cls = NSClassFromString(@"FLYEASDK");
    if (!cls) return;

    SEL sel = NSSelectorFromString(@"initWithSelfKey:appSecret:");
    Method method = class_getClassMethod(cls, sel);
    if (!method) return;

    IMP origImp = method_getImplementation(method);
    orig_FLYEASDK_initWithSelfKey_appSecret = (void *)origImp;

    IMP newImp = imp_implementationWithBlock(^(id self, NSString *selfKey, NSString *appSecret) {
        repl_FLYEASDK_initWithSelfKey_appSecret(self, sel, selfKey, appSecret);
    });
    method_setImplementation(method, newImp);
}
```

### Pure ObjC vs Logos Decision Guide

Use **pure ObjC** (`.m` file + `clang`) when:
- SPEC explicitly requests it
- Need `__attribute__((constructor))` for absolute earliest injection
- Target app may not have a jailbreak/Substrate environment
- User wants to compile without Theos dependency
- Need fine-grained control over swizzling timing (delayed load + main queue dispatch)

Use **Logos/Theos** (`.xm` file + `make package`) when:
- User wants a `.deb` package
- Hooking is straightforward (classes always loaded at startup)
- Need `%orig` convenience
- Want the Theos build system's packaging and installation

### Pure ObjC Build Command

```bash
clang -arch arm64 \
    -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
    -mios-version-min=13.0 \
    -dynamiclib \
    -fobjc-arc \
    -framework Foundation \
    -framework UIKit \
    -o <TweakName>.dylib \
    <TweakName>.m

# Pseudo-sign for TrollFools
ldid -S <TweakName>.dylib
```

## Hook Discovery — Analyzing the Target

Before writing the hook, the AI must verify the target class and method exist exactly as specified.

### Step 1: Confirm the Class Exists

```bash
grep -rn "@interface <ClassName>" <analysis-dir>/class-dump/
```

If the class is not found in class-dump headers, check strings output:
```bash
grep -rn "<ClassName>" <analysis-dir>/strings-raw.txt
```

### Step 2: Confirm the Method Signature

```bash
grep -A2 "\- \(.*\)<methodName>" <analysis-dir>/class-dump/<ClassName>.h
```

**Critical**: The Logos hook must match the exact return type and parameter types from the class-dump header. A type mismatch causes a compile error or runtime crash.

### Step 3: Check for Properties

```bash
grep -rn "@property.*<propertyName>" <analysis-dir>/class-dump/<ClassName>.h
```

Properties generate `- (Type)propertyName` getter and `- (void)setPropertyName:(Type)arg` setter methods. Hook these method forms.

### Step 4: Identify Instance vs Class Method

- Instance methods: `- (ReturnType)methodName` → hook with `-`
- Class methods: `+ (ReturnType)methodName` → hook with `+`

### Step 5: Check for Network-Related Classes (for capture generation)

If the target or related classes use network APIs, flag them for network capture:

```bash
grep -rn "URLSession\|Alamofire\|AFNetworking\|AFHTTPSessionManager\|Moya\|GraphQL\|WebSocket" <analysis-dir>/class-dump/
```

## Common Return Types and Their Hook Values

| Return Type | Correct Logos Hook Value | JSON config `returnValue` |
|-------------|--------------------------|---------------------------|
| `BOOL` / `_Bool` | `return YES;` or `return NO;` | `true` / `false` |
| `int`, `NSInteger`, `long` | `return 99;` | `99` |
| `float`, `CGFloat`, `double` | `return 999.0f;` or `return 999.0;` | `999.0` |
| `NSString *` | `return @"fixed_string";` | `"fixed_string"` |
| `NSNumber *` | `return @(99);` | `99` |
| `NSArray *` | `return @[...];` | `["a","b"]` |
| `NSDictionary *` | `return @{...};` | `{"key":"value"}` |
| `id` (nullable/any) | Can return any ObjC object or `nil` | `null` |
| `void` | `return;` | not applicable |
| `instancetype` (init) | `return [super init];` or `return nil;` | not applicable |
| Struct types (`CGRect`, etc.) | Use constructors like `CGRectMake(0,0,100,100)` | not supported in JSON |

## Error Prevention Checklist

Before declaring the tweak complete, verify:

1. **Class name exact match** — case-sensitive, must match class-dump output
2. **Method selector exact match** — including all colons (`:`) for parameters
3. **Return type match** — `BOOL` vs `_Bool` vs `bool` (ObjC uses `BOOL` / `_Bool`)
4. **Instance (-) vs Class (+) method** — matches the declaration
5. **ARC compatibility** — `-fobjc-arc` in Makefile or clang flags
6. **Superclass exists** — if hooking a subclass method, parent class must be loadable
7. **Framework linking** — add any needed frameworks to Makefile `_FRAMEWORKS` or clang `-framework` flags
8. **No dangling syntax** — every `%hook` has a matching `%end`, every brace is paired
9. **Crash handler is first in %ctor** — must be before any hook activation
10. **Logger path uses Documents** — never hardcode `/var/mobile/...`; use `NSSearchPathForDirectoriesInDomains`
11. **JSON config has correct returnType** — must match the hook's actual return type
12. **Network capture body sanitized** — `NSData` bodies are decoded to UTF-8 or reported as binary size
13. **Every hook wraps logging in @try/@catch** — logger code itself must never crash the app
14. **Every hook calls original implementation** — never swallow the original call unless explicitly desired
15. **Completion block wrapping never skips the block** — always call the original completion at the end
16. **Delayed loading implemented** — when target class is in an embedded framework, use NSClassFromString polling with retry
17. **Hooks activated on main queue** — use `dispatch_get_main_queue()` for UIKit-related swizzling
18. **ldid signing applied** — dylib must be pseudo-signed with `ldid -S` before TrollFools injection

## Build and Verification Commands

```bash
# Build the tweak
make -C <tweak-dir> package

# Check for build errors
make -C <tweak-dir> clean package 2>&1

# The output .deb is in <tweak-dir>/packages/

# Inspect the built dylib
file <tweak-dir>/.theos/obj/debug/<TweakName>.dylib
otool -L <tweak-dir>/.theos/obj/debug/<TweakName>.dylib

# Pure ObjC compile (no Theos required)
clang -arch arm64 \
    -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
    -mios-version-min=13.0 \
    -dynamiclib \
    -fobjc-arc \
    -framework Foundation \
    -framework UIKit \
    -o <TweakName>.dylib \
    <TweakName>.m

# Pseudo-sign the dylib (REQUIRED for TrollFools)
ldid -S <TweakName>.dylib

# Verify the dylib exports
nm -gU <tweak-dir>/.theos/obj/debug/<TweakName>.dylib
```

## TrollFools Installation

1. Extract the `.dylib` from the `.deb` package:
   ```bash
   ar x <package>.deb
   tar -xf data.tar.xz
   # Find .dylib in Library/MobileSubstrate/DynamicLibraries/
   ```

2. Transfer the `.dylib` to the iOS device (AirDrop, SFTP, etc.)

3. Open TrollFools on the device, select the target app, and inject the `.dylib`

4. Launch the app. The dylib loads and creates log files in the app's Documents directory.

5. To view logs on-device, use Filza to navigate to:
   ```
   /var/mobile/Containers/Data/Application/<App-UUID>/Documents/
   ```
   Look for:
   - `<TweakName>_hook.log` — hook invocation trace
   - `<TweakName>_crash.log` — crash reports (hope this stays empty)
   - `<TweakName>_config.json` — editable hook configuration
   - `<TweakName>_network.jsonl` — captured network traffic (if applicable)

## AI Workflow Summary

1. **Receive user input** — "hook `-[ClassName methodName]` to return `<value>`" or read SPEC.md
2. **Locate the class** — grep class-dump output for class name; check if in main binary or embedded framework
3. **Read the header** — confirm method signature (return type, params, instance vs class)
4. **Determine output format** — Logos/Theos (`.xm`) or pure ObjC (`.m` + `clang`) based on SPEC requirements
5. **Determine the hook syntax** — Logos `%hook` or ObjC `class_getClassMethod` + `method_setImplementation`
6. **Check for delayed loading** — if class is in embedded framework, add `NSClassFromString` polling with retry
7. **Check for network hooks** — if method takes completion blocks, add block wrapping for response capture
8. **Identify the bundle ID** — from Info.plist in analysis output
9. **Generate the enhanced project** — all 6 systems in Tweak.xm/.m, Makefile or build.sh, control+plist (Theos) or just README (ObjC)
10. **Validate** — @try/@catch wrapping, original called, main queue, ldid signing, check all 18 checklist items
11. **Attempt build** — `make package` (Theos) or `clang ... && ldid -S` (ObjC); fix any errors
12. **Generate README** — document hook target, log file locations, config JSON format, build steps, cold-start warning
13. **Deliver** — project directory, .deb or .dylib path, README
