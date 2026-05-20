# Dylib Injection Plugin Generation Guide

Techniques for generating Logos/Theos dylib injection plugins from reverse-engineered iOS app code. Every generated tweak includes four built-in systems: crash logging, file-based hook tracing, JSON hook configuration, and unified network protocol capture.

## Enhanced Dylib Architecture

Every AI-generated tweak ships with these four integrated systems:

| System | Purpose | Output Location |
|--------|---------|-----------------|
| **Crash Logger** | Captures ObjC exceptions + POSIX signals (SIGABRT, SIGSEGV, SIGBUS, SIGTRAP) with full stack traces | `Documents/<TweakName>/crash.log` |
| **Hook Logger** | Records every hook invocation with timestamps, class/method, original vs. modified values | `Documents/<TweakName>/hook.log` |
| **JSON Config** | Clean key-value hook configuration, editable without recompiling | `Documents/<TweakName>/config.json` |
| **Network Capture** | Unified REQUEST/RESPONSE JSON Lines capture for protocol analysis | `Documents/<TweakName>/network.jsonl` |
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

Captures all crashes — both ObjC exceptions and native signals — and writes a detailed crash report to `Documents/<TweakName>/crash.log`. This is the first thing initialized in `%ctor`, before any hooks activate.

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

Every hook invocation records a structured log entry to `Documents/<TweakName>/hook.log`. The logger uses a ring buffer and flushes periodically.

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
    NSLog(@"[%@] %@", TWEAK_NAME, line);

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

The dylib writes a clean JSON config file to `Documents/<TweakName>/config.json` on first launch. The user can edit this JSON to change hook behavior without recompiling. On subsequent launches, the dylib reads the config and applies settings.

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

When hooking network communication methods (URLSession, Alamofire, custom socket protocols, etc.), the dylib captures request and response data in a unified JSON Lines (`.jsonl`) format in `Documents/<TweakName>/network.jsonl`.

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

