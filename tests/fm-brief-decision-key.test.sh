#!/usr/bin/env bash
# Behavior tests for the keyed status spelling bin/fm-brief.sh teaches.
#
# A decision key is read only from the canonical `<verb> [key=<slug>]: <note>`
# position, where it may sit beside the optional `[at=<epoch>]` stamp in either
# order. The scaffold once described the key in a trailing parenthetical -
# "append `resolved: {how it was decided}` (add the same `[key=<slug>]` if you
# opened it with one)" - which reads literally as `resolved: [key=<slug>] note`.
# A parser that does not see that token folds every such line onto one shared
# slot, so a single resolution erased every other open captain decision, and in
# the generated ordinary ship brief that sentence was the only keyed guidance a
# crewmate could copy.
#
# These tests read the GENERATED briefs, which are what a crewmate actually
# copies from, and fold the brief's own templates through the running
# bin/fm-classify-lib.sh, so the instruction and the parser are checked together.
# Every fold assertion uses only the canonical spelling, which every parser
# version agrees on.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief-decision-key)
KEY_HOME="$TMP_ROOT/home"
mkdir -p "$KEY_HOME/data"

# generate_brief <id> <fm-brief.sh args...> - echoes the generated brief path.
generate_brief() {
  local id=$1
  shift
  FM_HOME="$KEY_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_SECONDMATE_CHARTER='sample domain' \
    "$ROOT/bin/fm-brief.sh" "$id" "$@" >/dev/null 2>&1 \
    || fail "fm-brief.sh failed to scaffold $id ($*)"
  printf '%s\n' "$KEY_HOME/data/$id/brief.md"
}

# Every scaffold variant a worker can receive, generated in the caller's own
# shell so a variant that fails to scaffold fails the test instead of silently
# dropping out of a command-substitution list.
all_briefs() { # sets BRIEFS
  BRIEFS=()
  local spec id
  for spec in 'key-nm some-proj --mode no-mistakes' 'key-dpr some-proj --mode direct-PR' \
    'key-lo some-proj --mode local-only' 'key-scout some-proj --scout' \
    'key-mate --secondmate --no-projects'; do
    id=${spec%% *}
    # shellcheck disable=SC2086 # Each spec is deliberately word-split into arguments.
    FM_HOME="$KEY_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_SECONDMATE_CHARTER='sample domain' \
      "$ROOT/bin/fm-brief.sh" $spec >/dev/null 2>&1 \
      || fail "fm-brief.sh failed to scaffold $spec"
    [ -s "$KEY_HOME/data/$id/brief.md" ] || fail "fm-brief.sh wrote no brief for $spec"
    BRIEFS+=("$KEY_HOME/data/$id/brief.md")
  done
}

# Print each line of <brief> that mentions a key token outside the canonical
# pre-colon position and is not an explicitly WRONG-labelled counter-example.
# Prose that names a keyed status without its note, such as the scout's
# "write needs-decision [key=board-review] with the live board URL", still puts
# the key straight after the verb, so a status verb directly before the key
# counts as canonical too.
non_canonical_key_lines() { # <brief>
  grep -F '[key=' "$1" \
    | grep -vE '[a-z-]+( \[(at|corr)=[^]]*\])* \[key=[^]]*\]( \[(at|corr)=[^]]*\])*:' \
    | grep -vE '(^|[^[:alnum:]_-])(needs-decision|blocked|resolved|paused)( \[(at|corr)=[^]]*\])* \[key=[^]]*\]' \
    | grep -vF 'WRONG' || true
}

test_every_generated_brief_teaches_only_the_canonical_spelling() {
  local brief tmpl offenders bare
  all_briefs
  [ "${#BRIEFS[@]}" -eq 5 ] || fail "expected 5 generated briefs, got ${#BRIEFS[@]}"
  for brief in "${BRIEFS[@]}"; do
    for tmpl in 'needs-decision [key=<slug>] [at=<epoch>]: ' 'blocked [key=<slug>] [at=<epoch>]: ' 'resolved [key=<slug>] [at=<epoch>]: '; do
      assert_grep "$tmpl" "$brief" \
        "$brief carries no copyable '$tmpl' template"
    done
    assert_grep 'a slug uses only letters, digits' "$brief" \
      "$brief does not state which characters a key slug may use"
    assert_no_grep 'if you opened it with one)' "$brief" \
      "$brief still describes the key in the ambiguous trailing parenthetical"
    offenders=$(non_canonical_key_lines "$brief")
    [ -z "$offenders" ] \
      || fail "$brief teaches a key token outside the canonical position:"$'\n'"$offenders"
    bare=$(grep -F ': [key=' "$brief" | grep -vF 'WRONG' || true)
    [ -z "$bare" ] \
      || fail "$brief shows the note-leading spelling without naming it wrong:"$'\n'"$bare"
  done
  pass "fm-brief.sh: every generated brief teaches only the canonical key spelling"
}

# template_for <brief> <verb> - the brief's own template line for <verb>,
# trimmed, so the fold below runs on exactly what a worker would copy.
template_for() {
  grep -E "^[[:space:]]*$2 \\[key=<slug>\\] \\[at=<epoch>\\]: " "$1" | head -1 \
    | sed -e 's/^[[:space:]]*//'
}

# instantiate <template> <slug> - fill a template the way a worker would.
instantiate() {
  local line=${1//<slug>/$2}
  line=${line//<epoch>/1788576000}
  printf '%s\n' "$line"
}

# A resolution must close only its own key: the multi-key independence case that
# the collapsed spelling broke, built from the generated ordinary ship brief.
test_brief_templates_close_only_their_own_key() {
  local brief status open nd bl rs
  brief=$(generate_brief key-fold some-proj --mode no-mistakes)
  nd=$(template_for "$brief" needs-decision)
  bl=$(template_for "$brief" blocked)
  rs=$(template_for "$brief" resolved)
  [ -n "$nd" ] && [ -n "$bl" ] && [ -n "$rs" ] \
    || fail "the generated ship brief lacks a needs-decision, blocked, or resolved template"

  status="$TMP_ROOT/fold.status"
  {
    instantiate "$nd" alpha
    instantiate "$nd" beta
    instantiate "$bl" gamma
    instantiate "$rs" beta
  } > "$status"
  open=$(bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2"' _ "$ROOT" "$status" | cut -f1 | sort | tr '\n' ' ')
  [ "$open" = "alpha gamma " ] \
    || fail "resolving beta must leave alpha and gamma open, got '$open' from:"$'\n'"$(cat "$status")"
  pass "a resolution written from the brief's template closes only its own key"
}

# A captain-held transfer closes only its own key, in a log mixing it with an
# ordinary resolution.
test_captain_held_closes_only_its_own_key() {
  local status open
  status="$TMP_ROOT/held.status"
  printf '%s\n' \
    'needs-decision [key=alpha]: first' \
    'needs-decision [key=beta]: second' \
    'blocked [key=gamma]: third' \
    'captain-held [key=beta]: moved to the captain backlog' \
    'resolved [key=gamma]: cleared' > "$status"
  open=$(bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2"' _ "$ROOT" "$status" | cut -f1 | tr '\n' ' ')
  [ "$open" = "alpha " ] \
    || fail "captain-held beta and resolved gamma must leave only alpha open, got '$open'"
  pass "a captain-held line closes only its own key"
}

test_every_generated_brief_teaches_only_the_canonical_spelling
test_brief_templates_close_only_their_own_key
test_captain_held_closes_only_its_own_key

echo "all fm-brief-decision-key tests passed"
