#!/usr/bin/env bash
# Regression coverage for the Lavish artifact scroll contract.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL="$ROOT/.agents/skills/lavish-artifacts/SKILL.md"
FIXTURE="$ROOT/tests/fixtures/lavish-scroll-root.html"
AGENTS="$ROOT/AGENTS.md"
FLEET_HYGIENE="$ROOT/.agents/skills/fleet-hygiene/SKILL.md"

extract_css_rule() {
  local file=$1 selector=$2

  awk -v selector="$selector" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    !inside && trim($0) == selector " {" {
      inside = 1
      next
    }
    inside && trim($0) == "}" {
      found = 1
      exit
    }
    inside {
      line = trim($0)
      if (line != "") print line
    }
    END {
      if (!found) exit 1
    }
  ' "$file"
}

require_declarations() {
  local file=$1 selector=$2 label=$3 rule declaration
  shift 3

  rule=$(extract_css_rule "$file" "$selector") || fail "$label lost the $selector declaration block"
  for declaration in "$@"; do
    if ! grep -Fqx -- "$declaration" <<<"$rule"; then
      fail "$label lost '$declaration' from the $selector declaration block"
    fi
  done
}

require_scroll_contract() {
  local file=$1 label=$2

  require_declarations "$file" 'html, body' "$label" \
    'margin: 0;' \
    'padding: 0;' \
    'height: 100%;' \
    'width: 100%;' \
    'overflow: hidden;'
  require_declarations "$file" '#scroll-root' "$label" \
    'height: 100%;' \
    'width: 100%;' \
    'overflow-x: hidden;' \
    'overflow-y: scroll;' \
    '-webkit-overflow-scrolling: touch;' \
    'touch-action: pan-y;' \
    'overscroll-behavior-x: none;' \
    'overscroll-behavior-y: auto;'
}

test_skill_owns_scroll_contract() {
  assert_present "$SKILL" "Lavish artifact skill is missing"
  assert_grep 'name: lavish-artifacts' "$SKILL" "Lavish artifact skill has the wrong name"
  assert_grep 'user-invocable: false' "$SKILL" "Lavish artifact skill must be agent-only"
  assert_grep 'internal: true' "$SKILL" "Lavish artifact skill must be internal"
  assert_grep 'Load this skill before authoring, substantially editing, or presenting a Lavish HTML artifact for captain review.' "$SKILL" \
    "Lavish artifact skill lost its load trigger"
  require_scroll_contract "$SKILL" "Lavish artifact skill"
  pass "Lavish artifact skill owns the scroll contract"
}

test_fixture_implements_scroll_root_pattern() {
  assert_present "$FIXTURE" "Lavish scroll fixture is missing"
  require_scroll_contract "$FIXTURE" "Lavish scroll fixture"
  assert_grep '<div id="scroll-root">' "$FIXTURE" "Lavish scroll fixture does not wrap body content"
  assert_grep 'overflow-x: auto' "$FIXTURE" "Lavish scroll fixture lost child horizontal overflow"
  pass "Lavish scroll fixture implements the scroll-root pattern"
}

test_runtime_triggers_point_to_skill() {
  assert_grep '- `lavish-artifacts` - load before authoring, substantially editing, or presenting a Lavish HTML artifact for captain review.' "$AGENTS" \
    "AGENTS.md lost the Lavish artifact trigger"
  assert_grep 'load `lavish-artifacts` and apply its scroll contract' "$FLEET_HYGIENE" \
    "fleet-hygiene no longer points at the Lavish artifact skill"
  pass "Runtime triggers point at the Lavish artifact skill"
}

test_skill_owns_full_contract_not_agents() {
  local agents_trigger_count

  agents_trigger_count=$(grep -Fc -- '- `lavish-artifacts` -' "$AGENTS")
  [ "$agents_trigger_count" -eq 1 ] || fail "AGENTS.md must have exactly one lavish-artifacts section 13 trigger, found $agents_trigger_count"
  assert_no_grep 'overflow-y: scroll' "$AGENTS" "AGENTS.md restated the Lavish CSS contract"
  pass "AGENTS.md keeps only the inline trigger"
}

test_skill_owns_full_contract_not_fleet_hygiene() {
  assert_no_grep 'overflow-y: scroll' "$FLEET_HYGIENE" "fleet-hygiene restated the Lavish CSS contract"
  assert_no_grep 'touch-action: pan-y' "$FLEET_HYGIENE" "fleet-hygiene restated the Lavish CSS contract"
  pass "fleet-hygiene keeps only a pointer to the scroll contract"
}

test_skill_owns_scroll_contract
test_fixture_implements_scroll_root_pattern
test_runtime_triggers_point_to_skill
test_skill_owns_full_contract_not_agents
test_skill_owns_full_contract_not_fleet_hygiene
