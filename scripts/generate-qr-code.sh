#!/usr/bin/env bash
# generate-qr-code.sh — PostToolUse hook for launch_widget_on_device.
#
# Generates a real, scannable QR code PNG for the deeplink the tool just
# constructed, and injects its local file path + a strong instruction into
# the tool's own result. Deliberately generates the file ONCE, the moment
# the deeplink is first created (launch_widget_on_device), not on every
# later advance_comparator_loop round - the deeplink is constant for the
# whole comparator loop (it only changes if a fresh launch_widget_on_device
# call is made, e.g. after a Tier 2 fix produces a genuinely new contract),
# so there's nothing to regenerate on every round.
#
# Design choice, not a guess: an earlier idea was embedding the QR code as
# base64 image data directly in updatedToolOutput. That was NOT built,
# because it's unverified whether Claude Code renders an image block
# returned this way inline - only text replacement via updatedToolOutput has
# actually been confirmed live (see capture-inspect-screen.sh). Saving a
# real file and pointing at its path uses the SAME text-replacement
# mechanism already proven to work, so this doesn't depend on an unverified
# assumption to have any effect at all.
#
# Uses a public QR-generation API (api.qrserver.com) via curl, not a local
# qrencode/qrcode dependency - qrencode isn't installed on this machine by
# default, and this repo's own existing hook (capture-inspect-screen.sh) is
# already curl+jq only, no other local tool assumed. The deeplink itself is
# not sensitive (a public temp-contract URL, no user data), so sending it to
# a third-party API costs nothing privacy-wise.
#
# Fails open: any error here (bad input, no navlink, download failure)
# falls through to {"continue":true} - the model just sees the original,
# unmodified launch_widget_on_device result, exactly as if this hook didn't
# exist. Never blocks or corrupts the underlying tool call.

QR_DIR="${WIDGET_PLATFORM_HOOKS_QR_DIR:-$HOME/.widget-platform-hooks/qr_codes}"
LOG_FILE="${WIDGET_PLATFORM_HOOKS_LOG:-$HOME/.widget-platform-hooks/generate-qr-code.log}"

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

result_json="$(printf '%s' "$input" | jq -r '.tool_response[0].text // empty' 2>/dev/null)"
[ -z "$result_json" ] && pass_through "no tool_response[0].text in hook input"

printf '%s' "$result_json" | jq -e . >/dev/null 2>&1 || pass_through "tool_response text was not valid JSON"

navlink="$(printf '%s' "$result_json" | jq -r '.navlink // empty' 2>/dev/null)"
[ -z "$navlink" ] && pass_through "no navlink field in launch_widget_on_device's result - nothing to encode"

mkdir -p "$QR_DIR" 2>/dev/null
filename="qr_$(date -u +%Y%m%dT%H%M%SZ)_$$.png"
filepath="$QR_DIR/$filename"

encoded_navlink="$(jq -rn --arg v "$navlink" '$v|@uri')"
http_status="$(curl -s -m 15 -o "$filepath" -w '%{http_code}' \
  "https://api.qrserver.com/v1/create-qr-code/?size=300x300&data=${encoded_navlink}" 2>/dev/null)"

if [ "$http_status" != "200" ] || [ ! -s "$filepath" ]; then
  rm -f "$filepath" 2>/dev/null
  pass_through "QR code download failed (http_status=$http_status) for navlink=$navlink"
fi

# Merge the new fields into the ORIGINAL result rather than replacing it -
# every field the calling model already relies on (commands, instruction,
# next_step, etc.) must still be present exactly as before.
jq -n --argjson orig "$result_json" --arg path "$filepath" --arg link "$navlink" '
  $orig + {
    qr_code_path: $path,
    qr_code_instruction: (
      "A scannable QR code for this widget'"'"'s deeplink (" + $link + ") was generated and saved to " + $path +
      ". Per the widget-comparator-loop playbook, the final report after this loop converges or gives up " +
      "must include this QR code (open/attach the file at the path above) alongside the score, deeplink, " +
      "and contract JSON links - not just the score and deeplink alone."
    )
  }
  | tostring
  | {hookSpecificOutput: {hookEventName: "PostToolUse", updatedToolOutput: .}}
'
