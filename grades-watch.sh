#!/data/data/com.termux/files/usr/bin/bash
#=======================================================================
#  grades-watch.sh -- watch a grades API and notify on new marks (Termux)
#
#  Polls  GET {host}/Api/Grades?StudentId={id}
#         Authorization: Bearer {auth}
#         Accept-Encoding: gzip          (default curl User-Agent)
#  every 5 minutes (configurable), compares the response against the
#  previous one (CRC32 via cksum -- available in Termux out of the box),
#  and fires one Android notification per new or updated grade:
#
#      title:    علامة جديدة للسنة 3
#      content:  اتصالات رقمية و تشابهية 25+20=45
#
#  One-time setup in Termux:
#      pkg install curl jq termux-api
#      # plus install the "Termux:API" companion app (from the same
#      # store you installed Termux from), then verify:
#      bash grades-watch.sh --test-notify
#
#  Run:
#      bash grades-watch.sh --auth TOKEN --host api.example.com --id 1111111111111111111
#
#      # background (a wake lock is acquired automatically so polling
#      # continues with the screen off; keep Termux out of battery
#      # optimization so Android doesn't kill it):
#      nohup bash grades-watch.sh --auth TOKEN --host api.example.com \
#            --id 1111111111111111111 >>grades.log 2>&1 &
#
#  Notes:
#    * The first successful poll only saves a baseline (no notification).
#    * State lives in ~/.grades-watch/, keyed by host+id; delete that
#      directory to force a fresh baseline.
#    * Marks are shown as  practical+theoretical=sum  -- swap $p and $t
#      in notify_entry() if you prefer the opposite order.
#=======================================================================

set -u

#----------------------------- defaults --------------------------------
INTERVAL=300            # seconds between polls (default: 5 minutes)
ONCE=0                  # 1 = single check, then exit
TEST_NOTIFY=0
AUTH=""                 # bearer token   (--auth)
HOST=""                 # API host       (--host)
STUDENT_ID=""           # student id     (--id)
UA_OPTS=(-A "okhttp/3.14.9")              # empty = curl's default User-Agent ("curl/x.y");
                        # e.g. UA_OPTS=(-A "Mozilla/5.0 (Android 14; Mobile)")
                        # to send a browser User-Agent instead.

#------------------------------ helpers --------------------------------
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

usage() {
cat <<'EOF'
Usage: grades-watch.sh --auth TOKEN --host HOST --id STUDENT_ID [options]

Required:
  --auth TOKEN        Bearer token for the Authorization header
  --host HOST         API host, e.g. api.example.com (https:// is assumed;
                      prefix http:// explicitly for a plain-HTTP host)
  --id STUDENT_ID     StudentId query parameter

Optional:
  --interval SECONDS  polling interval (default: 300 = 5 minutes)
  --once              perform a single check, then exit
  --test-notify       send a sample notification, then exit
  -h, --help          show this help
EOF
}

need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency '$1' (fix: pkg install $1)"; }

#--------------------------- core functions ----------------------------

notify() {  # $1 = title, $2 = content
  if command -v termux-notification >/dev/null 2>&1; then
    local out
    if out=$(termux-notification --title "$1" --content "$2" 2>&1); then
      return 0
    fi
    log "termux-notification failed: $out"
  fi
  log "NOTIFY | $1 | $2"   # fallback when Termux:API is unavailable
}

error_state() {  # $1 = short reason; notifies only once per failure streak
  log "ERROR: $1"
  if [ ! -e "$ERR_LATCH" ]; then
    : > "$ERR_LATCH"
    notify "خطأ في جلب العلامات" "$1"
  fi
}

fetch() {  # $1 = output file; sets global HTTP_CODE
  HTTP_CODE=$(curl -sS ${UA_OPTS+"${UA_OPTS[@]}"} \
    --compressed \
    --connect-timeout 15 --max-time 60 \
    -H "Authorization: Bearer ${AUTH}" \
    -H "Accept-Encoding: gzip" \
    -o "$1" -w '%{http_code}' \
    "$GRADES_URL")
}

maybe_gunzip() {  # $1 = file: decompress it if it is still gzip-compressed
  [ -s "$1" ] || return 0
  if [ "$(head -c 2 "$1" | od -An -tx1 | tr -d ' \n')" = "1f8b" ]; then
    gunzip -c "$1" > "$1.dec" 2>/dev/null && mv -f "$1.dec" "$1" || rm -f "$1.dec"
  fi
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
  content="$subject $p+$t=$sum"    # swap $p/$t here to flip the order
  notify "$title" "$content"
}

check_once() {
  local body entries new_ck notified line name p t rc
  body=$(mktemp) || { log "ERROR: mktemp failed"; return 1; }

  fetch "$body"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    error_state "network error / timeout (curl exit $rc)"
    rm -f "$body"; return 0
  fi
  case $HTTP_CODE in
    200) ;;
    ""|000) error_state "no response (network down?)"; rm -f "$body"; return 0 ;;
    *) error_state "HTTP $HTTP_CODE (bad token or host?)"; rm -f "$body"; return 0 ;;
  esac

  maybe_gunzip "$body"

  if ! entries=$(parse_entries "$body"); then
    error_state "response was not the expected JSON"
    rm -f "$body"; return 0
  fi
  rm -f "$ERR_LATCH"    # healthy again

  new_ck=$(cksum < "$body" | cut -d' ' -f1)

  # fast path: CRC32 of the response unchanged since last successful poll
  if [ -f "$CKSUM_FILE" ] && [ "$(cat "$CKSUM_FILE")" = "$new_ck" ]; then
    rm -f "$body"; return 0
  fi

  # first successful poll for this host+id: save a baseline, stay quiet
  if [ ! -f "$ENTRIES_FILE" ]; then
    printf '%s\n' "$entries" > "$ENTRIES_FILE"
    printf '%s\n' "$new_ck"   > "$CKSUM_FILE"
    log "baseline saved ($(printf '%s\n' "$entries" | grep -c .) entries)"
    rm -f "$body"; return 0
  fi

  # API suddenly returned an empty list: suspicious, keep the old state
  if [ -z "$entries" ] && [ -s "$ENTRIES_FILE" ]; then
    log "WARNING: API returned an empty list; keeping previous state"
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
  [ "$notified" -gt 0 ] && log "$notified notification(s) sent"
  rm -f "$body"
  return 0
}

