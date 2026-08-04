# llm-thinking-toggle-check

A small bash script that checks whether a reasoning LLM served via an
OpenAI-compatible endpoint (e.g. vLLM) actually honors the
`chat_template_kwargs.enable_thinking` toggle — i.e. whether you can reliably
suppress the model's "thinking" output through the API.

## How it works

The script sends the same trivial prompt (*"What is 12 \* 7? Reply with just
the number."*) twice at temperature 0 — once with `enable_thinking: false`,
once with `true` — and compares the responses. Note that
`chat_template_kwargs` must be **top-level** in the request body (a vLLM
extension); nesting it under `extra_body` is a LangChain-SDK-only wrapper that
never reaches the wire.

Since there is no universal reasoning marker (Qwen3 wraps thinking in
`</think>`, Gemma emits a literal `thought` line, others differ), the
`false` response is flagged as "still reasoning" heuristically: known marker
present, multi-line output, or more than 15 completion tokens for an answer
that should just be `84`.

Verdicts:

- ✅ toggle works — `false` gives a short direct answer, `true` shows reasoning
- ❌ toggle doesn't work — reasoning-shaped output despite `enable_thinking: false`
- ⚠️ toggle has no effect — identical output both ways (the model's chat
  template likely doesn't support the flag)

## Requirements

`bash`, `curl`, `jq`

## Usage

```bash
cp .env.example .env   # then fill in your endpoint URL, API key, and model
./llm_thinking_toggle_check.sh [model_id]
```

`model_id` is optional and defaults to `LLM_OPENAI_MODEL` from `.env`.
Both raw JSON responses are printed in full, followed by the verdict.

## Configuration (`.env`)

| Variable | Description |
|---|---|
| `LLM_OPENAI_API_URL` | Base URL of the endpoint, without `/v1` (the script appends `/v1/chat/completions`) |
| `LLM_OPENAI_API_KEY` | API key, sent as a Bearer token |
| `LLM_OPENAI_MODEL` | Default model ID to test |
