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
# Usage: ./llm_thinking_toggle_check.sh [model_id]
#   model_id defaults to $LLM_OPENAI_MODEL from .env if not given.

set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -f .env ]]; then
  echo "Error: .env not found. Copy .env.example to .env and fill in your values." >&2
  exit 1
fi
source .env

MODEL="${1:-$LLM_OPENAI_MODEL}"
PROMPT="What is 12 * 7? Reply with just the number."

echo "Testing model: ${MODEL}"
echo

call_llm() {
  local enable_thinking="$1"
  local body
  body=$(jq -n \
    --arg model "$MODEL" \
    --arg prompt "$PROMPT" \
    --argjson thinking "$enable_thinking" \
    '{
      model: $model,
      messages: [{role: "user", content: $prompt}],
      temperature: 0.0,
      chat_template_kwargs: {enable_thinking: $thinking}
    }')
  curl -s --max-time 120 "${LLM_OPENAI_API_URL}/v1/chat/completions" \
    -H "Authorization: Bearer ${LLM_OPENAI_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$body"
}

echo "=== Request 1: enable_thinking=false ==="
resp_false=$(call_llm false)
error_false=$(echo "$resp_false" | jq -r '.error.message // empty')
content_false=$(echo "$resp_false" | jq -r '.choices[0].message.content // empty')
tokens_false=$(echo "$resp_false" | jq -r '.usage.completion_tokens // empty')
echo "$resp_false" | jq .
echo

echo "=== Request 2: enable_thinking=true ==="
resp_true=$(call_llm true)
error_true=$(echo "$resp_true" | jq -r '.error.message // empty')
content_true=$(echo "$resp_true" | jq -r '.choices[0].message.content // empty')
tokens_true=$(echo "$resp_true" | jq -r '.usage.completion_tokens // empty')
echo "$resp_true" | jq .
echo

echo "=== Result ==="

if [[ -n "$error_false" || -n "$error_true" ]]; then
  echo "⚠️  Request failed -- cannot determine thinking-mode behavior."
  [[ -n "$error_false" ]] && echo "  enable_thinking=false error: ${error_false}"
  [[ -n "$error_true"  ]] && echo "  enable_thinking=true  error: ${error_true}"
  exit 1
fi

echo "enable_thinking=false -> completion_tokens=${tokens_false}, content: ${content_false}"
echo "enable_thinking=true  -> completion_tokens=${tokens_true}, content: ${content_true}"
echo

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
