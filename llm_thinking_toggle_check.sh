#!/usr/bin/env bash
# Diagnostic: confirm whether chat_template_kwargs.enable_thinking actually
# suppresses reasoning output on the configured LLM_OPENAI endpoint/model.
# chat_template_kwargs must be top-level in the request body (a vLLM
# extension), not nested under "extra_body" (that's a LangChain-SDK-only
# wrapper that never reaches the wire as a literal key).
#
# This is a per-model chat-template feature, not a universal API flag: Qwen3
# templates mark reasoning with a literal "</think>" tag, Gemma templates
# (observed on gemma4-31b-it-long-context) prefix it with a literal "thought"
# line instead, and a model with no such template logic will just ignore the
# flag entirely. There's no single marker string that covers every vendor, so
# this script also flags "reasoning-shaped" output heuristically (multi-line
# or unexpectedly long) rather than only grepping for "</think>".
#
# Usage: ./llm_thinking_toggle_check.sh [-v] [-s] [-u url] [-k key] [-m model_id] [model_id]
#   Run with -h for full help.

set -euo pipefail
cd "$(dirname "$0")"

# .env is optional: every variable can also be given as a command-line option
# (options take precedence over .env).
if [[ -f .env ]]; then
  source .env
fi

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [model_id]

Check whether an OpenAI-compatible endpoint (e.g. vLLM) honors
chat_template_kwargs.enable_thinking, by sending the same prompt twice
(enable_thinking=false / true) and comparing the responses.

Options:
  -u, --url URL       Base URL of the endpoint, without /v1
                      (overrides LLM_OPENAI_API_URL)
  -k, --api-key KEY   API key, sent as Bearer token
                      (overrides LLM_OPENAI_API_KEY)
  -m, --model MODEL   Model ID to test (overrides LLM_OPENAI_MODEL)
  -s, --stream        Use streaming (SSE) requests and additionally report
                      time-to-first-token (TTFT) and decode tokens/s
      --no-stream     Use plain non-streaming requests (default)
  -v, --verbose       Also print the full raw JSON responses
  -h, --help          Show this help and exit

A positional model_id is also accepted (same as --model).

Configuration is read from .env (LLM_OPENAI_API_URL, LLM_OPENAI_API_KEY,
LLM_OPENAI_MODEL); command-line options override it, and .env is not
required if all three are given as options.
Note: an --api-key on the command line is visible in the process list; prefer
.env for shared machines.

Exit codes: 0 = check completed, 1 = error / request failed.
EOF
}

VERBOSE=false
STREAM=false
MODEL_ARG=""
need_arg() { [[ $# -ge 2 ]] || { echo "Error: $1 requires an argument." >&2; exit 1; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    -v|--verbose) VERBOSE=true; shift ;;
    -s|--stream)  STREAM=true; shift ;;
    --no-stream)  STREAM=false; shift ;;
    -m|--model)   need_arg "$@"; MODEL_ARG="$2"; shift 2 ;;
    -u|--url)     need_arg "$@"; LLM_OPENAI_API_URL="$2"; shift 2 ;;
    -k|--api-key) need_arg "$@"; LLM_OPENAI_API_KEY="$2"; shift 2 ;;
    --)           shift; [[ $# -gt 0 ]] && MODEL_ARG="$1"; break ;;
    -*)           echo "Error: unknown option: $1" >&2; echo >&2; usage >&2; exit 1 ;;
    *)            MODEL_ARG="$1"; shift ;;
  esac
done

MODEL="${MODEL_ARG:-${LLM_OPENAI_MODEL:-}}"
LLM_OPENAI_API_URL="${LLM_OPENAI_API_URL:-}"
LLM_OPENAI_API_KEY="${LLM_OPENAI_API_KEY:-}"
missing=()
[[ -n "$MODEL" ]]               || missing+=("model (-m / LLM_OPENAI_MODEL)")
[[ -n "$LLM_OPENAI_API_URL" ]]  || missing+=("URL (-u / LLM_OPENAI_API_URL)")
[[ -n "$LLM_OPENAI_API_KEY" ]]  || missing+=("API key (-k / LLM_OPENAI_API_KEY)")
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "Error: missing setting(s):" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  echo "Provide them as options or in .env (see .env.example)." >&2
  exit 1
fi
LLM_OPENAI_API_URL="${LLM_OPENAI_API_URL%/}"
if [[ "$STREAM" == true && -z "${EPOCHREALTIME:-}" ]]; then
  echo "Error: --stream needs bash >= 5 (EPOCHREALTIME)." >&2
  exit 1
fi
PROMPT="What is 12 * 7? Reply with just the number."

echo "Testing model: ${MODEL}"
echo

# Wrap anything that is not valid JSON (HTML error page, curl failure text) as
# an OpenAI-style error object so the caller can treat all failures alike.
as_json_or_error() {
  local raw="$1"
  if echo "$raw" | jq -e . >/dev/null 2>&1; then
    echo "$raw"
  else
    jq -n --arg m "${raw:0:200}" '{error: {message: $m}}'
  fi
}

