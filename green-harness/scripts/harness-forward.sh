#!/bin/sh
# The harness forwarder: every Claude Code hook event goes to the harness server, and the
# server's answer comes back (b-187, b-201, b-266). Built from the spike
# docs/rebuild/spike/forward.sh; its behaviours are tests in tests/test_forward.py.
#
# No logic about the work itself: it POSTs the hook JSON from stdin and passes the answer on.
#   the server answers 200 with a JSON object         -> print it, exit 0
#   anything else (no answer within the bound, connect error, another status, an empty or
#   non-JSON body, a missing or unsafe setting)       -> reason on stderr, exit 2
#                                                        (fail CLOSED: the tool is stopped)
#
# PLUGIN MODE (b-285): when this script lies in the green-harness plugin - see below. The URL
# comes from the plugin option server_url, the credential is the attached session's token.
#
# ATTACHED SESSIONS (b-284, reviews 2 and 3 of wt/deploy; the plugin is the only way to
# attach): the `attach` tool returns a single-use claim code, never the session token. This
# script exchanges the code at <origin>/attach/claim for the token, bound to the event's own
# session_id, and keeps the token in ${CLAUDE_PLUGIN_DATA}/sessions/<session_id> (mode 600),
# which only it reads. A NEW attach result is always exchanged and replaces the kept token
# (review 3 item 3). A token the server calls ended (`session_ended`: expired, detached,
# replaced) is forgotten; the harness's own tools and the prompt then pass with a note, any
# other tool is blocked ONCE with the server's reason, then the session is simply not
# attached (review 2 item 4: a lapsed token must never lock the user out of attach).
#
# THE EVENT IS READ AS JSON (python3 -I), top-level fields only (review 2 item 1): a field
# named inside tool_input can never pose as the event's own session_id or tool_name. The
# harness's own tools are matched by their EXACT name, mcp__plugin_<plugin>_<server>__<tool>
# from the plugin's own plugin.json and .mcp.json. Without python3 (review 3 item 9): outside
# the plugin, blocked; in the plugin, an unattached session passes silently and only an
# attached one blocks - the session id is then read as the FIRST key of the input, which is
# where Claude Code writes it (MEASURED in the 2.1.283 bundle), before any tool_input.
#
# ONE BOUND FOR THE WHOLE EVENT (review 3 item 8): the claim exchange and the event share one
# deadline, `bound` seconds after the start. Claude Code does NOT block on a hook that hits
# its timeout (MEASURED in the 2.1.283 bundle: ABORT_ERR -> status 1, aborted ->
# hook_cancelled; SPIKE-transport.md), so every request must end before the hook's timeout;
# in the plugin (hooks.json timeout 10 s) the bound is capped at PLUGIN_MAX_BOUND.
#
# PATH is fixed (SAFE_PATH) before anything runs: a project's settings `env` reaches hook
# processes (MEASURED), and a PATH from there could put its own curl or python3 in front.
#
# SETTINGS come from ONE file, $HOME/.harness-forward.conf, mode 600, never from the
# environment (review 1 of wt/deploy, F9). A project's .claude/settings.json can set `env`
# for hook processes (MEASURED in the plugin run: it reaches them); if the URL came from
# there, a project could send the user's key to its own server. The file holds:
#   url=https://<domain>/hook   the server's hook endpoint
#   key=<tenant key>            sent as `Authorization: Bearer`, through a header file (mode
#                               600, removed on exit): on neither the URL nor curl's argv
#   bound=5                     seconds to wait, 1..60 (optional)
#   allow_local=yes             plain http to exactly 127.0.0.1, ::1 or localhost (optional)
#   bypass=<reason>             confirms a named bypass (below)
# A $HOME inside the project directory is refused: a project could point HOME at itself.
#
# NAMED BYPASS (b-187): HARNESS_BYPASS=<reason> set by a human when starting claude, AND the
# same reason on a `bypass=` line of the conf file. Then exit 0, the bypass is said on
# stderr and appended to $HOME/.harness-bypass.log; if that line cannot be written, the
# bypass is refused. A reason is at least BYPASS_MIN_CHARS characters on one line.
#
# The hook's own "timeout" in settings.json MUST be larger than the bound: a hook that
# Claude Code cancels at its timeout does not block (fail OPEN, SPIKE-transport.md).
#
# CHOSEN (executor, 2026-09-28, review 2 item 2): the only PATH this script runs with - the
# system directories and Homebrew's, where python3 and curl live; never the caller's PATH.
SAFE_PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin
PATH=$SAFE_PATH
export PATH
# CHOSEN (executor, 2026-09-24, SPIKE-transport.md): the default bound, 5 s - about 1.8 times
# the worst remote call measured (2.78 s of 100) and 20 times the median.
DEFAULT_BOUND=5
# CHOSEN (executor, 2026-09-25): the longest bound accepted. The hook timeout has to stay
# above it, and a minute of a frozen agent is already an outage.
MAX_BOUND=60
# CALCULATED (review 3 item 8, 2026-09-28): the longest bound in the plugin. Its hooks.json
# timeout is 10 s; the requests of one event share the bound (counted by curl's time_total),
# and everything around them - sh, python3, curl start-up - MEASURED 0.27 s at most (20 runs
# of an attach result, claim + event, against a local server). 6 s leaves 3.7 s of margin.
PLUGIN_MAX_BOUND=6
# CHOSEN (executor, 2026-09-28, review 1 F9): the shortest bypass reason - a word such as
# "outage" names no incident a reviewer can find later.
BYPASS_MIN_CHARS=10
# CHOSEN (executor, 2026-09-28, review 2 item 4): the harness's own tools, which an ended
# session lets through (with the prompt) so the user can always attach again or look.
OWN_TOOLS="attach detach status"

