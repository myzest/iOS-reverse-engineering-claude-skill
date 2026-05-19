---
allowed-tools: Bash, Read, Glob, Grep, Write, Edit
description: Generate a Logos/Theos or pure ObjC dylib injection plugin with crash logging, hook trace, JSON config, network capture, delayed class loading, and completion block wrapping
user-invocable: true
argument-hint: <hook description>
argument: description of what class/method to hook and the desired behavior
---

# /generate-dylib

Analyze reversed iOS app code and generate a working dylib injection plugin. Supports both Logos/Theos (`.xm` + `make package`) and pure ObjC (`.m` + `clang`) output. Every generated tweak includes six built-in systems: crash/exception logging, file-based hook trace, editable JSON configuration, unified network protocol capture, delayed class loading with retry, and completion block wrapping for network response interception. Write clean, compilable hook code, validate syntax, build the package, and produce accompanying documentation.

## Instructions

You are the AI-driven dylib injection plugin generator. Follow these steps:

### Step 1: Understand the User's Hook Request

Parse the user's input to identify:

- **Target class** — the Objective-C class to hook
- **Target method** — the exact selector to hook (instance `-` or class `+`)
- **Desired behavior** — what the hook should return or do instead
- **Target app** — which app to inject into (the user may mention an IPA they previously analyzed)
- **Network capture needed** — is the hook target a network/communication method? (URLSession, Alamofire, AFNetworking, Moya, custom socket, etc.)

If the user's description is ambiguous, ask clarifying questions to pin down:
- Exact class name (case-sensitive)
- Exact method signature
- What value the hook should return (and what type it is)
- Whether they also need network I/O capture

### Step 2: Verify the Target Exists in the Reversed Code

If the user previously ran `/extract-ipa`, identify the analysis output directory. If not, ask for the path.

**Confirm the class**:
```bash
grep -rn "@interface <ClassName>" <analysis-dir>/class-dump/
```

If not found, search strings:
```bash
grep -rn "<ClassName>" <analysis-dir>/strings-raw.txt
```

**Confirm the method signature** — read the header file to get:
- Exact return type (BOOL, int, id, void, NSString *, etc.)
- Parameter count and types
- Whether it's an instance (`-`) or class (`+`) method

**Get the bundle ID**:
```bash
grep -A1 CFBundleIdentifier <analysis-dir>/Info.plist | grep -o '<string>.*</string>' | sed 's/<[^>]*>//g'
```

**Check if target class is in an embedded framework** (not the main binary):
```bash
# If the class header file is NOT in the main binary's class-dump but listed under a framework subdirectory:
find <analysis-dir>/class-dump/ -name "<ClassName>.h"
# If found under <analysis-dir>/class-dump/Frameworks/<FrameworkName>/ — it's in an embedded framework
# → USE DELAYED LOADING with NSClassFromString polling
```

**Check for network-related classes** (if user wants network capture):
```bash
grep -rn "URLSession\|Alamofire\|AFNetworking\|AFHTTPSessionManager\|Moya\|GraphQL\|WebSocket" <analysis-dir>/class-dump/
```

If the class or method cannot be found in the analysis output, tell the user and suggest:
- Re-running `/extract-ipa` with full class-dump
- Checking if the class name might be obfuscated (short random names)
- Looking for the method in a parent class

### Step 3: Design the Hook

Based on the verified method signature, determine the correct Logos hook pattern:

| Return Type | Pattern |
|-------------|---------|
| `BOOL` / `_Bool` | `return YES;` or `return NO;` |
| `int` / `NSInteger` / `long` / `long long` | `return <integer>;` |
| `float` / `CGFloat` / `double` | `return <number>f;` or `return <number>;` |
| `NSString *` | `return @"<string>";` |
| `NSNumber *` | `return @(<number>);` |
| `NSArray *` | `return @[...];` |
| `NSDictionary *` | `return @{...};` |
| `void` | `return;` (skip original call entirely) |
| `id` | Return any ObjC object or `nil` |

For void methods where you want the original to still run but with modified behavior, use `%orig;` before or after your custom code.

For methods with arguments, include them in the hook signature exactly as declared in the class-dump header.

**If the user wants to modify args before calling original**:
```objc
%orig(modifiedArg);
```

**If the user wants to modify the return value after calling original**:
```objc
ReturnType orig = %orig;
// modify orig
return modifiedValue;
```

### Step 4: Generate the Enhanced Theos Project

Create a directory `tweaks/<TweakName>/` with these files:

#### Files Overview

Choose the output format based on the user's needs:

