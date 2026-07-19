# Vertex Adapter Patch (Sub-project A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Patch Grok Build's Rust source so Gemini (and other Vertex) models work with the full agent — starting with the Gemini 3.x `thought_signature` round-trip that today makes any multi-step tool use fail with HTTP 400.

**Architecture:** Three small, family-gated changes in the sampler stack: (A1) capture Gemini's `thought_signature` from streamed tool-call deltas, carry it on `ToolCall`, and echo it back on the next request; (A2) sanitize tool JSON-schemas Vertex rejects; (A3) route by model family. A1 is the foundation and is fully specified here; A2/A3 are scoped tasks refined after A1 lands and is built.

**Tech Stack:** Rust (edition per `rust-toolchain.toml`, pinned 1.92.0), Cargo workspace, `serde`/`serde_json`, `tokio`. Crates: `xai-grok-sampler`, `xai-grok-sampling-types`.

## Global Constraints

- Toolchain pinned by `rust-toolchain.toml` (1.92.0). Build via `cargo` per-crate; full-workspace builds are slow — always `-p <crate>`.
- Requires **DotSlash** on PATH (`bin/protoc` resolves through it) and **protoc** (or `$PROTOC`).
- Root `Cargo.toml` is generated/read-only — edit per-crate manifests only.
- `clippy.toml` bans `std::fs::canonicalize` and friends — do not introduce them.
- New behavior MUST be **gated to the Gemini model family** and be a strict no-op for xAI/OpenAI/Anthropic requests. Never send `thought_signature` to a non-Gemini endpoint.
- Keep the patch minimal and localized — this fork rebases on upstream syncs.
- Commit after each task with a message prefixed `feat(vertex):` or `test(vertex):`.

---

## Task 0: Establish a buildable baseline

**Files:** none (environment + baseline verification)

**Interfaces:**
- Produces: a confirmed-green baseline so later TDD failures are attributable to our code.

- [ ] **Step 1: Install the toolchain**

```bash
# Rust (rustup auto-installs the pinned toolchain on first build)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
# DotSlash (required for bin/protoc)
cargo install dotslash
# protoc fallback if DotSlash can't fetch: brew install protobuf  (macOS)
```

- [ ] **Step 2: Verify tooling**

Run: `cargo --version && dotslash --version && (protoc --version || bin/protoc --version)`
Expected: three version strings, no errors.

- [ ] **Step 3: Build the two crates we will touch (baseline)**

Run: `cargo test -p xai-grok-sampling-types -p xai-grok-sampler --no-run`
Expected: compiles; test binaries built. If it fails, fix the environment before proceeding.

- [ ] **Step 4: Run existing tests to confirm green baseline**

Run: `cargo test -p xai-grok-sampling-types -p xai-grok-sampler`
Expected: PASS (all existing tests green).

- [ ] **Step 5: Commit a baseline marker (docs only)**

```bash
git add docs/superpowers/plans/2026-07-18-vertex-adapter-patch.md
git commit -m "chore(vertex): record baseline build for adapter patch"
```

---

## Task 1: Wire type — capture `thought_signature` on streamed tool-call deltas

**Files:**
- Modify: `crates/codegen/xai-grok-sampling-types/src/types.rs:604-619` (`ToolCallDelta`)
- Test: same file's `#[cfg(test)]` module (add a deserialization test)

**Interfaces:**
- Produces: `ToolCallDelta { ..., extra_content: Option<ToolCallExtraContent> }` and
  `ToolCallExtraContent { google: Option<GoogleToolCallExtra> }`,
  `GoogleToolCallExtra { thought_signature: Option<String> }`. Consumed by Task 3.

- [ ] **Step 1: Write the failing test**

Add to the tests module in `types.rs`:

```rust
#[test]
fn tool_call_delta_captures_google_thought_signature() {
    let json = r#"{
        "index": 0,
        "id": "call_1",
        "type": "function",
        "function": {"name": "search", "arguments": "{}"},
        "extra_content": {"google": {"thought_signature": "SIG-ABC"}}
    }"#;
    let d: ToolCallDelta = serde_json::from_str(json).unwrap();
    assert_eq!(
        d.extra_content
            .and_then(|e| e.google)
            .and_then(|g| g.thought_signature)
            .as_deref(),
        Some("SIG-ABC")
    );
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p xai-grok-sampling-types tool_call_delta_captures_google_thought_signature`
Expected: FAIL — `ToolCallDelta` has no field `extra_content`.

- [ ] **Step 3: Add the types + field**

In `types.rs`, add near `ToolCallDelta`:

```rust
/// Provider-specific extension on a tool call. Gemini returns a
/// `thought_signature` here that MUST be echoed back on the next request.
#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct ToolCallExtraContent {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub google: Option<GoogleToolCallExtra>,
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct GoogleToolCallExtra {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thought_signature: Option<String>,
}
```

Then add to `ToolCallDelta` (after the `function` field, ~line 618):

```rust
    /// Provider extension (Gemini `thought_signature`, etc.).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub extra_content: Option<ToolCallExtraContent>,
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cargo test -p xai-grok-sampling-types tool_call_delta_captures_google_thought_signature`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add crates/codegen/xai-grok-sampling-types/src/types.rs
git commit -m "feat(vertex): capture Gemini thought_signature on tool-call delta"
```

---

## Task 2: Domain type — carry `thought_signature` on `ToolCall`

**Files:**
- Modify: `crates/codegen/xai-grok-sampling-types/src/conversation.rs:453-460` (`ToolCall`)
- Test: same file's tests module

**Interfaces:**
- Consumes: nothing new.
- Produces: `ToolCall` gains `pub thought_signature: Option<Arc<str>>` (defaulted `None`).
  Every existing `ToolCall { id, name, arguments }` literal must add `thought_signature: None`.

- [ ] **Step 1: Write the failing test**

Add to the tests module in `conversation.rs`:

```rust
#[test]
fn tool_call_defaults_thought_signature_none() {
    let tc = ToolCall {
        id: Arc::<str>::from("id"),
        name: "n".to_string(),
        arguments: Arc::<str>::from("{}"),
        thought_signature: None,
    };
    assert!(tc.thought_signature.is_none());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p xai-grok-sampling-types tool_call_defaults_thought_signature_none`
Expected: FAIL — no field `thought_signature` (compile error).

- [ ] **Step 3: Add the field**

In `ToolCall` (conversation.rs:453), after `arguments`:

```rust
    /// Gemini-only opaque signature that MUST be echoed back on the next
    /// request or Vertex rejects the follow-up turn (HTTP 400). `None` for
    /// all other providers.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thought_signature: Option<Arc<str>>,
```

- [ ] **Step 4: Fix every `ToolCall {…}` construction site**

Run: `cargo build -p xai-grok-sampling-types -p xai-grok-sampler 2>&1 | grep -n "missing field"`
For each reported site, add `thought_signature: None,`. Known site to update:
`crates/codegen/xai-grok-sampler/src/stream/chat_completions.rs:250-254` (handled fully in Task 3).

- [ ] **Step 5: Run test + build to verify green**

Run: `cargo test -p xai-grok-sampling-types tool_call_defaults_thought_signature_none`
Expected: PASS. Then `cargo build -p xai-grok-sampler` compiles.

- [ ] **Step 6: Commit**

```bash
git add crates/codegen/xai-grok-sampling-types/src/conversation.rs
git commit -m "feat(vertex): carry thought_signature on ToolCall"
```

---

## Task 3: Stream parse — thread `thought_signature` from delta into `ToolCall`

**Files:**
- Modify: `crates/codegen/xai-grok-sampler/src/stream/chat_completions.rs:76` (accumulator),
  `:197-230` (delta loop), `:248-255` (final build)
- Test: same file's tests module

**Interfaces:**
- Consumes: `ToolCallDelta.extra_content` (Task 1), `ToolCall.thought_signature` (Task 2).
- Produces: assembled `ToolCall`s whose `thought_signature` is set when the stream carried one.

- [ ] **Step 1: Write the failing test**

Add a test that feeds a synthetic chunk stream (follow the existing `rid()`/chunk-builder
test helpers at `chat_completions.rs:311+`) where a tool-call delta includes
`extra_content.google.thought_signature = "SIG"`, drives the collector, and asserts the
resulting `AssistantItem.tool_calls[0].thought_signature.as_deref() == Some("SIG")`.

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p xai-grok-sampler thought_signature`
Expected: FAIL — value is `None` (currently dropped).

- [ ] **Step 3: Extend the accumulator tuple**

At `chat_completions.rs:76`, change the accumulator value type to carry a 4th element:

```rust
// (id, name, arguments_buffer, thought_signature)
let mut tool_call_acc: BTreeMap<u32, (String, String, String, Option<String>)> = BTreeMap::new();
```

At `:200-202` update the `or_insert_with` to `(String::new(), String::new(), String::new(), None)`.
In the delta loop (after the `function` block, ~`:221`) add:

```rust
if let Some(extra) = tc_delta.extra_content
    && let Some(g) = extra.google
    && let Some(sig) = g.thought_signature
{
    entry.3 = Some(sig);
}
```

- [ ] **Step 4: Set the field when building the final `ToolCall`**

At `:248-255` update the map closure:

```rust
.map(|(id, name, arguments, thought_signature)| ToolCall {
    id: std::sync::Arc::<str>::from(id),
    name,
    arguments: std::sync::Arc::<str>::from(arguments),
    thought_signature: thought_signature.map(std::sync::Arc::<str>::from),
})
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cargo test -p xai-grok-sampler thought_signature`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add crates/codegen/xai-grok-sampler/src/stream/chat_completions.rs
git commit -m "feat(vertex): thread thought_signature from stream into ToolCall"
```

---

## Task 4: Request echo — send `thought_signature` back on the next turn

**Files:**
- Modify: the `ConversationItem::Assistant` → `ChatRequestMessage` serialization in
  `crates/codegen/xai-grok-sampling-types/src/conversation.rs` (the function that builds
  `ChatRequestMessage` with `tool_calls` from `AssistantItem`; locate with
  `grep -n "tool_calls" crates/codegen/xai-grok-sampling-types/src/conversation.rs` and find
  the request-build site that maps `ToolCall` → `ToolCallResponse`).
- Modify: `crates/codegen/xai-grok-sampling-types/src/types.rs` — add an optional
  `extra_content` to the outgoing `ToolCallResponse` (mirror of Task 1's types, serialized).
- Test: request-serialization test in `conversation.rs` tests module.

**Interfaces:**
- Consumes: `ToolCall.thought_signature` (Task 2), `ToolCallExtraContent` (Task 1).
- Produces: outgoing assistant `tool_calls[]` include
  `extra_content.google.thought_signature` when present. Gemini-family only (see Task 6 gate;
  until Task 6 lands, presence of a non-None `thought_signature` is itself the gate, since only
  Gemini ever populates it).

- [ ] **Step 1: Write the failing test**

In `conversation.rs` tests, build a `ConversationRequest` whose assistant item has a
`ToolCall { thought_signature: Some("SIG".into()), .. }`, serialize it to the chat request
body (via the same path the client uses), and assert the JSON contains
`"extra_content":{"google":{"thought_signature":"SIG"}}` inside that tool call.

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p xai-grok-sampling-types echo_thought_signature`
Expected: FAIL — field absent from serialized output.

- [ ] **Step 3: Add `extra_content` to `ToolCallResponse`**

In `types.rs` `ToolCallResponse` (`:506-511`):

```rust
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub extra_content: Option<ToolCallExtraContent>,
```

- [ ] **Step 4: Populate it at the request-build site**

Where `ToolCall` is mapped into `ToolCallResponse`, set:

```rust
extra_content: tc.thought_signature.as_ref().map(|sig| ToolCallExtraContent {
    google: Some(GoogleToolCallExtra { thought_signature: Some(sig.to_string()) }),
}),
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cargo test -p xai-grok-sampling-types echo_thought_signature`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add crates/codegen/xai-grok-sampling-types/src/{types.rs,conversation.rs}
git commit -m "feat(vertex): echo Gemini thought_signature on outgoing tool_calls"
```

---

## Task 5: End-to-end live verification against Vertex (Gemini 3.x)

**Files:** none (manual/integration verification using the built binary)

**Interfaces:**
- Consumes: Tasks 1–4. Produces: proof that Gemini 3.x multi-step tool use no longer 400s.

- [ ] **Step 1: Build the patched binary**

Run: `cargo build -p xai-grok-pager-bin --release`
Expected: builds `target/release/xai-grok-pager`.

- [ ] **Step 2: Point config at a Gemini 3.x model on the `global` endpoint**

Use the prototype config in `gemini-integration/` but switch the default model to
`gemini-3.1-pro-preview` with `base_url` = the `global` endpoint
(`https://aiplatform.googleapis.com/v1beta1/projects/<PROJECT>/locations/global/endpoints/openapi`).

- [ ] **Step 3: Run the multi-step tool task that previously 400'd**

Run: `target/release/xai-grok-pager --always-approve -p "Run the shell command 'date +%Y', write the year to year.txt, then read it back and report." -m gemini-3.1-pro-preview`
Expected: completes with `num_turns >= 2`, no `thought_signature` 400, and `year.txt` is created.

- [ ] **Step 4: Regression — confirm 2.5 + a non-Gemini model still work**

Run the same task with `-m gemini-2.5-pro` (expect success) and, if configured, a Claude-on-Vertex
model (expect success and NO `extra_content` in its request — capture with the logging proxy in
`gemini-integration` scratch if needed).

- [ ] **Step 5: Commit the verified config sample**

```bash
git add gemini-integration/
git commit -m "test(vertex): verified Gemini 3.x tool loop via thought_signature patch"
```

---

## Task 6: Family gate hardening (defense-in-depth)

**Files:**
- Modify: the request-build site from Task 4 to additionally gate emission on model family
  (Gemini), so a stray `thought_signature` can never be sent to xAI/OpenAI/Anthropic even if
  some future path populates it.
- Test: `conversation.rs` tests — assert a non-Gemini request omits `extra_content` even when a
  `ToolCall.thought_signature` is set.

**Interfaces:**
- Consumes: model-family detection (introduced here or in Task 7/A3). Minimal version: a boolean
  `is_gemini_family` threaded from the request's model id (`starts_with("google/")` or
  `contains("gemini")`).