HINT="Outage bypass: add bypass=<reason> to ~/.harness-forward.conf and restart claude with HARNESS_BYPASS=<reason>"

block() {
  echo "harness: $1 - blocked (fail closed). $HINT" >&2
  exit 2
}

umask 077
work=$(mktemp -d "${TMPDIR:-/tmp}/harness-fwd.XXXXXX") || block "mktemp failed"
trap 'rm -rf "$work"' EXIT HUP INT TERM
event_file="$work/event.json"
cat > "$event_file"

# json_get FILE KEY PATTERN: a top-level string field of a JSON object, printed only when
# the whole value matches PATTERN (a Python regex); nothing otherwise.
json_get() {
  python3 -I -c '
import json, re, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        v = json.load(f)
except (OSError, ValueError):
    sys.exit(0)
x = v.get(sys.argv[2]) if isinstance(v, dict) else None
if isinstance(x, str) and re.fullmatch(sys.argv[3], x):
    print(x)
' "$1" "$2" "$3" 2>/dev/null
}

# - plugin mode (b-285): this script is the one inside the green-harness plugin -
# The mode follows from WHERE the script lies - scripts/ next to .claude-plugin/plugin.json
# named green-harness - never from a variable: a project's .claude/settings.json `env`
# reaches hook processes (MEASURED in the plugin run, 2026-09-28), and a mode variable would
# let a project turn the harness into a pass-through. A plugin session with no token file is
# not attached: everything passes, silently. Hooks send only the session token, never the
# tenant key.
PLUGIN=""
self_dir=$(cd "$(dirname "$0")" && pwd -P)
if [ "${self_dir##*/}" = "scripts" ] \
    && grep -q '"name": *"green-harness"' "$self_dir/../.claude-plugin/plugin.json" 2>/dev/null; then
  PLUGIN=yes
fi

