#!/usr/bin/env bash
# tests/fm-retro.test.sh - behaviour of bin/fm-retro.sh, the read-only
# retrospective over state/branch-outcomes.jsonl and state/fleet-ledger.jsonl.
#
# Isolation: every test builds a throwaway state directory under a
# self-cleaning temp root and pins --now, so results never depend on the clock
# or on the live home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-retro)
RETRO="$ROOT/bin/fm-retro.sh"
NOW=1800000000

outcome() {  # <file> <seq> <age-seconds> <task> <wake-kind> <verdict> <summary>
  printf '{"seq":%s,"epoch":%s,"task":"%s","wake":"%s: x","verdict":"%s","summary":"%s"}\n' \
    "$2" "$((NOW - $3))" "$4" "$5" "$6" "$7" >>"$1"
}

seed_storm() {  # <state-dir>
  local s="$1" i
  mkdir -p "$s"
  for i in $(seq 1 25); do
    outcome "$s/branch-outcomes.jsonl" "$i" "$((i * 600))" storm-task stale routine "nothing new, no action taken"
  done
  outcome "$s/branch-outcomes.jsonl" 26 300 other-task signal captain "PR ready for review"
  outcome "$s/branch-outcomes.jsonl" 27 $((3 * 86400)) old-task signal captain "outside the window"
  printf 'not json\n' >>"$s/branch-outcomes.jsonl"
}

test_reports_routine_share_and_storm() {
  local s="$TMP_ROOT/storm/state" out
  seed_storm "$s"
  out=$(FM_STATE_OVERRIDE="$s" "$RETRO" --now "$NOW") || fail "retro exited non-zero"
  case "$out" in *"26 notifications handled: 25 routine (96.2%), 1 needed a decision"*) ;; *) fail "routine share missing: $out" ;; esac
  case "$out" in *"- storm-task: 25 notifications"*"100% routine"*) ;; *) fail "storm not reported: $out" ;; esac
  case "$out" in *old-task*) fail "record outside the window was counted" ;; esac
  pass "reports the routine share and a notification storm inside the window only"
}

test_wider_window_includes_older_records() {
  local s="$TMP_ROOT/wide/state" out
  seed_storm "$s"
  out=$(FM_STATE_OVERRIDE="$s" "$RETRO" --now "$NOW" --days 7) || fail "retro exited non-zero"
  case "$out" in *"27 notifications handled"*) ;; *) fail "7-day window missed the older record: $out" ;; esac
  pass "a wider window includes older records"
}

test_ledger_cycle_times() {
  local s="$TMP_ROOT/ledger/state" out
  seed_storm "$s"
  {
    printf '{"v":1,"ts":%s,"event":"task.dispatched","task":"a"}\n' "$((NOW - 7200))"
    printf '{"v":1,"ts":%s,"event":"task.pr_ready","task":"a"}\n' "$((NOW - 3600))"
    printf '{"v":1,"ts":%s,"event":"task.merged","task":"a","via":"pr"}\n' "$((NOW - 1800))"
  } >"$s/fleet-ledger.jsonl"
  out=$(FM_STATE_OVERRIDE="$s" "$RETRO" --now "$NOW") || fail "retro exited non-zero"
  case "$out" in *"Merged in window: 1."*"dispatch to ready for review: 1 h"*"ready for review to merged: 30 min"*) ;; *) fail "cycle times wrong: $out" ;; esac
  pass "derives cycle times from the fleet ledger"
}

test_missing_log_and_bad_args() {
  local out
  if out=$(FM_STATE_OVERRIDE="$TMP_ROOT/none" "$RETRO" --now "$NOW" 2>&1); then fail "missing log should fail"; fi
  case "$out" in *"no notification log"*) ;; *) fail "missing log message wrong: $out" ;; esac
  if FM_STATE_OVERRIDE="$TMP_ROOT/none" "$RETRO" --days abc >/dev/null 2>&1; then fail "bad --days accepted"; fi
  pass "refuses a missing log and a non-numeric window"
}

test_out_file_written() {
  local s="$TMP_ROOT/out/state"
  seed_storm "$s"
  FM_STATE_OVERRIDE="$s" "$RETRO" --now "$NOW" --out "$TMP_ROOT/out/report.md" >/dev/null || fail "retro exited non-zero"
  grep -q "^# Firstmate retro" "$TMP_ROOT/out/report.md" || fail "--out file missing the report"
  pass "writes the report to --out"
}

fm_test_run test_reports_routine_share_and_storm test_wider_window_includes_older_records \
  test_ledger_cycle_times test_missing_log_and_bad_args test_out_file_written
