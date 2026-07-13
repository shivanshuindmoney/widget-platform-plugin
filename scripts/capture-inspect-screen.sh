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

pass_through() {
  echo '{"continue":true,"suppressOutput":true}'
  exit 0
}

input="$(cat)"

command -v jq >/dev/null 2>&1 || pass_through
command -v curl >/dev/null 2>&1 || pass_through

tree_json="$(printf '%s' "$input" | jq -r '.tool_response[0].text // empty' 2>/dev/null)"
[ -z "$tree_json" ] && pass_through

# Confirm it's actually valid JSON before trying to upload it
printf '%s' "$tree_json" | jq -e . >/dev/null 2>&1 || pass_through

response="$(jq -n --argjson tree "$tree_json" \
  '{contract: $tree, label: "inspect_screen_capture", ttl_hours: 1}' 2>/dev/null | \
  curl -s -m 10 -X POST "$API_BASE/api/temp-contract" \
    -H "Content-Type: application/json" -d @- 2>/dev/null)"

capture_id="$(printf '%s' "$response" | jq -r '.id // empty' 2>/dev/null)"
[ -z "$capture_id" ] && pass_through

jq -n --arg cid "$capture_id" '
  {capture_id: $cid,
   note: "Full inspect_screen tree stored server-side - pass this as inspect_screen_capture_id to advance_comparator_loop instead of inspect_screen_root"}
  | tostring
  | {hookSpecificOutput: {hookEventName: "PostToolUse", updatedToolOutput: .}}
'
