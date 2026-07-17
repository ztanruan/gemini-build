# Gemini on Vertex AI — integration for Grok Build

Run the `grok` CLI/TUI against **Google Gemini** models on **your own GCP
project** (Vertex AI), authenticated by your `gcloud` login, with an
arrow-key model picker at launch.

**No source changes to Grok.** This works entirely through Grok's built-in
bring-your-own-model config (`api_backend = "chat_completions"` against
Vertex AI's OpenAI-compatible endpoint) plus its `auth_provider_command`
seam for short-lived GCP tokens.

## What's here

| File | Installed to | Purpose |
|------|--------------|---------|
| `config.toml`    | `~/.grok/config.toml`   | Vertex endpoints + switchable Gemini models |
| `gcp-token.sh`   | `~/.grok/gcp-token.sh`  | Mints a fresh GCP access token on demand (auto-refresh) |
| `grok-pick.zsh`  | `~/.grok/grok-pick.zsh` | Arrow-key model picker shown when you run bare `grok` |
| `install.sh`     | —                       | Copies the above into `~/.grok/` and edits `~/.zshrc` |

> These files must live in `~/.grok/` (and `~/.zshrc` must source the
> picker) for Grok to use them. This folder is the tracked source of truth;
> `install.sh` deploys it.

## Install

```sh
./install.sh
gcloud auth application-default login     # one-time
# enable billing on the project (see below), then:
grok
```

## Requirements

- `gcloud` installed and logged in.
- Vertex AI API enabled: `gcloud services enable aiplatform.googleapis.com`.
- **Billing enabled** on the project — Vertex returns HTTP 403
  `BILLING_DISABLED` until this is done.

## Configuration

- **Project / region** are baked into every `base_url` in `config.toml`
  (currently project `smoothiesdeliveryv1`, region `us-central1`). To change
  region, replace `us-central1` throughout, or use the `global` endpoint
  (host `aiplatform.googleapis.com`, `locations/global`).
- **Models**: each `[model.*]` block appears in the picker and in
  `/model` / `Ctrl+M`. Keep the `ids`/`labels` arrays in `grok-pick.zsh` in
  sync with the blocks in `config.toml`.

### Current models (July 2026)

- `gemini-3.1-pro` — flagship (default)
- `gemini-3.5-flash` — fast, newest
- `gemini-3.1-flash-lite` — cheapest
- `gemini-2.5-pro` — legacy, **retires 2026-10-16**

Gemini 2.0 was shut down June 2026. `gemini-3.5-pro` is still limited-preview.

## Verify (after billing is on)

```sh
TOKEN=$(gcloud auth application-default print-access-token)
curl -s -X POST \
  "https://us-central1-aiplatform.googleapis.com/v1beta1/projects/smoothiesdeliveryv1/locations/us-central1/endpoints/openapi/chat/completions" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"model":"google/gemini-3.1-pro","messages":[{"role":"user","content":"say works"}]}'
```

## Uninstall

```sh
rm ~/.grok/gcp-token.sh ~/.grok/grok-pick.zsh
# restore or remove ~/.grok/config.toml (see ~/.grok/config.toml.bak.* if any)
# remove the "source ~/.grok/grok-pick.zsh" line from ~/.zshrc
```
