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

test_large_log_does_not_overflow_argv() {
  local s="$TMP_ROOT/large/state" out long
  mkdir -p "$s"
  long=$(printf '%0300d' 0)
  awk -v now="$NOW" -v long="$long" 'BEGIN { for (i = 1; i <= 2000; i++)
    printf "{\"seq\":%d,\"epoch\":%d,\"task\":\"t%d\",\"wake\":\"signal: x\",\"verdict\":\"routine\",\"summary\":\"%s\"}\n", i, now - i * 30, i % 7, long }' \
    >"$s/branch-outcomes.jsonl"
  out=$(FM_STATE_OVERRIDE="$s" "$RETRO" --now "$NOW") || fail "retro failed on a large log: $out"
  case "$out" in *"2000 notifications handled"*) ;; *) fail "large log miscounted: $out" ;; esac
  pass "a log larger than one command-line argument still reports"
}

test_odd_wake_values_and_arg_edges() {
  local s="$TMP_ROOT/odd/state" out
  mkdir -p "$s"
  {
    printf '{"seq":1,"epoch":%s,"task":"a","verdict":"routine"}\n' "$((NOW - 60))"
    printf '{"seq":2,"epoch":%s,"task":"a","wake":42,"verdict":"routine"}\n' "$((NOW - 50))"
    printf '{"seq":3,"epoch":%s,"task":"a","wake":"","verdict":"captain","summary":"x"}\n' "$((NOW - 40))"
  } >"$s/branch-outcomes.jsonl"
  out=$(FM_STATE_OVERRIDE="$s" "$RETRO" --now "$NOW" --days 08) || fail "retro failed on odd wake values or --days 08: $out"
  case "$out" in *"unknown 2"*) ;; *) fail "missing or empty wake not counted as unknown: $out" ;; esac
  case "$out" in *"the last 8 days"*) ;; *) fail "--days 08 not read as 8: $out" ;; esac
  if FM_STATE_OVERRIDE="$s" "$RETRO" --days >/dev/null 2>&1; then fail "--days without a value accepted"; fi
  FM_STATE_OVERRIDE="$s" "$RETRO" --days >/dev/null 2>&1
  [ $? -eq 2 ] || fail "--days without a value should exit 2"
  pass "handles missing, numeric and empty wakes, a zero-padded window, and a flag with no value"
}

test_storm_explains_causes() {
  local s="$TMP_ROOT/why/state" out i w
  mkdir -p "$s"
  for i in $(seq 1 24); do
    if [ $((i % 2)) -eq 0 ]; then w="signal: x/land-$i.turn-ended"; else w="stale: default:w$i:p1"; fi
    printf '{"seq":%s,"epoch":%s,"task":"t","wake":"%s","verdict":"routine","silent":true,"statusIdent":"same"}\n' \
      "$i" "$((NOW - (25 - i) * 60))" "$w" >>"$s/branch-outcomes.jsonl"
  done
  printf '{"v":1,"ts":%s,"event":"task.pr_ready","task":"t"}\n' "$((NOW - 10 * 60))" >"$s/fleet-ledger.jsonl"
  out=$(FM_STATE_OVERRIDE="$s" "$RETRO" --now "$NOW") || fail "retro exited non-zero"
  case "$out" in *"unchanged since the previous notification: 23 of 23. Handled silently: 24."*) ;; *) fail "unchanged/silent counts wrong: $out" ;; esac
  case "$out" in *"After the task was ready for review: 10 of 24."*) ;; *) fail "after-ready count wrong: $out" ;; esac
  case "$out" in *"signal: land-N.turn-ended"?" 12"*) ;; *) fail "turn-ended causes not grouped: $out" ;; esac
  case "$out" in *"stale: default:wN:pN"?" 12"*) ;; *) fail "stale causes not grouped: $out" ;; esac
  pass "a storm names its causes, unchanged status, silent handling and post-review share"
}

test_ledger_absent_vs_empty() {
  local s="$TMP_ROOT/emptyledger/state" out
  seed_storm "$s"
  out=$(FM_STATE_OVERRIDE="$s" "$RETRO" --now "$NOW") || fail "retro exited non-zero"
  case "$out" in *"No fleet ledger yet"*) ;; *) fail "absent ledger not reported: $out" ;; esac
  : >"$s/fleet-ledger.jsonl"
  out=$(FM_STATE_OVERRIDE="$s" "$RETRO" --now "$NOW") || fail "retro exited non-zero"
  case "$out" in *"The fleet ledger has no records yet."*) ;; *) fail "empty ledger not reported: $out" ;; esac
  pass "tells an absent ledger from an empty one"
}

test_out_keeps_prior_file_on_failure() {
  local s="$TMP_ROOT/keep/state" dest="$TMP_ROOT/keep/new/dir/report.md"
  seed_storm "$s"
  FM_STATE_OVERRIDE="$s" "$RETRO" --now "$NOW" --out "$dest" >/dev/null || fail "--out did not create its directory"
  printf 'previous\n' >"$dest"
  if FM_STATE_OVERRIDE="$TMP_ROOT/keep/missing" "$RETRO" --now "$NOW" --out "$dest" >/dev/null 2>&1; then fail "missing log should fail"; fi
  grep -q '^previous$' "$dest" || fail "a failed run replaced the previous --out file"
  pass "--out creates its directory and keeps the previous report when a run fails"
}

fm_test_run test_reports_routine_share_and_storm test_large_log_does_not_overflow_argv test_wider_window_includes_older_records \
  test_ledger_cycle_times test_missing_log_and_bad_args test_out_file_written \
  test_odd_wake_values_and_arg_edges test_storm_explains_causes test_ledger_absent_vs_empty test_out_keeps_prior_file_on_failure
