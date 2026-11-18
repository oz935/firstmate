#!/usr/bin/env bash
# fm-retro.sh - read-only retrospective over this home's own supervision logs.
#
# Answers "where did supervision effort go, and what is worth fixing first?"
# from records firstmate already writes:
#   state/branch-outcomes.jsonl  one record per handled notification; format
#                                owned by bin/fm-branch-outcome.sh (task, wake,
#                                verdict routine|captain, summary, silent,
#                                statusIdent)
#   state/fleet-ledger.jsonl     optional, present when config/fleet-ledger is on
#                                (format owned by docs/fleet-ledger.md)
#
# It never writes outside an explicit --out file, never touches projects/, and
# needs only bash and jq, so it is safe to run while a fleet is live. It is not
# wired into supervision on purpose: a tool meant to cut notifications should
# not add one. Run it by hand, or from launchd/cron on the host.
#
# Usage: fm-retro.sh [--days N] [--now EPOCH] [--storm-min N] [--out FILE]
#   --days N       window to analyze, default 1 (the daily loop)
#   --now EPOCH    end of the window, default the current time (tests pin it)
#   --storm-min N  notifications for one task inside the window that count as
#                  a storm when at least 90% were routine, default 20 (per
#                  window, not per day)
#   --out FILE     also write the report to FILE, creating its directory; the
#                  file is replaced only after the report succeeds
#
# Output is Markdown, ranked by estimated impact: the share of notifications
# that needed nobody, then per-task storms with what drove them, then
# escalations, then cycle times when the ledger exists.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

DAYS=1
NOW=""
STORM_MIN=20
OUT=""

usage() { echo "usage: fm-retro.sh [--days N] [--now EPOCH] [--storm-min N] [--out FILE]" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --days | --now | --storm-min | --out)
      [ $# -ge 2 ] || { echo "fm-retro: $1 needs a value" >&2; usage; exit 2; }
      case "$1" in
        --days) DAYS="$2" ;;
        --now) NOW="$2" ;;
        --storm-min) STORM_MIN="$2" ;;
        --out) OUT="$2" ;;
      esac
      shift 2
      ;;
    -h | --help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

for n in "$DAYS" "$STORM_MIN" ${NOW:+"$NOW"}; do
  case "$n" in
    '' | *[!0-9]*) echo "fm-retro: expected a whole number, got '$n'" >&2; exit 2 ;;
  esac
