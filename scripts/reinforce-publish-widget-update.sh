#!/usr/bin/env bash
# reinforce-publish-widget-update.sh — PostToolUse hook for publish_widget.
#
# When a publish_widget call actually updated an already-published widget in
# place (updated_existing=true in the response), prepends a loud, separate
# reminder into the tool's own result: confirm with the user that
# overwriting that widget in place (not creating a new copy) was actually
# what they wanted, before reporting the publish as done. Backstops the
# "ask the user explicitly" instruction already in publish_widget's own
# docstring (widget-platform mcp/widget-history/server.py, 2026-07-15) for
# the case where a model skipped that step - same "make it impossible to
# miss instead of trusting the model read it" idea as
# reinforce-round-report.sh in this same plugin.
#
# Fails open: any error here (bad input, missing fields) falls through to
# {"continue":true} - the model just sees the original, unmodified
# publish_widget result.

LOG_FILE="${WIDGET_PLATFORM_HOOKS_LOG:-$HOME/.widget-platform-hooks/reinforce-publish-widget-update.log}"

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

result_json="$(printf '%s' "$input" | jq -r '.tool_response[0].text // empty' 2>/dev/null)"
[ -z "$result_json" ] && pass_through "no tool_response[0].text in hook input"

printf '%s' "$result_json" | jq -e . >/dev/null 2>&1 || pass_through "tool_response text was not valid JSON"

updated_existing="$(printf '%s' "$result_json" | jq -r '.updated_existing // false' 2>/dev/null)"
[ "$updated_existing" != "true" ] && pass_through "updated_existing is not true - this was a new publish, nothing to reinforce"

generation_id="$(printf '%s' "$result_json" | jq -r '.generation_id // "unknown"' 2>/dev/null)"
mode_used="$(printf '%s' "$result_json" | jq -r '.style_request_type_used // "unknown"' 2>/dev/null)"

jq -n --argjson orig "$result_json" --arg gid "$generation_id" --arg mode "$mode_used" '
  $orig + {
    MANDATORY_VISIBLE_CHAT_MESSAGE_THIS_TURN: (
      "This publish_widget call UPDATED an already-published widget IN PLACE (generation_id=" + $gid + ", style_request_type_used=" + $mode + ") - it overwrote that widget'"'"'s contracts rather than creating a new one. Before reporting this as done, confirm this is genuinely what the user asked for (updating the existing widget, not producing a fresh copy) - state that explicitly in your reply, do not just report success silently."
    )
  }
  | tostring
  | {hookSpecificOutput: {hookEventName: "PostToolUse", updatedToolOutput: .}}
'