build_body() {
  jq -n \
    --arg model "$MODEL" \
    --arg prompt "$PROMPT" \
    --argjson thinking "$1" \
    --argjson stream "$STREAM" \
    '{
      model: $model,
      messages: [{role: "user", content: $prompt}],
      temperature: 0.0,
      chat_template_kwargs: {enable_thinking: $thinking}
    } + (if $stream then {stream: true, stream_options: {include_usage: true}} else {} end)'
}

# Non-streaming request: prints the response JSON plus _elapsed_s.
call_llm() {
  local body raw elapsed=0
  body=$(build_body "$1")
  raw=$(curl -s --max-time 120 "${LLM_OPENAI_API_URL}/v1/chat/completions" \
    -H "Authorization: Bearer ${LLM_OPENAI_API_KEY}" \
    -H "Content-Type: application/json" \
    -w $'\n%{time_total}' \
    -d "$body") || raw="curl failed (exit $?): endpoint unreachable or timed out"
  # curl -w appended the total request time as the last line; split it off.
  if [[ "$raw" == *$'\n'* ]]; then
    elapsed="${raw##*$'\n'}"
    raw="${raw%$'\n'*}"
  fi
  [[ "$elapsed" =~ ^[0-9.]+$ ]] || elapsed=0
  as_json_or_error "$raw" | jq -c --argjson t "$elapsed" 'if .error then . else . + {_elapsed_s: $t} end'
}