When the target class lives in an embedded framework — not the main binary — it may not be loaded yet when the dylib's `%ctor` runs. This is common with third-party SDKs (e.g., analytics, security, or ad SDKs). The solution is a retry mechanism that polls `NSClassFromString` at intervals before attempting the hook.

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
    Class targetCls1 = NSClassFromString(@"<TargetClass1>");
    Class targetCls2 = NSClassFromString(@"<TargetClass2>");

    if (!targetCls1 || !targetCls2) {
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
    NSString *dir = [docs stringByAppendingPathComponent:@TWEAK_NAME];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    setupCrashHandler([dir stringByAppendingPathComponent:@"crash.log"]);

    // 2. Logger
    [[HKTweakLogger shared] setupWithPath:[dir stringByAppendingPathComponent:@"hook.log"]];
    [[HKTweakLogger shared] logInfo:@"Dylib loaded (PID: %d)", getpid()];

    // 3. Config
    NSString *cfgPath = [dir stringByAppendingPathComponent:@"config.json"];
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

%hook <TargetClass>
+ (void)<initMethod>:(NSString *)key1 appSecret:(NSString *)key2 {
    @try {
        [[HKTweakLogger shared] logHookEnter:@"<TargetClass>" selector:@"+<initMethod>:appSecret:"
                                        args:[NSString stringWithFormat:@"key1=%@ key2=%@", key1, key2]];
    } @catch (NSException *e) {}

    %orig;

    @try {
        [[HKTweakLogger shared] logHookVoid:@"<TargetClass>" selector:@"+<initMethod>:appSecret:" skipped:NO];
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
%hook <ServiceClass>
+ (void)<initConfigMethod>:(NSString *)appKey
                     secret:(NSString *)secret
                       duid:(NSString *)duid
                completion:(void (^)(NSDictionary *response, NSError *error))completion {

    [[HKTweakLogger shared] logHookEnter:@"<ServiceClass>"
                                selector:@"+<initConfigMethod>:secret:duid:completion:"
                                    args:[NSString stringWithFormat:@"appKey=%@ duid=%@", appKey, duid]];

    // Capture the request parameters immediately
    [[HKTweakNetworkCapture shared] captureRequest:@"<TARGET_API_URL>"
                                            method:@"POST"
                                           headers:nil
                                              body:@{@"appKey": appKey ?: @"", @"duid": duid ?: @""}
                                            caller:@"<ServiceClass>.<initConfigMethod>"];

    // Wrap the completion block to intercept the response
    void (^wrappedCompletion)(NSDictionary *, NSError *) = ^(NSDictionary *response, NSError *error) {
        @try {
            if (response) {
                [[HKTweakLogger shared] logEvent:@"<EVENT_NAME>_RESPONSE"
                                          detail:[NSString stringWithFormat:@"keys: %@",
                                                  [response allKeys]]];

                // Save full response to a dedicated JSON file (in subfolder)
                NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                      NSUserDomainMask, YES) firstObject];
                NSString *dir = [docs stringByAppendingPathComponent:@TWEAK_NAME];
                [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                          withIntermediateDirectories:YES attributes:nil error:nil];
                NSString *respPath = [dir stringByAppendingPathComponent:@"captured_response.json"];
                NSData *json = [NSJSONSerialization dataWithJSONObject:response
                                    options:NSJSONWritingPrettyPrinted error:nil];
                [json writeToFile:respPath atomically:YES];

                // Capture response in network log
                [[HKTweakNetworkCapture shared] captureResponse:@"<TARGET_API_URL>"
                                                     statusCode:200
                                                        headers:nil
                                                           body:response
                                                         caller:@"<ServiceClass>.<initConfigMethod>"];
            }
            if (error) {
                [[HKTweakLogger shared] logEvent:@"<EVENT_NAME>_ERROR"
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

## System 7: NSURLSession Transport-Layer Interception (Optional)

When the user wants to capture ALL HTTP traffic regardless of which upper-level SDK class makes the request, hook `-[NSURLSession dataTaskWithRequest:completionHandler:]`. This is the lowest-level HTTP API in iOS — every networking library (URLSession, Alamofire, AFNetworking, Moya) passes through it. One hook catches everything.

**When to include**: User requests "capture all HTTP traffic", "transport layer", "NSURLSession hook", or the SPEC mentions it. This is OPTIONAL — only add it when asked.

**Principle**: Filter by URL pattern (e.g., `containsString:@"api.example.com"`) so you only capture the target API, not every request the app makes (analytics, images, etc.).

### NSURLSession Transport Hook Template (Pure ObjC)

```objc
// ---- P4: -[NSURLSession dataTaskWithRequest:completionHandler:] (transport layer) ----
static NSURLSessionDataTask * (*orig_NSURLSession_dataTaskWithRequest_completionHandler)(
    id self, SEL _cmd, NSURLRequest *request, void (^completionHandler)(NSData *, NSURLResponse *, NSError *));

static NSURLSessionDataTask *repl_NSURLSession_dataTaskWithRequest_completionHandler(
    id self, SEL _cmd, NSURLRequest *request, void (^completionHandler)(NSData *, NSURLResponse *, NSError *)) {

    NSString *url = request.URL.absoluteString;

    // Only intercept target URLs — filter to avoid capturing analytics/images/etc.
    BOOL isTargetURL = [url containsString:@"<TARGET_DOMAIN>"];  // e.g., @"api-auth.zztfly.com"

    if (isTargetURL) {
        @try {
            [[HKTweakLogger shared] logEvent:@"NSURLSession_REQUEST"
                                      detail:[NSString stringWithFormat:@"%@ %@", request.HTTPMethod, url]];

            // Log request headers
            NSDictionary *reqHeaders = [request allHTTPHeaderFields];
            if (reqHeaders.count > 0) {
                [[HKTweakLogger shared] logEvent:@"REQUEST_HEADERS"
                                          detail:[NSString stringWithFormat:@"%@", reqHeaders]];
            }

            // Log request body
            if (request.HTTPBody) {
                NSString *body = [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding];
                if (body) [[HKTweakLogger shared] logEvent:@"REQUEST_BODY" detail:body];
            }
        } @catch (NSException *e) {}
    }

    // Wrap completion handler to capture RESPONSE
    void (^wrappedCompletion)(NSData *, NSURLResponse *, NSError *) =
        ^(NSData *data, NSURLResponse *response, NSError *error) {
            @try {
                if (isTargetURL && data && !error) {
                    NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
                    NSInteger statusCode = httpResp.statusCode;

                    [[HKTweakLogger shared] logEvent:@"NSURLSession_RESPONSE"
                                              detail:[NSString stringWithFormat:@"status=%ld url=%@",
                                                      (long)statusCode, url]];

                    // Parse and save JSON response
                    NSError *jsonErr = nil;
                    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
                    if (json) {
                        // Save to subfolder
                        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                  NSUserDomainMask, YES) firstObject];
                        NSString *dir = [docs stringByAppendingPathComponent:@TWEAK_NAME];
                        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                                  withIntermediateDirectories:YES attributes:nil error:nil];

                        NSMutableDictionary *saved = [NSMutableDictionary dictionaryWithDictionary:json];
                        saved[@"_captured_at"] = @([[NSDate date] timeIntervalSince1970]);
                        saved[@"_url"] = url;
                        saved[@"_method"] = @"NSURLSession transport";

                        NSData *outJson = [NSJSONSerialization dataWithJSONObject:saved
                                            options:NSJSONWritingPrettyPrinted error:nil];
                        [outJson writeToFile:[dir stringByAppendingPathComponent:@"transport_response.json"]
                                  atomically:YES];

                        [[HKTweakLogger shared] logEvent:@"TRANSPORT_CAPTURED"
                                                  detail:[NSString stringWithFormat:@"transport layer, url=%@", url]];
                    } else {
                        // Non-JSON response — log as text (truncated)
                        NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                        if (body.length > 500) body = [[body substringToIndex:500] stringByAppendingString:@"..."];
                        [[HKTweakLogger shared] logEvent:@"RESPONSE_BODY" detail:body ?: @"(binary)"];
                    }
                }
                if (error) {
                    [[HKTweakLogger shared] logEvent:@"NSURLSession_ERROR"
                                              detail:[NSString stringWithFormat:@"code=%ld domain=%@ url=%@",
                                                      (long)error.code, error.domain, url]];
                }
            } @catch (NSException *e) {
                [[HKTweakLogger shared] logEvent:@"NSURLSession_CAPTURE_ERROR"
                                          detail:[NSString stringWithFormat:@"%@", e.reason]];
            }

            // ALWAYS call original completion
            if (completionHandler) completionHandler(data, response, error);
        };

    // Call original with wrapped completion
    if (orig_NSURLSession_dataTaskWithRequest_completionHandler) {
        return orig_NSURLSession_dataTaskWithRequest_completionHandler(
            self, _cmd, request, wrappedCompletion);
    }
    return nil;
}

// Installation (called from installAllHooks):
// Class nsurlSession = NSClassFromString(@"NSURLSession");
// if (nsurlSession) {
//     swizzleInstanceMethod(nsurlSession,
//         NSSelectorFromString(@"dataTaskWithRequest:completionHandler:"),
//         (IMP)repl_NSURLSession_dataTaskWithRequest_completionHandler,
//         (void **)&orig_NSURLSession_dataTaskWithRequest_completionHandler);
// }
```

**Integration checklist** (AI fills these in):
1. Replace `<TARGET_DOMAIN>` with the actual API domain (e.g., `api-auth.zztfly.com`)
2. Add `orig_NSURLSession_...` to the orig function pointers section
3. Add `repl_NSURLSession_...` to the replacement implementations section
4. Add the swizzle call in `installAllHooks()`
5. Add `hook_nsurlsession_transport` entry to the JSON config defaults

---

## Mandatory Safety Rules

These rules are derived from real deployment failures. Every generated dylib MUST follow all 7 rules. Missing any one of them will cause a crash, silent failure, or captured ciphertext instead of plaintext.

### Rule 1: Block Copy for id-Typed Completion Parameters (CRITICAL)

When a method signature declares `completion:(id)completion` (NOT `(void (^)(...))completion`), ARC only **retains** the block — it does NOT copy it to the heap. Stack-allocated blocks become invalid after the function returns, causing **SIGSEGV** when the wrapper tries to call them.

**Root cause example**: A service class method takes `completion:(id)completion`. The wrapper captured this without `[completion copy]`. ARC retained the stack block, which was freed when the replacement method returned. Calling it later in the wrapper → SIGSEGV.

**Fix**: Always `[completion copy]` when the parameter type is `id`.

```objc
// === WRONG — stack block freed after return, wrapper calls garbage ===
id completion = /* from method parameter */;
void (^wrapped)(NSDictionary *, NSError *) = ^(NSDictionary *resp, NSError *err) {
    // ... capture response ...
    ((void (^)(NSDictionary *, NSError *))completion)(resp, err); // CRASH: stack block gone
};

// === CORRECT — copy to heap before wrapping ===
id stackBlock = /* from method parameter */;
id heapBlock = [stackBlock copy]; // moves to heap, safe to capture

void (^wrapped)(NSDictionary *, NSError *) = ^(NSDictionary *resp, NSError *err) {
    // ... capture response ...
    ((void (^)(NSDictionary *, NSError *))heapBlock)(resp, err); // SAFE
};
```

**Detection regex**: When reading a class-dump header, if you see `completion:(id)completion` or any block param typed as `id`, apply Rule 1.

**Verification grep** (add to Step 5):
```bash
# Every (id) block param in hooked methods must have a corresponding [xxx copy]
grep -n '(id).*completion\|(id).*block\|(id).*handler' <output>.m
```

---

### Rule 2: Method Enumeration Before Hooking (MANDATORY)

Public API names in class-dump headers are NOT necessarily the methods called at runtime. A documented public API class method may be **never called** at runtime. The actual working method could be a private method on an internal context/manager singleton, with no public header.

**Root cause**: SDKs commonly expose a public facade class but route internally through context/manager singletons. The public method may be a stub, deprecated, or only called in specific code paths.

**MANDATORY**: Before writing ANY hook code, enumerate the target class's methods using `class_copyMethodList`. Log ALL methods found. Then select the hook target based on actual runtime method names, not the public header.

```objc
// === MANDATORY: Method enumeration before hooking ===
static void enumerateClassMethods(Class cls, NSString *tag) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    [[HKTweakLogger shared] logInfo:@"=== %@: %u instance methods ===", tag, count];
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        [[HKTweakLogger shared] logInfo:@"  [%@] -%@", tag, NSStringFromSelector(sel)];
    }
    free(methods);

    // Also enumerate CLASS methods (+)
    Class meta = object_getClass(cls);
    Method *classMethods = class_copyMethodList(meta, &count);
    [[HKTweakLogger shared] logInfo:@"=== %@: %u class methods ===", tag, count];
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(classMethods[i]);
        [[HKTweakLogger shared] logInfo:@"  [%@] +%@", tag, NSStringFromSelector(sel)];
    }
    free(classMethods);
}

// Call in installAllHooks() BEFORE any swizzling:
// enumerateClassMethods(NSClassFromString(@"<TargetClass1>"), @"<TargetClass1>");
// enumerateClassMethods(NSClassFromString(@"<TargetClass2>"), @"<TargetClass2>");
```

**How to use the enumeration output**:
1. Look at the logged method list
2. Find methods whose argument COUNT and TYPES match what you expect (e.g., 3 NSStrings + a completion block)
3. Hook THAT method, not the one you guessed from the header
4. If the public API method IS in the list but was never called, it's a dead facade — ignore it

**This is a HARD BLOCKER**: generate-dylib.md Step 5 must verify `class_copyMethodList` appears in the generated code for every target class.

---

### Rule 3: Response Decryption Hook (Anti-Ciphertext)

NSURLSession transport-layer hooks capture HTTP response bodies **as transmitted over the wire**. If the API encrypts responses (common for security SDKs), you get ciphertext like `{"res":"eyJhY2Nlc3NLZXk...base64..."}` — useless without decryption.

**Root cause example**: The API response body is encrypted. NSURLSession captures `{"res":"base64 blob"}`. The plaintext values (`accessKey`, `channel`, etc.) are only available AFTER the SDK's internal decrypt-storage method decrypts and stores them.

**Strategy**: Three-layer capture:
1. **Transport layer** (NSURLSession) — captures raw bytes, timestamp, URL
2. **Decrypt/storage layer** — hook the SDK's internal method that stores the DECRYPTED result
3. **Config layer** — hook `<ConfigClass>` setters for final plaintext values

```objc
// === Layer 2: Hook the internal decrypt-storage method ===
// After enumerating instance methods (Rule 2), find methods matching:
//   set*Cache*, set*Response*, set*Config*, set*Info*, store*, update*
// These receive the DECRYPTED result.

// Example: <ContextClass> has -set<DecryptStoreMethod>:(NSDictionary *)dict
// This method receives plaintext {"key1":"...", "key2":"...", ...}

static void (*orig_<ContextClass>_<decryptStoreMethod>)(id self, SEL _cmd, NSDictionary *info);

static void repl_<ContextClass>_<decryptStoreMethod>(id self, SEL _cmd, NSDictionary *info) {
    @try {
        if (info) {
            [[HKTweakLogger shared] logEvent:@"DECRYPTED_RESPONSE"
                                      detail:[NSString stringWithFormat:@"keys: %@", [info allKeys]]];

            // Save the plaintext response
            NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                          NSUserDomainMask, YES) firstObject];
            NSString *dir = [docs stringByAppendingPathComponent:@TWEAK_NAME];
            [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                      withIntermediateDirectories:YES attributes:nil error:nil];

            NSMutableDictionary *saved = [NSMutableDictionary dictionaryWithDictionary:info];
            saved[@"_captured_at"] = @([[NSDate date] timeIntervalSince1970]);
            saved[@"_method"] = @"<decryptStoreMethod> (decrypted)";

            NSData *json = [NSJSONSerialization dataWithJSONObject:saved
                                options:NSJSONWritingPrettyPrinted error:nil];
            [json writeToFile:[dir stringByAppendingPathComponent:@"decrypted_response.json"]
                  atomically:YES];
        }
    } @catch (NSException *e) {
        [[HKTweakLogger shared] logEvent:@"DECRYPT_HOOK_ERROR"
                                  detail:[NSString stringWithFormat:@"%@", e.reason]];
    }

    if (orig_<ContextClass>_<decryptStoreMethod>) {
        orig_<ContextClass>_<decryptStoreMethod>(self, _cmd, info);
    }
}
```

**When to add Layer 2**: ALWAYS when NSURLSession transport is enabled. If the response happens to be plaintext, the decrypt hook is harmless (won't trigger). If encrypted, it's essential.

---

### Rule 4: Three-Layer Value Capture (setter + KVC + ivar enumeration)

SDKs may bypass ObjC property setters entirely by writing directly to ivars via `object_setIvar()` or C++ assignment. If all setter hooks are **silent** and KVC polling returns **all null**, the SDK likely writes configuration through a C++ model object that assigns directly to ivars, bypassing ObjC property accessors.

**Three-layer strategy**:

```objc
// === Layer 1: Hook ObjC property setters (may be bypassed) ===
// hook -[<ConfigClass> setAccessKey:], -setChannel:, etc.
// If these fire, you're done. If silent, proceed to Layer 2.

// === Layer 2: KVC polling with delays (may be null if C++ ivars) ===
// dispatch_after at 2s/5s/10s/20s/40s
// [[<ConfigClass> instance] valueForKey:@"accessKey"]
// If values appear, save them. If all null, proceed to Layer 3.

// === Layer 3: Direct ivar enumeration (catches C++-injected values) ===
// CRITICAL: This is a RUNTIME FALLBACK only. Do NOT add at generation time
// based solely on static C++ ivar detection. Only enable after Layer 1 (setter
// hooks) AND Layer 2 (KVC) both return nothing for 20+ seconds.
// CRITICAL: The instance passed to this function MUST be type-verified with
// isKindOfClass: BEFORE calling. Passing an NSDictionary or other class-cluster
// object to ivar enumeration can cause SIGSEGV.
static void pollConfigIvars(id instance) {
    if (!instance) return;

    // CRITICAL: Verify instance type before ivar enumeration
    Class expectedCls = NSClassFromString(@"<TargetClass>");
    if (![instance isKindOfClass:expectedCls]) {
        [[HKTweakLogger shared] logInfo:@"[WARN] KVC returned %@, expected %@ — skipping ivar enumeration",
         NSStringFromClass([instance class]), NSStringFromClass(expectedCls)];
        return;
    }

    Class cls = object_getClass(instance);
    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList(cls, &ivarCount);

    [[HKTweakLogger shared] logInfo:@"<ConfigClass> has %u ivars", ivarCount];

    NSMutableDictionary *ivarValues = [NSMutableDictionary dictionary];
    for (unsigned int i = 0; i < ivarCount; i++) {
        Ivar ivar = ivars[i];
        const char *name = ivar_getName(ivar);
        const char *type = ivar_getTypeEncoding(ivar);

        NSString *nameStr = [NSString stringWithUTF8String:name];
        NSString *typeStr = [NSString stringWithUTF8String:type];

        id value = nil;
        // CRITICAL: Only read ObjC object ivars (type encoding starts with @).
        // NEVER use @try/@catch as a substitute for this check — @try/@catch
        // cannot catch SIGSEGV from reading non-object ivars (C++ structs, std::string, primitives).
        if (type[0] == '@') {
            value = object_getIvar(instance, ivar);
        }

        if (value) {
            ivarValues[nameStr] = [NSString stringWithFormat:@"%@", value];
        }
        [[HKTweakLogger shared] logInfo:@"  ivar %s | type=%s | value=%@",
                                          name, type, value ?: @"(nil/non-ObjC)"];
    }
    free(ivars);

    if (ivarValues.count > 0) {
        // Save ivar values
        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                      NSUserDomainMask, YES) firstObject];
        NSString *dir = [docs stringByAppendingPathComponent:@TWEAK_NAME];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES attributes:nil error:nil];

        ivarValues[@"_captured_at"] = @([[NSDate date] timeIntervalSince1970]);
        ivarValues[@"_method"] = @"ivar enumeration (Layer 3)";

        NSData *json = [NSJSONSerialization dataWithJSONObject:ivarValues
                            options:NSJSONWritingPrettyPrinted error:nil];
        [json writeToFile:[dir stringByAppendingPathComponent:@"ivar_values.json"]
              atomically:YES];
    }
}

// ================================================================
// Layer 3 Instance Acquisition — Three Safe Patterns
// ================================================================
// DO NOT guess instance locations via unrelated KVC properties.
// Use one of these concrete patterns:

// Pattern A (RECOMMENDED): Capture instance from setter hook
// In the -[<TargetClass> setXxx:] repl_ function, save self to a static weak ref.
// ```
// static __weak id _captured<ConfigClass>Instance = nil;
// static void repl_<TargetClass>_setXxx(id self, SEL _cmd, id val) {
//     _captured<ConfigClass>Instance = self;  // safe: only stores valid instances
//     if (orig_<TargetClass>_setXxx) orig_<TargetClass>_setXxx(self, _cmd, val);
// }
// ```
// Then in KVC polling, use _captured<ConfigClass>Instance (check non-nil before use).

// Pattern B: Use a KNOWN singleton accessor
// Only if the class header explicitly declares a singleton method:
// + (id)defaultContext;  or  + (instancetype)shared;
// ```
// id instance = [<TargetClass> performSelector:@selector(defaultContext)];
// if (instance && [instance isKindOfClass:[<TargetClass> class]]) {
//     pollConfigIvars(instance);
// }
// ```

// Pattern C: Capture from your OWN init/config hook (most reliable)
// If you already hook a method that receives or creates the config instance:
// ```
// static void repl_<SDKClass>_initWithConfig:(id)config {
//     if (config && [config isKindOfClass:[<TargetClass> class]]) {
//         pollConfigIvars(config);
//     }
//     // ... call orig ...
// }
// ```

// WARNING: Never pass objects from unrelated KVC reads to pollConfigIvars.
// Example of WRONG usage:
//   id configInfo = [someOtherContext valueForKey:@"configureInfo"]; // NSDictionary!
//   pollConfigIvars(configInfo); // CRASH — NSDictionary is not <TargetClass>
```

**Note on C++ ivars**: If `type[0]` is NOT `@` (e.g., `{std::string=...}`), the ivar is a C++ object and `object_getIvar` won't work. For C++ ivars like `std::string`, you can try `valueForKey:` which may bridge through the `@property` accessor even if the setter wasn't called.

**When to enable Layer 3**: ONLY when Layer 1 (setter hooks) AND Layer 2 (KVC on captured instances) both return nothing after 20+ seconds. Do NOT enable Layer 3 at code-generation time based solely on static C++ ivar detection in class-dump headers. The C++ ivar presence is a SIGNAL that Layer 3 MAY be needed at runtime — not a trigger to add it during generation.

---

### Rule 5: Thread-Safe Completion Handlers

NSURLSession completion handlers execute on **CFNetwork internal threads** — NOT the main thread and NOT a dispatch queue you control. Performing JSON parsing, file I/O, or heavy string formatting on this thread can cause **SIGSEGV** due to thread-safety violations in Foundation/CoreFoundation.

**Root cause example**: The NSURLSession `wrappedCompletion` block called `NSJSONSerialization JSONObjectWithData:` and `writeToFile:atomically:` directly — both triggered intermittent SIGSEGV when the CFNetwork thread state was unexpected.

**Fix**: Block does ONLY lightweight logging. Dispatch heavy work to a background queue.

```objc
// === WRONG — heavy work on CFNetwork thread ===
void (^wrappedCompletion)(NSData *, NSURLResponse *, NSError *) =
    ^(NSData *data, NSURLResponse *response, NSError *error) {
        // ON CFNetwork THREAD — DANGEROUS
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data ...]; // may SIGSEGV
        [jsonData writeToFile:path atomically:YES]; // may SIGSEGV
        NSString *body = [[NSString alloc] initWithData:data ...]; // large alloc
        // ...
        if (completionHandler) completionHandler(data, response, error);
    };

// === CORRECT — dispatch heavy work off CFNetwork thread ===
static dispatch_queue_t _backgroundQueue = nil; // created in %ctor

void (^wrappedCompletion)(NSData *, NSURLResponse *, NSError *) =
    ^(NSData *data, NSURLResponse *response, NSError *error) {
        @try {
            NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
            NSString *urlStr = response.URL.absoluteString;

            // Only lightweight logging on this thread
            [[HKTweakLogger shared] logEvent:@"NSURLSession_RESPONSE"
                                      detail:[NSString stringWithFormat:@"status=%ld url=%@",
                                                      (long)statusCode, urlStr]];
        } @catch (NSException *e) {}

        // Retain data so it survives the dispatch
        NSData *dataCopy = [data copy];

        // Heavy work goes to background queue
        dispatch_async(_backgroundQueue, ^{
            @try {
                if (dataCopy) {
                    NSError *jsonErr = nil;
                    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:dataCopy
                                                options:0 error:&jsonErr];
                    if (json) {
                        // File I/O on background queue — safe
                        NSString *docs = [NSSearchPathForDirectoriesInDomains(
                                                  NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
                        NSString *dir = [docs stringByAppendingPathComponent:@TWEAK_NAME];
                        NSString *respPath = [dir stringByAppendingPathComponent:@"transport_response.json"];
                        NSData *outJson = [NSJSONSerialization dataWithJSONObject:json
                                            options:NSJSONWritingPrettyPrinted error:nil];
                        [outJson writeToFile:respPath atomically:YES];
                    }
                }
            } @catch (NSException *e) {}
        });

        // ALWAYS call original completion on its original thread
        if (completionHandler) completionHandler(data, response, error);
    };
```

**Setup in %ctor**:
```objc
_backgroundQueue = dispatch_queue_create("com.hktweak.background", DISPATCH_QUEUE_SERIAL);
```

---

### Rule 6: Constructor Timing — dispatch_after with Backoff

The dylib's `__attribute__((constructor))` (or `%ctor`) runs during dyld's image loading phase. At this point, embedded frameworks from the host app may NOT have been loaded yet. `NSClassFromString(@"SomeSDKClass")` returns `nil` even though the class will exist 500ms later.

This is already documented in **System 5: Delayed Class Loading** above. Key points reinforced:

1. **Never assume classes exist at %ctor time** — always check with `NSClassFromString`
2. **Use `dispatch_after` with increasing delays** — 0.5s first retry, then 3.0s for retries 2-10
3. **Cap retries at 10** — after ~30 seconds, give up and log
4. **Only swizzle AFTER confirmation** — `hooksInstalled` flag prevents double-install

This rule already exists in the codebase. The enforcement is strengthened: **generate-dylib.md Step 5 must verify `dispatch_after` + `NSClassFromString` retry loop exists when ANY target class is from an embedded framework**.

---

### Rule 7: Singleton Enumeration (+defaultContext / +shared / +defaultInstance)

85%+ of iOS SDKs expose their internal state through a singleton pattern. The singleton holds the live configuration object, which may be populated through paths that bypass setters entirely (C++ assignment, internal ivar writes, deserialization from network).

**Root cause example**: `<ConfigClass>` has a `+[<ConfigClass> defaultContext]` class method that returns the shared instance. The singleton's ivars may be populated by C++ code — setters never called, KVC returns nil initially. Only ivar enumeration (Rule 4) on the singleton instance captures the values.

**Strategy**: After enumerating class methods (Rule 2), scan for singleton accessors:

```objc
// === Scan class methods for singleton patterns ===
static id discoverSingleton(Class cls) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(object_getClass(cls), &count); // class methods

    NSArray *singletonPatterns = @[
        @"defaultContext", @"shared", @"sharedInstance",
        @"defaultInstance", @"defaultManager", @"sharedManager",
        @"current", @"main", @"standard"
    ];

    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        NSString *selName = NSStringFromSelector(sel);

        for (NSString *pattern in singletonPatterns) {
            if ([selName rangeOfString:pattern options:NSCaseInsensitiveSearch].location != NSNotFound) {
                // Check if it returns id (object type)
                char returnType[256];
                method_getReturnType(methods[i], returnType, sizeof(returnType));
                if (returnType[0] == '@') {
                    // Suppress "may leak" warning — the singleton doesn't need release
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    id instance = [cls performSelector:sel];
#pragma clang diagnostic pop
                    if (instance) {
                        [[HKTweakLogger shared] logInfo:@"Found singleton: +[%@ %@] → %@",
                                                      NSStringFromClass(cls), selName, instance];
                        free(methods);
                        return instance;
                    }
                }
            }
        }
    }
    free(methods);
    return nil;
}

// Usage:
// id config = discoverSingleton(NSClassFromString(@"<ConfigClass>"));
// if (config) {
//     pollConfigIvars(config);                     // Rule 4: ivar enumeration
//     // or: [config valueForKey:@"accessKey"];     // Rule 4: KVC polling
// }
```

**When to use**: ALWAYS when the target class has no public init hook that fires. The singleton + ivar enumeration is often the ONLY way to capture values.

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
//    - <TweakName>/hook.log     Hook invocation trace
//    - <TweakName>/crash.log    Crash/exception reports
//    - <TweakName>/config.json  Editable hook configuration
//    - <TweakName>/network.jsonl Network I/O capture
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
    NSLog(@"[%@] %@", TWEAK_NAME, line);

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

    // 2. Create subfolder for all output files (avoids cluttering Documents root)
    NSString *dir = [docs stringByAppendingPathComponent:@TWEAK_NAME];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];

    // 3. SETUP CRASH HANDLER FIRST — before anything else
    setupCrashHandler([dir stringByAppendingPathComponent:@"crash.log"]);

    // 4. Setup hook logger
    [[HKTweakLogger shared] setupWithPath:[dir stringByAppendingPathComponent:@"hook.log"]];

    // 5. Load config (writes defaults on first launch)
    NSString *configPath = [dir stringByAppendingPathComponent:@"config.json"];
    NSDictionary *defaultConfig = <JSON_CONFIG_PLACEHOLDER>;
    [[HKTweakConfig shared] loadFromPath:configPath defaults:defaultConfig];

    // 6. Setup network capture (only if this tweak hooks network methods)
    // [[HKTweakNetworkCapture shared] setupWithPath:[dir stringByAppendingPathComponent:@"network.jsonl"]];

    [[HKTweakLogger shared] logInfo:@"All systems initialized — output dir: %@", dir];

    // 7. Check if target classes are available. If in embedded frameworks, retry.
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
// ---- Replacement for +[<TargetClass> <initMethod>:<secretParam>:] ----
static void (*orig_<TargetClass>_<initMethod>)(id self, SEL _cmd, NSString *key1, NSString *key2);

static void repl_<TargetClass>_<initMethod>(id self, SEL _cmd, NSString *key1, NSString *key2) {
    @try {
        [[HKTweakLogger shared] logHookEnter:@"<TargetClass>"
                                    selector:@"+<initMethod>:<secretParam>:"
                                        args:[NSString stringWithFormat:@"key1=%@ key2=%@", key1, key2]];

        // Save keys to dedicated JSON file (in subfolder)
        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSString *dir = [docs stringByAppendingPathComponent:@TWEAK_NAME];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *keysPath = [dir stringByAppendingPathComponent:@"captured_keys.json"];
        NSDictionary *keys = @{
            @"key1": key1 ?: @"",
            @"key2": key2 ?: @"",
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
    if (orig_<TargetClass>_<initMethod>) {
        orig_<TargetClass>_<initMethod>(self, _cmd, key1, key2);
    }
}

// ---- Installation with delayed loading ----
static void install<TargetClass>Hook(void) {
    Class cls = NSClassFromString(@"<TargetClass>");
    if (!cls) return;

    SEL sel = NSSelectorFromString(@"<initMethod>:<secretParam>:");
    Method method = class_getClassMethod(cls, sel);
    if (!method) return;

    IMP origImp = method_getImplementation(method);
    orig_<TargetClass>_<initMethod> = (void *)origImp;

    IMP newImp = imp_implementationWithBlock(^(id self, NSString *key1, NSString *key2) {
        repl_<TargetClass>_<initMethod>(self, sel, key1, key2);
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
   Look for the `<TweakName>/` subfolder:
   - `hook.log` — hook invocation trace
   - `crash.log` — crash reports (hope this stays empty)
   - `config.json` — editable hook configuration
   - `network.jsonl` — captured network traffic (if applicable)

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