**Logos/Theos format** (default — user wants .deb packaging):
```
tweaks/<TweakName>/
├── Makefile              # Build configuration
├── Tweak.xm              # Logos source (hooks + 6 built-in systems, uses %group for delayed loading)
├── control               # .deb package metadata
├── <BundleID>.plist      # Injection target filter
└── README.md             # Documentation with log locations and config guide
```

**Pure ObjC format** (user wants clang direct compile, no Theos dependency):
```
tweaks/<TweakName>/
├── <TweakName>.m         # Pure ObjC source (hooks + 6 built-in systems, manual swizzling)
├── build.sh              # One-click clang compile + ldid sign
└── README.md             # Documentation with log locations and config guide
```

Use pure ObjC when:
- The SPEC explicitly requests it
- Target class is in an embedded framework (delayed loading is easier in ObjC)
- User doesn't have Theos installed
- User wants `__attribute__((constructor))` for earliest possible injection

#### Makefile
```makefile
ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0

INSTALL_TARGET_PROCESSES = <AppName>

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = <TweakName>
<TweakName>_FILES = Tweak.xm
<TweakName>_CFLAGS = -fobjc-arc
<TweakName>_FRAMEWORKS = UIKit Foundation
<TweakName>_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
```

`_LIBRARIES = substrate` is required for `MSHookIvar` and related APIs. Adjust `_FRAMEWORKS` — add frameworks the hook references (e.g., if hooking UIWebView methods, add `WebKit`).

#### Tweak.xm — Enhanced Template

Generate the full enhanced Tweak.xm using the template from `${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/references/dylib-injection-guide.md`. The template includes:

1. **Crash Handler** (runs first in `%ctor`): Captures ObjC exceptions (`NSSetUncaughtExceptionHandler`) and POSIX signals (`SIGABRT, SIGSEGV, SIGBUS, SIGTRAP, SIGILL, SIGFPE, SIGSYS`) with full stack traces. Writes to `Documents/<TweakName>_crash.log`.

2. **Hook Logger** (`HKTweakLogger`): Thread-safe file-based logger using `NSFileHandle`. Every hook records entry/exit with timestamps, class/method, args, original result, and modified result. Writes to `Documents/<TweakName>_hook.log`.

3. **JSON Config** (`HKTweakConfig`): On first launch, writes a clean `Documents/<TweakName>_config.json` with all hook settings. User can edit this JSON to toggle hooks or change return values without recompiling. Subsequent launches read from the edited file.

4. **Network Capture** (`HKTweakNetworkCapture`): Only included when hooking network methods. Captures REQUEST and RESPONSE in unified JSON Lines format to `Documents/<TweakName>_network.jsonl`.

**Building the `%ctor` initialization order:**

The `%ctor` MUST initialize systems in this order:
```
1. Crash handler (first — protects against crashes in subsequent setup)
2. Logger setup (so subsequent steps can log)
3. Config loader (writes default JSON, reads user edits)
4. Network capture setup (if applicable)
5. %init (activate all hooks — LAST)
```

**Generating each hook with logging:**

Every hook method must wrap its logic with logger calls. Use this exact pattern:

For simple return-value hooks:
```objc
%hook <ClassName>
- (<ReturnType>)<methodName> {
    [[HKTweakLogger shared] logHookEnter:@"<ClassName>" selector:@"<methodName>" args:nil];

    if (![[HKTweakConfig shared] isHookEnabled:@"<hookId>"]) {
        [[HKTweakLogger shared] logEvent:@"HOOK_DISABLED" detail:@"<hookId> — passing through"];
        return %orig;
    }

    <ReturnType> result = <hookValue>;
    [[HKTweakLogger shared] logHookLeave:@"<ClassName>" selector:@"<methodName>" originalResult:@"(skipped)" new:<resultAsObject>];
    return result;
}
%end
```

For hooks that call %orig then modify:
```objc
%hook <ClassName>
- (<ReturnType>)<methodName> {
    [[HKTweakLogger shared] logHookEnter:@"<ClassName>" selector:@"<methodName>" args:nil];

    if (![[HKTweakConfig shared] isHookEnabled:@"<hookId>"]) {
        return %orig;
    }

    <ReturnType> origResult = %orig;
    <ReturnType> newResult = <hookValue>;
    [[HKTweakLogger shared] logHookLeave:@"<ClassName>" selector:@"<methodName>" originalResult:@(origResult) new:@(newResult)];
    return newResult;
}
%end
```

