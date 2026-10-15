#!/usr/bin/env bash
# Update a firstmate home that carries LOCAL PATCHES, and prove they survived.
#
# This home carries fixes that upstream will not take (see data/local-patches.md
# for the captain's decision and the per-patch manifest). They live as ordinary
# commits on the local default branch, on top of origin's. That placement is what
# makes the whole scheme safe, because of one property:
#
#   bin/fm-update.sh advances the default branch only when
#   `git merge-base --is-ancestor HEAD origin/<default>` holds. With local patch
#   commits on the branch that predicate is false unless upstream has absorbed
#   them. So the plain updater ADVANCES ONLY WHEN THE PATCHES ARE ALREADY
#   UPSTREAM, and otherwise refuses with "skipped: diverged from origin/<default>".
#
# There is therefore no path in which an update moves the branch forward and
# silently drops a patch: the plain updater either refuses, or the patches are
# upstream anyway. A patch can be lost only by an explicit force, which no
# firstmate path performs.
#
# This script is the update entry point for such a home. It runs the ordinary
# updater for its secondmate work, then replays the local patches onto the new
# upstream with a rebase, then VERIFIES each patch against the file that is
# actually on disk. Verification is not optional and not remembered: an update
# that cannot carry a patch forward stops here, loudly, naming the fork branch
# that can restore it.
#
# The rebase is the only local-patch mutation, and it is deliberately conservative:
#   --no-autostash    never stash; a dirty tree is refused, not hidden
#   --no-update-refs  never move another branch that points into the replayed
#                     range, because sibling worktrees may have work checked out
# Both are passed explicitly so behavior never depends on ambient git config.
# A conflict stops the rebase and leaves the checkout mid-rebase; the failure
# output states that and names `git rebase --abort` as the restore.
#
# Nothing here touches projects/, forces, or discards committed work. The patch
# commits also remain on their fork branches, which the manifest records as the
# recovery source.
#
# Usage: fm-local-update.sh [--verify] [--help]
#   (no args)  update from upstream, replay local patches, verify
#   --verify   verify only: no network, no mutation, safe to run any time
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
MANIFEST="$FM_HOME/data/local-patches.md"

usage() { echo "usage: fm-local-update.sh [--verify] [--help]" >&2; }

MODE=update
case "${1:-}" in
  --help | -h)
    usage
    exit 0
    ;;
  --verify) MODE=verify ;;
  "") ;;
  *)
    usage
    exit 1
    ;;
esac
[ $# -le 1 ] || {
  usage
  exit 1
}

# --- the patch manifest, in the order data/local-patches.md applies them -----
#
# Each entry is: <id>|<file>|<fork branch>@<sha>
# The per-patch assertions live in verify_one below. They inspect the RUNNING
# file rather than git history, because a commit can survive while the change it
# made is gone - that is the manifest's rule 3, and it is the failure this whole
# mechanism exists to catch.

PATCH_IDS="spawn-bare-clone fleet-sync-bare-clone spawn-settings-pretty-print brief-decision-key-format"

patch_file() {
  case "$1" in
    spawn-bare-clone | spawn-settings-pretty-print) echo "bin/fm-spawn.sh" ;;
    fleet-sync-bare-clone) echo "bin/fm-fleet-sync.sh" ;;
    brief-decision-key-format) echo "bin/fm-brief.sh" ;;
  esac
}

patch_source() {
  case "$1" in
    spawn-bare-clone)
      echo "fm/fm-spawn-bare-clone@99b407a803bf0a14dfe39b11043de6b9c6ab5f20"
      ;;
    fleet-sync-bare-clone)
      echo "fm/fm-fleet-sync-bare-clone@d91b457fef389dc1d453a6f6925813a31d6194cd"
      ;;
    spawn-settings-pretty-print)
      echo "fm/fm-settings-local-minified@f7a8e3bf093e6e9c3b80764e67fe61fd06f2ab4c"
      ;;
    brief-decision-key-format)
      echo "fm/fm-brief-decision-key-format@611d0c9ff6e5ecbc2380e8da4c2ea827d0bf4d76"
      ;;
  esac
}

