# Communication Protocol Extraction Guide

Techniques for extracting and documenting the communication protocol layer from iOS app binaries. This goes beyond endpoint listing — it reconstructs the wire format, message framing, serialization, authentication state machine, and session lifecycle in sufficient detail for an AI to generate a client SDK wrapper.

## AI-Friendly Protocol Documentation

The goal is to produce a protocol specification that an LLM can read and use to generate correct, production-ready SDK code. The spec must be:

1. **Structured** — Sections map to implementation concerns (connect, auth, send, receive, reconnect)
2. **Concrete** — Real wire format examples, not abstract descriptions
3. **Complete** — Edge cases, errors, and lifecycle states are documented
4. **Actionable** — Enough detail to write code without guessing

### Protocol Spec Schema

```markdown
# Communication Protocol Analysis: <AppName>

## Protocol Overview
- Transport, Serialization, Auth scheme, Protocol type

## Connection Specification
- Host, Port, TLS, URL, Connection params

## Authentication State Machine
- States, transitions, token storage, refresh flow

## Message Catalog
### Message: <name>
- Direction, Trigger, Wire format, Schema, Example, Response

## Error Handling
- Error response format, error codes mapping

## Session Lifecycle
- Connect → Auth → Heartbeat → Reconnect → Disconnect

## SDK Implementation Notes
- Recommended libraries, Thread safety, Reconnection strategy
```

## Protocol Type Detection

### HTTP/REST Protocol

Beyond just finding endpoints, extract the protocol layer:

```bash
# Base URL configuration patterns
grep -rn 'baseURL\|base_url\|apiURL\|api_url\|ENDPOINT\|API_BASE\|kBase\|BASE_URL' output/

# HTTP method + path combinations
grep -rn 'httpMethod.*\|\.get\|\.post\|\.put\|\.delete\|\.patch' output/

# Request header construction
grep -rn 'setValue.*forHTTPHeaderField\|\.headers\s*=\|allHTTPHeaderFields' output/

# Response status code handling
grep -rn 'statusCode\|HTTPURLResponse\|didReceiveResponse' output/

# Error response format
grep -rn 'error.*code\|errorCode\|error_code\|message.*error\|\.failure\|\.serverError' output/

# Pagination patterns — determine offset/limit vs cursor-based
grep -rn 'page\|perPage\|pageSize\|limit\|offset\|cursor\|nextPage\|hasMore' output/

# Rate limiting
grep -rn 'rateLimit\|retryAfter\|x-ratelimit\|429\|throttle' output/
```

### WebSocket Protocol

```bash
# Connection
grep -rn 'webSocketTask\|\.connect()\|WebSocket\(url:\|initWithURL' output/

# Message I/O
grep -rn '\.send\(.*Message\|\.write\(string:\|\.write\(data:\|\.receive\s*\{' output/

# Event routing (the protocol layer on top of WebSocket frames)
grep -rn '\.emit\("*\|\.on\("*\|event.*=.*"\|type.*=.*"\|messageType\|msg_type' output/

# Keepalive / heartbeat
grep -rn 'ping\|pong\|heartbeat\|keepAlive\|sendPing\|pingInterval' output/

# Reconnection
grep -rn 'reconnect\|reconnectInterval\|autoReconnect\|connectionLost' output/
```

For WebSocket protocols, the key insight is that the "protocol" is often a JSON envelope over WebSocket frames:

```json
{"type": "message", "payload": {"text": "hello", "chatId": "123"}}
{"type": "typing", "payload": {"chatId": "123", "userId": "456"}}
{"type": "heartbeat", "payload": {"timestamp": 1234567890}}
```

Extract the `type` field values to enumerate protocol messages.

### gRPC / Protocol Buffers

```bash
# gRPC service methods
grep -rn 'GRPCChannel\|ClientConnection\|makeUnaryCall\|makeServerStreamingCall' output/

# Protobuf message classes
grep -rn 'GPBMessage\|SwiftProtobuf\|@interface.*_PB\|\.proto\b' output/

# Channel configuration
grep -rn 'GRPCChannel\|GRPCHost\|host.*port\|grpcPort\|insecureChannel' output/

# Field definitions
grep -rn 'readOnly.*BOOL\|readOnly.*int32\|readOnly.*int64\|GPBField\|\.has_\|\.array' output/
```

For protobuf-based protocols, the generated Objective-C/Swift classes in class-dump output reveal the message schema. Reconstruct `.proto`-like definitions from the property accessors.

### Custom TCP/UDP Binary Protocol

