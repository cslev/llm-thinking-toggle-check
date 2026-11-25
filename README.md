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
./llm_thinking_toggle_check.sh [-v] [-s] [-u url] [-k api_key] [-m model_id] [model_id]
```

| Option | Description |
|---|---|
| `-u`, `--url URL` | Endpoint base URL, no `/v1` (overrides `LLM_OPENAI_API_URL`) |
| `-k`, `--api-key KEY` | API key (overrides `LLM_OPENAI_API_KEY`; visible in `ps`, so prefer `.env` on shared machines) |
| `-m`, `--model MODEL` | Model to test (overrides `LLM_OPENAI_MODEL`; a positional `model_id` works too) |
| `-s`, `--stream` | Use streaming requests and also report time-to-first-token and decode tokens/s per mode |
| `--no-stream` | Plain non-streaming requests (default) |
| `-v`, `--verbose` | Also print the full raw JSON responses |
| `-h`, `--help` | Show help |

Options override `.env`, and `.env` is not needed if all three are given as options.
With `--stream`, two extra lines report TTFT (request start to first
content/reasoning chunk) and decode tokens/s ((tokens − 1) / time from first to
last chunk), which excludes prompt processing and latency. If the server sends no
usage block, the token count is estimated from chunks and flagged.
By default only the summary and verdict are printed. The summary includes the
completion tokens, request time and end-to-end tokens/s for each mode
(completion tokens / total request time, so it includes prompt processing and
network latency and understates decode speed for very short outputs).

## Configuration (`.env`)

| Variable | Description |
|---|---|
| `LLM_OPENAI_API_URL` | Base URL of the endpoint, without `/v1` (the script appends `/v1/chat/completions`) |
| `LLM_OPENAI_API_KEY` | API key, sent as a Bearer token |
| `LLM_OPENAI_MODEL` | Default model ID to test |
