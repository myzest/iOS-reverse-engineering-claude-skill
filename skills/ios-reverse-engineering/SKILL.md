---
name: ios-reverse-engineering
description: Extract and analyze iOS IPA, .app bundles, Mach-O binaries, .dylib, and .framework files using ipsw, otool, strings, radare2/rizin, and Ghidra headless. Reverse engineer iOS apps, extract HTTP API endpoints (URLSession, Alamofire, Moya, AFNetworking, GraphQL, WebSocket), trace call flows from ViewControllers to network layer, analyze security patterns (ATS, cert pinning, keychain, jailbreak detection), deep-scan for cloud credentials (Firebase, AWS, GCP, Azure, Stripe), perform LLM-assisted binary reversing analysis with Ghidra scripts, fingerprint embedded third-party SDKs with CVE checking, detect anti-tampering protections (obfuscation, anti-debug, dylib injection prevention, integrity checks), and generate Logos/Theos dylib injection plugins for TrollFools deployment. Use when the user wants to extract, analyze, or reverse engineer iOS packages, find API endpoints, follow call flows, audit app security, scan for leaked secrets, identify third-party SDKs, detect app protections, perform deep binary analysis, or generate a dylib injection tweak.
---

# iOS Reverse Engineering

Extract and analyze iOS IPA files, .app bundles, Mach-O binaries, dynamic libraries, and frameworks using ipsw (blacktop/ipsw), otool, strings, radare2/rizin, and Ghidra headless. Trace call flows through application code, analyze security patterns, deep-scan for cloud provider credentials (Firebase, GCP, AWS, Azure), perform LLM-assisted binary reversing with decompilation and Ghidra headless scripts, fingerprint embedded third-party SDKs with version detection and CVE cross-referencing, and detect anti-tampering protections (obfuscation tools, anti-debugging, dylib injection prevention, integrity checks, jailbreak detection). Produce structured documentation of extracted APIs and security findings. Works with both Swift and Objective-C applications.

## Prerequisites

