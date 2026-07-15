#!/usr/bin/env bash
# test_hooks.sh — regression tests for generate-qr-code.sh,
# reinforce-round-report.sh, guard-publish-widget-update-mode.sh, and
# reinforce-publish-widget-update.sh (capture-inspect-screen.sh's own
# live-device verification is documented in this repo's commit history
# instead; these don't need a real device, so a real automated test is
# practical here).
#
# Run: bash scripts/test_hooks.sh
#
# Each test builds a synthetic PostToolUse hook input via jq -n (never plain
# string concatenation - a real bug during development came from exactly
# that: nested shell-quoting corrupted a test fixture into invalid JSON that
# then silently looked like a hook failure instead of a test-construction
# bug). Asserts on the ACTUAL script output, not a reimplementation of its
# logic.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0
PASSED=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS  $desc"
    PASSED=$((PASSED + 1))
  else
    echo "  FAIL  $desc"
    echo "        expected: $expected"
    echo "        actual:   $actual"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_not_empty() {
  local desc="$1" actual="$2"
  if [ -n "$actual" ] && [ "$actual" != "null" ]; then
    echo "  PASS  $desc"
    PASSED=$((PASSED + 1))
  else
    echo "  FAIL  $desc (got empty/null)"
    FAILURES=$((FAILURES + 1))
  fi
}

# ── generate-qr-code.sh ──────────────────────────────────────────────────

echo "generate-qr-code.sh:"

launch_result="$(jq -n '{
  commands: {ios: "xcrun simctl openurl booted test"},
  navlink: "https://www.indmoney.com/widget/page?page=abcd&api_endpoint=test123",
  instruction: "Use your Bash tool...",
  next_step: "If this launch is for verifying..."
}')"
input="$(jq -n --arg text "$launch_result" '{tool_response: [{text: $text}]}')"
output="$(echo "$input" | bash "$SCRIPT_DIR/generate-qr-code.sh")"
updated="$(echo "$output" | jq -r '.hookSpecificOutput.updatedToolOutput')"

assert_eq "original 'instruction' field preserved" \
  "Use your Bash tool..." "$(echo "$updated" | jq -r '.instruction')"
assert_eq "original 'navlink' field preserved" \
  "https://www.indmoney.com/widget/page?page=abcd&api_endpoint=test123" "$(echo "$updated" | jq -r '.navlink')"
qr_path="$(echo "$updated" | jq -r '.qr_code_path')"
assert_not_empty "qr_code_path field is present" "$qr_path"
if [ -f "$qr_path" ] && file "$qr_path" | grep -q "PNG image data"; then
  echo "  PASS  qr_code_path points to a real PNG file"
  PASSED=$((PASSED + 1))
  rm -f "$qr_path"  # test cleanup - don't leave synthetic QR codes around
else
  echo "  FAIL  qr_code_path does not point to a real PNG file"
  FAILURES=$((FAILURES + 1))
fi

# Missing navlink -> must fail open (pass_through), not crash or hang
no_navlink_result="$(jq -n '{commands: {}, instruction: "x"}')"
no_navlink_input="$(jq -n --arg text "$no_navlink_result" '{tool_response: [{text: $text}]}')"
no_navlink_output="$(echo "$no_navlink_input" | bash "$SCRIPT_DIR/generate-qr-code.sh")"
assert_eq "missing navlink falls through to continue:true" \
  "true" "$(echo "$no_navlink_output" | jq -r '.continue')"

# Malformed tool_response text -> must fail open, not crash
malformed_output="$(echo '{"tool_response":[{"text":"not json"}]}' | bash "$SCRIPT_DIR/generate-qr-code.sh")"
assert_eq "malformed tool_response text falls through to continue:true" \
  "true" "$(echo "$malformed_output" | jq -r '.continue')"

# Completely empty input -> must fail open, not crash
empty_output="$(echo '{}' | bash "$SCRIPT_DIR/generate-qr-code.sh")"
assert_eq "empty input falls through to continue:true" \
  "true" "$(echo "$empty_output" | jq -r '.continue')"

# ── reinforce-round-report.sh ────────────────────────────────────────────

echo ""
echo "reinforce-round-report.sh:"

relaunch_result="$(jq -n '{
  action: "relaunch", iteration: 3, stage: "tier1_5",
  round_report: "test report content", round_report_note: "mandatory..."
}')"
relaunch_input="$(jq -n --arg text "$relaunch_result" '{tool_response: [{text: $text}]}')"
relaunch_output="$(echo "$relaunch_input" | bash "$SCRIPT_DIR/reinforce-round-report.sh")"
relaunch_updated="$(echo "$relaunch_output" | jq -r '.hookSpecificOutput.updatedToolOutput')"

assert_eq "original 'action' field preserved" \
  "relaunch" "$(echo "$relaunch_updated" | jq -r '.action')"
mandatory_msg="$(echo "$relaunch_updated" | jq -r '.MANDATORY_VISIBLE_CHAT_MESSAGE_THIS_TURN')"
assert_not_empty "MANDATORY_VISIBLE_CHAT_MESSAGE_THIS_TURN is present" "$mandatory_msg"
if echo "$mandatory_msg" | grep -q "test report content"; then
  echo "  PASS  reinforcement message includes the real round_report content"
  PASSED=$((PASSED + 1))