# Streaming request: every SSE line is stamped on arrival, then folded into a
# response-shaped JSON object (content, usage) plus _elapsed_s, _ttft_s (first
# content/reasoning chunk) and _decode_s (first -> last chunk).
call_llm_stream() {
  local body log t0 t1 rc=0 raw
  body=$(build_body "$1")
  log=$(mktemp)
  t0=${EPOCHREALTIME/,/.}
  curl -sN --max-time 120 "${LLM_OPENAI_API_URL}/v1/chat/completions" \
    -H "Authorization: Bearer ${LLM_OPENAI_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$body" | while IFS= read -r line || [[ -n "$line" ]]; do
      printf '%s\t%s\n' "${EPOCHREALTIME/,/.}" "$line"
    done > "$log" || rc=$?
  t1=${EPOCHREALTIME/,/.}
  if ! grep -q $'\tdata: ' "$log"; then
    # No SSE data: an error body (e.g. 401 JSON) or a connection failure.
    raw=$(cut -f2- "$log")
    [[ -n "$raw" ]] || raw="curl failed or no data received (endpoint unreachable or timed out)"
    rm -f "$log"
    as_json_or_error "$raw"
    return
  fi
  jq -R -s -c --argjson t0 "$t0" --argjson t1 "$t1" '
    [ split("\n")[] | select(length > 0) | split("\t")
      | {t: (.[0] | tonumber), l: (.[1:] | join("\t"))}
      | select(.l | startswith("data: "))
      | select(.l != "data: [DONE]")
      | {t, j: (.l[6:] | fromjson? )} | select(.j) ] as $c
    | ($c | map(select((.j.choices[0].delta.content // "") != ""
                       or (.j.choices[0].delta.reasoning // .j.choices[0].delta.reasoning_content // "") != ""))) as $tok
    | ($c | map(.j.usage.completion_tokens? // empty) | last) as $usage
    | {
        choices: [{message: {content: ($c | map(.j.choices[0].delta.content // "") | join(""))}}],
        usage: {completion_tokens: ($usage // ($tok | length)),
                tokens_estimated: ($usage == null)},
        _elapsed_s: ($t1 - $t0),
        _ttft_s: (if ($tok | length) > 0 then ($tok[0].t - $t0) else null end),
        _decode_s: (if ($tok | length) > 1 then ($tok[-1].t - $tok[0].t) else null end)
      }' "$log"
  rm -f "$log"
}

request() { if [[ "$STREAM" == true ]]; then call_llm_stream "$1"; else call_llm "$1"; fi; }

echo "=== Request 1: enable_thinking=false ==="
resp_false=$(request false)
error_false=$(echo "$resp_false" | jq -r '(.error.message? // .message? // .error? // empty) | if type=="string" then . else tojson end' 2>/dev/null || true)
[[ -z "$error_false" && -z "$(echo "$resp_false" | jq -r '.choices[0] // empty' 2>/dev/null)" ]] && error_false="no choices in response (not valid JSON or unexpected format): ${resp_false:0:200}"
content_false=$(echo "$resp_false" | jq -r '.choices[0].message.content // empty')
tokens_false=$(echo "$resp_false" | jq -r '.usage.completion_tokens // empty')
secs_false=$(echo "$resp_false" | jq -r '._elapsed_s // 0')
ttft_false=$(echo "$resp_false" | jq -r '._ttft_s // empty')
decode_false=$(echo "$resp_false" | jq -r '._decode_s // empty')
est_false=$(echo "$resp_false" | jq -r '.usage.tokens_estimated // false')
[[ "$VERBOSE" == true ]] && echo "$resp_false" | jq 'del(._elapsed_s, ._ttft_s, ._decode_s)'
printf 'Done in %.2fs\n' "$secs_false"
echo

echo "=== Request 2: enable_thinking=true ==="
resp_true=$(request true)
error_true=$(echo "$resp_true" | jq -r '(.error.message? // .message? // .error? // empty) | if type=="string" then . else tojson end' 2>/dev/null || true)
[[ -z "$error_true" && -z "$(echo "$resp_true" | jq -r '.choices[0] // empty' 2>/dev/null)" ]] && error_true="no choices in response (not valid JSON or unexpected format): ${resp_true:0:200}"
content_true=$(echo "$resp_true" | jq -r '.choices[0].message.content // empty')
tokens_true=$(echo "$resp_true" | jq -r '.usage.completion_tokens // empty')
secs_true=$(echo "$resp_true" | jq -r '._elapsed_s // 0')
ttft_true=$(echo "$resp_true" | jq -r '._ttft_s // empty')
decode_true=$(echo "$resp_true" | jq -r '._decode_s // empty')
est_true=$(echo "$resp_true" | jq -r '.usage.tokens_estimated // false')
[[ "$VERBOSE" == true ]] && echo "$resp_true" | jq 'del(._elapsed_s, ._ttft_s, ._decode_s)'
printf 'Done in %.2fs\n' "$secs_true"
echo

echo "=== Result ==="

if [[ -n "$error_false" || -n "$error_true" ]]; then
  echo "⚠️  Request failed -- cannot determine thinking-mode behavior."
  [[ -n "$error_false" ]] && echo "  enable_thinking=false error: ${error_false}"
  [[ -n "$error_true"  ]] && echo "  enable_thinking=true  error: ${error_true}"
  exit 1
fi

# End-to-end throughput: completion_tokens / total request time. This includes
# prompt processing and network latency, so for tiny outputs it understates the
# model's real decode speed; it is mainly useful for comparing the two modes.
tps() { awk -v t="${1:-0}" -v s="${2:-0}" 'BEGIN { if (s > 0 && t > 0) printf "%.1f", t / s; else print "n/a" }'; }
tps_false=$(tps "$tokens_false" "$secs_false")
tps_true=$(tps "$tokens_true" "$secs_true")

printf 'enable_thinking=false -> completion_tokens=%s, time=%.2fs, %s tok/s, content: %s\n' \
  "$tokens_false" "$secs_false" "$tps_false" "$content_false"
printf 'enable_thinking=true  -> completion_tokens=%s, time=%.2fs, %s tok/s, content: %s\n' \
  "$tokens_true" "$secs_true" "$tps_true" "$content_true"
echo

if [[ "$STREAM" == true ]]; then
  # Decode speed: tokens after the first one, over first -> last token time.
  dps() { awk -v t="${1:-0}" -v d="${2:-}" 'BEGIN { if (d != "" && d > 0 && t > 1) printf "%.1f", (t - 1) / d; else print "n/a" }'; }
  stream_line() {
    local label="$1" ttft="$2" tokens="$3" decode="$4" est="$5" note=""
    [[ "$est" == true ]] && note=" (token count estimated from chunks; server sent no usage)"
    if [[ -n "$ttft" ]]; then
      printf '%s -> TTFT=%.2fs, decode=%s tok/s%s\n' "$label" "$ttft" "$(dps "$tokens" "$decode")" "$note"
    else
      printf '%s -> TTFT=n/a, decode=n/a\n' "$label"
    fi
  }
  stream_line "enable_thinking=false" "$ttft_false" "$tokens_false" "$decode_false" "$est_false"
  stream_line "enable_thinking=true " "$ttft_true"  "$tokens_true"  "$decode_true"  "$est_true"
  echo
fi

# No single marker string covers every vendor's reasoning format (Qwen wraps
# in "</think>", Gemma prefixes with a literal "thought" line, others may
# differ again). Treat the false-response as "still reasoning" if it either
# contains a known marker, spans multiple lines, or is suspiciously long for
# a "reply with just the number" prompt -- the true answer here is 2 chars.
lines_false=$(printf '%s' "$content_false" | wc -l)
looks_like_reasoning=false
if echo "$content_false" | grep -qiE '</think>|^thought$|^thought[[:space:]]'; then
  looks_like_reasoning=true
elif [[ "$lines_false" -gt 0 || "${tokens_false:-0}" -gt 15 ]]; then
  looks_like_reasoning=true
fi

if [[ "$looks_like_reasoning" == true ]]; then
  echo "❌ Thinking mode could NOT be disabled -- reasoning-shaped output still present with enable_thinking=false."
elif [[ "$content_true" == "$content_false" ]]; then
  echo "⚠️  Identical output both ways -- enable_thinking had no effect (this model/template likely doesn't support the toggle at all)."
else
  echo "✅ Thinking mode CAN be disabled -- enable_thinking=false gives a short direct answer, enable_thinking=true adds visible reasoning."
fi
