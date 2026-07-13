#!/usr/bin/env bash
# capture-inspect-screen.sh — PostToolUse hook for inspect_screen.
#
# Uploads the raw device tree directly to widget-platform's existing
# /api/temp-contract storage (same storage store_temp_contract/
# temp_contract_id already use) and substitutes a small capture_id in
# place of the full tree - so the calling model never has to retype a
# large device tree (often tens of thousands of characters) as a
# tool-call argument to advance_comparator_loop. That retyping step is
# the actual root cause of a long-standing reliability bug (confirmed via
# a real transcript where the model's own words were "the earlier empty
# calls were consistently forgetting to include the parameter block").
#
# Verified live (2026-07-13): updatedToolOutput fully replaces an MCP
# tool's result before the model ever sees it - not just supplementary
# context alongside the original.
#
# Fails open: any error here (bad input, upload failure, no id in
# response) falls through to {"continue":true} - the model just sees the
# original, unmodified inspect_screen result, exactly as if this hook
# didn't exist. Never blocks or corrupts the underlying tool call.

API_BASE="${WIDGET_PLATFORM_API_BASE:-https://widgetplatform-pp.indiawealth.in}"
LOG_FILE="${WIDGET_PLATFORM_HOOKS_LOG:-$HOME/.widget-platform-hooks/capture-inspect-screen.log}"

# Local-file logging, not network-dependent (added after a real gap found in
# this exact codebase's reset_maestro_driver: silent fallback paths mean a
# broken upload looks identical to "everything is fine" - nobody can tell
# this hook stopped working until someone notices inspect_screen_root
# failures returning despite the plugin being installed). Deliberately NOT
# shipped to the widget-platform backend itself - if network/backend is
# what's broken, logging must not depend on the same thing that's failing.
log() {
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
  printf '%s pass_through: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$LOG_FILE" 2>/dev/null
}

pass_through() {
  log "$1"
  echo '{"continue":true,"suppressOutput":true}'
  exit 0
}

input="$(cat)"

command -v jq >/dev/null 2>&1 || pass_through "jq not found on PATH"
command -v curl >/dev/null 2>&1 || pass_through "curl not found on PATH"

tree_json="$(printf '%s' "$input" | jq -r '.tool_response[0].text // empty' 2>/dev/null)"
[ -z "$tree_json" ] && pass_through "no tool_response[0].text in hook input"

# Confirm it's actually valid JSON before trying to upload it
printf '%s' "$tree_json" | jq -e . >/dev/null 2>&1 || pass_through "tool_response text was not valid JSON"

response="$(jq -n --argjson tree "$tree_json" \
  '{contract: $tree, label: "inspect_screen_capture", ttl_hours: 1}' 2>/dev/null | \
  curl -s -m 10 -X POST "$API_BASE/api/temp-contract" \
    -H "Content-Type: application/json" -d @- 2>/dev/null)"

capture_id="$(printf '%s' "$response" | jq -r '.id // empty' 2>/dev/null)"
[ -z "$capture_id" ] && pass_through "upload to $API_BASE/api/temp-contract failed or returned no id - response: $(printf '%s' "$response" | head -c 300)"

# The note spells out the exact call shape, not just the field name in
# prose - a real incident had a calling model read an earlier, shorter
# version of this note and still get it wrong, nesting capture_id INSIDE
# inspect_screen_root instead of passing it as its own separate parameter.
# That mistake is now also caught server-side (advance_comparator_loop
# auto-corrects it), but fixing it here too means it's caught before ever
# happening, not just recovered from after the fact.
jq -n --arg cid "$capture_id" '
  {capture_id: $cid,
   note: ("Full inspect_screen tree stored server-side. Call advance_comparator_loop with capture_id as its OWN SEPARATE argument named inspect_screen_capture_id - example: advance_comparator_loop(loop_id=..., inspect_screen_capture_id=\"" + $cid + "\"). Do NOT nest it inside inspect_screen_root (e.g. inspect_screen_root={\"capture_id\": \"" + $cid + "\"}) - the backend now auto-corrects that specific mistake if it happens, but passing it correctly the first time avoids relying on that fallback at all.")}
  | tostring
  | {hookSpecificOutput: {hookEventName: "PostToolUse", updatedToolOutput: .}}
'
