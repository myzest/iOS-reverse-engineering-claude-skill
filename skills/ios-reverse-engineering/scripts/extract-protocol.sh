#!/usr/bin/env bash
# extract-protocol.sh — Extract and document communication protocols from iOS app analysis output
# Produces an AI-friendly protocol specification document that can be used to generate SDK wrappers.
set -euo pipefail

usage() {
  cat <<EOF
Usage: extract-protocol.sh <analysis-dir> [OPTIONS]

Extract and document the communication protocol layer from an iOS app.
Goes beyond HTTP endpoint listing — analyzes wire format, message framing,
serialization, authentication state machine, and session lifecycle.

Produces an AI-friendly Markdown protocol specification suitable for
generating client SDK wrapper code.

Arguments:
  <analysis-dir>    Path to the analysis output directory (from extract-ipa.sh)

Options:
  --http            Focus on HTTP/REST protocol layer
  --websocket       Focus on WebSocket protocol
  --grpc            Focus on gRPC / Protocol Buffers protocols
  --socket          Focus on custom TCP/UDP socket protocols
  --mqtt            Focus on MQTT protocols
  --auth            Focus on authentication state machine only
  --all             All protocol types (default)
  --report FILE     Write AI-friendly Markdown report to FILE (appended incrementally)
  --summary FILE    Write a concise summary suitable for AI prompt chaining (generated at end)
  --context N       Show N lines of context around matches (default: 2)
  -h, --help        Show this help message

Examples:
  extract-protocol.sh MyApp-analysis --report protocol-spec.md --summary protocol-summary.md
  extract-protocol.sh MyApp-analysis --websocket --report ws-protocol.md
  extract-protocol.sh MyApp-analysis --http --auth --report api-spec.md
EOF
  exit 0
}

# =====================================================================
# Argument parsing
# =====================================================================

ANALYSIS_DIR=""
DO_HTTP=false
DO_WEBSOCKET=false
DO_GRPC=false
DO_SOCKET=false
DO_MQTT=false
DO_AUTH=false
DO_ALL=true
REPORT_FILE=""
SUMMARY_FILE=""
CONTEXT_LINES=2

while [[ $# -gt 0 ]]; do
  case "$1" in
    --http)      DO_HTTP=true;      DO_ALL=false; shift ;;
    --websocket) DO_WEBSOCKET=true;  DO_ALL=false; shift ;;
    --grpc)      DO_GRPC=true;       DO_ALL=false; shift ;;
    --socket)    DO_SOCKET=true;     DO_ALL=false; shift ;;
    --mqtt)      DO_MQTT=true;       DO_ALL=false; shift ;;
    --auth)      DO_AUTH=true;       DO_ALL=false; shift ;;
    --all)       DO_ALL=true; shift ;;
    --report)    REPORT_FILE="$2"; shift 2 ;;
    --summary)   SUMMARY_FILE="$2"; shift 2 ;;
    --context)   CONTEXT_LINES="$2"; shift 2 ;;
    -h|--help)   usage ;;
    -*)          echo "Error: Unknown option $1" >&2; usage ;;
    *)           ANALYSIS_DIR="$1"; shift ;;
  esac
done

if [[ -z "$ANALYSIS_DIR" ]]; then
  echo "Error: No analysis directory specified." >&2
  usage
fi

if [[ ! -d "$ANALYSIS_DIR" ]]; then
  echo "Error: Directory not found: $ANALYSIS_DIR" >&2
  exit 1
fi

# =====================================================================
# Helpers
# =====================================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

APP_NAME=""
if [[ -f "$ANALYSIS_DIR/Info.plist" ]]; then
  if command -v plutil &>/dev/null; then
    APP_NAME=$(plutil -extract CFBundleDisplayName raw "$ANALYSIS_DIR/Info.plist" 2>/dev/null || \
               plutil -extract CFBundleName raw "$ANALYSIS_DIR/Info.plist" 2>/dev/null || echo "Unknown")
  fi
fi
if [[ -z "$APP_NAME" ]] || [[ "$APP_NAME" == "Unknown" ]]; then
  APP_NAME=$(basename "$ANALYSIS_DIR" | sed 's/-analysis$//')
fi

PROTOCOL_TYPES_FOUND=()
SECTION_NUM=0

# Robust line counter — avoids pipefail issues with grep -c on empty input
count_lines() {
  local input="$1"
  if [[ -z "$input" ]]; then
    echo "0"
  else
    echo "$input" | grep -c . 2>/dev/null || echo "0"
  fi
}

# Search across class-dump headers and strings
search_all() {
  local pattern="$1"
  local case_flag="${2:--i}"
  local results=""

  if [[ -d "$ANALYSIS_DIR/class-dump" ]]; then
    results+=$(grep -rn $case_flag ${CONTEXT_FLAG:+"$CONTEXT_FLAG"} "$pattern" "$ANALYSIS_DIR/class-dump/" 2>/dev/null | head -30 || true)
    if [[ -n "$results" ]]; then
      results+=$'\n'
    fi
  fi

  if [[ -f "$ANALYSIS_DIR/strings-raw.txt" ]]; then
    results+=$(grep $case_flag "$pattern" "$ANALYSIS_DIR/strings-raw.txt" 2>/dev/null | head -30 || true)
  fi

  echo "$results"
}

# Search only in strings
search_strings() {
  local pattern="$1"
  local case_flag="${2:--i}"
  if [[ -f "$ANALYSIS_DIR/strings-raw.txt" ]]; then
    grep $case_flag "$pattern" "$ANALYSIS_DIR/strings-raw.txt" 2>/dev/null | head -20 || true
  fi
}

# Search only in class-dump headers
search_headers() {
  local pattern="$1"
  local case_flag="${2:--i}"
  if [[ -d "$ANALYSIS_DIR/class-dump" ]]; then
    grep -rn $case_flag ${CONTEXT_FLAG:+"$CONTEXT_FLAG"} "$pattern" "$ANALYSIS_DIR/class-dump/" 2>/dev/null | head -30 || true
  fi
}

# Check linked libraries
search_linked() {
  local pattern="$1"
  if [[ -f "$ANALYSIS_DIR/linked-libraries.txt" ]]; then
    grep -i "$pattern" "$ANALYSIS_DIR/linked-libraries.txt" 2>/dev/null || true
  fi
}

# Search plists
search_plists() {
  local pattern="$1"
  if [[ -f "$ANALYSIS_DIR/Info.plist" ]]; then
    grep -i "$pattern" "$ANALYSIS_DIR/Info.plist" 2>/dev/null | head -10 || true
  fi
}

# --- Incremental Report Writing ---
# Each section is appended to the report file immediately as it's discovered.
# This allows real-time reading of partial results.

report_section() {
  local title="$1"
  local content="$2"
  local level="${3:-##}"

  if [[ -n "$REPORT_FILE" ]]; then
    {
      echo
      echo "${level} ${title}"
      echo
      echo "$content"
      echo
    } >> "$REPORT_FILE"
  fi
}

