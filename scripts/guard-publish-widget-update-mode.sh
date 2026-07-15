#!/usr/bin/env bash
# guard-publish-widget-update-mode.sh — PreToolUse hook for publish_widget.
#
# Hard-blocks ONE unambiguous, zero-false-positive-risk calling mistake:
# style_request_type="updation" passed WITHOUT generation_id. Per the
# backend's own enforcement (widget-platform backend/app.py
# ai_publish_widget, added 2026-07-15), "updation" only reuses existing
# style/structure IDs when diffed against an already-published generation -
# without generation_id there's nothing to diff against, so the server
# silently falls back to "addition" and creates a BRAND NEW history entry
# instead of updating anything. That silent downgrade is exactly the root
# cause of a real reported incident ("I asked it to update existing styles,
# it created new ones") - this hook catches the calling shape that causes
# it BEFORE the round-trip, instead of relying on a model noticing the
# style_request_type_used field in the response afterwards.
#
# Deliberately does NOT block the reverse case (generation_id set,
# style_request_type left at its "addition" default) - style_request_type
# defaults to "addition" in the tool signature itself, so there is no way
# to tell "deliberately chose addition" from "didn't think about it" from
# the call shape alone. That ambiguity is a judgment call for the model/user
# to make, not a static shape violation - same reasoning this same
# ecosystem's backend/claude_hooks/guard_comparator_loop_payload.py already
# applies (only blocks checks with zero false-positive risk; an earlier,
# transcript-scanning heuristic hook was deleted after a live false
# positive - not repeating that mistake here either).
#
# Fails open: any error here (bad input, missing fields) allows the call
# through unmodified - never blocks on ambiguous input, only on this one
# confirmed-bad shape.

LOG_FILE="${WIDGET_PLATFORM_HOOKS_LOG:-$HOME/.widget-platform-hooks/guard-publish-widget-update-mode.log}"

log() {
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$LOG_FILE" 2>/dev/null
}

allow() {
  log "ALLOWED: $1"
  exit 0
}

input="$(cat)"

command -v jq >/dev/null 2>&1 || allow "jq not found on PATH - failing open"

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)"
case "$tool_name" in
  *publish_widget*) ;;
  *) exit 0 ;;
esac

style_request_type="$(printf '%s' "$input" | jq -r '.tool_input.style_request_type // "addition"' 2>/dev/null)"
generation_id="$(printf '%s' "$input" | jq -r '.tool_input.generation_id // empty' 2>/dev/null)"

if [ "$style_request_type" = "updation" ] && [ -z "$generation_id" ]; then
  log "BLOCKED: style_request_type=updation with no generation_id"
  jq -n '{
    decision: "block",
    reason: (
      "style_request_type=\"updation\" was passed WITHOUT generation_id. " +
      "\"updation\" only reuses existing style/structure IDs when diffed " +
      "against an already-published generation - without generation_id " +
      "there is nothing to diff against, so the server silently falls " +
      "back to \"addition\" and creates a BRAND NEW history entry instead " +
      "of updating the widget you meant to update (this exact " +
      "silent-fallback shape is the root cause of a real reported " +
      "incident: \"I asked it to update existing styles, it created new " +
      "ones\"). If you are updating a widget that is already published, " +
      "call get_page_widgets to find its generation_id and pass " +
      "generation_id=<that id> alongside style_request_type=\"updation\". " +
      "If you actually meant to create a new widget, call again with " +
      "style_request_type=\"addition\" instead."
    )
  }'
  exit 0
fi

allow "style_request_type=$style_request_type generation_id=${generation_id:-<empty>}"