else
  echo "  FAIL  reinforcement message does not include round_report content"
  FAILURES=$((FAILURES + 1))
fi
if echo "$mandatory_msg" | grep -q "TERMINAL round"; then
  echo "  FAIL  non-terminal (relaunch) round must NOT include the terminal-round note"
  FAILURES=$((FAILURES + 1))
else
  echo "  PASS  non-terminal (relaunch) round correctly omits the terminal-round note"
  PASSED=$((PASSED + 1))
fi

giveup_result="$(jq -n '{
  action: "give_up", iteration: 5, stage: "tier2", reason: "max_iterations",
  round_report: "final report content", round_report_note: "mandatory..."
}')"
giveup_input="$(jq -n --arg text "$giveup_result" '{tool_response: [{text: $text}]}')"
giveup_output="$(echo "$giveup_input" | bash "$SCRIPT_DIR/reinforce-round-report.sh")"
giveup_updated="$(echo "$giveup_output" | jq -r '.hookSpecificOutput.updatedToolOutput')"
giveup_msg="$(echo "$giveup_updated" | jq -r '.MANDATORY_VISIBLE_CHAT_MESSAGE_THIS_TURN')"
if echo "$giveup_msg" | grep -q "TERMINAL round (action=give_up)"; then
  echo "  PASS  terminal (give_up) round correctly includes the terminal-round note"
  PASSED=$((PASSED + 1))
else
  echo "  FAIL  terminal (give_up) round is missing the terminal-round note"
  FAILURES=$((FAILURES + 1))
fi

converged_result="$(jq -n '{action: "converged", iteration: 4, stage: "tier1_5", round_report: "x", round_report_note: "y"}')"
converged_input="$(jq -n --arg text "$converged_result" '{tool_response: [{text: $text}]}')"
converged_output="$(echo "$converged_input" | bash "$SCRIPT_DIR/reinforce-round-report.sh")"
converged_msg="$(echo "$converged_output" | jq -r '.hookSpecificOutput.updatedToolOutput' | jq -r '.MANDATORY_VISIBLE_CHAT_MESSAGE_THIS_TURN')"
if echo "$converged_msg" | grep -q "TERMINAL round (action=converged)"; then
  echo "  PASS  terminal (converged) round correctly includes the terminal-round note"
  PASSED=$((PASSED + 1))
else
  echo "  FAIL  terminal (converged) round is missing the terminal-round note"
  FAILURES=$((FAILURES + 1))
fi

# Missing round_report -> must fail open
no_report_result="$(jq -n '{action: "relaunch"}')"
no_report_input="$(jq -n --arg text "$no_report_result" '{tool_response: [{text: $text}]}')"
no_report_output="$(echo "$no_report_input" | bash "$SCRIPT_DIR/reinforce-round-report.sh")"
assert_eq "missing round_report falls through to continue:true" \
  "true" "$(echo "$no_report_output" | jq -r '.continue')"

malformed_rr_output="$(echo '{"tool_response":[{"text":"not json"}]}' | bash "$SCRIPT_DIR/reinforce-round-report.sh")"
assert_eq "malformed tool_response text falls through to continue:true" \
  "true" "$(echo "$malformed_rr_output" | jq -r '.continue')"

empty_rr_output="$(echo '{}' | bash "$SCRIPT_DIR/reinforce-round-report.sh")"
assert_eq "empty input falls through to continue:true" \
  "true" "$(echo "$empty_rr_output" | jq -r '.continue')"

# ── guard-publish-widget-update-mode.sh ──────────────────────────────────
# PreToolUse hook: unlike the PostToolUse scripts above, "allow" produces NO
# stdout at all (matching this ecosystem's own Python precedent,
# backend/claude_hooks/guard_comparator_loop_payload.py) - only a block
# decision prints anything.

echo ""
echo "guard-publish-widget-update-mode.sh:"

guard_input() {
  jq -n --arg tool "$1" --arg style "$2" --arg gid "$3" \
    '{tool_name: $tool, tool_input: ({style_request_type: $style} + (if $gid == "" then {} else {generation_id: $gid} end))}'
}

# updation + no generation_id -> BLOCKED
blocked_output="$(guard_input "mcp__widget-history__publish_widget" "updation" "" | bash "$SCRIPT_DIR/guard-publish-widget-update-mode.sh")"
assert_eq "updation without generation_id is blocked" \
  "block" "$(echo "$blocked_output" | jq -r '.decision')"
if echo "$blocked_output" | jq -r '.reason' | grep -q "generation_id"; then
  echo "  PASS  block reason mentions generation_id"
  PASSED=$((PASSED + 1))
else
  echo "  FAIL  block reason does not mention generation_id"
  FAILURES=$((FAILURES + 1))
fi