- [ ] **Step 1: Write the failing test** — non-Gemini request with a set `thought_signature`
  serializes WITHOUT `extra_content`.
- [ ] **Step 2: Run — expect FAIL** (currently emitted unconditionally).
- [ ] **Step 3: Add the `is_gemini_family` gate** at the emission site.
- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit** `feat(vertex): gate thought_signature echo to Gemini family`.

---

## A2 (follow-on, to refine after A1 lands): Tool-schema sanitizer

Add a Gemini-family-gated pass over outgoing `ToolSpec.parameters` that removes/normalizes
JSON-Schema keywords Vertex rejects. Scope precisely to what actually breaks per model — in
this session `$schema` was tolerated, so start by testing each of Grok's ~24 built-in tool
schemas against Vertex and only strip keywords that produce a 400. TDD per keyword. Files:
`xai-grok-sampling-types` (schema transform) + a unit test matrix. Deferred to its own task set
because the exact keyword list must be measured against the built binary from Task 5.

## A3 (follow-on): Model-family routing/config

Centralize family detection (Gemini/Claude/xAI) and per-family defaults: backend
(`chat_completions` vs `messages`), region defaulting (Gemini 3.x → `global`), reasoning-effort
mapping (`minimal|low|medium|high`), and the A1/A2/A6 gates. Files: a small
`model_family.rs` helper in `xai-grok-sampler` consumed by the request builder. Deferred because
its shape is clearest once A1 + A2 exist.

