# Distribution & upstream-rebase playbook (Sub-project E)

How to build, ship, and keep this fork in sync with upstream Grok Build.

## Build & install

```sh
gemini-integration/build.sh              # release binary -> target/release/xai-grok-pager
gemini-integration/install.sh            # build (if needed) + install + run wizard
BRAND=myagent gemini-integration/install.sh   # install under a custom command name
```

Requirements: Rust (rustup auto-installs the pinned toolchain), and `protoc`
(or `dotslash` + `bin/protoc`). See the root README.

## What the fork adds (the patch surface to preserve on rebase)

All changes are small and localized — keep them minimal so rebases stay cheap:

| Area | Files | Purpose |
|------|-------|---------|
| Gemini thought_signature | `xai-grok-sampling-types/src/{types,conversation}.rs`, `xai-grok-sampler/src/stream/chat_completions.rs` | 3.x tool-use round-trip |
| Field fill-ins | `xai-grok-sampler/src/stream/messages.rs`, `xai-grok-shell/src/**` | `thought_signature: None` at `ToolCall` sites |
| Claude-on-Vertex | `xai-grok-sampler/src/client.rs` | `messages` backend → Vertex `streamRawPredict` shape |
| Onboarding/config | `gemini-integration/**` | wizard, token bridge, picker, MCP, installer |

## Rebasing on an upstream sync

Upstream (`xai-org/grok-build`) is periodically re-synced (squashed commits, a
new `SOURCE_REV`). To move the fork forward:

1. `git fetch upstream && git log -1 upstream/main` — note the new `SOURCE_REV`.
2. `git rebase upstream/main` onto the `vertex-native-agent` branch.
3. Resolve conflicts — they cluster in the four files above. The most likely
   conflict is **new `ToolCall { … }` construction sites** added upstream that
   now need `thought_signature: None`. After rebase:
   ```sh
   cargo build -p xai-grok-shell 2>&1 | grep -n "missing field \`thought_signature\`"
   ```
   Add `thought_signature: None,` at each reported site.
4. Re-run the guard tests:
   ```sh
   cargo test -p xai-grok-sampling-types -p xai-grok-sampler
   ```
   Expect the thought_signature + vertex_* tests green.
5. Rebuild and re-run the live check (patched binary + a Gemini 3.x multi-step
   tool task) — see `docs/superpowers/plans/2026-07-18-vertex-adapter-patch.md` Task 5.

## Provider status

| Provider | Backend | Status | Notes |
|----------|---------|--------|-------|
| Gemini 2.5 (pro/flash/lite) | chat_completions | ✅ verified live | us-central1 or global |
| Gemini 3.x (3.1-pro-preview, 3.5-flash, …) | chat_completions | ✅ verified live | **global only**; needs the patch |
| Claude (Sonnet/Opus) on Vertex | messages | 🧪 experimental, unit-tested | see `claude-vertex-sample.toml`; enable in Model Garden first |
| Other OpenAI-compat Vertex models | chat_completions | ⚪ untested | should work by config |

## Correctness behaviors added by the patch

- **thought_signature is gated to Gemini** (`client.rs` `apply_defaults` + `is_gemini_model`).
  It is captured/echoed for Gemini (required for 3.x tool loops) and **stripped** from
  requests to any non-Gemini chat_completions endpoint, so a mid-session model switch
  never leaks it. Tests: `apply_defaults_gates_thought_signature_to_gemini`, `gemini_model_detection`.
- **Safety/content-filter blocks are surfaced** (`stream/chat_completions.rs`). A Gemini/Vertex
  response with `finish_reason=content_filter` and no content now sets `stop_message`
  (consumed by the shell as a refusal explanation, `turn.rs:2067`) instead of a silent
  empty turn that would stall the agent loop. Test: `content_filter_block_sets_stop_message`.
- **Claude-on-Vertex dialect** (`client.rs`): the `messages` backend auto-switches to
  Vertex's `streamRawPredict` + `anthropic_version` shape when the base_url is an
  `aiplatform.googleapis.com` host. The URL/body decision is a single shared helper
  (`messages_request_target`) used by both the streaming and non-streaming paths so they
  can't drift. Tests: `messages_request_target_vertex_vs_anthropic`, `vertex_anthropic_*`,
  `vertexize_body_*`.
- **`api_backend` is auto-inferred from the model id / base_url** when the user omits it
  (`agent/config.rs` `infer_api_backend`): `claude*` or an `publishers/anthropic` /
  `api.anthropic.com` host → `messages`; everything else keeps the `chat_completions`
  default. Removes the "wrong backend" footgun for hand-written config. Test:
  `infer_api_backend_from_model_id_and_base_url`.

## Known limitations / not yet done

- **Claude-on-Vertex is unverified live** — enable a Claude model in Vertex Model Garden
  (accept Anthropic terms), then run a multi-turn tool task to confirm streaming + tool_use.
- **Structured output (responseSchema) and multimodal image input are untested** on the
  Vertex OpenAI-compat layer — they pass through but were not exercised; verify before relying on them.
- **Vertex-Anthropic detection is by host string** (`is_vertex_anthropic_host`), not an
  explicit per-model config flag. It is correct and zero-config; promoting it to a config
  field was deferred (it would touch ~26 `SamplerConfig` construction sites for no behavior change).
- Source rebrand (binary/product strings) — deferred until a product name is chosen.
- CI matrix for macOS/Linux release binaries + a hosted `install.sh` one-liner.
