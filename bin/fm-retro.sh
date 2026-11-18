#!/usr/bin/env bash
# fm-retro.sh - read-only retrospective over this home's own supervision logs.
#
# Answers "where did supervision effort go, and what is worth fixing first?"
# from records firstmate already writes:
#   state/branch-outcomes.jsonl  one record per handled notification
#                                (task, wake reason, verdict routine|captain, summary)
#   state/fleet-ledger.jsonl     optional, present when config/fleet-ledger is on
#                                (dispatched / pr_ready / merged / cleaned_up)
#
# It never writes outside an explicit --out file, never touches projects/, and
# needs only bash and jq, so it is safe to run while a fleet is live.
#
# Usage: fm-retro.sh [--days N] [--now EPOCH] [--storm-min N] [--out FILE]
#   --days N       window to analyze, default 1 (the daily loop)
#   --now EPOCH    end of the window, default the current time (tests pin it)
#   --storm-min N  wakes for one task inside the window that count as a storm
#                  when at least 90% of them were routine, default 20
#   --out FILE     also write the report to FILE (its directory must exist)
#
# Output is Markdown. Sections are ranked by estimated impact: the share of
# notifications that needed nobody, then per-task notification storms, then
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
    --days) DAYS="${2:-}"; shift 2 ;;
    --now) NOW="${2:-}"; shift 2 ;;
    --storm-min) STORM_MIN="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

for n in "$DAYS" "$STORM_MIN" ${NOW:+"$NOW"}; do
  case "$n" in
    '' | *[!0-9]*) echo "fm-retro: expected a whole number, got '$n'" >&2; exit 2 ;;
  esac
done
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

# Malformed lines are skipped, not fatal: the log is append-only and a torn
# final line during a live write must not stop the report.
outcomes_json() {
  jq -cR --argjson since "$SINCE" --argjson now "$NOW" '
    fromjson? | select(type == "object" and (.epoch | type) == "number")
    | select(.epoch >= $since and .epoch <= $now)' "$OUTCOMES"
}

ledger_json() {
  if [ -r "$LEDGER" ]; then
    jq -cR --argjson now "$NOW" '
      fromjson? | select(type == "object" and (.ts | type) == "number" and .ts <= $now)' "$LEDGER"
  fi
}

# The filtered records reach the report through temp files and --slurpfile,
# never argv: a multi-day window over a busy home is megabytes, past the
# argument-size limit.
report() {
  local tmp rc=0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-retro.XXXXXX")
  outcomes_json >"$tmp/rows.jsonl"
  ledger_json >"$tmp/ledger.jsonl"
  jq -nr --slurpfile rows "$tmp/rows.jsonl" --slurpfile ledger "$tmp/ledger.jsonl" \
    --argjson days "$DAYS" --argjson since "$SINCE" --argjson stormmin "$STORM_MIN" '
    def pct(a; b): if b == 0 then 0 else ((a * 1000 / b) | round) / 10 end;
    def kind: (.wake // "" | split(":")[0] | if . == "" then "unknown" else . end);
    def median: sort | if length == 0 then null
      elif length % 2 == 1 then .[length / 2 | floor]
      else (.[length / 2 - 1] + .[length / 2]) / 2 end;
    def dur: if . == null then "n/a"
      elif . < 3600 then "\(. / 60 | round) min"
      else "\((. / 360 | round) / 10) h" end;

    ($rows | length) as $total
    | ([$rows[] | select(.verdict == "routine")] | length) as $routine
    | ([$rows[] | select(.verdict == "captain")] | length) as $captain
    | ($rows | group_by(.task) | map({
        task: .[0].task, n: length,
        routine: ([.[] | select(.verdict == "routine")] | length),
        kinds: (group_by(kind) | map("\(.[0] | kind) \(length)") | join(", ")),
        hours: (((map(.epoch) | max) - (map(.epoch) | min)) / 3600)
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
          then "- Suggestion: most notifications ended with no action. Look at the storms below first; each one is supervision spend with no outcome."
          else empty end)
       end),
      "",
      "## 2. Notification storms (\($stormmin)+ notifications, 90%+ routine)",
      "",
      (if ($storms | length) == 0 then "None in this window."
       else ($storms[] |
         "- \(.task): \(.n) notifications over \((.hours * 10 | round) / 10) h, \(pct(.routine; .n))% routine (\(.kinds)).")
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
         | "- \(.task): \((.summary // "") | gsub("\\s+"; " ") | .[0:200])")
       end),
      "",
      "## 5. Cycle times",
      "",
      (if ($ledger | length) == 0 then "No fleet ledger yet. Create config/fleet-ledger to start recording dispatch, review and merge times."
       else
         ($ledger | group_by(.task) | map({
           d: ([.[] | select(.event == "task.dispatched") | .ts] | min),
           r: ([.[] | select(.event == "task.pr_ready") | .ts] | min),
           m: ([.[] | select(.event == "task.merged") | .ts] | min)
         })) as $t
         | [$t[] | select(.m != null and .m >= $since)] as $merged
         | "- Merged in window: \($merged | length).",
           "- Median dispatch to ready for review: \([$t[] | select(.d != null and .r != null and .r >= $since) | .r - .d] | median | dur).",
           "- Median ready for review to merged: \([$merged[] | select(.r != null) | .m - .r] | median | dur)."
       end)
  ' || rc=$?
  rm -rf "$tmp"
  return "$rc"
}

if [ -n "$OUT" ]; then
  report | tee "$OUT"
else
  report
fi