#-------------------------------- main ----------------------------------

main() {
  # --- parse arguments ---
  while [ $# -gt 0 ]; do
    case $1 in
      --auth)        [ $# -ge 2 ] || die "--auth requires a value"; AUTH=$2; shift 2 ;;
      --auth=*)      AUTH=${1#*=}; shift ;;
      --host)        [ $# -ge 2 ] || die "--host requires a value"; HOST=$2; shift 2 ;;
      --host=*)      HOST=${1#*=}; shift ;;
      --id)          [ $# -ge 2 ] || die "--id requires a value"; STUDENT_ID=$2; shift 2 ;;
      --id=*)        STUDENT_ID=${1#*=}; shift ;;
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
    notify "علامة جديدة للسنة 3" "اتصالات رقمية و تشابهية 25+20=45"
    exit 0
  fi

  # --- validate options ---
  case $INTERVAL in ''|*[!0-9]*) die "--interval must be a whole number of seconds" ;; esac
  [ "$INTERVAL" -ge 5 ] || die "--interval must be at least 5 seconds"
  [ -n "$AUTH" ]       || { usage >&2; die "--auth is required"; }
  [ -n "$HOST" ]       || { usage >&2; die "--host is required"; }
  [ -n "$STUDENT_ID" ] || { usage >&2; die "--id is required"; }

  need curl
  need jq

  # --- build the endpoint URL ---
  HOST=${HOST,,}     # lowercase
  HOST=${HOST%/}     # drop a trailing slash
  case $HOST in
    http://*|https://*) GRADES_URL="$HOST/Api/Grades?StudentId=$STUDENT_ID" ;;
    *)                  GRADES_URL="https://$HOST/Api/Grades?StudentId=$STUDENT_ID" ;;
  esac

  # --- state files (per host+id) ---
  STATE_DIR="$HOME/.grades-watch"
  mkdir -p "$STATE_DIR" || die "cannot create $STATE_DIR"
  STATE_KEY=$(printf '%s' "$GRADES_URL" | cksum | cut -d' ' -f1)
  CKSUM_FILE="$STATE_DIR/$STATE_KEY.cksum"
  ENTRIES_FILE="$STATE_DIR/$STATE_KEY.entries"
  ERR_LATCH="$STATE_DIR/$STATE_KEY.err"

  # --- keep the CPU awake while polling in the background ---
  if command -v termux-wake-lock >/dev/null 2>&1; then
    termux-wake-lock && log "wake lock acquired (polling continues with screen off)"
  fi
  cleanup() { command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock 2>/dev/null; }
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  log "watching $GRADES_URL every ${INTERVAL}s (state: $STATE_DIR)"
  while :; do
    check_once
    [ "$ONCE" -eq 1 ] && break
    sleep "$INTERVAL"
  done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
