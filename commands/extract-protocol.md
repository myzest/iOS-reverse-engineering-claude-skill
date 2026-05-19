---
allowed-tools: Bash, Read, Glob, Grep, Write, Edit
description: Extract and document an iOS app's communication protocol as an AI-friendly specification
user-invocable: true
argument-hint: <path to analysis directory>
argument: path to analysis output directory (from /extract-ipa)
---

# /extract-protocol

Extract and document an iOS app's communication protocol layer — wire format, message framing, serialization, authentication state machine, and session lifecycle. Produces an AI-friendly markdown specification that can be used to generate client SDK wrapper code.

## Instructions

You are starting the Communication Protocol Extraction workflow. Follow these steps:

### Step 1: Get the analysis directory

If the user provided a path as an argument, use that. The path should be the output directory from a prior `/extract-ipa` run (e.g., `MyApp-analysis/`).

If no argument was given, ask the user for the path to the analysis directory.

Verify the directory exists and contains extracted app data (class-dump/, strings-raw.txt, etc.).

### Step 2: Run the protocol extraction script

Run the full protocol analysis with both the detailed report and a concise summary:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/extract-protocol.sh <analysis-dir> --report protocol-spec.md --summary protocol-summary.md
```

This generates two files:
- `protocol-spec.md` — Full AI-friendly protocol specification (written incrementally)
- `protocol-summary.md` — Concise summary for AI prompt chaining (generated at end)

**The summary (`protocol-summary.md`)** is the key deliverable — it's a condensed briefing document with Quick Facts, Endpoints table, Auth Flow, Key Types, and an SDK Implementation Checklist. Feed it directly to an AI to generate the SDK.

For targeted analysis, use filters:
- `--http` — HTTP/REST protocol only
- `--websocket` — WebSocket protocol only
- `--grpc` — gRPC/Protobuf only
- `--socket` — Custom TCP/UDP socket only
- `--mqtt` — MQTT only
- `--auth` — Authentication state machine only
- `--http --auth` — HTTP + Auth (most common)

### Step 3: Review and enhance the protocol specification

After the script completes, read the generated `protocol-spec.md` and enhance it:

1. **Complete the Message Catalog** — For each discovered message type, read the relevant class-dump headers and strings to extract the full schema. Add example payloads extracted from the binary strings.

2. **Trace the Auth State Machine** — Read the class-dump headers for auth-related classes (login, token, refresh). Trace the exact flow:
   - What fields does the login request contain?
   - What fields does the login response return?
   - Where are tokens stored (Keychain, UserDefaults)?
   - What triggers a token refresh?
   - How is the auth header constructed?

3. **Reconstruct Wire Format** — If a custom binary protocol is detected, analyze the framing constants. Determine:
   - Header size and structure
   - Byte order (big-endian vs little-endian)
   - Message type field location
   - Payload length field location

4. **Document Error Handling** — Extract error codes, error messages, and error response formats from strings. Map them to protocol states.

5. **Write SDK Implementation Notes** — Based on all findings, write concrete guidance:
   - Which Swift types/libraries to use
   - How to handle threading (actor, serial queue, @MainActor)
   - What reconnection strategy to implement
   - How to handle token refresh race conditions

### Step 4: Deliver the protocol specification

Present the completed protocol specification to the user. The specification is an AI-training document — feed it to an LLM with the prompt:

> "Write a Swift client SDK that implements this communication protocol."

The LLM should be able to generate a working SDK from the specification.

### Step 5: Offer next steps

Tell the user what they can do with the protocol specification:
- **Generate SDK code**: "Feed the protocol-spec.md to an AI with: 'Write a Swift client SDK that implements this communication protocol.'"
- **API extraction**: "I can also search for all HTTP endpoints and document them using /extract-ipa's Phase 5"
- **Security audit**: "I can scan for security issues in how the protocol handles auth, encryption, and secrets"
- **Deep binary reversing**: "I can decompile the network functions to verify the protocol details at the assembly level"

Refer to the full skill documentation in `${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/SKILL.md` for the complete workflow.