if ! command -v python3 >/dev/null 2>&1; then
  why="python3 is needed to read the hook event as JSON, and there is none on $SAFE_PATH"
  [ -n "$PLUGIN" ] || block "$why"
  data=${CLAUDE_PLUGIN_DATA:-}
  [ -n "$data" ] || exit 0
  first=$(head -c 400 "$event_file" \
    | sed -n 's/^{ *"session_id" *: *"\([A-Za-z0-9_-]\{1,128\}\)".*/\1/p' | head -n 1)
  if [ -n "$first" ]; then
    [ -s "$data/sessions/$first" ] || exit 0
  elif [ -z "$(find "$data/sessions" -type f 2>/dev/null | head -c 1)" ]; then
    exit 0
  fi
  block "$why; this session is attached"
fi

if [ -n "$PLUGIN" ]; then
  # MEASURED (the plugin run, Claude Code 2.1.283): a plugin's MCP tools are named
  # mcp__plugin_<plugin name>_<server key in .mcp.json>__<tool>.
  PREFIX=$(python3 -I -c '
import json, re, sys
root = sys.argv[1]
with open(root + "/.claude-plugin/plugin.json", encoding="utf-8") as f:
    name = json.load(f)["name"]
with open(root + "/.mcp.json", encoding="utf-8") as f:
    [server] = json.load(f)["mcpServers"]
if re.fullmatch(r"[A-Za-z0-9_-]+", name) and re.fullmatch(r"[A-Za-z0-9_-]+", server):
    print(f"mcp__plugin_{name}_{server}__")
' "$self_dir/.." 2>/dev/null)
  [ -n "$PREFIX" ] || block "cannot read the plugin's own name and MCP server from $self_dir/.."
fi

# - the event: top-level fields only, read as JSON -
EVENT=$(json_get "$event_file" hook_event_name '[A-Za-z]{1,64}')
TOOL=$(json_get "$event_file" tool_name '[A-Za-z0-9_.:-]{1,256}')
SESSION=$(json_get "$event_file" session_id '[A-Za-z0-9_-]{1,128}')

# - the settings file (optional in plugin mode, where it only holds allow_local and bypass) -
load_conf() {
  HOME_DIR="${HOME:-}"
  [ -n "$HOME_DIR" ] && [ -d "$HOME_DIR" ] || block "HOME is not a directory"
  home_real=$(cd "$HOME_DIR" && pwd -P) || block "HOME cannot be read"
  here_real=$(pwd -P)
  case "$home_real/" in
    "$here_real"/*) block "HOME ($home_real) is inside the project directory ($here_real)" ;;
  esac
  CONF="$home_real/.harness-forward.conf"
  if [ -f "$CONF" ]; then
    if [ -n "$(find "$CONF" -perm -040 -o -perm -004 -o -perm -020 -o -perm -002 2>/dev/null | head -c1)" ]; then
      block "$CONF must be mode 600: other users can read or change it"
    fi
  elif [ -z "$PLUGIN" ]; then
    block "no settings: create $CONF (mode 600) with url= and key= lines"
  fi
}
setting() { [ -f "$CONF" ] && sed -n "s/^$1=//p" "$CONF" | tail -n 1; }

# - b-318, b-360: a cloud session uses the claude.ai connector, not the forwarder -
# A cloud session's network policy keeps its hooks from the server (MEASURED 2026-09-29: the
# proxy refused the harness domain, 403), and the owner decided against exceptions. Such a
# session is pointed at the claude.ai connector at its start and when it asks to attach; the
# capture hook pointed at before is withdrawn (b-360, 2026-10-08). Called ONLY
# where a session is not attached and passes anyway: CLAUDE_CODE_REMOTE can come from a
# project's settings `env`, so it may keep a session from attaching, never turn one off.
cloud_notice() {
  [ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || return 0
  why="harness: this is a Claude Code cloud session (CLAUDE_CODE_REMOTE=true): its network policy keeps hooks from the harness server, so /green-harness:start cannot attach here (b-318). Use the claude.ai connector instead (b-360): add https://harness.greenflac.online/mcp as a connector in claude.ai and sign in with your harness key; then type /green_harness_on with your task in any session to turn the harness on (/green_harness_off turns it off). Nothing is installed into your repository. If this session IS local, a project setting sets CLAUDE_CODE_REMOTE."
  case "$EVENT" in
    SessionStart)
      WHY=$why python3 -I -c 'import json, os; print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": os.environ["WHY"]}}))' ;;
    UserPromptSubmit)
      if [ -n "$(json_get "$event_file" prompt '(?s)\s*/green-harness:start\b.*')" ]; then
        WHY=$why python3 -I -c 'import json, os; print(json.dumps({"decision": "block", "reason": os.environ["WHY"]}))'
      fi ;;
  esac
}

CLAIM=""
if [ -n "$PLUGIN" ]; then
  data=${CLAUDE_PLUGIN_DATA:-}
  [ -n "$data" ] || { cloud_notice; exit 0; }
  SESSIONS="$data/sessions"
  if [ "$EVENT" = "PostToolUse" ] && [ "$TOOL" = "${PREFIX}attach" ]; then
    # The attach result: the claim code, found in the tool's result as the server sent it.
    CLAIM=$(python3 -I -c '
import json, re, sys
def found(v):
    if isinstance(v, dict):
        c = v.get("claim_code")
        if isinstance(c, str) and re.fullmatch(r"[A-Za-z0-9_-]{22,128}", c):
            return c
        return next((x for x in map(found, v.values()) if x), "")
    if isinstance(v, list):
        return next((x for x in map(found, v) if x), "")
    if isinstance(v, str) and v.lstrip()[:1] in ("{", "["):
        try:
            return found(json.loads(v))
        except ValueError:
            return ""
    return ""
with open(sys.argv[1], encoding="utf-8") as f:
    print(found(json.load(f).get("tool_response")))
' "$event_file" 2>/dev/null)
  fi
else
  # Outside the plugin: the user's own hooks with the tenant key from the conf file. No
  # session, no claim - attaching is the plugin's alone (review 3 item 0).
  load_conf
fi

TOKEN_FILE=""
[ -n "$PLUGIN" ] && [ -n "$SESSION" ] && TOKEN_FILE="$SESSIONS/$SESSION"
if [ -n "$TOKEN_FILE" ] && [ "$EVENT" = "PostToolUse" ] && [ "$TOOL" = "${PREFIX}detach" ]; then
  # The detach result: the server revoked this session's attachment; forget the token.
  rm -f "$TOKEN_FILE"
  exit 0
fi
if [ -n "$PLUGIN" ] && [ -z "$CLAIM" ] && { [ -z "$TOKEN_FILE" ] || [ ! -s "$TOKEN_FILE" ]; }; then
  cloud_notice
  exit 0
fi
[ -n "$PLUGIN" ] && load_conf

# - the named bypass -
if [ -n "${HARNESS_BYPASS:-}" ]; then
  reason=$HARNESS_BYPASS
  case "$reason" in
    *"
"*) reason="" ;;
  esac
  if [ "${#reason}" -lt "$BYPASS_MIN_CHARS" ]; then
    echo "harness: HARNESS_BYPASS is not honoured: a reason of at least $BYPASS_MIN_CHARS characters on one line is needed" >&2
  elif [ "$(setting bypass)" != "$reason" ]; then
    echo "harness: HARNESS_BYPASS is not honoured: not confirmed by a bypass= line with the same reason in $CONF" >&2
  else
    if ! printf '%s bypass=%s user=%s cwd=%s\n' "$(date -u +%FT%TZ)" "$reason" "${USER:-?}" \
        "$here_real" >> "$home_real/.harness-bypass.log" 2>/dev/null; then
      echo "harness: the bypass '$reason' could not be recorded in $home_real/.harness-bypass.log - blocked (fail closed)" >&2
      exit 2
    fi
    echo "harness bypass active: $reason (not checked by the server; recorded in ~/.harness-bypass.log)" >&2
    exit 0
  fi
fi

BOUND=$(setting bound)
BOUND=${BOUND:-$DEFAULT_BOUND}
case "$BOUND" in
  ''|*[!0-9]*) block "bound= must be a whole number of seconds, 1..$MAX_BOUND" ;;
esac
if [ "$BOUND" -lt 1 ] || [ "$BOUND" -gt "$MAX_BOUND" ]; then
  block "bound= must be a whole number of seconds, 1..$MAX_BOUND"
fi
# In the plugin the hook's timeout is fixed (hooks.json): a longer bound would let Claude
# Code cancel the hook first, and a cancelled hook does not block.
if [ -n "$PLUGIN" ] && [ "$BOUND" -gt "$PLUGIN_MAX_BOUND" ]; then
  BOUND=$PLUGIN_MAX_BOUND
fi
# Seconds the requests of this event have used so far (curl's own time_total).
USED=0

# - the URL, parsed: scheme, authority (no userinfo), host, port (F8) -
if [ -n "$PLUGIN" ]; then
  base=${CLAUDE_PLUGIN_OPTION_SERVER_URL:-}
  [ -n "$base" ] || block "the plugin option server_url is empty: set it in /config or reinstall with --config server_url=https://<domain>"
  URL="${base%/}/hook"
else
  URL=$(setting url)
fi
[ -n "$URL" ] || block "no url= line in $CONF"
case "$URL" in
  *[!]A-Za-z0-9._~:/%[-]*) block "url= holds a character outside a plain URL: no userinfo (@), query, fragment, space or backslash" ;;