# updation + generation_id present -> ALLOWED (no output)
allowed_output="$(guard_input "mcp__widget-history__publish_widget" "updation" "abc-123" | bash "$SCRIPT_DIR/guard-publish-widget-update-mode.sh")"
assert_eq "updation with generation_id is allowed (no output)" "" "$allowed_output"

# addition (default), no generation_id -> ALLOWED (no output) - never blocks this shape
addition_output="$(guard_input "mcp__widget-history__publish_widget" "addition" "" | bash "$SCRIPT_DIR/guard-publish-widget-update-mode.sh")"
assert_eq "addition without generation_id is allowed (no output)" "" "$addition_output"

# addition + generation_id present (a deliberate re-suffix while updating) -> ALLOWED
addition_with_gid_output="$(guard_input "mcp__widget-history__publish_widget" "addition" "abc-123" | bash "$SCRIPT_DIR/guard-publish-widget-update-mode.sh")"
assert_eq "addition with generation_id is allowed (no output)" "" "$addition_with_gid_output"

# unrelated tool name -> ALLOWED (no output), must not fire at all
unrelated_output="$(guard_input "mcp__widget-history__get_page_widgets" "updation" "" | bash "$SCRIPT_DIR/guard-publish-widget-update-mode.sh")"
assert_eq "unrelated tool name is allowed (no output)" "" "$unrelated_output"

# completely empty input -> must fail open, not crash
empty_guard_output="$(echo '{}' | bash "$SCRIPT_DIR/guard-publish-widget-update-mode.sh")"
assert_eq "empty input is allowed (no output, no crash)" "" "$empty_guard_output"

# ── reinforce-publish-widget-update.sh ───────────────────────────────────

echo ""
echo "reinforce-publish-widget-update.sh:"

update_result="$(jq -n '{
  generation_id: "gen-existing-123", updated_existing: true,
  style_request_type_used: "updation", deeplink: "https://www.indmoney.com/widget/page?x=1"
}')"
update_input="$(jq -n --arg text "$update_result" '{tool_response: [{text: $text}]}')"
update_output="$(echo "$update_input" | bash "$SCRIPT_DIR/reinforce-publish-widget-update.sh")"
update_updated="$(echo "$update_output" | jq -r '.hookSpecificOutput.updatedToolOutput')"

assert_eq "original 'generation_id' field preserved" \
  "gen-existing-123" "$(echo "$update_updated" | jq -r '.generation_id')"
assert_eq "original 'deeplink' field preserved" \
  "https://www.indmoney.com/widget/page?x=1" "$(echo "$update_updated" | jq -r '.deeplink')"
reinforce_msg="$(echo "$update_updated" | jq -r '.MANDATORY_VISIBLE_CHAT_MESSAGE_THIS_TURN')"
assert_not_empty "MANDATORY_VISIBLE_CHAT_MESSAGE_THIS_TURN is present" "$reinforce_msg"
if echo "$reinforce_msg" | grep -q "gen-existing-123" && echo "$reinforce_msg" | grep -q "updation"; then
  echo "  PASS  reinforcement message includes generation_id and style_request_type_used"
  PASSED=$((PASSED + 1))
else
  echo "  FAIL  reinforcement message missing generation_id or style_request_type_used"
  FAILURES=$((FAILURES + 1))
fi

# updated_existing=false (a brand-new publish) -> must fail open, nothing to reinforce
new_result="$(jq -n '{generation_id: "gen-new-456", updated_existing: false, style_request_type_used: "addition"}')"
new_input="$(jq -n --arg text "$new_result" '{tool_response: [{text: $text}]}')"
new_output="$(echo "$new_input" | bash "$SCRIPT_DIR/reinforce-publish-widget-update.sh")"
assert_eq "updated_existing=false falls through to continue:true" \
  "true" "$(echo "$new_output" | jq -r '.continue')"

# missing updated_existing entirely -> must fail open
no_flag_result="$(jq -n '{generation_id: "gen-789"}')"
no_flag_input="$(jq -n --arg text "$no_flag_result" '{tool_response: [{text: $text}]}')"
no_flag_output="$(echo "$no_flag_input" | bash "$SCRIPT_DIR/reinforce-publish-widget-update.sh")"
assert_eq "missing updated_existing falls through to continue:true" \
  "true" "$(echo "$no_flag_output" | jq -r '.continue')"

# malformed tool_response text -> must fail open, not crash
malformed_pw_output="$(echo '{"tool_response":[{"text":"not json"}]}' | bash "$SCRIPT_DIR/reinforce-publish-widget-update.sh")"
assert_eq "malformed tool_response text falls through to continue:true" \
  "true" "$(echo "$malformed_pw_output" | jq -r '.continue')"

# completely empty input -> must fail open
empty_pw_output="$(echo '{}' | bash "$SCRIPT_DIR/reinforce-publish-widget-update.sh")"
assert_eq "empty input falls through to continue:true" \
  "true" "$(echo "$empty_pw_output" | jq -r '.continue')"

# ── summary ──────────────────────────────────────────────────────────────

echo ""
echo "$PASSED passed, $FAILURES failed"
if [ "$FAILURES" -gt 0 ]; then
  exit 1
fi
echo "ALL REGRESSION TESTS PASSED"
