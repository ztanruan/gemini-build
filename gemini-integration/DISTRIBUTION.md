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

## Not yet done (future E work)
- Source rebrand (binary/product strings) — deferred until a product name is chosen.
- CI matrix for macOS/Linux release binaries + a hosted `install.sh` one-liner.
- Claude-on-Vertex **live** verification (needs a Model-Garden-enabled Claude model).