esac
scheme=${URL%%://*}
[ "$scheme" != "$URL" ] || block "url= has no scheme"
rest=${URL#*://}
authority=${rest%%/*}
case "$authority" in
  \[*\]:*) host=${authority%%]:*}]; port=${authority##*]:} ;;
  \[*\]) host=$authority; port="" ;;
  *:*) host=${authority%%:*}; port=${authority#*:} ;;
  *) host=$authority; port="" ;;
esac
[ -n "$host" ] || block "url= has no host"
case "$port" in
  '') ;;
  *[!0-9]*) block "url= has a port that is not a number" ;;
esac
case "$scheme" in
  https) ;;
  http)
    case "$host" in
      127.0.0.1|localhost|\[::1\]) ;;
      *) block "url= uses plain http to $host: only https, or plain http to 127.0.0.1, ::1 or localhost" ;;
    esac
    [ "$(setting allow_local)" = "yes" ] || block "url= is plain http to the loopback; allow it with allow_local=yes in $CONF"
    ;;
  *) block "url= must be https:// (the key would travel in clear)" ;;
esac

# post PATH BODY_FILE [HEADER_FILE]: the HTTP status on stdout, the answer in $work/body.
# Every request gets only what the earlier ones left of the one bound, counted from curl's
# own time_total (a clock read would round, and the first request would sometimes get less
# than the bound); none left is curl rc 28.
# curl -q first: no .curlrc from $HOME or $CURL_HOME can add options.
post() {
  if [ "$USED" = "0" ]; then
    left=$BOUND
  else
    left=$(awk -v b="$BOUND" -v u="$USED" 'BEGIN { l = b - u; if (l < 0.5) print 0; else printf "%.1f", l }')
  fi
  if [ "$left" = "0" ]; then
    echo "no time left of the ${BOUND}s bound" > "$work/err"
    return 28
  fi
  if [ -n "${3:-}" ]; then
    set -- "$1" "$2" -H @"$3"
  else
    set -- "$1" "$2"
  fi
  target=$1
  body_file=$2
  shift 2
  curl -q -sS --proto '=https,http' --max-time "$left" --connect-timeout "$left" \
    -o "$work/body" -w '%{http_code} %{time_total}' "$@" \
    -H 'Content-Type: application/json' --data-binary "@$body_file" "$target" \
    2>"$work/err" > "$work/status"
}

# status_of: sets `code` to the HTTP status of the last request and adds its time to USED
# (in this shell - a $(...) would lose the sum).
status_of() {
  last_code="" last_time=""
  [ -f "$work/status" ] && read -r last_code last_time < "$work/status"
  USED=$(awk -v u="$USED" -v t="${last_time:-0}" 'BEGIN { printf "%.3f", u + t }')
  code=${last_code:-000}
}

# answer_field KEY: a top-level field of the server's answer, on one line, 300 characters.
answer_field() {
  python3 -I -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        v = json.load(f)
except (OSError, ValueError):
    sys.exit(0)
x = v.get(sys.argv[2]) if isinstance(v, dict) else None
if x is not None:
    print(json.dumps(x) if isinstance(x, bool) else " ".join(str(x).split())[:300])
' "$work/body" "$1" 2>/dev/null
}

# - the claim: every attach result is exchanged, and replaces a kept token (review 3 item 3):
# re-attaching is how an unobserved or ended session comes back -
if [ -n "$CLAIM" ] && [ -n "$TOKEN_FILE" ]; then
  python3 -I -c '
import json, sys
print(json.dumps({"claim_code": sys.argv[1], "session_id": sys.argv[2]}))
' "$CLAIM" "$SESSION" > "$work/claim.json" || block "could not write the claim request"
  post "$scheme://$authority/attach/claim" "$work/claim.json"
  rc=$?
  status_of
  token=""
  if [ "$rc" -eq 0 ] && [ "$code" = "200" ]; then
    token=$(json_get "$work/body" session_token '[A-Za-z0-9_-]{43,128}')
  fi
  if [ -z "$token" ]; then
    why=$(answer_field error)
    rm -f "$TOKEN_FILE"
    echo "harness: the attach claim was not accepted (HTTP ${code:-none}${why:+: $why}): this session is NOT attached; run /green-harness:start again" >&2
    exit 0
  fi
  if ! { mkdir -p "$SESSIONS" && chmod 700 "$SESSIONS" \
      && printf '%s' "$token" > "$SESSIONS/.$SESSION.new" \
      && mv "$SESSIONS/.$SESSION.new" "$TOKEN_FILE"; }; then
    block "could not record the session token in $SESSIONS"
  fi
fi

TOKEN=""
if [ -n "$TOKEN_FILE" ] && [ -s "$TOKEN_FILE" ]; then
  TOKEN=$(cat "$TOKEN_FILE")
fi
if [ -n "$TOKEN" ]; then
  KEY=$TOKEN
elif [ -n "$PLUGIN" ]; then
  exit 0
else
  KEY=$(setting key)
fi
[ -n "$KEY" ] || block "no key= line in $CONF"

printf 'Authorization: Bearer %s\n' "$KEY" > "$work/headers"
post "$URL" "$event_file" "$work/headers"
rc=$?
status_of
if [ "$rc" -ne 0 ]; then
  block "the server is unreachable or gave no answer within ${BOUND}s (curl rc=$rc: $(head -c 300 "$work/err"))"
fi
if [ "$code" != "200" ]; then
  # The server's own reason ({"error": ...}), one line, at most 300 characters.
  reason=$(answer_field error)
  if [ -n "$TOKEN" ] && [ "$code" = "401" ] && [ "$(answer_field session_ended)" = "true" ]; then
    rm -f "$TOKEN_FILE"
    own=""
    for name in $OWN_TOOLS; do
      [ "$TOOL" = "$PREFIX$name" ] && own=yes
    done
    if [ "$EVENT" = "UserPromptSubmit" ] || [ -n "$own" ]; then
      echo "harness: this session is no longer attached (${reason:-ended}); the harness is silent here until you attach again" >&2
      exit 0
    fi
    block "this session is no longer attached: ${reason:-ended}. The next call passes unattached"
  fi
  block "the server answered HTTP $code${reason:+: $reason}"
fi
touch "$work/body"
[ -s "$work/body" ] || block "the server answered 200 with an empty body"
python3 -I -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    sys.exit(0 if isinstance(json.load(f), dict) else 1)
' "$work/body" 2>/dev/null || block "the server's answer is not a JSON object"
cat "$work/body"
exit 0