For network hooks (only if user wants network capture):
```objc
%hook <NetworkClass>
- (NSURLSessionDataTask *)<networkMethod>:(NSString *)url <otherParams> {
    [[HKTweakLogger shared] logHookEnter:@"<NetworkClass>" selector:@"<networkMethod>" args:url];

    // Capture REQUEST
    [[HKTweakNetworkCapture shared] captureRequest:url
                                            method:@"<HTTPMethod>"
                                           headers:<headers>
                                              body:<body>
                                            caller:NSStringFromSelector(_cmd)];

    // Call original, capture RESPONSE
    NSURLSessionDataTask *task = %orig;
    // ... wrap callbacks to capture response ...
    return task;
}
%end
```

**JSON config placeholder:** In the `%ctor`, replace `<JSON_CONFIG_PLACEHOLDER>` with the actual config dictionary:

```objc
NSDictionary *defaultConfig = @{
    @"tweak": @{
        @"name": @"<TweakName>",
        @"version": @"1.0",
        @"description": @"<User's hook description>"
    },
    @"created_at": @"<ISO 8601 timestamp>",
    @"enabled": @YES,
    @"hooks": @[
        @{
            @"id": @"hook_001",
            @"class": @"<ClassName>",
            @"method": @"<method signature>",
            @"description": @"<what this hook does>",
            @"returnType": @"<BOOL|int|NSString|...>",
            @"returnValue": <value>,
            @"enabled": @YES
        }
        // ... more hooks as needed
    ]
};
[[HKTweakConfig shared] loadFromPath:configPath defaults:defaultConfig];
```

**Important**: The `returnValue` in JSON must match the hook's return type:
- `BOOL`: `@YES` or `@NO` 
- `int`/`NSInteger`: `@(99)`
- `NSString *`: `@"string_value"`
- `NSNumber *`: `@(99.0)`
- `BOOL` in JSON: use `true` / `false`

#### control
```
Package: com.ai.<tweakname>
Name: <TweakName>
Version: 1.0
Architecture: iphoneos-arm
Description: <User's hook description in one line>
Maintainer: AI Generated
Author: AI Generated
Section: Tweaks
Depends: mobilesubstrate
```

#### <BundleID>.plist
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

### Step 5: Validate the Generated Code

Before writing files, verify:

1. **JSON Config system (HKTweakConfig) MUST be present** — this is a **HARD REQUIREMENT**. Every generated dylib MUST include the full HKTweakConfig class with `loadFromPath:defaults:` and `isHookEnabled:`. If HKTweakConfig is missing, the generation is INCOMPLETE. Re-generate before proceeding.
2. **Crash handler is first** in `%ctor` — before logger, config, or hooks
3. **%ctor initialization order MUST be correct** — verify with grep that `setupCrashHandler` → `setupWithPath:` → `loadFromPath:` → `tryInstallHooks` appear in that exact order. Any missing or out-of-order step is a blocker.
4. **Every `%hook` has a matching `%end`** (Logos) or every swizzle has orig + repl pair (ObjC)
5. **Return type in the hook matches the class-dump header exactly**
6. **Method selector matches exactly** (colons, parameter names)
7. **Instance (`-`) vs class (`+`) method is correct** — use `class_getClassMethod` for +, `class_getInstanceMethod` for -
8. **Every hook has logger calls** — `logHookEnter` at top, `logHookLeave` or `logHookVoid` at exit
9. **All hook logging wrapped in @try/@catch** — logger code must never crash the app (§5.3)
10. **Every hook calls original implementation** — `%orig` or `orig_*` function pointer is called
11. **Completion block wrapping never drops the block** — always call the original completion at the end
12. **All referenced frameworks are listed** in the Makefile or clang `-framework` flags
13. **`_LIBRARIES = substrate`** is in the Makefile (Logos), or `#include <objc/runtime.h>` is imported (ObjC)
14. **JSON config `returnType` matches** the hook's actual return type
15. **JSON config `returnValue` matches** the type (BOOL uses `@YES`/`@NO`, not `true`/`false`)
16. **Non-void methods always return a value** — the hook body must reach a `return` statement
17. **All file paths use Documents directory** — `NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,...)`, never hardcoded `/var/mobile/...`
18. **Delayed loading implemented** when class is in embedded framework — NSClassFromString polling + retry
19. **Hooks activated on main queue** — `dispatch_get_main_queue()` for UIKit-related swizzling
20. **ldid signing applied** — dylib must be pseudo-signed with `ldid -S` before TrollFools injection
21. **NSLog dual-output in writeLine** — the Logger's `writeLine:` method must call `NSLog(@"[HOOK_PREFIX] %@", line)` before the file write, so `idevicesyslog | grep HOOK_PREFIX` works for real-time monitoring
22. **Every `repl_` function checks config** — each replacement implementation must call `[[HKTweakConfig shared] isHookEnabled:]` and pass through to orig if disabled

