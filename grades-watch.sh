#!/data/data/com.termux/files/usr/bin/bash
#=======================================================================
#  grades-watch.sh -- log in, fetch student profile, watch grades (Termux)
#
#  Flow:
#    1. Prompt for username + password (only if no saved credentials).
#    2. POST  {host}/api/user/login        {"username","password"} -> token
#    3. GET   {host}/api/students/self     (Bearer token) -> profile + id
#       Log selected profile fields (firstName, lastName, ... faculty.*).
#    4. GET   {host}/Api/Grades?StudentId={id}  (Bearer token) every 5 min,
#       compare via CRC32 (cksum), notify per new/changed grade:
#         title:    علامة جديدة للسنة 3
#         content:  اتصالات رقمية و تشابهية 25 نظري + 20 عملي = 45
#
#  Credentials (username, password, token) are stored AES-256-CBC encrypted
#  via openssl; a random key file (chmod 600) lives next to them. The token
#  is auto-refreshed (re-login) on HTTP 401.
#
#  One-time setup in Termux:
#      pkg install curl jq openssl termux-api
#      # plus the "Termux:API" companion app (same store as Termux).
#      bash grades-watch.sh --test-notify
#
#  Run (interactively the first time to save credentials):
#      bash grades-watch.sh --host api.example.com
#      # then background (wake lock + channel are set up automatically):
#      nohup bash grades-watch.sh --host api.example.com >>grades.log 2>&1 &
#
#  State lives in ~/.grades-watch/; delete it to reset.
#=======================================================================

set -u

#----------------------------- defaults --------------------------------
INTERVAL=300                # seconds between polls (default: 5 minutes)
ONCE=0                      # 1 = single check, then exit
TEST_NOTIFY=0
HOST=""                     # API host (--host)
CHANNEL="NewGrade"         # Android notification channel
UA_OPTS=(-A "okhttp/3.14.9")   # User-Agent matching the mobile app

#------------------------------ globals --------------------------------
HTTP_CODE=""
RESULT=""
USERNAME=""
PASSWORD=""
TOKEN=""
STUDENT_ID=""
BASE_URL=""
GRADES_URL=""

#------------------------------ helpers ---------------------------------
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

usage() {
cat <<'EOF'
Usage: grades-watch.sh --host HOST [options]

Required:
  --host HOST         API host, e.g. city-uni-api.example.com

Optional:
  --interval SECONDS  polling interval (default: 300 = 5 minutes)
  --once              perform a single check, then exit
  --test-notify       send a sample notification, then exit
  -h, --help          show this help

Credentials are prompted interactively on first run and stored encrypted
in ~/.grades-watch/. The token is auto-refreshed on HTTP 401.
EOF
}

need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency '$1' (fix: pkg install $1)"; }

#--------------------------- core functions ----------------------------

notify() {  # $1 = title, $2 = content
  if command -v termux-notification >/dev/null 2>&1; then
    local out
    if out=$(termux-notification --title "$1" --content "$2" \
        --channel "$CHANNEL" --icon input --sound 2>&1); then
      return 0
    fi
    log "termux-notification failed: $out"
  fi
  log "NOTIFY | $1 | $2"   # fallback when Termux:API is unavailable
}

error_state() {  # $1 = short reason; notifies once per failure streak; sets RESULT
  RESULT="error: $1"
  if [ ! -e "$ERR_LATCH" ]; then
    : > "$ERR_LATCH"
    notify "خطأ في جلب العلامات" "$1"
  fi
}

maybe_gunzip() {  # $1 = file: decompress it if it is still gzip-compressed
  [ -s "$1" ] || return 0
  if [ "$(head -c 2 "$1" | od -An -tx1 | tr -d ' \n')" = "1f8b" ]; then
    gunzip -c "$1" > "$1.dec" 2>/dev/null && mv -f "$1.dec" "$1" || rm -f "$1.dec"
  fi
}

