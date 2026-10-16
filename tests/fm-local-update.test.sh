#!/usr/bin/env bash
# tests/fm-local-update.test.sh - behaviour of bin/fm-local-update.sh, the update
# entry point for a home that carries local patches on top of upstream.
#
# The property the whole local-patch scheme rests on is that bin/fm-update.sh
# advances the default branch only when
# `git merge-base --is-ancestor HEAD origin/<default>` holds, so with local patch
# commits present it REFUSES rather than advancing and dropping them. These tests
# pin that refusal, and pin that the wrapper replays the patches and verifies
# them afterwards.
#
# Isolation: every test builds a throwaway upstream and a throwaway home under a
# self-cleaning temp root. Nothing touches the live fleet, its worktrees, or
# projects/.
#
# The fixture seeds upstream from the upstream commit THIS repo's HEAD sits on
# (its merge base with origin/<default>) and the home from its current HEAD, so
# the "local patches" under test are the real ones this home carries. The merge
# base, not the origin/<default> tip, because a fetch moves that tip past the
# carried base whenever upstream has advanced and the update is not yet applied. A checkout with no local commits (upstream CI, or a home whose patches
# have all landed upstream) has nothing to exercise and skips.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-local-update)

DEFAULT=$(git -C "$ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)
DEFAULT=${DEFAULT#origin/}
HOME_TIP=$(git -C "$ROOT" rev-parse --verify --quiet HEAD 2>/dev/null || echo "")
UPSTREAM_TIP=$(git -C "$ROOT" merge-base HEAD "refs/remotes/origin/$DEFAULT" 2>/dev/null || echo "")

[ -n "$UPSTREAM_TIP" ] && [ -n "$HOME_TIP" ] || {
  echo "skip: no origin/$DEFAULT to seed a fixture from"
  exit 0
}
if [ "$(git -C "$ROOT" rev-list --count "$UPSTREAM_TIP..$HOME_TIP")" = 0 ]; then
  echo "skip: this checkout carries no local patch commits"
  exit 0
fi

export GIT_AUTHOR_NAME=fm-test GIT_AUTHOR_EMAIL=fm-test@example.com
export GIT_COMMITTER_NAME=fm-test GIT_COMMITTER_EMAIL=fm-test@example.com

# new_fixture <name> - echoes a home dir whose default branch is upstream plus
# this repo's local patch commits, with origin pointing at a throwaway upstream.
new_fixture() {
  local name=$1 up home
  up="$TMP_ROOT/$name-up.git"
  home="$TMP_ROOT/$name-home"
  git init --quiet --bare "$up"
  git -C "$up" symbolic-ref HEAD "refs/heads/$DEFAULT"
  git -C "$ROOT" push --quiet "$up" "$UPSTREAM_TIP:refs/heads/$DEFAULT"
  git clone --quiet "$up" "$home"
  git -C "$home" fetch --quiet "$ROOT" "$HOME_TIP"
  git -C "$home" merge --quiet --ff-only FETCH_HEAD \
    || fail "fixture $name: the home's patches do not fast-forward from the seeded upstream"
  printf '%s\n' "$home"
}

# advance_upstream <home> <file> <message> - lands one new upstream commit.
advance_upstream() {
  local home=$1 file=$2 msg=$3 work
  work="$home.upwork"
  rm -rf "$work"
  git clone --quiet "$(git -C "$home" remote get-url origin)" "$work"
  printf '\n<!-- %s -->\n' "$msg" >> "$work/$file"
  git -C "$work" commit --quiet -am "$msg"
  git -C "$work" push --quiet origin "$DEFAULT"
  rm -rf "$work"
}

run_wrapper() { # <home> [args...] -> WRAPPER_OUT / WRAPPER_RC
  local home=$1
  shift
  set +e
  WRAPPER_OUT=$(FM_ROOT_OVERRIDE="$home" "$home/bin/fm-local-update.sh" "$@" 2>&1)
  WRAPPER_RC=$?
  set -e
}

test_plain_updater_refuses_while_patches_are_carried() {
  local home out
  home=$(new_fixture refuse)
  advance_upstream "$home" AGENTS.md "upstream moves on"
  local before
  before=$(git -C "$home" rev-parse HEAD)

  set +e
  out=$(FM_ROOT_OVERRIDE="$home" "$home/bin/fm-update.sh" 2>&1)
  set -e

  assert_contains "$out" "firstmate: skipped: diverged from origin/$DEFAULT" \
    "the plain updater must refuse to advance a branch carrying local patches"
  [ "$(git -C "$home" rev-parse HEAD)" = "$before" ] \
    || fail "the plain updater moved the default branch and dropped local patches"
  pass "the plain updater refuses rather than advancing over local patches"
}

test_wrapper_updates_and_replays_patches() {
  local home local_before
  home=$(new_fixture replay)
  local_before=$(git -C "$home" rev-list --count "origin/$DEFAULT..HEAD")
  advance_upstream "$home" AGENTS.md "upstream instruction change"

  run_wrapper "$home"
  expect_code 0 "$WRAPPER_RC" "wrapper update"
  assert_contains "$WRAPPER_OUT" "local patches replayed onto $DEFAULT" \
    "the wrapper must report the replay"
  assert_contains "$WRAPPER_OUT" "reread-firstmate: yes" \
    "an upstream AGENTS.md change must be reported as an instruction change"
  git -C "$home" merge-base --is-ancestor "origin/$DEFAULT" HEAD \
    || fail "the new upstream commit is not an ancestor of the updated branch"
  [ "$(git -C "$home" rev-list --count "origin/$DEFAULT..HEAD")" = "$local_before" ] \
    || fail "the replay did not preserve every local patch commit"
  pass "the wrapper lands the upstream update and replays the local patches"
}

# Regression: the wrapper must decide there is work to do from "is origin/<default>
# already an ancestor of HEAD", NOT from "did this run's fetch move the ref".
# Trying the plain updater first is the normal way to discover that it refuses,
# and that attempt already fetched - keying off ref movement would then report
# nothing to do while the branch is still behind, silently skipping the update.
test_update_still_lands_when_the_ref_was_already_fetched() {
  local home
  home=$(new_fixture prefetched)
  advance_upstream "$home" AGENTS.md "upstream change discovered by a plain run"
  FM_ROOT_OVERRIDE="$home" "$home/bin/fm-update.sh" >/dev/null 2>&1 || true

  run_wrapper "$home"
  expect_code 0 "$WRAPPER_RC" "wrapper update after a prior fetch"
  assert_not_contains "$WRAPPER_OUT" "already current" \
    "a branch that is still behind must never be reported as already current"
  git -C "$home" merge-base --is-ancestor "origin/$DEFAULT" HEAD \
    || fail "the update was skipped even though the branch was behind"
  pass "an already-fetched upstream ref still lands the update"
}

test_nothing_to_do_is_reported_and_verified() {
  local home
  home=$(new_fixture current)

  run_wrapper "$home"
  expect_code 0 "$WRAPPER_RC" "wrapper with no upstream change"
  assert_contains "$WRAPPER_OUT" "already current" \
    "an unchanged upstream must be reported as already current"
  assert_contains "$WRAPPER_OUT" "local-patch" \
    "verification must run even when the update had nothing to do"
  pass "an unchanged upstream still verifies the patches"
}

test_conflicting_upstream_change_stops_loudly() {
  local home patched_file
  home=$(new_fixture conflict)
  # Replace, upstream, the whole content of a file a local patch also modifies.
  # The replacement must collide with the patch's own hunks - appending to the
  # end of a large file merges cleanly and would not exercise this path at all.
  # Only files that already exist upstream qualify; a file the patches ADD has
  # nothing upstream to conflict with.
  patched_file=$(git -C "$ROOT" diff --name-only "$UPSTREAM_TIP..$HOME_TIP" \
    -- bin/fm-fleet-sync.sh bin/fm-spawn.sh | head -1)
  [ -n "$patched_file" ] || {
    echo "skip: no patched bin/ file to build a conflict from"
    return 0
  }
  local work
  work="$home.conflict"
  rm -rf "$work"
  git clone --quiet "$(git -C "$home" remote get-url origin)" "$work"
  printf '#!/usr/bin/env bash\n# upstream rewrote this file entirely\n' > "$work/$patched_file"
  git -C "$work" commit --quiet -am "upstream rewrites a locally patched file"
  git -C "$work" push --quiet origin "$DEFAULT"
  rm -rf "$work"

  run_wrapper "$home"
  expect_code 2 "$WRAPPER_RC" "wrapper on a conflicting replay"
  assert_contains "$WRAPPER_OUT" "LOCAL PATCH COULD NOT BE CARRIED FORWARD" \
    "a replay conflict must stop the update loudly"
  assert_contains "$WRAPPER_OUT" "rebase --abort" \
    "the failure must name the command that restores the pre-update state"

  git -C "$home" rebase --abort
  run_wrapper "$home" --verify
  expect_code 0 "$WRAPPER_RC" "verify after aborting the conflicted replay"
  pass "a conflicting upstream change stops loudly and aborts back to intact patches"
}

test_reverted_patch_is_reported_as_lost() {
  local home target
  home=$(new_fixture reverted)
  target=$(git -C "$ROOT" diff --name-only "$UPSTREAM_TIP..$HOME_TIP" -- 'bin/fm-spawn.sh' 'bin/fm-fleet-sync.sh' | head -1)
  [ -n "$target" ] || {
    echo "skip: no verified patch file present to revert"
    return 0
  }
  git -C "$home" show "$UPSTREAM_TIP:$target" > "$home/$target"

  run_wrapper "$home" --verify
  expect_code 2 "$WRAPPER_RC" "verify with a reverted patch"
  assert_contains "$WRAPPER_OUT" "LOCAL PATCH LOST" \
    "a reverted patch must be reported loudly, not silently tolerated"
  assert_contains "$WRAPPER_OUT" "restore:" \
    "the report must name the fork branch that restores the patch"
  pass "a patch reverted in the working tree is reported as lost"
}

test_brief_decision_key_patch_is_verified() {
  local home
  home=$(new_fixture brief-key)
  git -C "$ROOT" diff --quiet "$UPSTREAM_TIP" "$HOME_TIP" -- bin/fm-brief.sh && {
    echo "skip: bin/fm-brief.sh carries no local patch"
    return 0
  }

  run_wrapper "$home" --verify
  expect_code 0 "$WRAPPER_RC" "verify with the brief key-spelling patch intact"
  assert_contains "$WRAPPER_OUT" "local-patch brief-decision-key-format: applied" \
    "the intact brief key-spelling patch must verify as applied"

  git -C "$home" show "$UPSTREAM_TIP:bin/fm-brief.sh" > "$home/bin/fm-brief.sh"
  run_wrapper "$home" --verify
  expect_code 2 "$WRAPPER_RC" "verify with the brief key-spelling patch reverted"
  assert_contains "$WRAPPER_OUT" "local-patch brief-decision-key-format: LOST" \
    "a reverted brief key-spelling patch must be reported as lost"
  assert_contains "$WRAPPER_OUT" "restore: fm/fm-brief-decision-key-format@" \
    "the report must name the fork branch that restores the brief patch"
  pass "the brief key-spelling patch verifies when present and is reported lost when reverted"
}

test_captain_hold_archive_patch_is_verified() {
  local home file
  home=$(new_fixture archive-fallback)
  git -C "$ROOT" diff --quiet "$UPSTREAM_TIP" "$HOME_TIP" -- \
    bin/fm-captain-hold.sh bin/fm-backlog-transition-lib.sh && {
    echo "skip: the captain-hold archive fallback files carry no local patch"
    return 0
  }

  run_wrapper "$home" --verify
  expect_code 0 "$WRAPPER_RC" "verify with the captain-hold archive fallback intact"
  assert_contains "$WRAPPER_OUT" "local-patch captain-hold-archive-fallback: applied" \
    "the intact archive fallback must verify as applied"

  # Each file carries half of the patch, so each is reverted on its own.
  for file in bin/fm-captain-hold.sh bin/fm-backlog-transition-lib.sh; do
    cp "$home/$file" "$home/$file.kept"
    git -C "$home" show "$UPSTREAM_TIP:$file" > "$home/$file"
    run_wrapper "$home" --verify
    expect_code 2 "$WRAPPER_RC" "verify with the archive fallback reverted in $file"
    assert_contains "$WRAPPER_OUT" "local-patch captain-hold-archive-fallback: LOST - $file" \
      "a revert of $file must be reported as the archive fallback lost, naming the file"
    assert_contains "$WRAPPER_OUT" "restore: fm/fm-decision-hold-pruned@" \
      "the report must name the fork branch that restores the archive fallback"
    mv "$home/$file.kept" "$home/$file"
  done
  pass "the captain-hold archive fallback verifies when present and is reported lost when either half is reverted"
}

test_refuses_outside_the_primary_checkout() {
  local home
  home=$(new_fixture detached)
  git -C "$home" checkout --quiet --detach HEAD

  run_wrapper "$home"
  expect_code 1 "$WRAPPER_RC" "wrapper at a detached HEAD"
  assert_contains "$WRAPPER_OUT" "expected '$DEFAULT'" \
    "the wrapper must refuse to rebase anywhere but the primary checkout's default branch"
  pass "the wrapper refuses to run outside the primary checkout"
}

test_plain_updater_refuses_while_patches_are_carried
test_wrapper_updates_and_replays_patches
test_update_still_lands_when_the_ref_was_already_fetched
test_nothing_to_do_is_reported_and_verified
test_conflicting_upstream_change_stops_loudly
test_reverted_patch_is_reported_as_lost
test_brief_decision_key_patch_is_verified
test_captain_hold_archive_patch_is_verified
test_refuses_outside_the_primary_checkout

echo "all fm-local-update tests passed"