**Count verification**:
```bash
# Hook/%end must balance. Note: %end also closes %group blocks,
# so the count may differ if groups are used.
grep -c '%hook' <tweak-dir>/Tweak.xm
grep -c '%end' <tweak-dir>/Tweak.xm

# HKTweakConfig MUST exist — if count is 0, BLOCK the generation
grep -c 'HKTweakConfig' <tweak-dir>/Tweak.xm
grep -c 'HKTweakConfig' <tweak-dir>/<TweakName>.m

# %ctor order MUST be: setupCrashHandler → setupWithPath → loadFromPath → tryInstallHooks
grep -n 'setupCrashHandler\|setupWithPath\|loadFromPath\|tryInstallHooks' <tweak-dir>/Tweak.xm
grep -n 'setupCrashHandler\|setupWithPath\|loadFromPath\|tryInstallHooks' <tweak-dir>/<TweakName>.m
```

**If HKTweakConfig grep returns 0**: The generation is INCOMPLETE. Add the full HKTweakConfig class from the reference guide template and re-verify. Do not proceed to build.

**If %ctor order is wrong**: Reorder the constructor to follow crash→logger→config→hooks. Any deviation from this order is a blocker.

**Common pitfall — Swift classes in ObjC runtime**:
Swift classes bridged to ObjC use a module prefix: `_TtC<ModuleLength><Module><ClassLength><Class>`. The class-dump output shows the ObjC-facing name. Use that exact name in `%hook`.

**Common pitfall — Property hooks**:
When hooking a property `@property (nonatomic) BOOL isVip;`, hook the getter `- (BOOL)isVip` and setter `- (void)setIsVip:(BOOL)arg`.

### Step 6: Build the Package (if Theos is available)

Check if Theos is installed:
```bash
which theos > /dev/null 2>&1 || echo "THEOS not found"
echo $THEOS
```

If Theos is available, attempt to build:
```bash
cd <tweak-dir> && make clean package 2>&1
```

If the build succeeds:
- Report the `.deb` path: `<tweak-dir>/packages/<tweakname>_1.0_iphoneos-arm.deb`
- Extract and show the dylib location inside the package
- **For pure ObjC output**: after `clang` compile, run `ldid -S <TweakName>.dylib` to pseudo-sign (REQUIRED for TrollFools)

If the build fails:
- Read the error output carefully
- Fix the Tweak.xm or Makefile based on the specific error
- Re-build and verify

**Common build errors and fixes**:

| Error | Fix |
|-------|-----|
| `error: expected ';' after expression` | Missing semicolon in hook body |
| `error: use of undeclared identifier` | Missing import or misspelled symbol |
| `error: no visible @interface for ...` | Class not found; check class name in %hook |
| `error: ... is not a member of class ...` | Instance method hooked as class method or vice versa |
| `ld: framework not found` | Remove unused framework from Makefile or add needed one |
| `error: unknown type name 'NSString'` | Add `#import <Foundation/Foundation.h>` |
| `MSHookIvar: undeclared` | Add `#import <substrate.h>` and `_LIBRARIES = substrate` |
| `ld: library not found for -lsubstrate` | Add `_LIBRARIES = substrate` to Makefile |

If Theos is NOT installed, tell the user the project is ready and provide:
- The command to install Theos: `bash -c "$(curl -fsSL https://raw.githubusercontent.com/theos/theos/master/bin/install-theos)"`
- The command to build: `cd <tweak-dir> && make package`

### Step 7: Document the Hook in a README

Generate a `README.md` inside the tweak directory:

```markdown
# <TweakName>

> <User's hook description>

## Hook Target

- **App**: `<AppName>` (`<BundleID>`)
- **Class**: `<ClassName>` (found in: `<path-to-header>`)
- **Method**: `<method signature>`
- **Original behavior**: ...
- **Hooked behavior**: ...

## Built-in Systems

This tweak includes four integrated systems:

| System | File (in App Documents) | Purpose |
|--------|------------------------|---------|
| Crash Logger | `<TweakName>_crash.log` | Captures ObjC exceptions + native signals with stack traces |
| Hook Logger | `<TweakName>_hook.log` | Records every hook invocation with timestamps and values |
| JSON Config | `<TweakName>_config.json` | Editable configuration — toggle hooks or change values without recompiling |
| Network Capture | `<TweakName>_network.jsonl` | Unified REQUEST/RESPONSE capture for protocol analysis |

## How It Works

1. The dylib is injected into `<AppName>` at launch via TrollFools
2. `%ctor` initializes systems in order: crash handler → logger → config → hooks
3. Crash handler protects against exceptions and signals with full stack traces
4. When `<ClassName> <methodName>` is called, the hook intercepts
5. Logger records the call with timestamp, original value, and modified value
6. Config is checked — if the hook is disabled in JSON, it passes through to original

## Hook Configuration (JSON)

Edit `<TweakName>_config.json` in the app's Documents directory:

```json
{
  "tweak": { "name": "<TweakName>", "version": "1.0" },
  "enabled": true,
  "hooks": [
    {
      "id": "hook_001",
      "class": "<ClassName>",
      "method": "<method signature>",
      "description": "Force VIP status",
      "returnType": "BOOL",
      "returnValue": true,
      "enabled": true
    }
  ]
}
```

Set `"enabled": false` on a hook to bypass it. Set `"enabled": false` at the top level to disable all hooks.

## Build

```bash
make clean package
```

Output: `packages/<tweakname>_1.0_iphoneos-arm.deb`

## Install

1. Extract the `.dylib` from the `.deb`:
   ```bash
   ar x packages/<tweakname>_1.0_iphoneos-arm.deb
   tar -xf data.tar.xz
   ```

2. Find the `.dylib` in `Library/MobileSubstrate/DynamicLibraries/`

3. Transfer to your iOS device (AirDrop, SFTP, etc.)

4. Open **TrollFools** → select `<AppName>` → inject the `.dylib`

5. Launch `<AppName>` — the hook is now active

## Verification Checklist

After injecting the dylib, follow these steps to verify it's working:

- [ ] **Kill the app completely** — swipe it away from the app switcher (background)
- [ ] **Cold start the app** — tap the app icon to launch it fresh (NOT from background)
- [ ] **Wait 10-15 seconds** — let the SDK initialize and network requests complete. Do NOT kill the app immediately.
- [ ] **Trigger key actions** — log in, refresh the home page, or do whatever action triggers the hooked methods. Wait another 5-10 seconds.
- [ ] **Check Documents directory with Filza** — navigate to the app's Documents folder and verify these files exist:
  - `<TweakName>_hook.log` — should show "Dylib Loaded" and hook entries
  - `<TweakName>_config.json` — should be auto-generated on first launch
  - `<TweakName>_crash.log` — should be empty (no crashes)
- [ ] **If hook log only has initialization lines** but no hook calls, the app hasn't run long enough. Keep the app open longer and check again.
- [ ] **Real-time monitoring**: run `idevicesyslog | grep SOUL_HOOK` in a terminal to watch log output live. All hook events are echoed to NSLog with the SOUL_HOOK prefix.
- [ ] **All output files are in Documents** — if you don't see files in /tmp, that's expected. The primary output is always the Documents directory.

## Viewing Logs on Device

Use **Filza** to navigate to the app's Documents directory:
```
/var/mobile/Containers/Data/Application/<App-UUID>/Documents/
```

Look for these files:
- `<TweakName>_hook.log` — Hook invocation trace (check this first if behavior is unexpected)
- `<TweakName>_crash.log` — Crash reports (should stay empty; if not, read for the crash reason)
- `<TweakName>_config.json` — Edit this to change hook behavior without reinstalling
- `<TweakName>_network.jsonl` — Captured network traffic (if applicable)

For real-time monitoring without Filza:
```bash
idevicesyslog | grep SOUL_HOOK
```

## Files

| File | Purpose |
|------|---------|
| `Makefile` | Theos build configuration |
| `Tweak.xm` | Logos source with crash handler, logger, config, and hooks |
| `control` | .deb package metadata |
| `<BundleID>.plist` | Injection target filter |
```

### Step 8: Deliver the Complete Package

Present the user with:

1. **Summary** of what was generated and where
2. **The Tweak.xm code** (inlined for review — highlight the hook logic)
3. **The JSON config** (the default config that will be written on first launch)
4. **Log file locations** — how to find and read logs on-device via Filza
5. **Build status** — success, or manual build command if Theos unavailable
6. **Install instructions** — how to get the dylib onto the device via TrollFools
7. **README path** — for full documentation reference

Refer to the full reference at `${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/references/dylib-injection-guide.md` for the complete enhanced template code, system-by-system breakdown, Logos syntax patterns, and troubleshooting.