done
# Base 10 explicitly: a leading zero would otherwise read as octal ("08" fails).
DAYS=$((10#$DAYS))
STORM_MIN=$((10#$STORM_MIN))
[ -z "$NOW" ] || NOW=$((10#$NOW))
[ "$DAYS" -ge 1 ] || { echo "fm-retro: --days must be at least 1" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "fm-retro: jq is required" >&2; exit 2; }

OUTCOMES="$STATE/branch-outcomes.jsonl"
LEDGER="$STATE/fleet-ledger.jsonl"
[ -n "$NOW" ] || NOW=$(date +%s)
SINCE=$((NOW - DAYS * 86400))

if [ ! -r "$OUTCOMES" ]; then
  echo "fm-retro: no notification log at $OUTCOMES" >&2
  exit 1
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-retro.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

# Records reach jq through files and --slurpfile, never argv: a multi-day
# window over a busy home is megabytes, past the argument-size limit.
# Malformed lines are skipped, not fatal: the log is append-only and a torn
# final line during a live write must not stop the report.
jq -cR --argjson since "$SINCE" --argjson now "$NOW" '
  fromjson? | select(type == "object" and (.epoch | type) == "number")
  | select(.epoch >= $since and .epoch <= $now)' "$OUTCOMES" >"$TMP/rows.jsonl"
LEDGER_STATE=absent
: >"$TMP/ledger.jsonl"
if [ -r "$LEDGER" ]; then
  LEDGER_STATE=present
  jq -cR --argjson now "$NOW" '
    fromjson? | select(type == "object" and (.ts | type) == "number" and .ts <= $now)' "$LEDGER" >"$TMP/ledger.jsonl"
fi

jq -nr --slurpfile rows "$TMP/rows.jsonl" --slurpfile ledger "$TMP/ledger.jsonl" \
  --arg ledgerstate "$LEDGER_STATE" \
  --argjson days "$DAYS" --argjson since "$SINCE" --argjson stormmin "$STORM_MIN" '
  def pct(a; b): if b == 0 then 0 else ((a * 1000 / b) | round) / 10 end;
  def wake: (.wake // "") | tostring;
  def kind: (wake | split(":")[0] // "") | if . == "" then "unknown" else . end;
  # A wake text with paths cut to their last component and digits masked, so
  # repeats of one cause group together: "signal: x/nice-land-12.turn-ended"
  # and "...-13.turn-ended" both read "signal: nice-land-N.turn-ended".
  def pattern: wake | gsub("[^ ]*/"; "") | gsub("[0-9]+"; "N") | .[0:100];
  def median: sort | if length == 0 then null
    elif length % 2 == 1 then .[length / 2 | floor]
    else (.[length / 2 - 1] + .[length / 2]) / 2 end;
  def dur: if . == null then "n/a"
    elif . < 3600 then "\(. / 60 | round) min"
    else "\((. / 360 | round) / 10) h" end;
  def gaps: [range(1; length) as $i | .[$i] - .[$i - 1]];

  ($ledger | group_by(.task) | map({
     key: .[0].task,
     value: {
       d: ([.[] | select(.event == "task.dispatched") | .ts] | min),
       r: ([.[] | select(.event == "task.pr_ready") | .ts] | min),
       m: ([.[] | select(.event == "task.merged") | .ts] | min)
     }
   }) | from_entries) as $life
  | ($rows | length) as $total
  | ([$rows[] | select(.verdict == "routine")] | length) as $routine
  | ([$rows[] | select(.verdict == "captain")] | length) as $captain
  | ($rows | group_by(.task) | map(sort_by(.seq // .epoch) | . as $t | {
      task: $t[0].task, n: length,
      routine: ([$t[] | select(.verdict == "routine")] | length),
      silent: ([$t[] | select(.silent == true)] | length),
      unchanged: ([range(1; length) as $i
        | select(($t[$i].statusIdent // null) != null and $t[$i].statusIdent == $t[$i - 1].statusIdent)] | length),
      hours: (((map(.epoch) | max) - (map(.epoch) | min)) / 3600),
      gap: (map(.epoch) | gaps | median),
      patterns: (map(pattern) | group_by(.) | map({p: .[0], c: length}) | sort_by(-.c) | .[0:3]),
      afterready: ($life[$t[0].task].r as $r | if $r == null then null else ([$t[] | select(.epoch >= $r)] | length) end)
    }) | sort_by(-.n)) as $bytask
  | [$bytask[] | select(.n >= $stormmin and pct(.routine; .n) >= 90)] as $storms
  | (if $days == 1 then "the last 24 hours" else "the last \($days) days" end) as $window

  | "# Firstmate retro: \($window)",
    "",
    "Window starts \($since | todate). Read-only report from the notification log\(if ($ledger | length) > 0 then " and the fleet ledger" else "" end).",
    "",
    "## 1. Notifications that needed nobody",
    "",
    (if $total == 0 then "No notifications were handled in this window."
     else
       "- \($total) notifications handled: \($routine) routine (\(pct($routine; $total))%), \($captain) needed a decision.",
       "- By reason: \($rows | group_by(kind) | sort_by(-length) | map("\(.[0] | kind) \(length)") | join(", ")).",
       (if pct($routine; $total) >= 80
        then "- Suggestion: most notifications ended with no action. Start with the storms below; each is supervision spend with no outcome."
        else empty end)
     end),
    "",
    "## 2. Notification storms (\($stormmin)+ notifications in the window, 90%+ routine)",
    "",
    (if ($storms | length) == 0 then "None in this window."
     else ($storms[] |
       "- \(.task): \(.n) notifications over \((.hours * 10 | round) / 10) h, \(pct(.routine; .n))% routine, median gap \(.gap | dur).",
       "  - Status record unchanged since the previous notification: \(.unchanged) of \(.n - 1). Handled silently: \(.silent).",
       (if .afterready != null then "  - After the task was ready for review: \(.afterready) of \(.n)." else empty end),
       "  - Top causes: \(.patterns | map("`\(.p)` \(.c)") | join("; ")).")
     end),
    "",
    "## 3. Busiest tasks",
    "",
    (if ($bytask | length) == 0 then "None."
     else ($bytask[:8][] | "- \(.task): \(.n) notifications, \(.n - .routine) needed a decision.") end),
    "",
    "## 4. What reached a decision",
    "",
    (if $captain == 0 then "Nothing needed a decision."
     else ([$rows[] | select(.verdict == "captain")] | sort_by(.epoch) | reverse | .[:10][]
       | "- \(.task): \((.summary // "") | tostring | gsub("\\s+"; " ") | .[0:200])")
     end),
    "",
    "## 5. Cycle times",
    "",
    (if $ledgerstate == "absent" then "No fleet ledger yet. Create config/fleet-ledger to start recording dispatch, review and merge times."
     elif ($ledger | length) == 0 then "The fleet ledger has no records yet."
     else
       [$life[] | select(.m != null and .m >= $since)] as $merged
       | "- Merged in window: \($merged | length).",
         "- Median dispatch to ready for review: \([$life[] | select(.d != null and .r != null and .r >= $since) | .r - .d] | median | dur).",
         "- Median ready for review to merged: \([$merged[] | select(.r != null) | .m - .r] | median | dur)."
     end)
' >"$TMP/report.md"

cat "$TMP/report.md"
if [ -n "$OUT" ]; then
  mkdir -p "$(dirname "$OUT")"
  cp "$TMP/report.md" "$OUT"
fi
