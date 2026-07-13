#!/usr/bin/env bash
# reinforce-round-report.sh — PostToolUse hook for advance_comparator_loop.
#
# advance_comparator_loop's own response already includes round_report (a
# pre-built score/breakdown string) and round_report_note (marking it
# mandatory every round) - the gap isn't missing data, it's that this text
# sits inside a large JSON blob a calling model can read via jq/Bash without
# ever surfacing it in a visible chat message (a real incident: a run did
# exactly that - read the fields with its own jq command, never once pasted
# them into the transcript). This hook doesn't invent new data; it makes the
# SAME data impossible to miss by prepending a loud, separate instruction
# field, and on a terminal round (converged/give_up) adds the reminder that
# the final report also needs the deeplink/QR code/contract links this
# specific tool's response doesn't itself carry (see generate-qr-code.sh,
# which runs on launch_widget_on_device instead, earlier in the same loop).
#
# Fails open: any error here falls through to {"continue":true} - the model
# just sees the original, unmodified advance_comparator_loop result.

LOG_FILE="${WIDGET_PLATFORM_HOOKS_LOG:-$HOME/.widget-platform-hooks/reinforce-round-report.log}"

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

round_report="$(printf '%s' "$result_json" | jq -r '.round_report // empty' 2>/dev/null)"
[ -z "$round_report" ] && pass_through "no round_report field in this response - nothing to reinforce"

action="$(printf '%s' "$result_json" | jq -r '.action // empty' 2>/dev/null)"

terminal_note=""
if [ "$action" = "converged" ] || [ "$action" = "give_up" ]; then
  terminal_note=" This is a TERMINAL round (action=${action}) - your final report must ALSO include the deeplink, QR code (see qr_code_path from the earlier launch_widget_on_device call in this same conversation), and contract JSON links, not just this score breakdown alone."
fi

jq -n --argjson orig "$result_json" --arg report "$round_report" --arg note "$terminal_note" '
  $orig + {
    MANDATORY_VISIBLE_CHAT_MESSAGE_THIS_TURN: (
      $report + "\n\n(This must be pasted into a VISIBLE chat message THIS turn, before your next tool call - not left inside this tool result, and not deferred to a later summary.)" + $note
    )
  }
  | tostring
  | {hookSpecificOutput: {hookEventName: "PostToolUse", updatedToolOutput: .}}
'
