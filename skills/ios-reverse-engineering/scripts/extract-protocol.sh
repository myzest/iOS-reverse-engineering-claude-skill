#!/usr/bin/env bash
# extract-protocol.sh — Discover networking-related files in extracted iOS app output.
# This script DISCOVERS and CATEGORIZES files; it does NOT analyze protocol content.
# The AI reads the discovered files and performs intelligent protocol analysis.
#
# Architecture: Script discovers files → AI reads files → AI writes protocol spec
# Compatible with bash 3.2+ (macOS default)
set -euo pipefail

usage() {
  cat <<EOF
Usage: extract-protocol.sh <analysis-dir> [OPTIONS]

Discover networking and protocol-related files in an extracted iOS app.
Categorizes class-dump headers, extracts relevant strings, and produces
a structured reading guide for AI-driven protocol analysis.

Architecture: Script discovers files -> AI reads files -> AI produces protocol spec

Arguments:
  <analysis-dir>    Path to the analysis output directory (from extract-ipa.sh)

Options:
  -o, --output DIR  Output directory (default: <analysis-dir>/protocol-analysis/)
  -h, --help        Show this help message

Output:
  protocol-guide.md       Structured reading plan for AI
  file-index.md           Complete categorized file list
  relevant-strings.txt    Protocol-related strings from binary
EOF
  exit 0
}

# =====================================================================
# Argument parsing
# =====================================================================

ANALYSIS_DIR=""
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output) OUTPUT_DIR="$2"; shift 2 ;;
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

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$ANALYSIS_DIR/protocol-analysis"
fi
mkdir -p "$OUTPUT_DIR"

# =====================================================================
# Setup
# =====================================================================

CLASSDUMP_DIR=""
if [[ -d "$ANALYSIS_DIR/class-dump" ]]; then
  FIRST_SUBDIR=$(find "$ANALYSIS_DIR/class-dump" -maxdepth 1 -type d ! -name class-dump 2>/dev/null | head -1)
  if [[ -n "$FIRST_SUBDIR" ]] && [[ -d "$FIRST_SUBDIR" ]]; then
    CLASSDUMP_DIR="$FIRST_SUBDIR"
  else
    CLASSDUMP_DIR="$ANALYSIS_DIR/class-dump"
  fi
fi

STRINGS_RAW="$ANALYSIS_DIR/strings-raw.txt"
STRINGS_URLS="$ANALYSIS_DIR/strings-urls-and-keys.txt"
LINKED_LIBS="$ANALYSIS_DIR/linked-libraries.txt"
SYMBOLS="$ANALYSIS_DIR/symbols-demangled.txt"
[[ ! -f "$SYMBOLS" ]] && SYMBOLS="$ANALYSIS_DIR/symbols.txt"

APP_NAME=""
if [[ -f "$ANALYSIS_DIR/Info.plist" ]] && command -v plutil &>/dev/null; then
  APP_NAME=$(plutil -extract CFBundleDisplayName raw "$ANALYSIS_DIR/Info.plist" 2>/dev/null || \
             plutil -extract CFBundleName raw "$ANALYSIS_DIR/Info.plist" 2>/dev/null || echo "")
fi
[[ -z "$APP_NAME" ]] && APP_NAME=$(basename "$ANALYSIS_DIR" | sed 's/-analysis$//')

echo "=== Protocol File Discovery: $APP_NAME ==="
echo "Class-dump dir: ${CLASSDUMP_DIR:-none}"
echo "Output: $OUTPUT_DIR"
echo

# =====================================================================
# Category definitions — parallel indexed arrays (bash 3.2 compatible)
# =====================================================================

CAT_NAMES=()
CAT_REGEX=()
CAT_PRIO=()
CAT_HINT=()

add_category() {
  CAT_NAMES+=("$1")
  CAT_REGEX+=("$2")
  CAT_PRIO+=("$3")
  CAT_HINT+=("$4")
}

add_category "HTTP_API_Client" '(API|APIClient|Network|Networking|HTTP|Http|Request|Response|URLSession|Alamofire|Moya|AFNetworking|REST|Rest|EndPoint)' 1 \
  "Core HTTP networking — base URL config, request building, response handling"