# Authenticated GET (Bearer token + gzip). $1 = full URL, $2 = output file.
curl_get() {
  HTTP_CODE=$(curl -sS ${UA_OPTS+"${UA_OPTS[@]}"} \
    --compressed \
    --connect-timeout 15 --max-time 60 \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept-Encoding: gzip" \
    -o "$2" -w '%{http_code}' \
    "$1") || HTTP_CODE=""
  maybe_gunzip "$2"
}

parse_entries() {  # $1 = JSON file; stdout: "name \x01 practical \x01 theoretical" lines
  jq -r '
    .[] |
    [ ((.file.name // "") | gsub("\\s+"; " ")),
      ((.grades[0].practicalMark   // "") | tostring),
      ((.grades[0].theoreticalMark // "") | tostring) ] |
    join("\u0001")
  ' "$1"
}

notify_entry() {  # $1 = course/file name, $2 = practical, $3 = theoretical
  local name=$1 p=$2 t=$3 subject year sum title content
  # name layout: "faculty - subject - exam session - year" (split on " - ")
  subject=$(printf '%s' "$name" | awk -F' - ' 'NF>=2 {print $2; exit}')
  year=$(printf '%s'    "$name" | awk -F' - ' 'NF>=4 {print $4; exit}')
  [ -n "$subject" ] || subject=$name
  [ -n "$p" ] || p=0
  [ -n "$t" ] || t=0
  sum=$(awk -v a="$p" -v b="$t" 'BEGIN { printf "%g", a + b }')
  if [ -n "$year" ]; then title="علامة جديدة $year"; else title="علامة جديدة"; fi
  content="$subject $t نظري + $p عملي = $sum"   # swap labels here if needed
  notify "$title" "$content"
}

check_once() {
  local body entries new_ck notified line name p t rc
  body=$(mktemp) || { RESULT="error: mktemp failed"; return 1; }

  curl_get "$GRADES_URL" "$body"
  rc=$?
  if [ "$rc" -ne 0 ] && [ "$HTTP_CODE" = "" -o "$HTTP_CODE" = "000" ]; then
    error_state "network error / timeout (curl exit $rc)"
    rm -f "$body"; return 0
  fi
  case $HTTP_CODE in
    200) ;;
    401)
      if refresh_login; then
        :  # RESULT already set; next cycle retries with the fresh token
      else
        error_state "login failed during token refresh (401)"
      fi
      rm -f "$body"; return 0
      ;;
    ""|000) error_state "no response (network down?)"; rm -f "$body"; return 0 ;;
    *) error_state "HTTP $HTTP_CODE"; rm -f "$body"; return 0 ;;
  esac

  if ! entries=$(parse_entries "$body"); then
    error_state "response was not the expected JSON"
    rm -f "$body"; return 0
  fi
  rm -f "$ERR_LATCH"    # healthy again

  new_ck=$(cksum < "$body" | cut -d' ' -f1)

  # fast path: CRC32 of the response unchanged since last successful poll
  if [ -f "$CKSUM_FILE" ] && [ "$(cat "$CKSUM_FILE")" = "$new_ck" ]; then
    RESULT="no change"
    rm -f "$body"; return 0
  fi

  # first successful poll for this host+id: save a baseline, stay quiet
  if [ ! -f "$ENTRIES_FILE" ]; then
    printf '%s\n' "$entries" > "$ENTRIES_FILE"
    printf '%s\n' "$new_ck"   > "$CKSUM_FILE"
    RESULT="baseline saved ($(printf '%s\n' "$entries" | grep -c .) entries)"
    rm -f "$body"; return 0
  fi

  # API suddenly returned an empty list: suspicious, keep the old state
  if [ -z "$entries" ] && [ -s "$ENTRIES_FILE" ]; then
    RESULT="empty list (keeping previous state)"
    rm -f "$body"; return 0
  fi

  # notify for every entry that is new or whose marks changed
  notified=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    grep -qxF -- "$line" "$ENTRIES_FILE" && continue
    IFS=$'\x01' read -r name p t <<< "$line"
    [ -n "$p" ] || [ -n "$t" ] || continue    # marks not posted yet
    notify_entry "$name" "$p" "$t"
    notified=$((notified + 1))
  done <<< "$entries"

  printf '%s\n' "$entries" > "$ENTRIES_FILE"
  printf '%s\n' "$new_ck"   > "$CKSUM_FILE"
  RESULT="$notified notification(s) sent"
  rm -f "$body"
  return 0
}

#------------------------- credential functions ------------------------

do_login() {  # POST /api/user/login; sets TOKEN; returns 0 on success
  local payload body code
  payload=$(jq -n --arg u "$USERNAME" --arg p "$PASSWORD" '{username:$u, password:$p}') || return 1
  body=$(mktemp) || return 1
  code=$(curl -sS ${UA_OPTS+"${UA_OPTS[@]}"} --compressed \
    --connect-timeout 15 --max-time 60 \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Accept-Encoding: gzip" \
    -d "$payload" \
    -o "$body" -w '%{http_code}' \
    "$BASE_URL/api/user/login") || code=""
  maybe_gunzip "$body"
  if [ "$code" != "200" ]; then
    rm -f "$body"; return 1
  fi
  TOKEN=$(jq -r '.token // empty' "$body" 2>/dev/null) || { rm -f "$body"; return 1; }
  rm -f "$body"
  [ -n "$TOKEN" ] || return 1
  return 0
}

load_creds() {  # decrypt saved creds -> USERNAME, PASSWORD, TOKEN; 1 if none/bad
  [ -f "$CREDS_FILE" ] && [ -f "$KEYFILE" ] || return 1
  local plain
  plain=$(openssl enc -d -aes-256-cbc -pass file:"$KEYFILE" -in "$CREDS_FILE" 2>/dev/null) || return 1
  { read -r USERNAME; read -r PASSWORD; read -r TOKEN; } <<< "$plain"
  [ -n "$USERNAME" ] && [ -n "$PASSWORD" ] || return 1
  return 0
}

save_creds() {  # encrypt USERNAME, PASSWORD, TOKEN to CREDS_FILE
  [ -f "$KEYFILE" ] || { openssl rand -hex 32 > "$KEYFILE" && chmod 600 "$KEYFILE"; }
  printf '%s\n%s\n%s\n' "$USERNAME" "$PASSWORD" "$TOKEN" \
    | openssl enc -aes-256-cbc -salt -pass file:"$KEYFILE" -out "$CREDS_FILE" 2>/dev/null
  chmod 600 "$CREDS_FILE" 2>/dev/null || true
}

refresh_login() {  # re-login on 401; updates TOKEN + saved creds; sets RESULT
  if ! do_login; then
    RESULT="error: login failed during token refresh (401)"
    return 1
  fi
  save_creds
  rm -f "$ERR_LATCH"
  RESULT="token refreshed after 401; will retry next cycle"
  return 0
}

fetch_student_self() {  # GET /api/students/self; logs profile; sets STUDENT_ID
  local body code
  body=$(mktemp) || return 1
  curl_get "$BASE_URL/api/students/self" "$body"
  code=$HTTP_CODE
  if [ "$code" = "401" ]; then
    rm -f "$body"
    if refresh_login; then
      body=$(mktemp) || return 1
      curl_get "$BASE_URL/api/students/self" "$body"
      code=$HTTP_CODE
    else
      rm -f "$body"; return 1
    fi
  fi
  if [ "$code" != "200" ]; then
    rm -f "$body"; return 1
  fi
  STUDENT_ID=$(jq -r '.id // empty' "$body" 2>/dev/null) || { rm -f "$body"; return 1; }
  jq -r '
    "firstName: \(.firstName // "")",
    "lastName: \(.lastName // "")",
    "nationalId: \(.nationalId // "")",
    "registrationDate: \(.registrationDate // "")",
    "id: \(.id // "")",
    "createdAt: \(.createdAt // "")",
    "universityNumber: \(.universityNumber // "")",
    "ministerialNumber: \(.ministerialNumber // "")",
    "year: \(.year // "")",
    "username: \(.username // "")",
    "email: \(.email // "")",
    "faculty.arabicName: \(.faculty.arabicName // "")",
    "faculty.englishName: \(.faculty.englishName // "")"
  ' "$body" >&2
  rm -f "$body"
  [ -n "$STUDENT_ID" ] || return 1
  return 0
}

#-------------------------------- main ----------------------------------

main() {
  # --- parse arguments ---
  while [ $# -gt 0 ]; do
    case $1 in
      --host)        [ $# -ge 2 ] || die "--host requires a value"; HOST=$2; shift 2 ;;
      --host=*)      HOST=${1#*=}; shift ;;
      --interval)    [ $# -ge 2 ] || die "--interval requires a value"; INTERVAL=$2; shift 2 ;;
      --interval=*)  INTERVAL=${1#*=}; shift ;;
      --once)        ONCE=1; shift ;;
      --test-notify) TEST_NOTIFY=1; shift ;;
      -h|--help)     usage; exit 0 ;;
      *)             usage >&2; die "unknown option: $1" ;;
    esac
  done

  # --- sample notification (verifies the Termux:API setup) ---
  if [ "$TEST_NOTIFY" -eq 1 ]; then
    notify "علامة جديدة للسنة 3" "اتصالات رقمية و تشابهية 20 نظري + 25 عملي = 45"
    exit 0
  fi

  # --- validate options ---
  case $INTERVAL in ''|*[!0-9]*) die "--interval must be a whole number of seconds" ;; esac
  [ "$INTERVAL" -ge 5 ] || die "--interval must be at least 5 seconds"
  [ -n "$HOST" ] || { usage >&2; die "--host is required"; }

  need curl
  need jq
  need openssl

  # --- build base URL ---
  HOST=${HOST,,}     # lowercase
  HOST=${HOST%/}     # drop a trailing slash
  case $HOST in
    http://*|https://*) BASE_URL=$HOST ;;
    *)                  BASE_URL="https://$HOST" ;;
  esac

  # --- state directory + credential paths ---
  STATE_DIR="$HOME/.grades-watch"
  mkdir -p "$STATE_DIR" || die "cannot create $STATE_DIR"
  chmod 700 "$STATE_DIR" 2>/dev/null || true
  KEYFILE="$STATE_DIR/key"
  HOST_HASH=$(printf '%s' "$BASE_URL" | cksum | cut -d' ' -f1)
  CREDS_FILE="$STATE_DIR/creds.$HOST_HASH.enc"
  ERR_LATCH="$STATE_DIR/$HOST_HASH.err"   # available before student id is known

  # --- create the Android notification channel (silent) ---
  if command -v termux-notification-channel >/dev/null 2>&1; then
    termux-notification-channel "$CHANNEL" "$CHANNEL" > /dev/null 2>&1 || true
  fi

  # --- acquire wake lock (silent) ---
  if command -v termux-wake-lock >/dev/null 2>&1; then
    termux-wake-lock 2>/dev/null || true
  fi
  cleanup() { command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock 2>/dev/null; }
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  # --- load saved credentials or prompt ---
  if ! load_creds; then
    printf 'No saved credentials for %s. Please log in.\n' "$BASE_URL" >&2
    read -r -p "Username: " USERNAME
    read -r -s -p "Password: " PASSWORD; echo
    if ! do_login; then
      die "login failed (check username, password, and host)"
    fi
    save_creds
    log "credentials saved (encrypted): $CREDS_FILE"
  fi

  # --- fetch student profile (also validates the token; refreshes on 401) ---
  if ! fetch_student_self; then
    die "failed to fetch /api/students/self (HTTP $HTTP_CODE)"
  fi

  # --- build the grades URL ---
  GRADES_URL="$BASE_URL/Api/Grades?StudentId=$STUDENT_ID"
  STATE_KEY=$(printf '%s' "$GRADES_URL" | cksum | cut -d' ' -f1)
  CKSUM_FILE="$STATE_DIR/$STATE_KEY.cksum"
  ENTRIES_FILE="$STATE_DIR/$STATE_KEY.entries"

  log "watching $GRADES_URL every ${INTERVAL}s (state: $STATE_DIR)"
  CHECK_N=0
  while :; do
    CHECK_N=$((CHECK_N + 1))
    check_once
    log "check #$CHECK_N: $RESULT"
    [ "$ONCE" -eq 1 ] && break
    sleep "$INTERVAL"
  done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