---

## Status (2026-07-18) — Sub-project A functionally COMPLETE & VERIFIED

- **A1 (thought_signature round-trip): DONE.** Tasks 0–5 implemented, TDD-green
  (155 sampler + 274 types tests pass), and **verified live**: patched binary +
  `gemini-3.1-pro-preview` completed a shell→write→read multi-step tool loop
  against Vertex (global) with **no HTTP 400**. Commits `aadd8fd`..`e769a6e`.
- **A2 (schema sanitizer): NOT NEEDED (YAGNI).** The live verification sent Grok's
  full 24-tool schema (with `$schema`/`format`/`const`/`additionalProperties`) and
  Vertex accepted it — the first tool-call request succeeded; only the *follow-up*
  400'd on the missing signature, which A1 fixes. No keyword actually breaks. Revisit
  only if a specific future model rejects a specific schema.
- **A3 (family routing): DEFERRED (polish).** Config already routes backend/region/
  reasoning per model (`api_backend`, per-model `base_url`, region in URL). Centralizing
  in code is a refactor, not a functional gap.
- **Task 6 (family gate): DEFERRED (YAGNI).** Guards a narrow mid-session Gemini→non-Gemini
  switch; `extra_content` is `skip_serializing_if none` and other chat_completions providers
  ignore unknown fields. Add if a strict non-Gemini endpoint is observed rejecting it.

**Conclusion:** the adapter's essential change (A1) is complete and proven. The rest of
the product is Sub-projects B–E (catalog, wizard, MCP bundle, rebrand/distribution).

## Self-Review

- **Spec coverage:** A1 (thought_signature) fully covered by Tasks 1–6; A2 and A3 from the spec
  are scoped as explicit follow-on task sets (their exact content depends on measurements from the
  Task 5 build). Build-environment risk (spec §7) covered by Task 0.
- **Placeholder scan:** Task 4/Task 6 reference a request-build site located by `grep` rather than a
  fixed line — this is because the exact conversion line must be confirmed in the working tree; the
  grep anchor + the type names make it unambiguous. No "TBD/handle edge cases" placeholders remain.
- **Type consistency:** `ToolCallExtraContent`/`GoogleToolCallExtra`/`thought_signature` names are
  used identically across Tasks 1, 3, 4, 6; `ToolCall.thought_signature: Option<Arc<str>>` matches
  its construction in Task 3 (`.map(Arc::<str>::from)`) and its read in Task 4 (`as_ref().map(to_string)`).
