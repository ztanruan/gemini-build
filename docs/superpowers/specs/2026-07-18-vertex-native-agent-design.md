# Vertex-Native Coding Agent — Design Spec

**Date:** 2026-07-18
**Status:** Draft for review
**Base:** Fork of Grok Build (`xai-org/grok-build`, Apache-2.0), pinned to a `SOURCE_REV`.

---

## 1. Summary

A standalone, rebranded terminal coding agent built on Grok Build. Users connect
their **own** Google Cloud / Vertex AI project and use **any supported Vertex
model** (v1: Gemini + Claude) with **all** of Grok Build's tools, subagents, and
MCP — working correctly and tuned per model. Ships with a **guided setup wizard**,
a **curated set of default MCP servers**, and first-class **custom MCP** support.

### Goals
- Connect a user's own Vertex AI / GCP project; no xAI account or key required.
- Support **Gemini** (2.5 **and** 3.x) and **Claude on Vertex** (Model Garden) in v1.
- Every built-in tool + subagent works with these models; no silent tool failures.
- "Optimized for Vertex": per-model request adaptation (see §5).
- Curated default MCP servers on by default; one-command custom MCP add.
- Guided onboarding wizard writes a working config end to end.
- Distributed as a standalone rebranded CLI with its own install script.

### Non-goals (v1)
- Llama/Mistral/other Model Garden families (v2).
- A native Gemini `generateContent` backend (we use Vertex's OpenAI-compat layer).
- Fine-grained cost/billing dashboards.
- Windows (best-effort only, matching upstream).

---

## 2. Verified findings this project is built on

All confirmed with live tests against Vertex AI on 2026-07-18 (project
`shutterstock-asset-processor`):

1. **Gemini works via Vertex's OpenAI-compat endpoint** (`.../endpoints/openapi/chat/completions`),
   using Grok's existing `chat_completions` backend, model id `google/<model>`.
2. **Gemini 2.5 (pro/flash/flash-lite)** works fully — including **multi-step tool
   loops** (verified: shell → write file → read back). Region `us-central1`.
3. **Gemini 3.x** (3.1-pro-preview, 3.5-flash, 3.1-flash-lite) works for chat on the
   **`global`** endpoint, but **any multi-turn tool use returns HTTP 400**:
   `Function call is missing a thought_signature in functionCall parts`. Gemini 3.x
   returns a `thought_signature` in `tool_calls[].extra_content.google.thought_signature`
   that must be echoed back on the next turn; Grok drops it. **This is the core patch.**
4. **Built-in `web_search` is impossible with non-xAI models** — it calls the xAI
   Responses API with server-side search; Vertex returns `OpenMaaS model ... not supported`.
   Replaced by an MCP search server.
5. **Auth** works via a `gcloud`-minted OAuth token fed through Grok's
   `auth_provider_command` seam (short-lived, auto-refreshed). No source change needed.
6. **TOML gotcha:** model keys contain dots, so table headers MUST be quoted —
   `[model."gemini-2.5-pro"]`, not `[model.gemini-2.5-pro]` (the latter nests tables).
7. **Claude on Vertex** uses the Anthropic Messages API (Vertex Model Garden), which
   maps to Grok's existing `messages` backend. To be validated in Sub-project A/B.

---

## 3. Architecture

Three layers over a pinned upstream fork:

```
Layer 3  CONFIG/PROFILE (no build)   model catalog · token bridge · default+custom MCP
Layer 2  ONBOARDING WIZARD (any lang) gcloud → project → region → discover → write config
Layer 1  SOURCE PATCH (small Rust fork) thought_signature · schema sanitize · family routing · rebrand
──────── pinned on upstream Grok Build (SOURCE_REV) ────────
```

**Design principle:** keep Layer 1 (the Rust fork) as small as possible so it
rebases cleanly on each upstream sync. Everything that can live in config/wizard
(Layers 2–3) stays out of the fork.

---

## 4. Sub-projects (each gets its own plan)

### A. Vertex adapter patch (Rust, Layer 1) — foundation
The minimal source changes config cannot do.

- **A1. Gemini `thought_signature` round-trip.** Three touch points:
  1. **Capture** on response parse — `crates/codegen/xai-grok-sampler/src/stream/chat_completions.rs`
     accumulates tool calls as `(id, name, arguments)` at ~line 76; extend to also read
     `extra_content.google.thought_signature` from each `tool_calls` delta.
  2. **Store** on the tool call — add `thought_signature: Option<Arc<str>>` to
     `ToolCall` (`crates/codegen/xai-grok-sampling-types/src/conversation.rs:453`) and the
     wire delta types (`.../types.rs:605` `ToolCallDelta`, `:506` `ToolCallResponse`).
  3. **Echo** on request serialization — when an assistant turn with tool calls is
     re-serialized into the outgoing `chat/completions` body, emit
     `extra_content.google.thought_signature`. Gated to Gemini model family so it's a
     no-op for xAI/OpenAI/Anthropic.
- **A2. Tool-schema sanitizer.** Some JSON-Schema constructs in Grok's ~24 tool
  definitions can be rejected by Vertex's stricter validation. Add a family-gated pass
  that strips/normalizes unsupported keywords (`$schema`, `$ref`, `additionalProperties`,
  `format`, `const`, `not`, `prefixItems`, empty objects) before send. (Note: in testing
  `$schema` was tolerated, so scope this to what actually breaks per model.)
- **A3. Model-family routing/config.** Detect family from model id / base_url and apply:
  backend (Gemini→`chat_completions`, Claude→`messages`), region defaulting
  (Gemini 3.x→`global`), reasoning/thinking config mapping, and the A1/A2 gates.

**Testing A:** regression test that a captured `thought_signature` survives
capture→store→echo; unit tests for the sanitizer per keyword; an integration smoke
test per model (chat + multi-turn tool loop) run in the build environment.

### B. Model catalog + token bridge (Layer 3) — mostly built
- **B1. Token bridge** — `gcloud`-minted OAuth token via `auth_provider_command`,
  JSON `{access_token, expires_in, issuer}`, pinned to the project-owner account.
  (Prototype exists: `gemini-integration/gcp-token.sh`.)
- **B2. Model catalog generation** — writes quoted `[model."..."]` blocks for the
  discovered Gemini + Claude models with correct `base_url`, `api_backend`, region,
  `context_window`. (Prototype exists: `gemini-integration/config.toml`.)
- **B3. Claude-on-Vertex entries** — `messages` backend against the Vertex Anthropic
  endpoint; auth via the same gcloud bearer. Validate tool use end to end.

### C. Onboarding wizard (Layer 2)
A first-run / `init` subcommand. Flow:
1. Check `gcloud` present; if not, guide install.
2. `gcloud auth login` / ADC if not authenticated.
3. List the user's GCP projects → user picks one.
4. Ask region (default `us-central1`; note `global` for Gemini 3.x).
5. Ensure billing enabled + `aiplatform.googleapis.com` enabled (guide if not).
6. **Discover** models: Vertex publisher list (Gemini) + Model Garden (Claude);
   **probe** each with a 1-token call; keep only those returning 200.
7. Write `config.toml` (catalog + token bridge + default MCP) and install the token script.
8. Print next steps.

**Testing C:** scripted run against a test project; asserts a working config that
passes a live chat + tool probe.

### D. Default MCP bundle (Layer 3)
- Curated productivity set enabled by default: **web search + fetch** (keyless, e.g.
  DuckDuckGo MCP — replaces the broken `web_search`), plus **persistent memory**,
  **time/date**, and **sequential-thinking**. Each vetted, pinned, and launched via a
  runtime already present (`uvx`/`npx`).
- `disable_web_search = true` set by default (the xAI one can't work).
- Custom MCP: rely on Grok's existing `[mcp_servers.*]` + a thin `mcp add` catalog command.

**Testing D:** each default server handshakes (`mcp doctor`) and exposes expected tools;
one live agent task that invokes the search MCP under Gemini 2.5 and Claude.

### E. Rebrand + build/distribution pipeline (Layer 1 + packaging)
- Rename binary + product strings; own install script (`curl … | bash`) and update flow.
- **Build pipeline** applies the Layer-1 patches to the pinned upstream `SOURCE_REV`
  and produces macOS/Linux binaries. Requires Rust toolchain + DotSlash + protoc.
- Rebase playbook for each upstream sync.

---

## 5. "Optimized for Vertex" — concrete scope
1. `thought_signature` round-trip (correctness for Gemini 3.x tools) — **required**.
2. Tool-schema sanitization for Vertex's stricter validation.
3. Per-model reasoning/thinking config (`reasoning_effort` ∈ {minimal,low,medium,high}).
4. Region routing (per-model availability: `us-central1` vs `global`).
5. Backend routing (Gemini→`chat_completions`, Claude→`messages`).
6. Token/usage accounting mapped from Vertex responses.

---

## 6. Model support matrix (v1)

| Model | Backend | Endpoint/region | Tools | Notes |
|---|---|---|---|---|
| Gemini 2.5 pro/flash/flash-lite | chat_completions | us-central1 | ✅ verified | Works today, no patch |
| Gemini 3.x (3.1-pro-preview, 3.5-flash, 3.1-flash-lite) | chat_completions | global | ✅ **after A1** | 400 without thought_signature patch |
| Claude (Opus/Sonnet) on Vertex | messages (**adapted**) | Model Garden region | ⚠️ **needs source work** | See note below |

> **Claude-on-Vertex correction (verified 2026-07-18):** NOT a drop-in config path.
> (1) Claude models 404 until enabled per-model in Vertex Model Garden (accept Anthropic
> terms — user action). (2) Vertex Claude uses `…/publishers/anthropic/models/<model>:streamRawPredict`
> with `{"anthropic_version":"vertex-2023-10-16", …}` and the model in the URL — Grok's
> `messages` backend posts to `{base_url}/messages` with `model` in the body. So B requires a
> small source variant of the messages backend (Vertex rawPredict shape), gated by base_url host.
> This moves Claude from "config-only" to a Layer-1 (patch) item, like Gemini 3.x.

---

## 7. Risks & open questions
- **Build environment**: Layers 1 & E need a Rust build pipeline not present on the
  current machine. Must be set up (dev machine or CI) before A/E can be realized.
- **Upstream churn**: Grok Build is monorepo-synced; the Layer-1 patch must be kept
  small and rebase-tested each sync.
- **Gemini preview volatility**: 3.x model ids/regions and the OpenAI-compat surface can
  change; discovery-by-probe (C6) hedges this.
- **Claude-on-Vertex tool use** not yet end-to-end verified (open item for A/B).
- **thought_signature semantics**: confirm it must be echoed verbatim and only on the
  Gemini family; ensure it never leaks to xAI/OpenAI/Anthropic requests.
- **Naming/branding** for the standalone product: TBD.

---

## 8. Build order
**A → B → C → D → E**, with A first (unblocks 3.x and clean tool use). B is largely
prototyped. C/D are user-facing. E productizes and ships.