add_category "Auth" '(Auth|Login|SignIn|SignUp|Register|Token|OAuth|SSO|Account|Session|Credential)' 1 \
  "Authentication flow — login, token handling, session management"

add_category "Service_Layer" '(Service|Repository|DataProvider|RemoteDataSource)' 2 \
  "Service classes wrapping API calls with business logic"

add_category "WebSocket" '(WebSocket|SocketIO|SocketRocket|Starscream|Realtime|Live|IM|Message|Chat|Push|Streaming|WS)' 2 \
  "Real-time communication — WebSocket connections, message routing, events"

add_category "Socket_Custom" '(AsyncSocket|TcpClient|TcpServer|UdpSocket|NWConnection|CFStream|SipSocket|TXCAsync)' 3 \
  "Custom TCP/UDP socket protocols — raw I/O, framing, binary protocols"

add_category "gRPC_Protobuf" '(GRPC|gRPC|Protobuf|ProtoMessage|GPB|pb_|\.pb\.|ProtoRPC)' 3 \
  "gRPC services and Protocol Buffers message definitions"

add_category "MQTT" '(MQTT|Mqtt|CocoaMQTT|MqttClient|MqttSession)' 3 \
  "MQTT protocol — broker connection, topic subscription, publish"

add_category "GraphQL" '(GraphQL|Apollo|Query|Mutation|Subscription|GQL)' 3 \
  "GraphQL queries, mutations, and subscriptions"

add_category "Serialization" '(Model|Entity|DTO|Codable|Decodable|Encodable|JSON|Serializable|Mappable|GPBMessage|Message\b)' 4 \
  "Data models and serialization — request/response body structures"