```bash
# Socket creation
grep -rn 'socket()\|connect()\|CFStreamCreate\|NWConnection\|nw_connection' output/

# I/O
grep -rn 'send()\|recv()\|write()\|read()\|CFReadStreamRead\|CFWriteStreamWrite' output/

# Byte-order manipulation (indicates binary protocol)
grep -rn 'CFSwapInt16\|CFSwapInt32\|htonl\|htons\|ntohl\|ntohs' output/

# Message framing constants
grep -rn 'messageLength\|packetLength\|bodyLength\|msgType\|CMD_\|PACKET_' output/

# Buffer size constants
grep -rn 'kRecvBuf\|kSendBuf\|MAX_PACKET\|MAX_MESSAGE\|buf\[[0-9]+\]' output/
```

For custom binary protocols, the key patterns to identify:
- **Length-prefixed**: 2-byte or 4-byte length field before payload
- **Type-Length-Value (TLV)**: Type tag, length, then value bytes
- **Fixed-length**: All messages are the same size
- **Delimited**: Messages separated by a delimiter byte/sequence

### MQTT

```bash
# Library detection
grep -rn 'CocoaMQTT\|MQTTClient\|MQTTSession\|MQTTAsync' output/

# Connection
grep -rn 'mqtt://\|mqtts://\|MQTT_HOST\|MQTT_PORT\|broker' output/

# Topics
grep -rn 'subscribe\|publish\|topic.*=.*"\|qos' output/
```

## Message Format Reverse Engineering

### From Strings

The binary's strings often contain:
- URL paths and query parameter names → reconstruct endpoint list
- JSON field names → reconstruct request/response schemas
- Error messages → understand error handling
- Event type strings → reconstruct WebSocket/Socket.IO message routing

### From Class-Dump Headers

Generated code reveals message structure:
- `GPBMessage` subclasses → protobuf message fields
- `Codable` structs → JSON request/response types
- Enum types with `.get`, `.post` cases → HTTP method routing

### From Symbols

Function names reveal protocol operations:
- `loginWithEmail:password:` → authentication operation
- `sendMessage:toRoom:` → messaging protocol
- `subscribeToTopic:` → pub/sub pattern

## State Machine Reconstruction

### Authentication State Machine

Most apps follow this pattern:

```
UNAUTHENTICATED → AUTHENTICATING → AUTHENTICATED → REFRESHING → UNAUTHENTICATED
```

Key methods to find:
- **Login trigger**: Button handler → ViewModel.login() → Service.login()
- **Token extraction**: Response JSON parsing → `accessToken`, `refreshToken`
- **Token storage**: Keychain/UserDefaults write after successful login
- **Token injection**: Request interceptor that adds Authorization header
- **Token refresh**: 401 response → refresh token request → store new tokens → retry
- **Logout**: Clear stored tokens → reset to UNAUTHENTICATED

### Connection Lifecycle

```
DISCONNECTED → CONNECTING → CONNECTED → (optionally) AUTHENTICATED
     ▲                                            │
     └──────────── DISCONNECTED ◄─────────────────┘
```

## SDK Generation from Protocol Specs

When an AI reads the protocol specification to generate an SDK, it needs:

### 1. Transport Setup
```swift
let session: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 300
    return URLSession(configuration: config)
}()
```

### 2. Request Construction
```swift
func makeRequest<T: Decodable>(_ endpoint: Endpoint, body: Encodable? = nil) async throws -> T {
    var request = URLRequest(url: baseURL.appendingPathComponent(endpoint.path))
    request.httpMethod = endpoint.method.rawValue
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let token = tokenStore.getToken() {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    if let body = body {
        request.httpBody = try encoder.encode(body)
    }
    // ... execute and decode
}
```

### 3. Auth Interceptor
```swift
actor TokenStore {
    private var accessToken: String?
    private var refreshToken: String?
    private var refreshTask: Task<String, Error>?

    func validToken() async throws -> String {
        if let token = accessToken, !isExpired(token) {
            return token
        }
        if let task = refreshTask {
            return try await task.value
        }
        let task = Task { try await refreshAccessToken() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }
}
```

### 4. Reconnection (WebSocket/Socket)
```swift
func connectWithBackoff() {
    Task {
        while !Task.isCancelled {
            do {
                try await ws.connect()
                backoff = .seconds(1) // reset
                await handleMessages()
            } catch {
                try await Task.sleep(for: backoff)
                backoff = min(backoff * 2, .seconds(60))
            }
        }
    }
}
```

## Search Strategy

1. **Start with strings** — URLs, JSON keys, error messages, protocol constants are in the binary strings
2. **Class-dump headers** — Generated code, service classes, message types reveal protocol structure
3. **Linked libraries** (`otool -L`) — Alamofire, Starscream, SwiftProtobuf, CocoaMQTT tell you the protocol family
4. **Symbols** (`nm`) — Function names reveal protocol operations even when classes are obfuscated
5. **Cross-reference** — A class that both uses `URLSession` AND has `Authorization` headers is the HTTP client
6. **Follow the data** — Trace from UI → ViewModel → Service → Network to find the complete call chain
7. **Look for constants** — Buffer sizes, timeouts, retry counts are often named constants