# Assert a patch is present in the file on disk. Each patch is checked by more
# than one anchor - a definition AND its call site, or a new form AND the absence
# of the old one - so a half-reverted patch fails instead of passing on a
# surviving fragment. VERIFY_DETAIL names the first failing anchor.
VERIFY_DETAIL=""
verify_one() {
  local id=$1 f
  f="$FM_ROOT/$(patch_file "$id")"
  VERIFY_DETAIL=""
  if [ ! -f "$f" ]; then
    VERIFY_DETAIL="$(patch_file "$id") is missing"
    return 1
  fi
  case "$id" in
    spawn-bare-clone)
      # The bare-flagged-clone lease: its detector, the lease itself, and the
      # abort-path release that must not outlive the task's ownership.
      grep -q '^project_is_bare_flagged()' "$f" || {
        VERIFY_DETAIL="project_is_bare_flagged() is gone"
        return 1
      }
      grep -q '^lease_bare_clone_worktree()' "$f" || {
        VERIFY_DETAIL="lease_bare_clone_worktree() is gone"
        return 1
      }
      grep -q 'GIT_WORK_TREE' "$f" || {
        VERIFY_DETAIL="the GIT_WORK_TREE lease override is gone"
        return 1
      }
      grep -q -- '--if-lease-holder' "$f" || {
        VERIFY_DETAIL="the --if-lease-holder release guard is gone"
        return 1
      }
      ;;
    fleet-sync-bare-clone)
      # The ref-only advance: the function the manifest names, its call site,
      # and the bare detection that selects it.
      grep -q '^advance_local_default()' "$f" || {
        VERIFY_DETAIL="advance_local_default() is gone"
        return 1
      }
      grep -q 'if ! advance_local_default; then' "$f" || {
        VERIFY_DETAIL="advance_local_default() is defined but no longer called"
        return 1
      }
      grep -q 'is-bare-repository' "$f" || {
        VERIFY_DETAIL="the core.bare detection is gone"
        return 1
      }
      ;;
    spawn-settings-pretty-print)
      # The shape of the settings file this script WRITES, asserted on the
      # heredoc that produces it: a 2-space-indented depth-1 key and a
      # 4-space-indented depth-2 key (which together pin indent width 2, and
      # pin spaces rather than biome's default tabs), plus the absence of the
      # minified writer this patch replaced.
      if ! grep -q '^  "hooks": {$' "$f"; then
        VERIFY_DETAIL="the 2-space-indented \"hooks\" line is gone"
        return 1
      fi
      if ! grep -q '^    "UserPromptSubmit": \[$' "$f"; then
        VERIFY_DETAIL="the 4-space depth-2 indent is gone (indent width changed?)"
        return 1
      fi
      if grep -q '{"hooks":{"UserPromptSubmit"' "$f"; then
        VERIFY_DETAIL="the minified settings writer is back"
        return 1
      fi
      ;;
    brief-decision-key-format)
      # The keyed status spelling every scaffold teaches: a canonical resolved
      # template in each of the three scaffolds (ship, scout, secondmate
      # charter), and the absence of the trailing parenthetical that read
      # literally as the note-leading spelling. The count catches a replay
      # conflict resolved in only some of the scaffolds.
      # Upstream stamps every status line with [at=<epoch>], so the template
      # carries the stamp after the key, still before the colon.
      if [ "$(grep -c 'resolved \[key=<slug>\] \[at=<epoch>\]: ' "$f")" -lt 3 ]; then
        VERIFY_DETAIL="a scaffold lost its canonical resolved [key=<slug>] [at=<epoch>]: template"
        return 1
      fi
      if grep -q 'if you opened it with one)' "$f"; then
        VERIFY_DETAIL="the ambiguous trailing key parenthetical is back"
        return 1
      fi
      ;;
    *)
      VERIFY_DETAIL="no verification defined"
      return 1
      ;;
  esac
  return 0
}