CAT_COUNT=${#CAT_NAMES[@]}

# =====================================================================
# Content grep tags — parallel arrays
# =====================================================================

CT_TAGS=()
CT_PATTERNS=()

add_ct() {
  CT_TAGS+=("$1")
  CT_PATTERNS+=("$2")
}

add_ct "URLSession_users"     'URLSession|NSURLSession|URLRequest|dataTask|uploadTask'
add_ct "WebSocket_users"      'URLSessionWebSocketTask|webSocketTask|\.send.*Message|\.receive.*Message|WebSocketDelegate|SRWebSocket'
add_ct "gRPC_users"           'makeUnaryCall|makeServerStreamingCall|GRPCChannel|ClientConnection'
add_ct "Socket_IO_users"      'send\(|recv\(|CFReadStreamRead|CFWriteStreamWrite|nw_connection_send|nw_connection_receive'
add_ct "Auth_flow_users"      'Keychain|SecItemAdd|SecItemCopyMatching|tokenExpired|refreshToken|Authorization.*Bearer'

CT_COUNT=${#CT_TAGS[@]}

# =====================================================================
# File Discovery by filename pattern
# =====================================================================

echo "--- Discovering by filename ---"
TOTAL=0

TMPDIR_CAT="$OUTPUT_DIR/.tmp-categories"
rm -rf "$TMPDIR_CAT"
mkdir -p "$TMPDIR_CAT"

for ((i=0; i<CAT_COUNT; i++)); do
  name="${CAT_NAMES[$i]}"
  regex="${CAT_REGEX[$i]}"
  prio="${CAT_PRIO[$i]}"

  results=""
  if [[ -d "$CLASSDUMP_DIR" ]]; then
    results=$(find "$CLASSDUMP_DIR" -name "*.h" -type f 2>/dev/null | while IFS= read -r f; do
      bn=$(basename "$f" .h)
      if echo "$bn" | grep -qiE "$regex"; then
        echo "$f"
      fi
    done || true)
  fi

  if [[ -n "$results" ]]; then
    echo "$results" > "$TMPDIR_CAT/${i}_files.txt"
  else
    touch "$TMPDIR_CAT/${i}_files.txt"
  fi

  count=0
  [[ -s "$TMPDIR_CAT/${i}_files.txt" ]] && count=$(wc -l < "$TMPDIR_CAT/${i}_files.txt" | tr -d ' ')
  TOTAL=$((TOTAL + count))
  echo "  $name: $count files (P$prio)"
done

echo "  => $TOTAL total files"
echo

# =====================================================================
# Additional discovery: grep inside headers to find networking API users
# =====================================================================

echo "--- Discovering by API usage (content grep) ---"

for ((i=0; i<CT_COUNT; i++)); do
  tag="${CT_TAGS[$i]}"
  pattern="${CT_PATTERNS[$i]}"
  data=""
  if [[ -d "$CLASSDUMP_DIR" ]]; then
    data=$(grep -rEl "$pattern" "$CLASSDUMP_DIR" 2>/dev/null | head -50 || true)
  fi
  if [[ -n "$data" ]]; then
    echo "$data" > "$TMPDIR_CAT/content_${tag}.txt"
  else
    touch "$TMPDIR_CAT/content_${tag}.txt"
  fi
  count=0
  [[ -s "$TMPDIR_CAT/content_${tag}.txt" ]] && count=$(wc -l < "$TMPDIR_CAT/content_${tag}.txt" | tr -d ' ')
  echo "  $tag: $count files"
done

echo

# =====================================================================
# Extract relevant strings
# =====================================================================

echo "--- Extracting relevant strings ---"

RELEVANT="$OUTPUT_DIR/relevant-strings.txt"
{
  echo "# Protocol-Relevant Strings — $APP_NAME"
  echo "# Extracted: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "# These strings may contain URLs, endpoints, auth tokens, protocol constants."
  echo

  if [[ -f "$STRINGS_URLS" ]]; then
    echo "## URLs and API Keys (from strings-urls-and-keys.txt)"
    echo
    head -500 "$STRINGS_URLS"
    echo
  elif [[ -f "$STRINGS_RAW" ]]; then
    echo "## URLs (from raw strings)"
    grep -iE 'https?://|api[_.-]|/v[0-9]+/|\.com/|wss?://' "$STRINGS_RAW" 2>/dev/null | head -500 || true
    echo
  fi

  if [[ -f "$STRINGS_RAW" ]]; then
    echo "## Auth & Token"
    grep -iE 'token|auth|login|signin|signup|register|password|credential|bearer|oauth|jwt|key|secret' "$STRINGS_RAW" 2>/dev/null | head -200 || true
    echo
    echo "## Protocol Constants"
    grep -iE 'MSG_|CMD_|PACKET_|TIMEOUT|BUFFER_SIZE|MAX_LEN|HEADER_SIZE|BODY_SIZE' "$STRINGS_RAW" 2>/dev/null | head -200 || true
    echo
  fi

  if [[ -f "$SYMBOLS" ]]; then
    echo "## Relevant Symbols"
    grep -iE 'api|network|http|socket|connect|request|response|auth|login|token|message|send|receive|protocol|serialize|encode|decode' "$SYMBOLS" 2>/dev/null | head -300 || true
    echo
  fi
} > "$RELEVANT"

echo "  Saved: $(wc -l < "$RELEVANT" | tr -d ' ') lines"

# =====================================================================
# Linked networking libraries
# =====================================================================

NETWORK_LIBS=""
if [[ -f "$LINKED_LIBS" ]]; then
  NETWORK_LIBS=$(grep -iE 'CFNetwork|Alamofire|AFNetworking|Moya|Starscream|SocketRocket|Apollo|GRPC|Protobuf|CocoaMQTT|Agora|WebRTC|LiveKit|SocketIO' "$LINKED_LIBS" 2>/dev/null || true)
fi

# =====================================================================
# Generate: Reading Guide (main AI prompt)
# =====================================================================

echo "--- Generating reading guide ---"

GUIDE="$OUTPUT_DIR/protocol-guide.md"

{
  echo "# Protocol Reverse Engineering Guide: $APP_NAME"
  echo
  echo "> **For the AI**: This is a structured reading plan. Read the files listed in each section,"
  echo "> understand the protocol they implement, and document your findings incrementally."
  echo "> After completing all sections, produce a final protocol specification."
  echo
  echo "**Generated**: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "**Analysis base**: \`$ANALYSIS_DIR\`"
  echo "**Discovered**: $TOTAL files across $CAT_COUNT categories"
  echo
  echo "---"
  echo
  echo "## 1. Reading Plan"
  echo
  echo "Before reading individual files, get context from:"
  echo
  echo "1. **Info.plist** — App identity, URL schemes, ATS configuration → \`$ANALYSIS_DIR/Info.plist\`"
  echo "2. **Relevant strings** — URLs, endpoints, auth patterns → \`$RELEVANT\`"
  echo "3. **Linked libraries** — Which networking libs are linked → \`$LINKED_LIBS\`"
  echo

  if [[ -n "$NETWORK_LIBS" ]]; then
    echo "### Detected Networking Libraries"
    echo
    echo '```'
    echo "$NETWORK_LIBS" | head -30
    echo '```'
    echo
    echo "These libraries suggest the following protocol families:"
    echo
    # Pre-compute hints to avoid SIGPIPE in pipe chain inside { } redirect
    LIB_HINTS=$(echo "$NETWORK_LIBS" | head -30 | while IFS= read -r lib; do
      ll=$(echo "$lib" | tr '[:upper:]' '[:lower:]')
      if echo "$ll" | grep -qi 'alamofire\|moya\|afnetworking'; then
        echo "- \`$lib\` → HTTP REST API client"
      elif echo "$ll" | grep -qi 'starscream\|socketrocket\|socketio'; then
        echo "- \`$lib\` → WebSocket real-time protocol"
      elif echo "$ll" | grep -qi 'grpc\|protobuf\|swiftprotobuf'; then
        echo "- \`$lib\` → gRPC / Protocol Buffers"
      elif echo "$ll" | grep -qi 'agora\|webrtc\|livekit'; then
        echo "- \`$lib\` → Real-time audio/video (WebRTC/UDP)"
      elif echo "$ll" | grep -qi 'mqtt\|cocoamqtt'; then
        echo "- \`$lib\` → MQTT publish/subscribe"
      elif echo "$ll" | grep -qi 'apollo\|graphql'; then
        echo "- \`$lib\` → GraphQL"
      elif echo "$ll" | grep -qi 'cfnetwork'; then
        echo "- \`$lib\` → Foundation networking (URLSession)"
      fi
    done || true)
    echo "$LIB_HINTS"
    echo
  fi

  echo "---"
  echo
  echo "## 2. File Categories (read in priority order)"
  echo

  for priority in 1 2 3 4; do
    for ((i=0; i<CAT_COUNT; i++)); do
      cat_name="${CAT_NAMES[$i]}"
      cat_prio="${CAT_PRIO[$i]}"
      cat_hint="${CAT_HINT[$i]}"

      if [[ "$cat_prio" != "$priority" ]]; then
        continue
      fi

      files_file="$TMPDIR_CAT/${i}_files.txt"
      [[ ! -s "$files_file" ]] && continue

      count=$(wc -l < "$files_file" | tr -d ' ')

      echo "### Priority $priority: $cat_name ($count files)"
      echo
      echo "**Goal**: $cat_hint"
      echo
      echo "**Key files** (start with these):"
      echo

      while IFS= read -r f; do
        bn=$(basename "$f" .h)
        if ! echo "$bn" | grep -qiE 'PodsDummy|Pods_|^_TtP'; then
          echo "- [ ] \`$f\`"
        fi
      done < "$files_file" | head -15

      if [[ "$count" -gt 15 ]]; then
        echo
        echo "<details>"
        echo "<summary>All $count files</summary>"
        echo
        while IFS= read -r f; do
          echo "- \`$f\`"
        done < "$files_file"
        echo
        echo "</details>"
      fi
      echo
    done
  done

  # Content-grep discovered files
  echo "---"
  echo
  echo "## 3. Additional Files (API users not caught by filename)"
  echo
  echo "These files use networking APIs but weren't categorized by filename."
  echo

  for ((i=0; i<CT_COUNT; i++)); do
    tag="${CT_TAGS[$i]}"
    data_file="$TMPDIR_CAT/content_${tag}.txt"
    [[ ! -s "$data_file" ]] && continue
    count=$(wc -l < "$data_file" | tr -d ' ')
    echo "### $tag ($count files)"
    echo
    head -20 "$data_file" | while IFS= read -r f; do
      echo "- \`$f\`"
    done
    echo
  done

  echo "---"
  echo
  echo "## 4. Analysis & Output Instructions"
  echo
  echo "### For each discovered file, note:"
  echo
  echo "- **Which protocol** does it implement? (HTTP REST, WebSocket, gRPC, custom socket, MQTT)"
  echo "- **What role** does it play? (Client setup, request builder, response handler, message router)"
  echo "- **What are the key methods**? (connect, disconnect, send, receive, login, refresh)"
  echo "- **What types** does it reference? (Request/Response models, Codable structs, Protobuf messages)"
  echo "- **How does it handle auth**? (Token injection, refresh interceptor, keychain storage)"
  echo "- **Cross-reference** with \`relevant-strings.txt\` for actual URL/endpoint values"
  echo
  echo "### Produce a protocol specification with:"
  echo
  echo "1. **Protocol Overview** — Transport, serialization format, auth scheme"
  echo "2. **Connection Spec** — Base URLs, ports, TLS config"
  echo "3. **Authentication** — Login flow (real field names), token storage, refresh mechanism"
  echo "4. **Message Catalog** — Per message: direction, trigger, wire format, field schema, example payload"
  echo "5. **Error Handling** — Error response format, error code mapping"
  echo "6. **Session Lifecycle** — Connect → Auth → Heartbeat → Reconnect → Disconnect"
  echo "7. **SDK Guidance** — Recommended libraries, thread safety, reconnection strategy"
  echo
  echo "---"
  echo "_Generated by ios-reverse-engineering-skill. Feed this file to an AI to perform protocol analysis._"
} > "$GUIDE"

# =====================================================================
# Generate: File Index (full reference)
# =====================================================================

INDEX="$OUTPUT_DIR/file-index.md"

{
  echo "# Protocol File Index: $APP_NAME"
  echo
  echo "Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo

  for ((i=0; i<CAT_COUNT; i++)); do
    cat_name="${CAT_NAMES[$i]}"
    files_file="$TMPDIR_CAT/${i}_files.txt"
    [[ ! -s "$files_file" ]] && continue
    count=$(wc -l < "$files_file" | tr -d ' ')
    echo "## $cat_name ($count files)"
    echo
    while IFS= read -r f; do
      echo "- \`$f\`"
    done < "$files_file"
    echo
  done

  for ((i=0; i<CT_COUNT; i++)); do
    tag="${CT_TAGS[$i]}"
    data_file="$TMPDIR_CAT/content_${tag}.txt"
    [[ ! -s "$data_file" ]] && continue
    count=$(wc -l < "$data_file" | tr -d ' ')
    echo "## $tag ($count files)"
    echo
    while IFS= read -r f; do
      echo "- \`$f\`"
    done < "$data_file"
    echo
  done
} > "$INDEX"

# =====================================================================
# Summary
# =====================================================================

echo
echo "========================================="
echo "  Protocol File Discovery Complete"
echo "========================================="
echo
echo "Found $TOTAL files across $CAT_COUNT categories"
echo

for ((i=0; i<CAT_COUNT; i++)); do
  cat_name="${CAT_NAMES[$i]}"
  cat_prio="${CAT_PRIO[$i]}"
  files_file="$TMPDIR_CAT/${i}_files.txt"
  if [[ -s "$files_file" ]]; then
    count=$(wc -l < "$files_file" | tr -d ' ')
    echo "  $cat_name: $count files (P$cat_prio)"
  fi
done

echo
echo "Output:"
echo "  $GUIDE   ← Feed this to AI"
echo "  $INDEX   ← Full reference"
echo "  $RELEVANT   ← Related strings"
echo
echo "Next step:"
echo
echo "  Give protocol-guide.md to an AI with:"
echo '  "Follow this protocol reverse engineering guide, read each file, and produce a protocol specification."'
