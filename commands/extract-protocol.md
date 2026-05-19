---
allowed-tools: Bash, Read, Glob, Grep, Write, Edit
description: Discover networking files and guide AI-driven protocol analysis
user-invocable: true
argument-hint: <path to analysis directory>
argument: path to analysis output directory (from /extract-ipa)
---

# /extract-protocol

Discover networking and protocol-related files in an extracted iOS app, then guide the AI through reading those files to produce a complete protocol specification.

**Architecture**: Script discovers files → AI reads files → AI writes protocol spec

## Instructions

You are starting the Communication Protocol Discovery & Analysis workflow. Follow these steps:

### Step 1: Get the analysis directory

If the user provided a path as an argument, use that. The path should be the output directory from a prior `/extract-ipa` run (e.g., `MyApp-analysis/`).

If no argument was given, ask the user for the path to the analysis directory.

Verify the directory exists and contains extracted app data (class-dump/, strings-raw.txt, etc.).

### Step 2: Run the file discovery script

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/scripts/extract-protocol.sh <analysis-dir>
```

This discovers and categorizes networking-related files. It generates:

- **`protocol-analysis/protocol-guide.md`** — Structured reading plan for AI (the main deliverable)
- **`protocol-analysis/file-index.md`** — Complete categorized file list
- **`protocol-analysis/relevant-strings.txt`** — Protocol-related strings from binary

### Step 3: Read and analyze the discovered files

The script only finds files — **you (the AI) must read them** to understand the protocol.

Follow the reading guide in `protocol-guide.md`:

1. **Read `relevant-strings.txt` first** — Find base URLs, endpoints, auth patterns
2. **Read Priority 1 files** (HTTP API Client, Auth) — Understand the core networking and auth
3. **Read Priority 2 files** (Service Layer, WebSocket) — Understand real-time and business logic
4. **Read Priority 3 files** (Socket, gRPC, MQTT, GraphQL) — If present, understand specialized protocols
5. **Read Priority 4 files** (Serialization) — Understand data models

For each file you read:
- Read the class-dump header to understand the interface
- Cross-reference findings with `relevant-strings.txt` for real values
- Note what protocol it implements, what role it plays, key methods and types

### Step 4: Write the protocol specification

Based on your reading, produce a protocol specification (`protocol-spec.md`):

```markdown
# Communication Protocol Analysis: <AppName>

## Protocol Overview
- Transport, Serialization, Auth scheme

## Connection Specification
- Base URLs, ports, TLS config

## Authentication Flow
- Login request/response (real field names from headers)
- Token storage mechanism
- Token refresh flow
- Auth header format

## Message Catalog
For each API endpoint or message type:
- Direction, Trigger, Wire format, Schema, Example payload

## Error Handling
- Error response format, error code mapping

## Session Lifecycle
- Connect → Auth → Heartbeat → Reconnect → Disconnect

## SDK Implementation Notes
- Recommended libraries, Thread safety, Reconnection
```

### Step 5: Write the summary

Based on the full spec, write a concise summary (`protocol-summary.md`) for AI prompt chaining:

- Quick Facts table (transport, serialization, auth, token storage)
- Endpoints table (method + path + purpose)
- Auth flow (step-by-step)
- Key data types (Codable structs needed)
- SDK implementation checklist

### Step 6: Deliver

Tell the user what was produced. The user can feed `protocol-summary.md` to an AI with:
> "Based on this protocol summary, write a complete Swift client SDK."

Refer to the full skill documentation in `${CLAUDE_PLUGIN_ROOT}/skills/ios-reverse-engineering/SKILL.md` for the complete workflow.
