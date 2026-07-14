#!/usr/bin/env bash
# reinforce-formula-builder.sh — UserPromptSubmit hook for the universal-communicator-formula skill.
#
# The universal-communicator-formula skill (skills/universal-communicator-formula/SKILL.md) exists precisely
# because a hand-written widget formula routinely ships bugs that only surface
# at RUNTIME on Android (Rhino), not at author time on iOS (JSC): a `var final`
# reserved-word identifier, a `.trim()` call, an `Array.isArray`, a `let`/arrow,
# a trailing comma, a straight single quote `'` inside a spliced config value
# that silently closes the `'{"key":#key}'` wrapper and makes the whole formula
# return `undefined`, or a bare `/0/` array-index path segment that never
# resolves (must be `###{0}###`). The skill encodes every one of these traps.
#
# The gap this hook closes: the skill only helps if it's actually invoked. When
# a user asks for "a formula" or "the universal_widget_communication block", the
# model can just hand-roll the JS from memory and reintroduce exactly the bugs
# the skill was written to prevent - the skill's own description is the only
# thing nudging it, and that nudge is easy to skip mid-conversation. This hook
# makes the nudge deterministic: if the incoming prompt is asking for a formula
# / a universal_widget_communication block, it injects a loud, separate
# instruction telling the model to drive the answer through the
# universal-communicator-formula skill rather than free-handing the JavaScript.
#
# It does NOT force the skill on unrelated prompts - it only fires when the
# prompt text actually mentions a formula / the universal_widget_communication
# block / input_validators, so ordinary turns are untouched.
#
# Fails open: any error here (missing jq, no prompt field, no match) falls
# through to {"continue":true} - the prompt proceeds exactly as if this hook
# didn't exist. Never blocks or rewrites the user's prompt.

LOG_FILE="${WIDGET_PLATFORM_HOOKS_LOG:-$HOME/.widget-platform-hooks/reinforce-formula-builder.log}"

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

prompt="$(printf '%s' "$input" | jq -r '.prompt // empty' 2>/dev/null)"
[ -z "$prompt" ] && pass_through "no prompt field in hook input"

# Case-insensitive trigger detection. Deliberately narrow: it keys on the
# concrete artifacts the skill owns (a widget "formula", the
# universal_widget_communication block, input_validators) rather than the
# generic word "validation" alone, so a prompt about, say, form validation in
# unrelated code doesn't drag the skill in. `communicat` (no suffix) matches
# both "communication" and the occasional "communicator" phrasing.
lc="$(printf '%s' "$prompt" | tr '[:upper:]' '[:lower:]')"

matched=""
case "$lc" in
  *formula*)                          matched="formula" ;;
  *universal_widget_communicat*)      matched="universal_widget_communication block" ;;
  *"universal widget communicat"*)    matched="universal_widget_communication block" ;;
  *input_validators*)                 matched="input_validators block" ;;
esac

[ -z "$matched" ] && pass_through "prompt does not reference a formula / universal_widget_communication block - skill not applicable"

log "matched on: $matched"

# additionalContext is appended to the prompt context the model sees. Keep it
# specific about WHY the skill matters (the cross-engine runtime traps) so the
# model treats it as load-bearing, not decorative.
jq -n --arg trigger "$matched" '
  {
    hookSpecificOutput: {
      hookEventName: "UserPromptSubmit",
      additionalContext: (
        "This request involves a widget " + $trigger + ". Use the universal-communicator-formula skill " +
        "(skills/universal-communicator-formula/SKILL.md) to generate, update, or debug the formula rather than " +
        "hand-writing the JavaScript from memory. That skill encodes the traps a hand-rolled formula " +
        "reintroduces every time - Rhino (Android) vs JSC (iOS) cross-engine safety (no `var final` or " +
        "other reserved-word identifiers, no `.trim()`, no `Array.isArray`, no let/const/arrow/template-" +
        "literals/trailing-commas), the single-quote-in-config bug that makes a formula silently return " +
        "`undefined`, the `###{N}###` array-index path token (never a bare `/N/`), the driving-widget " +
        "`selection.api_key` wiring, and the canonical `universal_widget_communication` delivery shape " +
        "(inputs + input_validators.<key>.formula.formula + nested variablesMap). Invoke the skill; do not skip it."
      )
    }
  }
'