report_init() {
  if [[ -z "$REPORT_FILE" ]]; then
    return
  fi

  cat > "$REPORT_FILE" <<EOF
# Communication Protocol Analysis: ${APP_NAME}

**Generated**: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
**Analysis directory**: \`${ANALYSIS_DIR}\`

> This document is an AI-friendly protocol specification. It describes the communication protocol layer of the application in sufficient detail for an AI to generate client SDK wrapper code. Each section documents a specific aspect of the protocol: transport, serialization, message formats, authentication flow, and session lifecycle.

---

## Protocol Discovery Summary

EOF
}

report_summary() {
  if [[ -z "$REPORT_FILE" ]]; then
    return
  fi

  {
    echo "| Category | Detected | Details |"
    echo "|----------|----------|---------|"
    for entry in "${PROTOCOL_TYPES_FOUND[@]}"; do
      echo "| $entry |"
    done
    echo
    echo "---"
  } >> "$REPORT_FILE"
}

section_header() {
  SECTION_NUM=$((SECTION_NUM + 1))
  local title="$1"
  echo
  echo -e "${BLUE}━━━ ${SECTION_NUM}. ${title} ━━━${NC}"
  echo
}

print_finding() {
  local type="$1"
  local detail="$2"
  echo -e "  ${GREEN}[${type}]${NC} ${detail}"
}

# =====================================================================
# Initialize report
# =====================================================================

report_init

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     Communication Protocol Extraction & Documentation       ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo
echo "App: $APP_NAME"
echo "Analysis directory: $ANALYSIS_DIR"
[[ -n "$REPORT_FILE" ]] && echo "Report: $REPORT_FILE"
echo

# =====================================================================
# 1. TRANSPORT LAYER DETECTION
# =====================================================================

section_header "Transport Layer Detection"

echo "Identifying network transports used by the application..."
echo

TRANSPORT_CONTENT=""

# --- HTTP/HTTPS ---
http_urls=$(search_strings '"https\?://[^"]*"' || true)
http_count=$(count_lines "$http_urls")

if [[ "$http_count" -gt 0 ]]; then
  print_finding "TRANSPORT" "HTTP/HTTPS detected — $http_count URLs found"
  PROTOCOL_TYPES_FOUND+=("HTTP/HTTPS | Yes | $http_count URLs found in binary strings")
  TRANSPORT_CONTENT+=$'\n'"### HTTP/HTTPS"$'\n\n'
  TRANSPORT_CONTENT+="HTTP/HTTPS is the primary transport. $http_count URLs found in the binary."$'\n\n'

  # Extract unique hosts
  unique_hosts=$(echo "$http_urls" | grep -oE 'https?://[^/"]+' | sort -u | head -10 || true)
  if [[ -n "$unique_hosts" ]]; then
    TRANSPORT_CONTENT+="**Discovered hosts:**"$'\n'
    while IFS= read -r host; do
      [[ -n "$host" ]] && TRANSPORT_CONTENT+="- \`$host\`"$'\n'
    done <<< "$unique_hosts"
    TRANSPORT_CONTENT+=$'\n'
  fi

  # Detect CDN usage
  cdn_hosts=$(echo "$unique_hosts" | grep -iE 'cdn|cloudfront|akamai|fastly|cloudflare' || true)
  if [[ -n "$cdn_hosts" ]]; then
    TRANSPORT_CONTENT+="**CDN/Edge hosts detected:**"$'\n'
    while IFS= read -r host; do
      [[ -n "$host" ]] && TRANSPORT_CONTENT+="- \`$host\`"$'\n'
    done <<< "$cdn_hosts"
    TRANSPORT_CONTENT+=$'\n'
  fi
fi

# --- WebSocket ---
ws_urls=$(search_all '"wss\?://[^"]*"' || true)
ws_count=$(count_lines "$ws_urls")

ws_libs=$(search_all 'URLSessionWebSocketTask\|Starscream\|SocketRocket\|NWProtocolWebSocket\|SocketIOClient\|SocketManager' || true)
ws_lib_count=$(count_lines "$ws_libs")

if [[ "$ws_count" -gt 0 ]] || [[ "$ws_lib_count" -gt 0 ]]; then
  print_finding "TRANSPORT" "WebSocket detected — $ws_count WS URLs, $ws_lib_count library references"
  PROTOCOL_TYPES_FOUND+=("WebSocket | Yes | $ws_count WS URLs, $ws_lib_count library references")
  TRANSPORT_CONTENT+=$'\n'"### WebSocket"$'\n\n'

  if [[ "$ws_count" -gt 0 ]]; then
    TRANSPORT_CONTENT+="**WebSocket URLs found:**"$'\n'
    echo "$ws_urls" | head -10 | while IFS= read -r line; do
      [[ -n "$line" ]] && TRANSPORT_CONTENT+="- \`$(echo "$line" | grep -oE 'wss?://[^"]*' || echo "$line")\`"$'\n'
    done
    TRANSPORT_CONTENT+=$'\n'
  fi

  TRANSPORT_CONTENT+="**WebSocket libraries detected:**"$'\n\n'
  TRANSPORT_CONTENT+='```'$'\n'"$ws_libs"$'\n''```'$'\n\n'
fi

# --- Custom TCP/UDP Socket ---
socket_refs=$(search_all 'socket\(\)\|connect\(\)\|CFStreamCreate\|CFStreamCreatePair\|NWConnection\|nw_connection\|getaddrinfo' || true)
socket_count=$(count_lines "$socket_refs")

if [[ "$socket_count" -gt 3 ]]; then
  print_finding "TRANSPORT" "Custom TCP/UDP socket usage detected — $socket_count references"
  PROTOCOL_TYPES_FOUND+=("Custom Socket | Yes | $socket_count socket API references")
  TRANSPORT_CONTENT+=$'\n'"### Custom TCP/UDP Socket"$'\n\n'
  TRANSPORT_CONTENT+="Low-level socket APIs detected. This may indicate a custom binary protocol."$'\n\n'
  TRANSPORT_CONTENT+='```'$'\n'"$socket_refs"$'\n''```'$'\n\n'

  # Look for port numbers near socket usage
  ports=$(search_strings ':\d{4,5}' | grep -oE '[.:][0-9]{4,5}' | sort -u | head -10 || true)
  if [[ -n "$ports" ]]; then
    TRANSPORT_CONTENT+="**Possible port numbers found:**"$'\n'
    while IFS= read -r port; do
      [[ -n "$port" ]] && TRANSPORT_CONTENT+="- \`$port\`"$'\n'
    done <<< "$ports"
    TRANSPORT_CONTENT+=$'\n'
  fi
fi

# --- gRPC ---
grpc_refs=$(search_all 'GRPCChannel\|ClientConnection\|GRPCManagedChannel\|CallOptions\|makeUnaryCall\|makeServerStreamingCall\|makeBidirectionalStreamingCall\|SwiftGRPC\|grpc-swift\|grpc\.swift' || true)
grpc_count=$(count_lines "$grpc_refs")

if [[ "$grpc_count" -gt 0 ]]; then
  print_finding "TRANSPORT" "gRPC detected — $grpc_count references"
  PROTOCOL_TYPES_FOUND+=("gRPC | Yes | $grpc_count gRPC library references")
  TRANSPORT_CONTENT+=$'\n'"### gRPC"$'\n\n'
  TRANSPORT_CONTENT+="gRPC client usage detected."$'\n\n'
  TRANSPORT_CONTENT+='```'$'\n'"$grpc_refs"$'\n''```'$'\n\n'
fi

# --- MQTT ---
mqtt_refs=$(search_all 'MQTT\|CocoaMQTT\|MQTTClient\|MQTTSession\|MQTTAsync\|mqtt://\|mqtts://' || true)
mqtt_count=$(count_lines "$mqtt_refs")

if [[ "$mqtt_count" -gt 0 ]]; then
  print_finding "TRANSPORT" "MQTT detected — $mqtt_count references"
  PROTOCOL_TYPES_FOUND+=("MQTT | Yes | $mqtt_count MQTT library references")
  TRANSPORT_CONTENT+=$'\n'"### MQTT"$'\n\n'
  TRANSPORT_CONTENT+="MQTT client usage detected."$'\n\n'
  TRANSPORT_CONTENT+='```'$'\n'"$mqtt_refs"$'\n''```'$'\n\n'

  # Extract topics
  mqtt_topics=$(search_strings 'mqtt\|topic.*/' | grep -oE '["/][a-z]+/[a-z0-9/_#+]+' | sort -u | head -15 || true)
  if [[ -n "$mqtt_topics" ]]; then
    TRANSPORT_CONTENT+="**MQTT Topics found:**"$'\n'
    while IFS= read -r topic; do
      [[ -n "$topic" ]] && TRANSPORT_CONTENT+="- \`$topic\`"$'\n'
    done <<< "$mqtt_topics"
    TRANSPORT_CONTENT+=$'\n'
  fi
fi

if [[ "$http_count" -eq 0 ]] && [[ "$ws_count" -eq 0 ]] && [[ "$mqtt_count" -eq 0 ]] && [[ "$socket_count" -le 3 ]]; then
  TRANSPORT_CONTENT="No clear transport protocol detected. The app may use only Apple system APIs or the binary is heavily stripped."
  print_finding "TRANSPORT" "No clear transport detected (binary may be stripped)"
fi

report_section "Transport Layer" "$TRANSPORT_CONTENT"

# =====================================================================
# 2. SERIALIZATION FORMAT DETECTION
# =====================================================================

section_header "Serialization Format Detection"

echo "Identifying data serialization formats..."
echo

SERIAL_CONTENT=""

# --- JSON ---
json_refs=$(search_all 'JSONDecoder\|JSONEncoder\|JSONSerialization\|SwiftyJSON\|ObjectMapper\|HandyJSON\|Codable.*JSON\|\.responseJSON\|responseDecodable\|\.decode(' || true)
json_count=$(count_lines "$json_refs")

if [[ "$json_count" -gt 0 ]]; then
  print_finding "FORMAT" "JSON — $json_count references to JSON parsing/coding"
  SERIAL_CONTENT+="### JSON (JavaScript Object Notation)"$'\n\n'
  SERIAL_CONTENT+="JSON is used for data serialization. $json_count references to JSON coding."$'\n\n'

  # Find JSON key patterns
  json_keys=$(search_strings '"[a-z_][a-z0-9_]*"\s*:' | grep -oE '"[a-z_][a-z0-9_]*"' | sort -u | head -20 || true)
  if [[ -n "$json_keys" ]]; then
    SERIAL_CONTENT+="**Common JSON keys extracted from binary:**"$'\n'
    while IFS= read -r key; do
      [[ -n "$key" ]] && SERIAL_CONTENT+="- $key"$'\n'
    done <<< "$json_keys"
    SERIAL_CONTENT+=$'\n'
  fi
fi

# --- Protocol Buffers ---
protobuf_refs=$(search_all 'GPBMessage\|GPBString\|GPBInt32\|GPBBool\|\.proto\|protobuf\|SwiftProtobuf\|protoc\|GPBCodedInputStream\|GPBCodedOutputStream\|GPBWireFormat\|\.pb\.\|SerializedSize\|mergeFrom\|parseFrom\|proto3\|proto2' || true)
proto_count=$(count_lines "$protobuf_refs")

if [[ "$proto_count" -gt 0 ]]; then
  print_finding "FORMAT" "Protocol Buffers — $proto_count references"
  PROTOCOL_TYPES_FOUND+=("Protobuf | Yes | $proto_count protobuf references")
  SERIAL_CONTENT+="### Protocol Buffers (protobuf)"$'\n\n'
  SERIAL_CONTENT+="Protocol Buffers binary serialization detected. $proto_count references found."$'\n\n'
  SERIAL_CONTENT+='```'$'\n'"$protobuf_refs"$'\n''```'$'\n\n'

  # Look for .proto file references
  proto_files=$(search_strings '\.proto' | grep -oE '[a-zA-Z0-9_]+\.proto' | sort -u | head -20 || true)
  if [[ -n "$proto_files" ]]; then
    SERIAL_CONTENT+="**Proto file references:**"$'\n'
    while IFS= read -r pf; do
      [[ -n "$pf" ]] && SERIAL_CONTENT+="- \`$pf\`"$'\n'
    done <<< "$proto_files"
    SERIAL_CONTENT+=$'\n'
  fi

  # Look for message type names (GPB* classes)
  proto_messages=$(search_headers '@interface GPB\|@interface.*Message\b' | grep -v 'SystemConfiguration\|Foundation' | head -20 || true)
  if [[ -n "$proto_messages" ]]; then
    SERIAL_CONTENT+="**Generated protobuf message classes:**"$'\n'
    echo "$proto_messages" | while IFS= read -r line; do
      [[ -n "$line" ]] && SERIAL_CONTENT+="- \`$line\`"$'\n'
    done
    SERIAL_CONTENT+=$'\n'
  fi
fi

# --- MessagePack ---
msgpack_refs=$(search_all 'MessagePack\|msgpack\|MPMessagePack\|MPEncoder\|MPDecoder\|MessagePackEncoder\|MessagePackDecoder' || true)
msgpack_count=$(count_lines "$msgpack_refs")

if [[ "$msgpack_count" -gt 0 ]]; then
  print_finding "FORMAT" "MessagePack — $msgpack_count references"
  SERIAL_CONTENT+="### MessagePack"$'\n\n'
  SERIAL_CONTENT+="MessagePack binary serialization detected."$'\n\n'
fi

# --- Custom Binary ---
binary_framing=$(search_all 'memcpy\|CFSwapInt16\|CFSwapInt32\|CFSwapInt64\|htonl\|htons\|ntohl\|ntohs\|encodeBytes\|encodeInt\|encodeString\|Data\(bytes:\|withUnsafeBytes' || true)
binary_count=$(count_lines "$binary_framing")

# Check for byte-level manipulation combined with send/recv
if [[ "$binary_count" -gt 5 ]] && [[ "$socket_count" -gt 2 ]]; then
  print_finding "FORMAT" "Custom binary protocol likely — byte-level manipulation + socket I/O"
  SERIAL_CONTENT+="### Custom Binary Format"$'\n\n'
  SERIAL_CONTENT+="Byte-level manipulation combined with socket I/O suggests a custom binary wire format."$'\n\n'
  SERIAL_CONTENT+="**Byte-order functions detected:**"$'\n'
  echo "$binary_framing" | head -15 | while IFS= read -r line; do
    [[ -n "$line" ]] && SERIAL_CONTENT+="- \`$line\`"$'\n'
  done
  SERIAL_CONTENT+=$'\n'
fi

# --- Message Framing Detection ---
framing_patterns=""

# Length-prefix framing
len_prefix=$(search_all 'readInt32\|readUInt32\|readInt16\|writeInt32\|writeUInt32\|varint\|readVarint\|writeVarint\|bodyLength\|messageLength\|packetSize\|payloadSize\|dataLength\|contentLength' || true)
len_prefix_count=$(count_lines "$len_prefix")

if [[ "$len_prefix_count" -gt 0 ]]; then
  framing_patterns+="- **Length-prefixed framing**: Messages prefixed with size field (e.g., 4-byte big-endian length). $len_prefix_count references."$'\n'
fi

# Delimiter-based framing
delimiter_refs=$(search_strings '\\\\r\\\\n\|\\\\n\|\\\\0\|<EOF>\|--boundary' | head -10 || true)
delim_count=$(count_lines "$delimiter_refs")

if [[ "$delim_count" -gt 0 ]]; then
  framing_patterns+="- **Delimiter-based framing**: Messages terminated by delimiter characters."$'\n'
  framing_patterns+='```'$'\n'"$delimiter_refs"$'\n''```'$'\n'
fi

# Fixed-size messages
fixed_size=$(search_all 'sizeof\(\)|kMessageSize\|kPacketSize\|kFrameSize\|MSG_SIZE\|PACKET_SIZE\|BUFFER_SIZE' | head -10 || true)
fixed_count=$(count_lines "$fixed_size")

if [[ "$fixed_count" -gt 0 ]]; then
  framing_patterns+="- **Fixed-size messages**: Constant message/packet sizes may indicate fixed-length protocol."$'\n'
  framing_patterns+='```'$'\n'"$fixed_size"$'\n''```'$'\n'
fi

if [[ -n "$framing_patterns" ]]; then
  SERIAL_CONTENT+="### Message Framing"$'\n\n'
  SERIAL_CONTENT+="$framing_patterns"$'\n'
fi

if [[ "$json_count" -eq 0 ]] && [[ "$proto_count" -eq 0 ]] && [[ "$msgpack_count" -eq 0 ]] && [[ -z "$framing_patterns" ]]; then
  if [[ "$http_count" -gt 0 ]]; then
    SERIAL_CONTENT="JSON is likely used (standard for HTTP APIs) but no explicit JSON coding references were found (binary may strip them)."
    print_finding "FORMAT" "JSON (assumed from HTTP usage)"
  else
    SERIAL_CONTENT="No serialization format detected. Binary may be stripped or use encrypted payloads."
  fi
fi

report_section "Serialization & Message Format" "$SERIAL_CONTENT"

# =====================================================================
# 3. HTTP/REST PROTOCOL DEEP DIVE
# =====================================================================

if [[ "$DO_ALL" == true ]] || [[ "$DO_HTTP" == true ]]; then
  section_header "HTTP/REST Protocol Layer"

  HTTP_CONTENT=""

  # --- Base URLs ---
  base_urls=$(search_all 'baseURL\|base_url\|apiURL\|api_url\|serverURL\|server_url\|ENDPOINT\|API_BASE\|kAPI\|kBase\|BASE_URL\|API_URL\|SERVER_URL' || true)
  base_count=$(count_lines "$base_urls")

  if [[ "$base_count" -gt 0 ]]; then
    HTTP_CONTENT+="### Base URL Configuration"$'\n\n'
    HTTP_CONTENT+="The app configures its API base URL through these patterns:"$'\n\n'
    HTTP_CONTENT+='```'$'\n'"$base_urls"$'\n''```'$'\n\n'
  fi

  # --- API Path Patterns ---
  api_paths=$(search_all '"/api/[^"]*"\|"/v[0-9]+/[^"]*"\|"[a-z]+/[a-z]+.*path\|path.*=.*"/' || true)
  path_count=$(count_lines "$api_paths")

  if [[ "$path_count" -gt 0 ]]; then
    HTTP_CONTENT+="### API Path Patterns"$'\n\n'
    HTTP_CONTENT+='```'$'\n'"$api_paths"$'\n''```'$'\n\n'
  fi

  # --- HTTP Methods ---
  http_methods=$(search_all 'httpMethod\s*=\s*"GET"\|httpMethod\s*=\s*"POST"\|httpMethod\s*=\s*"PUT"\|httpMethod\s*=\s*"DELETE"\|httpMethod\s*=\s*"PATCH"\|\.get\|\.post\|\.put\|\.delete\|\.patch\|HTTPMethod' || true)
  method_count=$(count_lines "$http_methods")

  if [[ "$method_count" -gt 0 ]]; then
    HTTP_CONTENT+="### HTTP Methods Used"$'\n\n'
    HTTP_CONTENT+='```'$'\n'"$http_methods"$'\n''```'$'\n\n'
  fi

  # --- Request Headers ---
  req_headers=$(search_all 'setValue.*forHTTPHeaderField\|addValue.*forHTTPHeaderField\|\.headers\s*=\s*\["\|allHTTPHeaderFields\|Authorization\|Content-Type.*application\|Accept.*application\|x-api-key\|User-Agent\|X-' || true)
  header_count=$(count_lines "$req_headers")

  if [[ "$header_count" -gt 0 ]]; then
    HTTP_CONTENT+="### Request Headers"$'\n\n'
    HTTP_CONTENT+="Common HTTP headers found in the binary:"$'\n\n'
    HTTP_CONTENT+='```'$'\n'"$req_headers"$'\n''```'$'\n\n'

    # Summarize common header patterns
    HTTP_CONTENT+="**Header summary:**"$'\n'
    echo "$req_headers" | grep -oiE '(Authorization|Content-Type|Accept|User-Agent|x-api-key|x-request-id|X-[A-Za-z-]+)' | sort -u | while IFS= read -r hdr; do
      [[ -n "$hdr" ]] && HTTP_CONTENT+="- \`$hdr\`"$'\n'
    done
    HTTP_CONTENT+=$'\n'
  fi

  # --- Response Handling ---
  resp_patterns=$(search_all 'statusCode\|HTTPURLResponse\|didReceiveResponse\|responseDecodable\|responseJSON\|\.response\s*\{' || true)
  resp_count=$(count_lines "$resp_patterns")

  if [[ "$resp_count" -gt 0 ]]; then
    HTTP_CONTENT+="### Response Handling"$'\n\n'
    HTTP_CONTENT+="Response processing patterns:"$'\n\n'
    HTTP_CONTENT+='```'$'\n'"$resp_patterns"$'\n''```'$'\n\n'
  fi

  # --- Error Response Format ---
  error_patterns=$(search_all 'error.*code\|errorCode\|error_code\|message.*error\|error.*message\|\.failure\|\.serverError\|\.clientError\|unauthorized\|forbidden\|notFound\|internalServerError' || true)
  error_count=$(count_lines "$error_patterns")

  if [[ "$error_count" -gt 0 ]]; then
    HTTP_CONTENT+="### Error Response Handling"$'\n\n'
    HTTP_CONTENT+="Error handling patterns found. The API likely returns structured error responses:"$'\n\n'
    HTTP_CONTENT+='```'$'\n'"$error_patterns"$'\n''```'$'\n\n'
  fi

  # --- Pagination ---
  pagination=$(search_all 'page\|perPage\|pageSize\|limit\|offset\|cursor\|nextPage\|hasMore\|next_cursor\|totalPages\|total_count' || true)
  page_count=$(count_lines "$pagination")

  if [[ "$page_count" -gt 0 ]]; then
    HTTP_CONTENT+="### Pagination"$'\n\n'
    HTTP_CONTENT+="The API uses pagination. Parameters/fields detected:"$'\n\n'
    HTTP_CONTENT+='```'$'\n'"$pagination"$'\n''```'$'\n\n'

    # Determine pagination style
    if echo "$pagination" | grep -qi 'cursor\|next_cursor'; then
      HTTP_CONTENT+="**Pagination style**: Cursor-based"$'\n\n'
    elif echo "$pagination" | grep -qi 'page\|perPage\|pageSize'; then
      HTTP_CONTENT+="**Pagination style**: Page-based (offset/limit)"$'\n\n'
    fi
  fi

  # --- Rate Limiting ---
  rate_limit=$(search_all 'rateLimit\|rate_limit\|retryAfter\|retry_after\|x-ratelimit\|429\|tooManyRequests\|throttle' || true)
  rl_count=$(count_lines "$rate_limit")

  if [[ "$rl_count" -gt 0 ]]; then
    HTTP_CONTENT+="### Rate Limiting"$'\n\n'
    HTTP_CONTENT+="Rate limit handling detected:"$'\n\n'
    HTTP_CONTENT+='```'$'\n'"$rate_limit"$'\n''```'$'\n\n'
  fi

  if [[ "$base_count" -eq 0 ]] && [[ "$path_count" -eq 0 ]] && [[ "$method_count" -eq 0 ]]; then
    HTTP_CONTENT="No HTTP-specific patterns found in extracted data. The app may use a non-HTTP protocol or the relevant code is stripped/encrypted."
  fi

  report_section "HTTP/REST Protocol Details" "$HTTP_CONTENT"

else
  echo "  (skipped — use --http to include)"
fi

# =====================================================================
# 4. WEBSOCKET PROTOCOL DEEP DIVE
# =====================================================================

if [[ "$DO_ALL" == true ]] || [[ "$DO_WEBSOCKET" == true ]]; then
  section_header "WebSocket Protocol Layer"

  WS_CONTENT=""

  # --- Connection Details ---
  ws_connect=$(search_all 'webSocketTask\|\.connect()\|WebSocket\(url:\|initWithURL' || true)
  ws_connect_count=$(count_lines "$ws_connect")

  if [[ "$ws_connect_count" -gt 0 ]]; then
    WS_CONTENT+="### Connection Establishment"$'\n\n'
    WS_CONTENT+="WebSocket connection creation patterns:"$'\n\n'
    WS_CONTENT+='```'$'\n'"$ws_connect"$'\n''```'$'\n\n'
  fi

  # --- Message Sending ---
  ws_send=$(search_all '\.send\(.*Message\|\.write\(string:\|\.write\(data:\|\.sendPing\|\.sendPong\|\.receive\s*\{' || true)
  ws_send_count=$(count_lines "$ws_send")

  if [[ "$ws_send_count" -gt 0 ]]; then
    WS_CONTENT+="### Message Send/Receive"$'\n\n'
    WS_CONTENT+="WebSocket message I/O patterns:"$'\n\n'
    WS_CONTENT+='```'$'\n'"$ws_send"$'\n''```'$'\n\n'
  fi

  # --- Message Routing (event types) ---
  ws_events=$(search_all '\.emit\("*\|\.on\("*\|\.on\(event:\|event.*=.*"\|type.*=.*"\|action.*=.*"\|messageType\|msg_type\|\.case\s*=\s*"' || true)
  ws_events_count=$(count_lines "$ws_events")

  if [[ "$ws_events_count" -gt 0 ]]; then
    WS_CONTENT+="### Message Routing / Event Types"$'\n\n'
    WS_CONTENT+="The WebSocket protocol routes messages by event type or action field:"$'\n\n'
    WS_CONTENT+='```'$'\n'"$ws_events"$'\n''```'$'\n\n'

    # Extract event type strings
    event_types=$(echo "$ws_events" | grep -oE '"[a-z_][a-z0-9_]*(\.[a-z_][a-z0-9_]*)*"' | sort -u | head -30 || true)
    if [[ -n "$event_types" ]]; then
      WS_CONTENT+="**Detected event types:**"$'\n'
      while IFS= read -r evt; do
        [[ -n "$evt" ]] && WS_CONTENT+="- $evt"$'\n'
      done <<< "$event_types"
      WS_CONTENT+=$'\n'
    fi
  fi

  # --- Heartbeat / Ping-Pong ---
  ws_ping=$(search_all 'ping\|pong\|heartbeat\|heart_beat\|keepAlive\|keep_alive\|sendPing\|sendPong\|pingInterval\|pingSender' || true)
  ws_ping_count=$(count_lines "$ws_ping")

  if [[ "$ws_ping_count" -gt 0 ]]; then
    WS_CONTENT+="### Keepalive / Heartbeat"$'\n\n'
    WS_CONTENT+="WebSocket keepalive patterns detected:"$'\n\n'
    WS_CONTENT+='```'$'\n'"$ws_ping"$'\n''```'$'\n\n'
  fi

  # --- Reconnection ---
  ws_reconnect=$(search_all 'reconnect\|reconnectInterval\|autoReconnect\|shouldReconnect\|connectionLost\|didDisconnect\|onDisconnect' || true)
  ws_reconn_count=$(count_lines "$ws_reconnect")

  if [[ "$ws_reconn_count" -gt 0 ]]; then
    WS_CONTENT+="### Reconnection Strategy"$'\n\n'
    WS_CONTENT+="The WebSocket client implements reconnection logic:"$'\n\n'
    WS_CONTENT+='```'$'\n'"$ws_reconnect"$'\n''```'$'\n\n'
  fi

  if [[ "$ws_connect_count" -eq 0 ]] && [[ "$ws_events_count" -eq 0 ]]; then
    WS_CONTENT="No WebSocket-specific patterns detected."
  fi

  report_section "WebSocket Protocol Details" "$WS_CONTENT"

else
  echo "  (skipped — use --websocket to include)"
fi

# =====================================================================
# 5. gRPC / PROTOBUF PROTOCOL DEEP DIVE
# =====================================================================

if [[ "$DO_ALL" == true ]] || [[ "$DO_GRPC" == true ]]; then
  section_header "gRPC & Protocol Buffers Layer"

  GRPC_CONTENT=""

  # --- Service Definitions ---
  grpc_service=$(search_all 'ServiceClient\|ServiceServer\|\.async\.\|\.rx\.\|makeUnaryCall\|makeServerStreamingCall\|makeClientStreamingCall\|makeBidirectionalStreamingCall\|GRPCAsync\|GRPCClient' || true)
  grpc_svc_count=$(count_lines "$grpc_service")

  if [[ "$grpc_svc_count" -gt 0 ]]; then
    GRPC_CONTENT+="### gRPC Service Methods"$'\n\n'
    GRPC_CONTENT+="gRPC service method calls detected:"$'\n\n'
    GRPC_CONTENT+='```'$'\n'"$grpc_service"$'\n''```'$'\n\n'
  fi

  # --- Proto Messages ---
  proto_msgs=$(search_headers '@interface GPB\|@interface.*_PB\|PB_OBJECT_CLASS\|Message.*:.*NSObject\|Message.*:.*GPBMessage' || true)
  proto_msg_count=$(count_lines "$proto_msgs")

  if [[ "$proto_msg_count" -gt 0 ]]; then
    GRPC_CONTENT+="### Protobuf Message Definitions"$'\n\n'
    GRPC_CONTENT+="Generated protobuf message classes found in class-dump headers:"$'\n\n'
    GRPC_CONTENT+='```'$'\n'"$proto_msgs"$'\n''```'$'\n\n'

    # Try to reconstruct field definitions
    proto_fields=$(search_headers 'readOnly.*BOOL\|readOnly.*int32\|readOnly.*int64\|readOnly.*string\|readOnly.*bytes\|readOnly.*float\|readOnly.*double\|GPBField\|GPBMessageField\|\.array\|\.has_' || true)
    if [[ -n "$proto_fields" ]]; then
      GRPC_CONTENT+="**Protobuf field accessors:**"$'\n\n'
      GRPC_CONTENT+='```'$'\n'"$proto_fields"$'\n''```'$'\n\n'
    fi
  fi

  # --- Channel Configuration ---
  grpc_channel=$(search_all 'GRPCChannel\|GRPCHost\|host.*port\|grpcPort\|insecureChannel\|secureChannel\|GRPCManager\|GRPCService' || true)
  grpc_chan_count=$(count_lines "$grpc_channel")

  if [[ "$grpc_chan_count" -gt 0 ]]; then
    GRPC_CONTENT+="### Channel Configuration"$'\n\n'
    GRPC_CONTENT+="gRPC channel/host configuration:"$'\n\n'
    GRPC_CONTENT+='```'$'\n'"$grpc_channel"$'\n''```'$'\n\n'
  fi

  if [[ "$grpc_svc_count" -eq 0 ]] && [[ "$proto_msg_count" -eq 0 ]]; then
    GRPC_CONTENT="No gRPC or protobuf-specific patterns detected."
  fi

  report_section "gRPC/Protobuf Protocol Details" "$GRPC_CONTENT"

else
  echo "  (skipped — use --grpc to include)"
fi

# =====================================================================
# 6. CUSTOM SOCKET PROTOCOL DEEP DIVE
# =====================================================================

if [[ "$DO_ALL" == true ]] || [[ "$DO_SOCKET" == true ]]; then
  section_header "Custom Socket Protocol Layer"

  SOCK_CONTENT=""

  # --- Connection Parameters ---
  sock_conn=$(search_all 'CFStreamCreatePairWithSocketToHost\|NWEndpoint\|nw_endpoint_create_host\|connect.*port\|getaddrinfo.*port\|sockaddr_in' || true)
  sock_conn_count=$(count_lines "$sock_conn")

  if [[ "$sock_conn_count" -gt 0 ]]; then
    SOCK_CONTENT+="### Connection Parameters"$'\n\n'
    SOCK_CONTENT+="Socket connection setup detected:"$'\n\n'
    SOCK_CONTENT+='```'$'\n'"$sock_conn"$'\n''```'$'\n\n'
  fi

  # --- Send/Recv Buffer Analysis ---
  sock_io=$(search_all 'send\(\|recv\(\|write\(\|read\(\|CFWriteStreamWrite\|CFReadStreamRead\|nw_connection_send\|nw_connection_receive' || true)
  sock_io_count=$(count_lines "$sock_io")

  if [[ "$sock_io_count" -gt 0 ]]; then
    SOCK_CONTENT+="### Socket I/O Operations"$'\n\n'
    SOCK_CONTENT+="Low-level socket read/write patterns:"$'\n\n'
    SOCK_CONTENT+='```'$'\n'"$sock_io"$'\n''```'$'\n\n'

    # Look for buffer size constants near I/O
    sock_buf_sizes=$(search_all 'kRecvBuf\|kSendBuf\|RECV_BUF\|SEND_BUF\|MAX_PACKET\|MAX_MESSAGE\|buf\[[0-9]+\]\|bufferSize.*=[0-9]' || true)
    if [[ -n "$sock_buf_sizes" ]]; then
      SOCK_CONTENT+="**Buffer size constants:**"$'\n\n'
      SOCK_CONTENT+='```'$'\n'"$sock_buf_sizes"$'\n''```'$'\n\n'
    fi
  fi

  # --- TLS/SSL on Socket ---
  sock_tls=$(search_all 'SSLSetEnabledCiphers\|SSLContext\|SecTrust\|kCFStreamPropertySocketSecurityLevel\|kCFStreamSSL\|tls_ciphersuite\|startTLS' || true)
  sock_tls_count=$(count_lines "$sock_tls")

  if [[ "$sock_tls_count" -gt 0 ]]; then
    SOCK_CONTENT+="### TLS/SSL Configuration"$'\n\n'
    SOCK_CONTENT+="Custom socket uses TLS encryption:"$'\n\n'
    SOCK_CONTENT+='```'$'\n'"$sock_tls"$'\n''```'$'\n\n'
  fi

  # --- Framing Details ---
  sock_frame=$(search_all 'messageLength\|packetLength\|msgLength\|bodyLength\|readHeader\|parseHeader\|writeHeader\|messageType\|msgType\|packetType\|command\|CMD_' || true)
  sock_frame_count=$(count_lines "$sock_frame")

  if [[ "$sock_frame_count" -gt 0 ]]; then
    SOCK_CONTENT+="### Message Framing"$'\n\n'
    SOCK_CONTENT+="Custom protocol message framing:"$'\n\n'
    SOCK_CONTENT+='```'$'\n'"$sock_frame"$'\n''```'$'\n\n'
  fi

  if [[ "$sock_conn_count" -eq 0 ]] && [[ "$sock_io_count" -eq 0 ]]; then
    SOCK_CONTENT="No custom socket protocol patterns detected."
  fi

  report_section "Custom Socket Protocol Details" "$SOCK_CONTENT"

else
  echo "  (skipped — use --socket to include)"
fi

# =====================================================================
# 7. AUTHENTICATION STATE MACHINE
# =====================================================================

section_header "Authentication State Machine"

echo "Reconstructing authentication flow..."
echo

AUTH_CONTENT=""

# --- Login Request ---
login_patterns=$(search_all 'login\|signIn\|sign_in\|authenticate\|logon\|LoginRequest\|SignInRequest\|AuthRequest' || true)
login_count=$(count_lines "$login_patterns")

# --- Token Handling ---
token_patterns=$(search_all 'accessToken\|access_token\|refreshToken\|refresh_token\|idToken\|id_token\|bearer\|Bearer\|JWT\|oauth\|OAuth\|token.*=.*"\|setToken\|saveToken\|storeToken' || true)
token_count=$(count_lines "$token_patterns")

# --- Token Storage ---
token_storage=$(search_all 'KeychainWrapper\|KeychainAccess\|SecItemAdd.*token\|SAMKeychain\|UserDefaults.*token\|UserDefaults.*Token\|\.set\(.*token\|token.*UserDefaults\|NSUbiquitousKeyValueStore' || true)
storage_count=$(count_lines "$token_storage")

# --- Token Refresh ---
refresh_patterns=$(search_all 'refreshToken\|refresh_token\|refreshAuth\|renewToken\|tokenExpired\|token.*expir\|401\|unauthorized\|didExpire\|isExpired' || true)
refresh_count=$(count_lines "$refresh_patterns")

# --- Auth Headers ---
auth_headers=$(search_all 'Authorization\|authorization\|Bearer\|bearer\|x-api-key\|x-auth\|x-access-token\|Authentication' || true)
auth_header_count=$(count_lines "$auth_headers")

# --- Build State Machine ---
AUTH_CONTENT+="### Authentication Flow"$'\n\n'

if [[ "$login_count" -gt 0 ]]; then
  AUTH_CONTENT+="#### Login Request"$'\n\n'
  AUTH_CONTENT+="The app sends a login/authentication request. Patterns found:"$'\n\n'
  AUTH_CONTENT+='```'$'\n'"$login_patterns"$'\n''```'$'\n\n'

  # Try to extract login parameters
  login_params=$(search_all '"email"\|"password"\|"username"\|"phone"\|"code"\|"captcha"\|"smsCode"\|"verificationCode"' | head -20 || true)
  if [[ -n "$login_params" ]]; then
    AUTH_CONTENT+="**Likely login parameters:**"$'\n'
    echo "$login_params" | grep -oE '"[a-zA-Z]+"' | sort -u | while IFS= read -r param; do
      [[ -n "$param" ]] && AUTH_CONTENT+="- $param"$'\n'
    done
    AUTH_CONTENT+=$'\n'
  fi
fi

if [[ "$token_count" -gt 0 ]]; then
  AUTH_CONTENT+="#### Token Acquisition"$'\n\n'
  AUTH_CONTENT+="After successful authentication, the app receives and processes tokens:"$'\n\n'
  AUTH_CONTENT+='```'$'\n'"$token_patterns"$'\n''```'$'\n\n'
fi

if [[ "$storage_count" -gt 0 ]]; then
  AUTH_CONTENT+="#### Token Storage"$'\n\n'
  AUTH_CONTENT+="Tokens are persisted using:"$'\n\n'
  AUTH_CONTENT+='```'$'\n'"$token_storage"$'\n''```'$'\n\n'

  if echo "$token_storage" | grep -qi 'Keychain\|SecItemAdd\|SAMKeychain'; then
    AUTH_CONTENT+="**Storage mechanism**: Keychain (secure)"$'\n\n'
  elif echo "$token_storage" | grep -qi 'UserDefaults\|NSUserDefaults'; then
    AUTH_CONTENT+="**Storage mechanism**: UserDefaults (insecure — consider Keychain for SDK)"$'\n\n'
  fi
fi

if [[ "$refresh_count" -gt 0 ]]; then
  AUTH_CONTENT+="#### Token Refresh"$'\n\n'
  AUTH_CONTENT+="The app handles token expiration and refresh:"$'\n\n'
  AUTH_CONTENT+='```'$'\n'"$refresh_patterns"$'\n''```'$'\n\n'
fi

if [[ "$auth_header_count" -gt 0 ]]; then
  AUTH_CONTENT+="#### Auth Header Injection"$'\n\n'
  AUTH_CONTENT+="Authentication is attached to requests via:"$'\n\n'
  AUTH_CONTENT+='```'$'\n'"$auth_headers"$'\n''```'$'\n\n'
fi

# --- State Machine Diagram ---
AUTH_CONTENT+="### State Machine"$'\n\n'
AUTH_CONTENT+='```'$'\n'
AUTH_CONTENT+="                    ┌──────────────────────────┐"$'\n'
AUTH_CONTENT+="                    │     UNAUTHENTICATED       │"$'\n'
AUTH_CONTENT+="                    │  (no token / token exp)   │"$'\n'
AUTH_CONTENT+="                    └──────────┬───────────────┘"$'\n'
AUTH_CONTENT+="                               │"$'\n'
AUTH_CONTENT+="                     login(email, password)"$'\n'
AUTH_CONTENT+="                               │"$'\n'
AUTH_CONTENT+="                               ▼"$'\n'
AUTH_CONTENT+="                    ┌──────────────────────────┐"$'\n'
if [[ "$refresh_count" -gt 0 ]]; then
  AUTH_CONTENT+="         ┌─────────│      AUTHENTICATED        │◄────────┐"$'\n'
  AUTH_CONTENT+="         │         │  (valid access token)     │         │"$'\n'
  AUTH_CONTENT+="         │         └──────────┬───────────────┘         │"$'\n'
  AUTH_CONTENT+="         │                    │                          │"$'\n'
  AUTH_CONTENT+="         │           token expires / 401                 │"$'\n'
  AUTH_CONTENT+="         │                    │                          │"$'\n'
  AUTH_CONTENT+="         │                    ▼                          │"$'\n'
  AUTH_CONTENT+="         │         ┌──────────────────────────┐         │"$'\n'
  AUTH_CONTENT+="         │         │    TOKEN REFRESHING       │─────────┘"$'\n'
  AUTH_CONTENT+="         │         │ (refresh_token request)   │   success"$'\n'
  AUTH_CONTENT+="         │         └──────────┬───────────────┘"$'\n'
  AUTH_CONTENT+="         │                    │"$'\n'
  AUTH_CONTENT+="         │             refresh fails"$'\n'
  AUTH_CONTENT+="         │                    │"$'\n'
  AUTH_CONTENT+="         └────────────────────┘"$'\n'
else
  AUTH_CONTENT+="                    │      AUTHENTICATED        │"$'\n'
  AUTH_CONTENT+="                    │  (valid access token)     │"$'\n'
  AUTH_CONTENT+="                    └──────────────────────────┘"$'\n'
fi
AUTH_CONTENT+="                               │"$'\n'
AUTH_CONTENT+="                     logout / clear token"$'\n'
AUTH_CONTENT+="                               │"$'\n'
AUTH_CONTENT+="                               ▼"$'\n'
AUTH_CONTENT+="                    (back to UNAUTHENTICATED)"$'\n'
AUTH_CONTENT+='```'$'\n\n'

if [[ "$login_count" -eq 0 ]] && [[ "$token_count" -eq 0 ]]; then
  AUTH_CONTENT="No authentication patterns detected. The app may use no auth, device-based auth, or the relevant code is stripped."
fi

report_section "Authentication State Machine" "$AUTH_CONTENT"

# =====================================================================
# 8. SESSION LIFECYCLE
# =====================================================================

section_header "Session Lifecycle"

LIFECYCLE_CONTENT=""

# --- Connection Lifecycle ---
lifecycle_patterns=$(search_all 'didConnect\|onConnect\|didDisconnect\|onDisconnect\|connectionLost\|networkReachable\|reachabilityChanged\|didBecomeActive\|willResignActive\|didEnterBackground\|willEnterForeground' || true)
lifecycle_count=$(count_lines "$lifecycle_patterns")

# --- Retry / Backoff ---
retry_patterns=$(search_all 'retry\|retryCount\|maxRetry\|retryDelay\|backoff\|exponentialBackoff\|jitter\|retryAfter' || true)
retry_count=$(count_lines "$retry_patterns")

# --- Timeouts ---
timeout_patterns=$(search_all 'timeout\|timeoutInterval\|requestTimeout\|connectTimeout\|socketTimeout\|TimeoutInterval' || true)
timeout_count=$(count_lines "$timeout_patterns")

LIFECYCLE_CONTENT+="### Connection Lifecycle"$'\n\n'

if [[ "$lifecycle_count" -gt 0 ]]; then
  LIFECYCLE_CONTENT+="The app manages connection state through these patterns:"$'\n\n'
  LIFECYCLE_CONTENT+='```'$'\n'"$lifecycle_patterns"$'\n''```'$'\n\n'
fi

LIFECYCLE_CONTENT+='```'$'\n'
LIFECYCLE_CONTENT+="DISCONNECTED ⟶ CONNECTING ⟶ CONNECTED ⟶ AUTHENTICATED"$'\n'
LIFECYCLE_CONTENT+="     ▲                            │"$'\n'
LIFECYCLE_CONTENT+="     │                            │ (optional auth)"$'\n'
LIFECYCLE_CONTENT+="     │                            ▼"$'\n'
LIFECYCLE_CONTENT+="     └────────── DISCONNECTED ◄─── AUTHENTICATED"$'\n'
LIFECYCLE_CONTENT+="                  (error / timeout / background)"$'\n'
LIFECYCLE_CONTENT+='```'$'\n\n'

if [[ "$retry_count" -gt 0 ]]; then
  LIFECYCLE_CONTENT+="### Retry & Backoff Strategy"$'\n\n'
  LIFECYCLE_CONTENT+="The app implements retry logic:"$'\n\n'
  LIFECYCLE_CONTENT+='```'$'\n'"$retry_patterns"$'\n''```'$'\n\n'
fi

if [[ "$timeout_count" -gt 0 ]]; then
  LIFECYCLE_CONTENT+="### Timeout Configuration"$'\n\n'
  LIFECYCLE_CONTENT+="Timeout values found:"$'\n\n'
  LIFECYCLE_CONTENT+='```'$'\n'"$timeout_patterns"$'\n''```'$'\n\n'
fi

report_section "Session Lifecycle" "$LIFECYCLE_CONTENT"

# =====================================================================
# 9. SDK IMPLEMENTATION NOTES
# =====================================================================

section_header "SDK Implementation Notes"

SDK_CONTENT=""

SDK_CONTENT+="The following notes are generated to guide AI in creating a client SDK wrapper for this protocol."$'\n\n'

# Transport recommendations
SDK_CONTENT+="### Recommended Transport Library"$'\n\n'

if [[ "$http_count" -gt 0 ]]; then
  SDK_CONTENT+="- **Primary**: URLSession (Foundation) — native, well-supported, handles HTTP/HTTPS"$'\n'
  if echo "$http_urls" | grep -qi 'alamofire\|AF\.'; then
    SDK_CONTENT+="- **Alternative**: Alamofire — already used by the app for request management"$'\n'
  fi
fi

if [[ "$ws_count" -gt 0 ]] || [[ "$ws_lib_count" -gt 0 ]]; then
  SDK_CONTENT+="- **WebSocket**: URLSessionWebSocketTask (native iOS 13+) — or Starscream for broader compatibility"$'\n'
fi

if [[ "$grpc_count" -gt 0 ]]; then
  SDK_CONTENT+="- **gRPC**: grpc-swift or SwiftGRPC — use the extracted proto definitions"$'\n'
fi

if [[ "$socket_count" -gt 3 ]]; then
  SDK_CONTENT+="- **Custom Socket**: Network.framework (NWConnection) — modern replacement for raw sockets"$'\n'
fi

if [[ "$mqtt_count" -gt 0 ]]; then
  SDK_CONTENT+="- **MQTT**: CocoaMQTT or MQTTClient — native Swift/ObjC MQTT libraries"$'\n'
fi

SDK_CONTENT+=$'\n'

# Serialization recommendations
SDK_CONTENT+="### Serialization"$'\n\n'

if [[ "$json_count" -gt 0 ]]; then
  SDK_CONTENT+="- Use \`Codable\` (JSONDecoder/JSONEncoder) for type-safe JSON serialization"$'\n'
fi
if [[ "$proto_count" -gt 0 ]]; then
  SDK_CONTENT+="- Use SwiftProtobuf or GPBMessage for protobuf message serialization"$'\n'
  SDK_CONTENT+="- Recompile \`.proto\` files with \`protoc\` to generate Swift message types"$'\n'
fi
if [[ "$msgpack_count" -gt 0 ]]; then
  SDK_CONTENT+="- Use MessagePack encoder/decoder library for binary serialization"$'\n'
fi

SDK_CONTENT+=$'\n'

# Auth implementation guidance
SDK_CONTENT+="### Authentication"$'\n\n'

if [[ "$token_count" -gt 0 ]]; then
  SDK_CONTENT+="- Implement \`AuthInterceptor\` protocol (or \`RequestAdapter\`/\`RequestRetrier\` for Alamofire)"$'\n'
  SDK_CONTENT+="- Store tokens in Keychain (use \`SecItemAdd\`/\`SecItemCopyMatching\`)"$'\n'
  SDK_CONTENT+="- Auto-refresh tokens on 401 response using refresh token"$'\n'
  SDK_CONTENT+="- Queue pending requests during token refresh to avoid race conditions"$'\n'
fi

if [[ "$refresh_count" -gt 0 ]]; then
  SDK_CONTENT+="- Token refresh endpoint: extract from auth flow above"$'\n'
  SDK_CONTENT+="- Refresh before expiry (e.g., 5 minutes before \`expires_in\`)"$'\n'
fi

SDK_CONTENT+=$'\n'

# Thread safety
SDK_CONTENT+="### Thread Safety"$'\n\n'
SDK_CONTENT+="- All network callbacks should dispatch to a designated serial queue"$'\n'
SDK_CONTENT+="- Use \`@MainActor\` for UI-bound state updates"$'\n'
SDK_CONTENT+="- Token refresh must be serialized (only one refresh at a time)"$'\n'
SDK_CONTENT+=$'\n'

# Error handling
SDK_CONTENT+="### Error Handling"$'\n\n'
SDK_CONTENT+="- Define a typed error enum covering: network errors, HTTP status errors, protocol errors, auth errors"$'\n'
SDK_CONTENT+="- Parse error response bodies for server-side error codes and messages"$'\n'
SDK_CONTENT+="- Implement retry with exponential backoff for transient failures (5xx, network errors)"$'\n'
SDK_CONTENT+="- Do not retry client errors (4xx, except 429 rate limit)"$'\n'
SDK_CONTENT+=$'\n'

# Reconnection
if [[ "$ws_count" -gt 0 ]] || [[ "$socket_count" -gt 3 ]]; then
  SDK_CONTENT+="### Reconnection Strategy"$'\n\n'
  SDK_CONTENT+="- Exponential backoff with jitter (e.g., 1s, 2s, 4s, 8s, max 60s)"$'\n'
  SDK_CONTENT+="- Reset backoff on successful connection"$'\n'
  SDK_CONTENT+="- Re-authenticate after reconnect if session tokens are still valid"$'\n'
  SDK_CONTENT+="- Monitor reachability to trigger reconnect on network restoration"$'\n'
  SDK_CONTENT+=$'\n'
fi

# API style recommendation
SDK_CONTENT+="### Recommended SDK API Style"$'\n\n'
SDK_CONTENT+="Based on the detected patterns, the SDK should expose:"$'\n\n'
SDK_CONTENT+="\`\`\`swift"$'\n'
SDK_CONTENT+="// Async/await API (modern Swift)"$'\n'
SDK_CONTENT+="public final class AppClient {"$'\n'
SDK_CONTENT+="    public init(configuration: Configuration)"$'\n'
SDK_CONTENT+="    public func login(email: String, password: String) async throws -> AuthToken"$'\n'
SDK_CONTENT+="    // ... protocol-specific methods"$'\n'
SDK_CONTENT+="}"$'\n'
SDK_CONTENT+="\`\`\`"$'\n\n'

report_section "SDK Implementation Guidance" "$SDK_CONTENT"

# =====================================================================
# FINAL SUMMARY
# =====================================================================

report_summary

echo
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║              Protocol Extraction Complete                    ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo
echo "Protocols detected: ${#PROTOCOL_TYPES_FOUND[@]}"
for entry in "${PROTOCOL_TYPES_FOUND[@]}"; do
  echo "  - $entry"
done
echo

if [[ -n "$REPORT_FILE" ]]; then
  {
    echo
    echo "---"
    echo
    echo "_Protocol specification generated by ios-reverse-engineering-skill. This document is designed for AI consumption — feed it to an LLM along with the prompt: \"Write a Swift client SDK that implements this communication protocol.\"_"
  } >> "$REPORT_FILE"
  echo -e "${GREEN}Report saved to: $REPORT_FILE${NC}"
  echo
  echo "To generate SDK code from this spec, give the report to an AI with:"
  echo "  \"Write a Swift client SDK that implements this communication protocol.\""
else
  echo -e "${YELLOW}Tip: Use --report protocol-spec.md to save the full AI-friendly specification.${NC}"
fi

# =====================================================================
# SUMMARY GENERATION — concise doc for AI prompt chaining
# =====================================================================

if [[ -n "$SUMMARY_FILE" ]]; then
  echo
  echo -e "${BLUE}Generating concise summary for AI prompt chaining...${NC}"

  # --- Helper: extract a section from the report ---
  extract_report_section() {
    local heading="$1"
    if [[ -n "$REPORT_FILE" ]] && [[ -f "$REPORT_FILE" ]]; then
      awk -v h="$heading" '
        $0 ~ "^## "h"$" { found=1; next }
        found && /^## / { exit }
        found { print }
      ' "$REPORT_FILE" 2>/dev/null || true
    fi
  }

  # --- Determine transport ---
  SUMMARY_TRANSPORT=""
  if [[ "$http_count" -gt 0 ]]; then
    SUMMARY_TRANSPORT="HTTPS (REST)"
  fi
  if [[ "$ws_count" -gt 0 ]] || [[ "$ws_lib_count" -gt 0 ]]; then
    [[ -n "$SUMMARY_TRANSPORT" ]] && SUMMARY_TRANSPORT+=" + "
    SUMMARY_TRANSPORT+="WebSocket (wss://)"
  fi
  if [[ "$grpc_count" -gt 0 ]]; then
    [[ -n "$SUMMARY_TRANSPORT" ]] && SUMMARY_TRANSPORT+=" + "
    SUMMARY_TRANSPORT+="gRPC"
  fi
  if [[ "$mqtt_count" -gt 0 ]]; then
    [[ -n "$SUMMARY_TRANSPORT" ]] && SUMMARY_TRANSPORT+=" + "
    SUMMARY_TRANSPORT+="MQTT"
  fi
  if [[ "$socket_count" -gt 3 ]]; then
    [[ -n "$SUMMARY_TRANSPORT" ]] && SUMMARY_TRANSPORT+=" + "
    SUMMARY_TRANSPORT+="Custom TCP Socket"
  fi
  [[ -z "$SUMMARY_TRANSPORT" ]] && SUMMARY_TRANSPORT="Unknown (binary may be stripped)"

  # --- Determine serialization ---
  SUMMARY_SERIALIZATION=""
  if [[ "$json_count" -gt 0 ]]; then
    SUMMARY_SERIALIZATION="JSON (Codable/JSONDecoder)"
  fi
  if [[ "$proto_count" -gt 0 ]]; then
    [[ -n "$SUMMARY_SERIALIZATION" ]] && SUMMARY_SERIALIZATION+=" + "
    SUMMARY_SERIALIZATION+="Protocol Buffers"
  fi
  if [[ "$msgpack_count" -gt 0 ]]; then
    [[ -n "$SUMMARY_SERIALIZATION" ]] && SUMMARY_SERIALIZATION+=" + "
    SUMMARY_SERIALIZATION+="MessagePack"
  fi
  [[ -z "$SUMMARY_SERIALIZATION" ]] && SUMMARY_SERIALIZATION="JSON (assumed)"

  # --- Determine auth ---
  SUMMARY_AUTH="None detected"
  if [[ "$token_count" -gt 0 ]]; then
    if echo "$token_patterns" | grep -qi 'bearer\|Bearer'; then
      SUMMARY_AUTH="Bearer Token"
    elif echo "$token_patterns" | grep -qi 'x-api-key\|api_key\|apikey'; then
      SUMMARY_AUTH="API Key Header"
    elif echo "$token_patterns" | grep -qi 'jwt\|JWT'; then
      SUMMARY_AUTH="JWT Bearer Token"
    else
      SUMMARY_AUTH="Token-based (scheme unclear)"
    fi
  fi

  SUMMARY_TOKEN_STORAGE="Unknown"
  if [[ "$storage_count" -gt 0 ]]; then
    if echo "$token_storage" | grep -qi 'Keychain\|SecItemAdd\|SAMKeychain\|KeychainWrapper\|Valet'; then
      SUMMARY_TOKEN_STORAGE="Keychain (secure)"
    elif echo "$token_storage" | grep -qi 'UserDefaults\|NSUserDefaults'; then
      SUMMARY_TOKEN_STORAGE="UserDefaults (insecure)"
    fi
  fi

  SUMMARY_HAS_REFRESH="No"
  [[ "$refresh_count" -gt 0 ]] && SUMMARY_HAS_REFRESH="Yes"

  # --- Extract base URLs ---
  SUMMARY_BASE_URLS=""
  if [[ "$http_count" -gt 0 ]]; then
    SUMMARY_BASE_URLS=$(echo "$http_urls" | grep -oE 'https?://[^/"]+' | sort -u | head -5 | while read -r u; do echo "$u"; done || true)
  fi

  # --- Extract notable endpoints (from strings and class-dump) ---
  SUMMARY_ENDPOINTS=""
  if [[ "$http_count" -gt 0 ]]; then
    # Try to extract method + path patterns
    SUMMARY_ENDPOINTS=$(search_all '"/[a-z0-9_/-]+"' 2>/dev/null | \
      grep -oE '"/[a-z0-9_/-]{3,}"' | \
      grep -vE '/(usr|bin|var|etc|tmp|dev|System|Library|Applications|private)/' | \
      sort -u | head -20 || true)

    if [[ -z "$SUMMARY_ENDPOINTS" ]]; then
      # Try extracting path components from URLs
      SUMMARY_ENDPOINTS=$(echo "$http_urls" | grep -oE 'https?://[^"]+' | \
        sed 's|https\?://[^/]*||' | sort -u | head -20 || true)
    fi
  fi

  # --- Extract WebSocket events ---
  SUMMARY_WS_EVENTS=""
  if [[ "$ws_events_count" -gt 0 ]]; then
    SUMMARY_WS_EVENTS=$(echo "$ws_events" | grep -oE '"[a-z_][a-z0-9_]*(\.[a-z_][a-z0-9_]*)*"' | sort -u | head -20 || true)
  fi

  # --- Write the summary ---
  {
    echo "# Protocol Summary: ${APP_NAME}"
    echo
    echo "> Concise briefing for AI prompt chaining. Feed this document to an LLM with:"
    echo "> \"Based on this protocol summary, generate a Swift client SDK.\""
    echo
    echo "---"
    echo
    echo "## Quick Facts"
    echo
    echo "| Property | Value |"
    echo "|----------|-------|"
    echo "| Transport | ${SUMMARY_TRANSPORT} |"
    echo "| Serialization | ${SUMMARY_SERIALIZATION} |"
    echo "| Auth Scheme | ${SUMMARY_AUTH} |"
    echo "| Token Storage | ${SUMMARY_TOKEN_STORAGE} |"
    echo "| Token Refresh | ${SUMMARY_HAS_REFRESH} |"

    # Add base URLs
    if [[ -n "$SUMMARY_BASE_URLS" ]]; then
      echo "| Base URL(s) | $(echo "$SUMMARY_BASE_URLS" | head -3 | tr '\n' ' ' | sed 's/  */, /g' | sed 's/, $//') |"
    fi

    # Add WebSocket summary
    if [[ "$ws_count" -gt 0 ]] || [[ "$ws_lib_count" -gt 0 ]]; then
      echo "| WebSocket | Yes ($ws_count URLs, $ws_lib_count library refs) |"
    fi

    echo
    echo "---"
    echo
    echo "## Endpoints / Messages"
    echo

    if [[ "$http_count" -gt 0 ]] && [[ -n "$SUMMARY_ENDPOINTS" ]]; then
      echo "### HTTP Endpoints"
      echo
      echo "| Path | Notes |"
      echo "|------|-------|"
      echo "$SUMMARY_ENDPOINTS" | while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        path_clean=$(echo "$path" | tr -d '"')
        echo "| \`${path_clean}\` | |"
      done
      echo
    fi

    if [[ -n "$SUMMARY_WS_EVENTS" ]]; then
      echo "### WebSocket Event Types"
      echo
      echo "| Event | Direction | Notes |"
      echo "|-------|-----------|-------|"
      echo "$SUMMARY_WS_EVENTS" | while IFS= read -r evt; do
        [[ -z "$evt" ]] && continue
        evt_clean=$(echo "$evt" | tr -d '"')
        echo "| \`${evt_clean}\` | | |"
      done
      echo
    fi

    if [[ "$grpc_count" -gt 0 ]]; then
      echo "### gRPC Service Methods"
      echo
      echo '```'
      echo "$grpc_service" | head -15
      echo '```'
      echo
    fi

    echo "---"
    echo
    echo "## Authentication Flow"
    echo
    echo '```'
    if [[ "$token_count" -gt 0 ]]; then
      echo "1. Login: POST /auth/login (or similar) with credentials"
      echo "2. Receive: { access_token, refresh_token?, expires_in? }"
      echo "3. Store: ${SUMMARY_TOKEN_STORAGE}"
      echo "4. Attach: Authorization: ${SUMMARY_AUTH} header on all requests"
      if [[ "$SUMMARY_HAS_REFRESH" == "Yes" ]]; then
        echo "5. Refresh: On 401, POST /auth/refresh (or similar) with refresh_token"
        echo "6. Retry: Original request with new access_token"
        echo "7. Logout: Clear stored tokens → UNAUTHENTICATED"
      fi
    else
      echo "No authentication detected (or stripped binary)"
    fi
    echo '```'
    echo

    echo "---"
    echo
    echo "## Key Data Types"
    echo
    echo "Based on detected patterns, the following types likely need to be defined:"
    echo

    if [[ "$token_count" -gt 0 ]]; then
      echo "- **LoginRequest**: credentials payload (email, password, phone, etc.)"
      echo "- **AuthToken**: access_token, refresh_token?, expires_in?, token_type"
    fi

    if [[ "$http_count" -gt 0 ]]; then
      echo "- **APIError**: error code, message, details (from error response body)"
      echo "- **Pagination<T>**: page/offset/cursor + items array"
    fi

    if [[ "$proto_count" -gt 0 ]]; then
      echo "- **Protobuf Messages**: Recompile .proto files to generate Swift types"
      echo
      echo "Proto files referenced:"
      echo "$proto_files" | while IFS= read -r pf; do
        [[ -n "$pf" ]] && echo "  - ${pf}"
      done
    fi

    echo
    echo "---"
    echo
    echo "## SDK Implementation Checklist"
    echo
    echo "Use this checklist to guide the SDK implementation:"
    echo

    echo "### Transport Layer"
    echo "- [ ] Configure URLSession with appropriate timeout and caching"
    if [[ "$ws_count" -gt 0 ]] || [[ "$ws_lib_count" -gt 0 ]]; then
      echo "- [ ] Set up WebSocket connection with URLSessionWebSocketTask or Starscream"
    fi
    if [[ "$socket_count" -gt 3 ]]; then
      echo "- [ ] Implement custom socket connection with Network.framework (NWConnection)"
    fi
    echo

    echo "### Serialization"
    if [[ "$json_count" -gt 0 ]]; then
      echo "- [ ] Define Codable request/response types matching the API schema"
      echo "- [ ] Configure JSONEncoder/JSONDecoder with appropriate key strategies"
    fi
    if [[ "$proto_count" -gt 0 ]]; then
      echo "- [ ] Compile .proto files with protoc and integrate generated Swift types"
    fi
    echo

    echo "### Authentication"
    if [[ "$token_count" -gt 0 ]]; then
      echo "- [ ] Implement login function taking credentials, returning AuthToken"
      echo "- [ ] Store tokens in Keychain (SecItemAdd/SecItemCopyMatching)"
      echo "- [ ] Implement RequestInterceptor/Adapter to inject Authorization header"
      if [[ "$SUMMARY_HAS_REFRESH" == "Yes" ]]; then
        echo "- [ ] Implement token refresh interceptor (serialized, only one refresh at a time)"
        echo "- [ ] Queue pending requests during refresh, then retry with new token"
      fi
      echo "- [ ] Implement logout (clear Keychain, cancel pending requests)"
    fi
    echo

    echo "### Error Handling"
    echo "- [ ] Define typed ClientError enum (network, http, server, auth, decoding)"
    echo "- [ ] Parse server error response body for error codes/messages"
    echo "- [ ] Retry on 5xx and network errors with exponential backoff"
    echo "- [ ] Do NOT retry on 4xx (except 429 rate limit)"
    echo

    echo "### Thread Safety"
    echo "- [ ] Use actor for token store to serialize refresh"
    echo "- [ ] Callbacks on a dedicated serial queue, not main"
    echo "- [ ] @MainActor only for UI-bound published state"
    echo

    if [[ "$ws_count" -gt 0 ]] || [[ "$socket_count" -gt 3 ]]; then
      echo "### Connection Lifecycle"
      echo "- [ ] Implement exponential backoff reconnection (1s → 2s → 4s → ... → 60s max)"
      echo "- [ ] Monitor NWPathMonitor for reachability changes"
      echo "- [ ] Re-authenticate after successful reconnect"
      echo
    fi

    echo "### API Style"
    echo "- [ ] Use Swift async/await (modern, no callback nesting)"
    echo "- [ ] Return Result<T, ClientError> or throw typed errors"
    echo "- [ ] Public API: \`AppClient\` class with configuration struct"
    echo

    echo "---"
    echo
    echo "## LLM Prompt Template"
    echo
    echo "Copy this entire document and append:"
    echo
    echo "> Based on the protocol summary above, write a complete Swift client SDK."
    echo "> Use async/await, URLSession, and follow the SDK Implementation Checklist."
    echo "> Include: configuration, auth interceptor with token refresh, error handling, and retry logic."
    echo "> Generate all necessary Codable types, the public API class, and usage examples."
    echo
    echo "---"
    echo "_Summary generated by ios-reverse-engineering-skill_"
  } > "$SUMMARY_FILE"

  echo -e "${GREEN}Summary saved to: $SUMMARY_FILE${NC}"
  echo
  echo "To generate SDK code, feed the summary to an AI with:"
  echo "  \"Based on this protocol summary, write a complete Swift client SDK.\""
fi