This skill requires **ipsw** (which includes class-dump functionality and much more) and standard macOS developer tools (**otool**, **strings**, **plutil**, **codesign**). For deep binary analysis, **radare2** (or **rizin**) is recommended; **Ghidra headless** is optional for advanced decompilation. On macOS, most tools are available via Xcode Command Line Tools. On Linux, only static analysis of extracted files is supported. Run the dependency checker to verify:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/check-deps.sh
```

If anything is missing, follow the installation instructions in `${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/references/setup-guide.md`.

## Workflow

### Phase 1: Verify and Install Dependencies

Before analyzing, confirm that the required tools are available — and install any that are missing.

**Action**: Run the dependency check script.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/check-deps.sh
```

The output contains machine-readable lines:
- `INSTALL_REQUIRED:<dep>` — must be installed before proceeding
- `INSTALL_OPTIONAL:<dep>` — recommended but not blocking

**If required dependencies are missing** (exit code 1), install them automatically:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/install-dep.sh <dep>
```

The install script detects the OS and package manager, then:
- Installs via Homebrew when available (`brew install blacktop/tap/ipsw`)
- Falls back to downloading from GitHub releases to `~/.local/share/`, symlinks in `~/.local/bin/`
- If installation fails, it prints the exact manual command and exits with code 2 — show these instructions to the user

**For optional dependencies**, ask the user if they want to install them. jtool2 and frida are recommended for deeper analysis.

After installation, re-run `check-deps.sh` to confirm everything is in place. Do not proceed to Phase 2 until all required dependencies are OK.

### Phase 2: Extract and Dump Classes

Use the extraction script to process the target file. The script supports IPA, .app, Mach-O, .dylib, and .framework files.

**Action**: Run the extraction script.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/extract-ipa.sh [OPTIONS] <file>
```

For **IPA** files: the script extracts the ZIP archive, locates the .app bundle inside `Payload/`, identifies the main Mach-O binary, runs `ipsw class-dump`, extracts Info.plist, entitlements, embedded frameworks, and string constants.

For **.app** bundles: the script works directly on the bundle directory.

For **Mach-O** binaries, **.dylib**, and **.framework** files: the script runs `ipsw class-dump` and string extraction directly.

Options:
- `-o <dir>` — Custom output directory (default: `<filename>-analysis`)
- `--no-classdump` — Skip class-dump (faster, metadata-only analysis)
- `--thin <arch>` — Extract a specific architecture from fat binaries (e.g., `arm64`)
- `--swift-demangle` — Demangle Swift symbols in output

See `${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/references/class-dump-usage.md` for the full ipsw class-dump reference.

### Phase 3: Analyze Structure

Navigate the extracted output to understand the app's architecture.

**Actions**:

1. **Read Info.plist** from `<output>/Info.plist`:
   - Identify the bundle identifier (`CFBundleIdentifier`)
   - Check minimum iOS version (`MinimumOSVersion`)
   - Find URL schemes (`CFBundleURLTypes`)
   - Note App Transport Security settings (`NSAppTransportSecurity`)
   - Find background modes (`UIBackgroundModes`)
   - Check for privacy usage descriptions (camera, location, etc.)

2. **Review entitlements** from `<output>/entitlements.plist`:
   - Keychain access groups
   - App groups
   - Push notification entitlements
   - Associated domains (universal links)

3. **Survey the ipsw class-dump output** in `<output>/class-dump/`:
   - Identify ViewControllers — these are the UI entry points
   - Look for classes named with `API`, `Network`, `Service`, `Client`, `Manager`, `Repository`
   - Distinguish app code from framework code
   - Identify architecture pattern (MVC, MVVM, VIPER, Coordinator)

4. **List embedded frameworks** in `<output>/frameworks/`:
   - Identify third-party frameworks (Alamofire, AFNetworking, Firebase, etc.)
   - Note any custom frameworks that may contain networking code

5. **Identify the architecture pattern**:
   - MVC: ViewControllers with direct networking code
   - MVVM: ViewModel classes with binding patterns
   - VIPER: Interactor, Presenter, Router classes
   - Coordinator: Coordinator/Flow classes managing navigation
   - This informs where to look for network calls in the next phases

### Phase 4: Trace Call Flows

Follow execution paths from user-facing entry points down to network calls.

**Actions**:

1. **Start from entry points**: Read the main ViewController or AppDelegate identified in Phase 3.

2. **Follow the initialization chain**: `AppDelegate.application(_:didFinishLaunchingWithOptions:)` or `@main App` struct often sets up the HTTP client, base URL, and DI framework. Read this first.

3. **Trace user actions**: From a ViewController, follow:
   - `viewDidLoad()` → setup → IBAction/button targets
   - IBAction/target → ViewModel/Presenter method
   - ViewModel → Repository/Service → API client
   - API client → URLSession/Alamofire call

4. **Map DI and service creation**: Find where networking services are instantiated:
   - Swinject containers
   - Manual dependency injection via init parameters
   - Singleton patterns (`shared`, `default`, `instance`)

5. **Handle Swift name mangling**: When symbols are mangled, use strings output and ipsw class-dump headers as anchors. Protocol conformances and property names are readable even in optimized builds.

See `${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/references/call-flow-analysis.md` for detailed techniques and grep commands.

### Phase 5: Extract and Document APIs

Find all API endpoints and produce structured documentation.

**Action**: Run the API search script for a broad sweep.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/find-api-calls.sh <output>/
```

Additional options:
- `--context N` — Show N lines of context around each match (recommended: `--context 3`)
- `--report FILE` — Export results as a structured Markdown report
- `--dedup` — Deduplicate results by endpoint/URL

Targeted searches:
```bash
# Only URLSession patterns
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/find-api-calls.sh <output>/ --urlsession

# Only Alamofire/AFNetworking
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/find-api-calls.sh <output>/ --alamofire

# Only hardcoded URLs
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/find-api-calls.sh <output>/ --urls

# Only auth patterns
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/find-api-calls.sh <output>/ --auth

# Only Combine/async-await patterns
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/find-api-calls.sh <output>/ --swift-concurrency

# Only GraphQL patterns
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/find-api-calls.sh <output>/ --graphql

# Only WebSocket patterns
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/find-api-calls.sh <output>/ --websocket

# Only security patterns (ATS, cert pinning, jailbreak detection)
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/find-api-calls.sh <output>/ --security

# Full analysis with context and Markdown report
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/find-api-calls.sh <output>/ --context 3 --dedup --report report.md
```

Then, for each discovered endpoint, read the surrounding source/strings to extract:
- HTTP method and path
- Base URL
- Path parameters, query parameters, request body
- Headers (especially authentication)
- Response type
- Where it's called from (the call chain from Phase 4)

**Document each endpoint** using this format:

```markdown
### `METHOD /path`

- **Source**: `MyApp.APIService` (class-dump header or strings reference)
- **Base URL**: `https://api.example.com/v1`
- **Path params**: `id` (String)
- **Query params**: `page` (Int), `limit` (Int)
- **Headers**: `Authorization: Bearer <token>`
- **Request body**: `{ "email": "string", "password": "string" }`
- **Response**: `Codable struct User`
- **Called from**: `LoginViewController → LoginViewModel → AuthService → APIClient`
```

See `${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/references/api-extraction-patterns.md` for library-specific search patterns and the full documentation template.

### Phase 6: Security Analysis

Scan for security-relevant patterns in the extracted app.

**Action**: Run the security-focused search:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/find-api-calls.sh <output>/ --security --context 3
```

Look for and flag:
- **App Transport Security (ATS) exceptions** — `NSAllowsArbitraryLoads`, `NSExceptionDomains` with `NSExceptionAllowsInsecureHTTPLoads`
- **Disabled certificate pinning** — custom `URLAuthenticationChallenge` handling that always trusts, `ServerTrustPolicy.disableEvaluation`
- **Exposed secrets** — hardcoded passwords, API keys, encryption keys in strings or class-dump output
- **Jailbreak detection bypass** — checks for `/Applications/Cydia.app`, `canOpenURL("cydia://")`, `/bin/bash` existence
- **Weak crypto** — MD5 hashing, ECB mode, hardcoded IVs/keys, CC_MD5 usage
- **Keychain misuse** — `kSecAttrAccessibleAlways`, missing access control flags
- **Debug flags** — `#if DEBUG` artifacts, staging URLs, verbose logging
- **Privacy** — clipboard access, pasteboard snooping, tracking without consent

See `${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/references/api-extraction-patterns.md` for the full list of security patterns.

### Phase 7: LLM Deep Secret & Credential Analysis

Perform a comprehensive scan for cloud provider credentials, API keys, and secrets embedded in the binary. The LLM analyzes each finding to classify, assess risk, and provide remediation guidance.

**Action**: Run the deep secret scanner:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/deep-secret-scan.sh <output>/ --report secrets-report.md
```

Targeted scans:
```bash
# Firebase / Google only
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/deep-secret-scan.sh <output>/ --firebase

# AWS only
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/deep-secret-scan.sh <output>/ --aws

# Azure only
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/deep-secret-scan.sh <output>/ --azure

# GCP only
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/deep-secret-scan.sh <output>/ --gcp

# Payment providers (Stripe, PayPal, RevenueCat)
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/deep-secret-scan.sh <output>/ --payments

# Messaging (Twilio, SendGrid, Slack, OneSignal)
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/deep-secret-scan.sh <output>/ --messaging

# Analytics (Sentry, Mixpanel, Amplitude, Segment)
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/deep-secret-scan.sh <output>/ --analytics

# JWT tokens
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/deep-secret-scan.sh <output>/ --jwt

# Critical and high severity only
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/deep-secret-scan.sh <output>/ --severity high --report secrets-report.md
```

**LLM Analysis**: After the scan completes, read the report and for each finding:

1. **Classify** — Identify the service and credential type
2. **Assess if client-safe** — Some keys are intended for client use (Firebase API keys, Stripe publishable keys)
3. **Determine blast radius** — What can an attacker do with this credential?
4. **Check for false positives** — Example values, documentation strings, test data
5. **Suggest validation** — Safe commands to test if the credential is active
6. **Recommend remediation** — Rotate, restrict API key, move to server-side, use environment config

**Document each finding** using this format:

```markdown
### [SEVERITY] Service — Credential Type

- **Value**: `[first 4 chars]...[last 4 chars]` (redacted)
- **Location**: `file:line`
- **Client-safe**: Yes / No
- **Impact**: What an attacker could do
- **False positive likelihood**: Low / Medium / High
- **Validation**: How to test if active
- **Remediation**: Specific steps to fix
```

See `${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/references/cloud-secrets-patterns.md` for the full list of cloud provider patterns, key formats, and risk assessments.

### Phase 8: Deep Binary Reversing with LLM Analysis

Use CLI reversing tools (radare2/rizin or Ghidra headless) to perform deep binary analysis. The LLM reads the structured output to identify security issues invisible to string/pattern matching alone.

**Prerequisites**: radare2/rizin or Ghidra must be installed. Install with:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/install-dep.sh radare2
# or
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/install-dep.sh ghidra
```

**Action**: Run the reversing analysis on the main binary:

```bash
# Full analysis (functions, strings, imports, exports, classes, security, network, crypto, auth, entropy)
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/reversing-analyze.sh <main-binary> -o <output>/reversing

# Quick scan (functions + strings + imports only)
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/reversing-analyze.sh --quick <main-binary> -o <output>/reversing

# Force Ghidra headless (uses Java scripts for decompilation, secret scanning, crypto analysis)
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/reversing-analyze.sh --tool ghidra <main-binary> -o <output>/reversing
```

**Ghidra Headless Scripts**: When using Ghidra, the tool automatically runs specialized Java scripts from `${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/ghidra/`:
- `DecompileAllFunctions.java` — Decompiles all functions to pseudo-C (or `--security-only` for targeted decompilation)
- `FindSecrets.java` — Searches decompiled code for hardcoded credentials, API keys, and secrets
- `ExportAPICalls.java` — Finds networking API symbols, traces callers, extracts URLs from decompiled code
- `ExportCryptoUsage.java` — Identifies crypto function usage, decompiles crypto-calling functions, flags weak patterns
- `ExportStringXrefs.java` — Exports all strings with cross-references, categorized by type (URLs, auth, crypto, cloud)

Targeted analysis:
```bash
# Focus on secret/credential handling code
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/reversing-analyze.sh --secrets <binary> -o <output>/reversing

# Focus on networking code
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/reversing-analyze.sh --network <binary> -o <output>/reversing

# Focus on crypto implementations
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/reversing-analyze.sh --crypto <binary> -o <output>/reversing

# Focus on authentication logic
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/reversing-analyze.sh --auth <binary> -o <output>/reversing

# Decompile a specific function
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/reversing-analyze.sh --decompile "sym.objc.AuthService.login" <binary> -o <output>/reversing

# Decompile all functions matching a pattern
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/reversing-analyze.sh --decompile-pattern "auth\|login\|token" <binary> -o <output>/reversing

# Cross-references to a specific function
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/reversing-analyze.sh --xrefs "sym.imp.CCCrypt" <binary> -o <output>/reversing

# Call graph for a function
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/reversing-analyze.sh --callgraph "sym.objc.NetworkManager.request" <binary> -o <output>/reversing

# Entropy analysis (detect packing/encryption)
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/reversing-analyze.sh --entropy <binary> -o <output>/reversing
```

**LLM Analysis**: After the reversing tool produces output, read the generated files and analyze:

1. **Read `functions-secrets.txt`** — Identify functions that handle credentials, keys, tokens
2. **Read `functions-network.txt`** — Map the networking layer, find API endpoints in code
3. **Read `functions-crypto.txt`** — Identify crypto implementations, check for weak patterns
4. **Read `functions-auth.txt`** — Understand authentication flow and potential bypasses
5. **Read `xrefs-security.txt`** — Trace how crypto/keychain APIs are actually called
6. **Read `xrefs-network.txt`** — Trace how network APIs are called, find hidden endpoints
7. **Read `classes-interesting.txt`** — Identify security-critical classes and their relationships
8. **Read `strings-interesting.txt`** — Cross-reference with decompiled code
9. **Use `--decompile`** on interesting functions to get pseudo-code for detailed analysis
10. **Use `--callgraph`** on key functions to visualize execution paths

**Key things to look for in decompiled code:**
- Hardcoded values passed to crypto functions (keys, IVs, salts)
- Authentication bypass conditions (debug flags, hardcoded credentials)
- Insecure data flow (secrets stored in UserDefaults, logged to console)
- Certificate pinning bypass potential
- Jailbreak detection logic (for understanding, not bypassing)
- Obfuscated string decryption routines

See `${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/references/reversing-tools-guide.md` for the full radare2/rizin/Ghidra command reference.

### Phase 9: SDK & Framework Fingerprinting

Identify all third-party SDKs and frameworks embedded in the application. Detect versions where possible and cross-reference with known CVEs.

**Action**: Run the SDK detection script:

```bash
# Full SDK detection with CVE checking
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/detect-sdks.sh <output>/ --check-cves --report sdks-report.md

# Verbose output with match details
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/detect-sdks.sh <output>/ --verbose --check-cves

# JSON output for programmatic use
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/detect-sdks.sh <output>/ --json --check-cves
```

The script fingerprints SDKs by searching:
- Embedded framework names in `Frameworks/`
- Linked libraries from `otool -L` output
- Class prefixes in class-dump headers (e.g., `FIR*` = Firebase, `STP*` = Stripe)
- SDK-specific strings in the binary (domain names, API patterns)
- Symbols and metadata

**SDK categories detected**: Networking, Analytics, Advertising, Authentication, Payments, Push Notifications, Maps, Social, Database, Cloud Storage, UI/UX, Security, Messaging, Crash Reporting, A/B Testing, Deep Linking, AR/ML.

**LLM Analysis**: After detection, assess:

1. **Attack surface** — Each SDK is a potential vector; more SDKs = larger surface
2. **Outdated versions** — Cross-reference detected versions with CVE database
3. **API key safety** — Determine if exposed keys are client-safe (Firebase API key) or server-only (Stripe secret key)
4. **Data flow mapping** — What data does each SDK collect? Where is it sent?
5. **Privacy compliance** — Verify ATT (App Tracking Transparency) for tracking SDKs
6. **Unnecessary SDKs** — Unused SDKs increase risk without benefit

See `${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/references/sdk-fingerprinting.md` for the full SDK fingerprint database, detection techniques, and CVE reference.

### Phase 10: Protection & Anti-Tampering Detection

Detect security protections, anti-tampering mechanisms, obfuscation, and anti-debugging techniques used by the application.

**Action**: Run the protection detection script:

```bash
# Full protection analysis
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/detect-protections.sh <output>/ --report protections-report.md

# With direct binary analysis (more accurate for some checks)
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/detect-protections.sh <output>/ --binary <path-to-macho-binary> --report protections-report.md
```

Targeted analysis:
```bash
# Only obfuscation detection
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/detect-protections.sh <output>/ --obfuscation

# Only anti-debugging checks
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/detect-protections.sh <output>/ --debugger

# Only dylib injection prevention
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/detect-protections.sh <output>/ --injection

# Only integrity/tampering checks
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/detect-protections.sh <output>/ --integrity

# Only jailbreak detection
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/detect-protections.sh <output>/ --jailbreak

# Only binary encryption (FairPlay DRM)
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/detect-protections.sh <output>/ --encryption
```

**Protection types detected**:

- **Obfuscation** — Known tools (iXGuard, SwiftShield, OLLVM, Arxan), class/method name obfuscation ratio, string encryption, control flow flattening
- **Anti-Debugging** — `ptrace(PT_DENY_ATTACH)`, sysctl P_TRACED check, timing-based detection, exception port manipulation, SIGTRAP handlers, debug server detection
- **Dylib Injection Prevention** — `__RESTRICT` segment, `DYLD_INSERT_LIBRARIES` checks, loaded library enumeration/validation, Substrate/Frida detection
- **Integrity Checks** — Runtime code signing verification, binary hash self-checks, team ID verification, provisioning profile validation, App Store receipt validation
- **Jailbreak Detection** — File path checks (Cydia, Sileo, SSH, apt), URL scheme checks, sandbox escape tests (fork), symlink validation, environment variable checks, detection libraries (IOSSecuritySuite)
- **Binary Encryption** — FairPlay DRM (LC_ENCRYPTION_INFO cryptid), with guidance for decryption tools

**Protection Score**: The script outputs a protection score (0-20) assessing the overall level of protection:
- 15-20: Heavily protected
- 10-14: Well protected
- 5-9: Moderately protected
- 1-4: Lightly protected
- 0: Unprotected

**LLM Analysis**: After detection, assess:

1. **Protection quality** — Are protections layered or single-point-of-failure?
2. **Bypass difficulty** — Single-function checks vs distributed checks
3. **Detection vs response** — Does the app crash? Report to server? Degrade gracefully?
4. **Obfuscation coverage** — Partial obfuscation may leave sensitive code readable
5. **Server-side attestation** — Client-side checks can be bypassed; App Attest/DeviceCheck cannot

See `${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/references/anti-tampering-patterns.md` for the full reference on protection patterns and detection techniques.

### Phase 11: Communication Protocol Discovery & Analysis

Discover the app's underlying communication protocol through **AI-guided file analysis**. The script discovers and categorizes networking-related files; the AI reads those files to understand the protocol and produce a specification.

**Architecture**: Script discovers files → AI reads files → AI writes protocol spec

**Action**: Run the file discovery script:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/extract-protocol.sh <output>/
```

This produces three files in `<output>/protocol-analysis/`:
- **`protocol-guide.md`** — Structured reading plan with files categorized by protocol area and priority
- **`file-index.md`** — Complete categorized file list
- **`relevant-strings.txt`** — Protocol-related strings (URLs, endpoints, auth patterns)

The script discovers files by:
- **Filename pattern** — Matching header filenames against 9 categories (HTTP_API_Client, Auth, Service_Layer, WebSocket, Socket_Custom, gRPC_Protobuf, MQTT, GraphQL, Serialization)
- **API usage** — Grep inside headers to find files that use networking APIs but aren't named obviously
- **Linked libraries** — Detecting Alamofire, Starscream, SocketRocket, gRPC, Agora, etc.

**AI Analysis**: After the script completes, the AI follows the reading guide:

1. **Read `relevant-strings.txt`** — Get base URLs, endpoints, auth token patterns
2. **Read Priority 1 files** (HTTP API Client, Auth) — Understand core networking and authentication
3. **Read Priority 2 files** (Service Layer, WebSocket) — Understand real-time and business logic
4. **Read Priority 3-4 files** — Understand specialized protocols and data models
5. **For each file read** — Cross-reference with `relevant-strings.txt` for real values
6. **Produce the protocol specification** — Full spec with protocol overview, connection spec, auth flow, message catalog, error handling, session lifecycle, SDK guidance
7. **Write the summary** — Condensed version for AI prompt chaining

The AI reads actual class-dump headers (not grep snippets), so it can understand method signatures, property types, protocol conformances, and class relationships — producing a more accurate specification than keyword matching alone.

See `${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/references/protocol-extraction-guide.md` for the AI-friendly spec format, protocol type detection techniques, and SDK generation guidance.

### Phase 12: Dylib Injection Plugin Generation

Generate a working dylib injection plugin based on the user's hook requirements and the reversed code analysis. Supports both Logos/Theos (`.xm` + `make package`) and pure ObjC (`.m` + `clang`) output. The AI analyzes class-dump output to verify the target, intelligently selects which systems to enable (never blindly includes all), enforces 7 Mandatory Safety Rules (block copy, method enumeration, decrypt hooks, ivar enumeration, thread safety, constructor timing, singleton discovery), writes correct hook code, builds the package, and documents the hook.

Every generated tweak includes six integrated systems that write to the app's Documents directory:

| System | Output File | Purpose | When Enabled |
|--------|-------------|---------|-------------|
| Crash Logger | `<Tweak>/crash.log` | Captures ObjC exceptions + POSIX signals with full stack traces | ALWAYS |
| Hook Logger | `<Tweak>/hook.log` | Records every hook invocation with timestamps | ALWAYS |
| JSON Config | `<Tweak>/config.json` | Editable hook configuration | ALWAYS |
| Method Enumeration (Rule 2) | (hook log) | class_copyMethodList for every target class | ALWAYS (MANDATORY) |
| Network Capture | `<Tweak>/network.jsonl` | Unified REQUEST/RESPONSE JSON Lines capture | When SPEC mentions network I/O |
| Delayed Loading (Rule 6) | (internal) | NSClassFromString polling with retry | When class in embedded framework |
| Block Wrapping (Rule 1) | (internal) | Intercepts completion blocks; enforces [completion copy] | When method has completion: param |
| NSURLSession Transport (Rule 5) | `<Tweak>/transport_response.json` | Transport-layer HTTP interception | User explicitly requests |
| Decrypt Hook (Rule 3) | `<Tweak>/decrypted_response.json` | Hooks SDK decrypt-storage method | NSURLSession + encrypted responses |
| KVC Polling | `<Tweak>/kvc_config.json` | valueForKey: polling with delays | C++ ivars or non-setter paths |
| Ivar Enumeration (Rule 4) | `<Tweak>/ivar_values.json` | class_copyIvarList + object_getIvar | Setters + KVC both fail |
| Singleton Discovery (Rule 7) | (internal) | Scans for +defaultContext/+shared patterns | Class has singleton class methods |

**Prerequisites**: Theos is optional for building. If not installed, the AI generates the project ready to build:
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/theos/theos/master/bin/install-theos)"
```

**Action**: The AI performs the following workflow (see `/generate-dylib` command for step-by-step detail):

1. **Parse the hook request** — Identify target class, method, desired behavior, and whether network capture is needed
2. **Verify the target** — Grep class-dump output to confirm class and method exist with exact signatures
3. **Design the hook** — Select the correct Logos pattern based on return type (BOOL, int, id, void, etc.)
4. **Generate the Theos project** — Create `tweaks/<TweakName>/` with Makefile, enhanced Tweak.xm (all 4 systems), control, and filter plist
5. **Validate syntax** — Check %ctor init order (crash→logger→config→hooks), balanced %hook/%end, correct return types
6. **Build the package** — Run `make package` if Theos is available; report and fix any compilation errors
7. **Generate documentation** — Write README.md with hook details, JSON config format, log file locations, and TrollFools instructions

**Dylib project structure generated by the AI**:
```
tweaks/<TweakName>/
├── Makefile           # Theos build configuration (ARCHS, target, frameworks, _LIBRARIES=substrate)
├── Tweak.xm           # Enhanced Logos source: crash handler + logger + config + hooks (+ optional network capture)
├── control            # .deb package metadata
├── <BundleID>.plist   # Injection target filter
└── README.md          # Hook documentation, log locations, config guide, build/install steps
```

**Key Logos patterns the AI uses**:

| Pattern | Example |
|---------|---------|
| Return fixed value | `return YES;` / `return 99;` / `return @"string";` |
| Call original then modify | `%orig; return YES;` |
| Modify args to original | `%orig(modifiedArg);` |
| Skip original (void method) | `return;` |
| Constructor (load hook) | `%ctor { <crash> <logger> <config> %init; }` |
| Config-aware hook | Check `[[HKTweakConfig shared] isHookEnabled:]` before applying |
| Network capture hook | `[[HKTweakNetworkCapture shared] captureRequest:...]` wrap callbacks |
| Delayed loading | `%group DelayedHooks` + `NSClassFromString` polling + retry, then `%init(DelayedHooks)` |
| Block wrapping | Wrap completion blocks to intercept response before calling original block |
| Pure ObjC swizzling | `class_getClassMethod` / `method_setImplementation` / `imp_implementationWithBlock` |

**%ctor initialization order (CRITICAL)**:
1. Crash handler — first, protects against crashes in subsequent setup
2. Logger setup — so subsequent steps can log
3. Config loader — writes default JSON on first launch, reads user edits
4. Network capture setup — if applicable
5. Delayed loading check — `NSClassFromString` polling with retry for embedded framework classes
6. `%init` on main queue — activate all hooks LAST via `dispatch_get_main_queue()`

**Build output**: `<tweak-dir>/packages/<tweakname>_1.0_iphoneos-arm.deb`

**Installation via TrollFools**:
1. Extract `.dylib` from `.deb` with `ar x` and `tar -xf`
2. Transfer dylib to iOS device
3. Open TrollFools → select target app → inject dylib
4. Launch app — hook is active. Logs appear in Documents directory.

**Viewing logs on-device**: Use Filza to navigate to `/var/mobile/Containers/Data/Application/<App-UUID>/Documents/<Tweak>/` and find the `hook.log`, `crash.log`, `config.json`, and `network.jsonl` files.

See `${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/references/dylib-injection-guide.md` for the full enhanced Tweak.xm template, all four system implementations, network capture JSONL format, config JSON schema, and troubleshooting.

### Post-Generation Feedback Loop

After a user runs a generated dylib and reports results (success or failure), the AI MUST execute this feedback loop. The goal is not just to fix the one dylib, but to fix the Skill files that caused the problem — preventing the same mistake in all future generations.

#### Step 1: Read the User's Hook Log

Ask the user to provide these files and read each one:

- `<TweakName>/hook.log` — Check which hooks were installed, which triggered, timestamps, any errors
- `<TweakName>/crash.log` — If non-empty, the dylib caused a crash; analyze the stack trace
- `<TweakName>/config.json` — Verify it was auto-generated and contains all hook entries

#### Step 2: Diagnose from Log Patterns

Match the log evidence against this classification table:

| Log Evidence | Diagnosis | Root Cause |
|-------------|-----------|------------|
| Hook installed but never triggered ("PASS-THROUGH" or no [HOOK:ENTER] lines) | App killed too early / SDK not initialized | User needs verification checklist — cold start + wait 10-15s |
| Only backup-layer hooks trigger (e.g., internal context class), P0 hooks missing | Primary class in embedded framework, loaded later than expected | Increase NSClassFromString retry count or interval in delayed loading |
| "SWIZZLE_FAIL" entries in log | Method signature mismatch between dylib and actual binary | Re-check class-dump header; the app version may differ |
| crash.log has content | Hook code caused a crash | Check @try/@catch coverage, return type mismatch, wild pointer in repl_ function |
| No files generated at all | Dylib not loaded or Documents path unresolvable | Check TrollFools injection, verify `__attribute__((constructor))` ran |
| Hook log format differs from template | AI deviated from reference guide template | Strengthen constraints in generate-dylib.md |
| `_config.json` missing but hook log exists | JSON Config system was skipped during generation | HKTweakConfig class missing — hard blocker, see generate-dylib.md Step 5 item 1 |
| NSLog output not appearing in idevicesyslog | Logger missing NSLog dual-output | writeLine: method missing `NSLog(@"[PREFIX] %@", line)` call |
| Some hooks have config checks, others don't | Inconsistent HKTweakConfig integration | AI added config to some repl_ functions but not all |
| SIGSEGV in NSURLSession completion or block wrapper | Block was stack-allocated and freed | Missing `[completion copy]` for `id`-typed block param (Rule 1) |
| P0 hooks (public API name) never trigger but backup hooks work | Public API name ≠ runtime method name | Did not run class_copyMethodList before hooking (Rule 2) |
| transport_response.json shows `{"res":"base64..."}` | Response is encrypted at transport layer | Missing decrypt-layer hook — need to hook the SDK's decrypt-storage method (Rule 3) |
| All setter hooks silent + KVC polling returns all null | SDK bypasses setters and KVC via C++ ivar manipulation | Missing ivar enumeration — class_copyIvarList as 3rd capture layer (Rule 4) |
| Intermittent SIGSEGV during JSON parse or writeToFile in completion block | Heavy Foundation work on CFNetwork internal thread | Missing dispatch_async to background queue in NSURLSession wrapped completion (Rule 5) |
| "Target class not loaded" after 10 retries but class definitely exists | Constructor runs before embedded framework dyld loads | Retry delay too short or max retries too low — increase to 15 retries with 5s interval (Rule 6) |
| KVC polling finds values but setters never triggered | Singleton populated via C++ code, not through ObjC setter path | Missing +defaultContext/+shared singleton discovery for KVC reads (Rule 7) |

#### Step 3: Fix the Skill Files (NOT just the dylib)

**Critical principle**: When a bug is found in a generated dylib, trace it back to the Skill file that caused it. Fix the root cause, not the symptom.

Fix priority order:

1. **Reference guide template code** (`dylib-injection-guide.md`) — If the template has a bug, every future generation will replicate it. Fix the template first. The "Mandatory Safety Rules" chapter contains 7 rules that each address a known deployment failure mode.
2. **Command file constraints** (`generate-dylib.md`) — If AI skipped a system, tighten the validation checklist. Add grep verification. Add blocker language. Validation items #24-#30 enforce the 7 mandatory rules at generation time.
3. **SKILL.md workflow** — If a Phase description is ambiguous, add clarifying language and concrete examples. The diagnostic table maps log evidence to specific Mandatory Safety Rule violations.

**Example**: If the generated tweak was missing HKTweakConfig → the root cause is that `generate-dylib.md` Step 5 didn't enforce it as a hard blocker. Fix: add a grep check and blocker language in Step 5.

#### Step 4: Record the Fix in Memory

After fixing the Skill files, save a **project memory** summarizing:
- What problem was found
- What Skill file(s) were changed to prevent recurrence
- Any non-obvious constraint (e.g., "App sandbox cannot write to /tmp, use NSLog for real-time output")

This ensures future AI instances in new sessions benefit from the learning.

### Feedback Loop Example

**User reports**: "No files in /tmp, and Documents/crash.log is empty but hook.log only has init lines"

**AI response**:
1. Read hook log → Only "Dylib Loaded" and "Target classes not loaded" lines. No hook triggers.
2. Read dylib source → `setupWithPath:` accepts one arg but was called with two (tmpLogPath silently dropped). P0 hooks in retry loop never escaped because app was killed too fast.
3. Diagnosis: (a) Logger had dead /tmp code — NSLog wasn't being used. (b) App runtime too short.
4. Fix `dylib-injection-guide.md`: Logger writeLine now includes `NSLog(@"[%@] ...", TWEAK_NAME)` for real-time output.
5. Fix `generate-dylib.md`: README template now includes verification checklist telling user to wait 10-15 seconds.
6. Save project memory: "Dylib loggers must use NSLog dual-output since App sandbox can't write to /tmp. Users need explicit cold-start wait instructions."

## Output

At the end of the workflow, deliver:

1. **Extracted app contents** in the output directory
2. **Architecture summary** — app structure, main classes, pattern used, frameworks
3. **API documentation** — all discovered endpoints in the format above
4. **Call flow map** — key paths from UI to network (especially authentication and main features)
5. **Security findings** — ATS config, cert pinning status, exposed secrets, jailbreak detection, crypto issues
6. **Cloud credential report** — all cloud provider secrets found, classified by service, severity, and risk (Phase 7)
7. **Deep binary analysis** — decompiled functions, cross-references, crypto analysis, data flow findings (Phase 8)
8. **SDK inventory** — all third-party SDKs identified, with versions, categories, CVE matches, and risk assessment (Phase 9)
9. **Protection assessment** — anti-tampering mechanisms, obfuscation, anti-debug, injection prevention, with protection score (Phase 10)
10. **Protocol specification** — AI-friendly communication protocol document covering transport, serialization, auth state machine, message catalog, session lifecycle, and SDK implementation guidance (Phase 11)
11. **Dylib injection plugin** — working Logos/Theos tweak project with Tweak.xm, Makefile, compiled .deb, and documentation (Phase 12)

Use `--report report.md` on find-api-calls.sh, deep-secret-scan.sh, detect-sdks.sh, detect-protections.sh, and extract-protocol.sh to generate structured Markdown reports automatically.

## References

- `${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/references/setup-guide.md` — Installing ipsw, jtool2, frida, and optional tools
- `${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/references/class-dump-usage.md` — ipsw class-dump CLI options, Swift support, and Mach-O analysis
- `${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/references/api-extraction-patterns.md` — Library-specific search patterns and documentation template
- `${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/references/call-flow-analysis.md` — Techniques for tracing call flows in iOS apps
- `${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/references/cloud-secrets-patterns.md` — Cloud provider credential patterns (Firebase, GCP, AWS, Azure, Stripe, etc.)
- `${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/references/reversing-tools-guide.md` — CLI reversing tools reference (radare2, rizin, Ghidra headless)
- `${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/references/sdk-fingerprinting.md` — SDK fingerprint database, class prefixes, version extraction, and CVE reference
- `${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/references/anti-tampering-patterns.md` — Anti-tampering, obfuscation, anti-debug, and injection prevention patterns
- `${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/references/protocol-extraction-guide.md` — Communication protocol extraction, AI-friendly spec format, and SDK generation guidance
- `${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/references/dylib-injection-guide.md` — Logos/Theos dylib injection plugin generation, hook patterns, project templates, and TrollFools deployment