# Verify every patch. Prints one line per patch and returns non-zero if any is
# missing, with a banner that names the recovery source.
verify_patches() {
  local id rc=0 failed=""
  echo "--- local patch verification (${FM_ROOT}) ---"
  for id in $PATCH_IDS; do
    if verify_one "$id"; then
      echo "local-patch $id: applied"
    else
      echo "local-patch $id: LOST - $VERIFY_DETAIL"
      failed="$failed $id"
      rc=2
    fi
  done
  if [ "$rc" -ne 0 ]; then
    echo ""
    echo "########################################################"
    echo "# LOCAL PATCH LOST - this home is missing a fix it needs"
    echo "########################################################"
    for id in $failed; do
      echo "  $id"
      echo "    file:    $(patch_file "$id")"
      echo "    restore: $(patch_source "$id")"
    done
    echo ""
    echo "  manifest: $MANIFEST"
    echo "  Restore from the fork branch above, then re-run --verify."
    echo "  Do not treat this as a note: it is a regression in a shipped fix."
  fi
  return "$rc"
}

if [ "$MODE" = verify ]; then
  verify_patches
  exit $?
fi

# --- update path ------------------------------------------------------------

default_branch_name() {
  local ref
  ref=$(git -C "$FM_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  case "$ref" in
    origin/*)
      echo "${ref#origin/}"
      return 0
      ;;
  esac
  if git -C "$FM_ROOT" show-ref --verify --quiet refs/heads/main; then
    echo main
  else
    echo master
  fi
}

DEFAULT=$(default_branch_name)

# Preconditions. This must run against the PRIMARY checkout on its default
# branch: a linked worktree is at a detached HEAD or on a task branch, and
# rebasing there would replay the wrong commits.
cur=$(git -C "$FM_ROOT" symbolic-ref --short HEAD 2>/dev/null || echo "")
if [ "$cur" != "$DEFAULT" ]; then
  echo "fm-local-update: refusing: $FM_ROOT is on '${cur:-detached HEAD}', expected '$DEFAULT'." >&2
  echo "fm-local-update: run this against the primary checkout, not a task worktree." >&2
  exit 1
fi
if [ -n "$(git -C "$FM_ROOT" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "fm-local-update: refusing: $FM_ROOT has local changes." >&2
  echo "fm-local-update: commit or remove them first; this never stashes." >&2
  exit 1
fi
if [ -d "$(git -C "$FM_ROOT" rev-parse --path-format=absolute --git-path rebase-merge 2>/dev/null)" ] \
  || [ -d "$(git -C "$FM_ROOT" rev-parse --path-format=absolute --git-path rebase-apply 2>/dev/null)" ]; then
  echo "fm-local-update: refusing: a rebase is already in progress in $FM_ROOT." >&2
  echo "fm-local-update: finish it or run 'git -C $FM_ROOT rebase --abort' first." >&2
  exit 1
fi

# Delegate to the ordinary updater. It owns the fetch and every secondmate
# target. Its own line for this repo is expected to say "skipped: diverged",
# because that is exactly the refusal that keeps our patches safe - it is
# replaced below with the authoritative result. Any OTHER skip reason is a real
# problem and is passed through untouched.
echo "--- upstream update ---"
update_rc=0
update_out=$("$SCRIPT_DIR/fm-update.sh" 2>&1) || update_rc=$?
expected_skip="firstmate: skipped: diverged from origin/$DEFAULT"
printf '%s\n' "$update_out" \
  | grep -v -x -F "$expected_skip" \
  | grep -v -E '^reread-firstmate: ' || true
if [ "$update_rc" -ne 0 ]; then
  echo "fm-local-update: the upstream updater exited $update_rc (output above)." >&2
fi

upstream=$(git -C "$FM_ROOT" rev-parse --verify --quiet "refs/remotes/origin/$DEFAULT" 2>/dev/null || echo "")

# The upstream commit this home has ALREADY incorporated - the commit our patch
# commits currently sit on. Everything below keys off this rather than off
# whether the fetch moved origin/<default> during this run: the ref may already
# have been current before we started (an earlier fetch, a bootstrap sweep, or
# the plain updater being tried first, which is the normal way to discover that
# it refuses). Asking "did the ref move" would then report nothing to do while
# the branch is still behind, which is a silently skipped update.
carried_base=""
if [ -n "$upstream" ]; then
  carried_base=$(git -C "$FM_ROOT" merge-base HEAD "$upstream" 2>/dev/null || echo "")
fi

# --- replay the local patches onto the new upstream -------------------------

echo "--- local patches ---"
rebase_rc=0
before_head=$(git -C "$FM_ROOT" rev-parse --short HEAD)
if [ -z "$upstream" ] || [ -z "$carried_base" ]; then
  echo "firstmate: skipped: origin/$DEFAULT is unreadable (fetch failed?)"
  rebase_rc=1
elif git -C "$FM_ROOT" merge-base --is-ancestor "$upstream" HEAD 2>/dev/null; then
  echo "firstmate: already current"
else
  rebase_out=""
  if rebase_out=$(git -C "$FM_ROOT" rebase --no-autostash --no-update-refs \
    "refs/remotes/origin/$DEFAULT" 2>&1); then
    after_head=$(git -C "$FM_ROOT" rev-parse --short HEAD)
    echo "firstmate: updated $before_head..$after_head (local patches replayed onto $DEFAULT)"
  else
    rebase_rc=$?
    printf '%s\n' "$rebase_out" >&2
    echo "" >&2
    echo "#############################################################" >&2
    echo "# LOCAL PATCH COULD NOT BE CARRIED FORWARD - update stopped" >&2
    echo "#############################################################" >&2
    echo "  $FM_ROOT is now MID-REBASE on '$DEFAULT'." >&2
    echo "  Resolve the conflict and 'git -C $FM_ROOT rebase --continue'," >&2
    echo "  or restore the pre-update state with:" >&2
    echo "      git -C $FM_ROOT rebase --abort" >&2
    echo "  Patches were NOT verified because the tree is mid-rebase." >&2
    echo "  manifest: $MANIFEST" >&2
    exit 2
  fi
fi

# Which watched instruction paths upstream changed. The watched surface is the
# one bin/fm-ff-lib.sh's changed_instr defines (AGENTS.md, bin, .agents/skills);
# keep this list in step with it. Compared from the upstream commit this home
# had already incorporated to the new one, so it reports what upstream actually
# changed: our own patches touch bin/, and comparing against our branch tip
# instead would force a re-read on every run that upstream did not earn.
instr=""
if [ -n "$upstream" ] && [ -n "$carried_base" ] && [ "$carried_base" != "$upstream" ]; then
  for p in AGENTS.md bin .agents/skills; do
    if ! git -C "$FM_ROOT" diff --quiet "$carried_base" "$upstream" -- "$p" 2>/dev/null; then
      instr="$instr${instr:+, }$p"
    fi
  done
fi
if [ -n "$instr" ]; then
  echo "reread-firstmate: yes (instructions changed: $instr)"
else
  echo "reread-firstmate: no"
fi

# --- verification always runs ------------------------------------------------
# Reached whether the rebase replayed commits, reported nothing to do, or the
# delegated updater failed. A rebase can drop a patch that became empty and still
# exit 0, so a clean rebase is not evidence a patch survived; only this is.

echo ""
verify_rc=0
verify_patches || verify_rc=$?

if [ "$verify_rc" -ne 0 ]; then
  exit "$verify_rc"
fi
if [ "$rebase_rc" -ne 0 ] || [ "$update_rc" -ne 0 ]; then
  exit 1
fi
exit 0
