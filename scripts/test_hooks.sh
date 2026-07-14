#!/usr/bin/env bash
# test_hooks.sh — regression tests for generate-qr-code.sh and
# reinforce-round-report.sh (capture-inspect-screen.sh's own live-device
# verification is documented in this repo's commit history instead; these
# two don't need a real device, so a real automated test is practical here).
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

# ── reinforce-formula-builder.sh ─────────────────────────────────────────

echo ""
echo "reinforce-formula-builder.sh:"

# A prompt explicitly asking for a formula -> must inject the skill instruction.
formula_input="$(jq -n '{prompt: "Create a required-amount validation formula for the lumpsum widget"}')"
formula_output="$(echo "$formula_input" | bash "$SCRIPT_DIR/reinforce-formula-builder.sh")"
formula_ctx="$(echo "$formula_output" | jq -r '.hookSpecificOutput.additionalContext // empty')"
assert_not_empty "formula prompt injects additionalContext" "$formula_ctx"
if echo "$formula_ctx" | grep -q "universal-communicator-formula skill"; then
  echo "  PASS  injected context points at the universal-communicator-formula skill"
  PASSED=$((PASSED + 1))
else
  echo "  FAIL  injected context does not mention the universal-communicator-formula skill"
  FAILURES=$((FAILURES + 1))
fi
assert_eq "formula prompt sets UserPromptSubmit event name" \
  "UserPromptSubmit" "$(echo "$formula_output" | jq -r '.hookSpecificOutput.hookEventName')"

# A prompt mentioning the universal_widget_communication block -> must match.
uwc_input="$(jq -n '{prompt: "Give me the full universal_widget_communication block for this checkbox"}')"
uwc_output="$(echo "$uwc_input" | bash "$SCRIPT_DIR/reinforce-formula-builder.sh")"
assert_not_empty "universal_widget_communication prompt injects additionalContext" \
  "$(echo "$uwc_output" | jq -r '.hookSpecificOutput.additionalContext // empty')"

# Case-insensitivity — uppercase should still match.
upper_input="$(jq -n '{prompt: "Build the FORMULA for input_validators"}')"
upper_output="$(echo "$upper_input" | bash "$SCRIPT_DIR/reinforce-formula-builder.sh")"
assert_not_empty "uppercase / input_validators prompt still matches" \
  "$(echo "$upper_output" | jq -r '.hookSpecificOutput.additionalContext // empty')"

# An unrelated prompt -> must NOT inject anything (fail-open, no skill nudge).
unrelated_input="$(jq -n '{prompt: "Refactor the login screen layout constraints"}')"
unrelated_output="$(echo "$unrelated_input" | bash "$SCRIPT_DIR/reinforce-formula-builder.sh")"
assert_eq "unrelated prompt falls through to continue:true" \
  "true" "$(echo "$unrelated_output" | jq -r '.continue')"
assert_eq "unrelated prompt injects no additionalContext" \
  "" "$(echo "$unrelated_output" | jq -r '.hookSpecificOutput.additionalContext // empty')"

# Missing prompt field -> must fail open, not crash.
no_prompt_output="$(echo '{}' | bash "$SCRIPT_DIR/reinforce-formula-builder.sh")"
assert_eq "missing prompt field falls through to continue:true" \
  "true" "$(echo "$no_prompt_output" | jq -r '.continue')"

# ── summary ──────────────────────────────────────────────────────────────

echo ""
echo "$PASSED passed, $FAILURES failed"
if [ "$FAILURES" -gt 0 ]; then
  exit 1
fi
echo "ALL REGRESSION TESTS PASSED"
