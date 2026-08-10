#!/bin/sh
set -u

endpoint=
header_file=
body_file=
expected_key="$(cat "$HOME/expected-key")"

file_mode() {
  if mode="$(stat -c '%a' "$1" 2>/dev/null)"; then
    printf '%s' "$mode"
  else
    stat -f '%Lp' "$1"
  fi
}

for argument in "$@"; do
  printf '%s\n' "$argument" >> "$HOME/curl-arguments"
  case "$argument" in
    *"$expected_key"*) exit 90 ;;
    @*)
      candidate="${argument#@}"
      if grep -Fq 'Authorization: Bearer ' "$candidate"; then
        header_file="$candidate"
      else
        body_file="$candidate"
      fi
      ;;
    http://*|https://*) endpoint="$argument" ;;
  esac
done

[ -n "$endpoint" ] || exit 91
[ -n "$header_file" ] || exit 92
[ -n "$body_file" ] || exit 93
[ "$(file_mode "$header_file")" = 600 ] || exit 94
[ "$(file_mode "$body_file")" = 600 ] || exit 95
cmp -s "$header_file" "$HOME/expected-header" || exit 96

case "$endpoint" in
  */responses)
    api=responses
    expected_body="$HOME/expected-responses"
    ;;
  */chat/completions)
    api=chat
    expected_body="$HOME/expected-chat"
    ;;
  *) exit 97 ;;
esac
cmp -s "$body_file" "$expected_body" || exit 98
printf '%s\n' "$endpoint" >> "$HOME/curl-endpoints"

case "$FAKE_CURL_MODE:$api" in
  responses_success:responses) printf '204' ;;
  fallback:responses) printf '404' ;;
  fallback:chat) printf '200' ;;
  unauthorized:responses) printf '401' ;;
  http_error:responses) printf '404' ;;
  http_error:chat) printf '500' ;;
  network:responses) exit 7 ;;
  *) exit 99 ;;
esac
