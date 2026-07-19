#!/usr/bin/env bash
# Vertex-native onboarding wizard for the Grok-on-Vertex fork.
#
# Connects the user's own GCP / Vertex AI project and writes a working config:
#   gcloud check/login -> pick project -> region -> ensure API -> discover &
#   PROBE models (Gemini + Claude) -> write ~/.grok/config.toml + token bridge
#   + default MCP + launch picker.
#
# Only models that return HTTP 200 to a real 1-token probe are written, so the
# config never contains a model the project can't actually serve.
#
# Usage:  ./setup-wizard.sh            # interactive, writes to $GROK_HOME (default ~/.grok)
#         GROK_HOME=/tmp/x ./setup-wizard.sh
#         ./setup-wizard.sh --probe-only PROJECT REGION   # non-interactive dry run
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${GROK_HOME:-$HOME/.grok}"
say()  { printf '\033[1;36m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$*"; }
err()  { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }

need() { command -v "$1" >/dev/null 2>&1 || { err "Missing required tool: $1"; exit 1; }; }

# ---- Candidate models to probe. Gemini via OpenAI-compat; Claude via messages. ----
# Region matters: Gemini 3.x currently only serves on the `global` endpoint.
GEMINI_CANDIDATES=(
  "gemini-2.5-pro" "gemini-2.5-flash" "gemini-2.5-flash-lite"
  "gemini-3.1-pro-preview" "gemini-3.5-flash" "gemini-3-flash-preview" "gemini-3.1-flash-lite"
)
CLAUDE_CANDIDATES=(
  "claude-sonnet-4-5@20250929" "claude-opus-4-1@20250805"
)

# openapi base for a region (global uses the apex host).
openapi_base() {
  local proj="$1" region="$2"
  if [[ "$region" == "global" ]]; then
    echo "https://aiplatform.googleapis.com/v1beta1/projects/${proj}/locations/global/endpoints/openapi"
  else
    echo "https://${region}-aiplatform.googleapis.com/v1beta1/projects/${proj}/locations/${region}/endpoints/openapi"
  fi
}

# Probe one Gemini model via the OpenAI-compat chat endpoint. Echoes "200" etc.
probe_gemini() {
  local token="$1" proj="$2" region="$3" model="$4"
  local url; url="$(openapi_base "$proj" "$region")/chat/completions"
  curl -s -o /dev/null -w "%{http_code}" -X POST "$url" \
    -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    -d "{\"model\":\"google/${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1}"
}

# Anthropic-on-Vertex base (Model Garden). The patched client appends
# /{model}:streamRawPredict and injects anthropic_version.
claude_base() {
  local proj="$1" region="$2"
  echo "https://${region}-aiplatform.googleapis.com/v1/projects/${proj}/locations/${region}/publishers/anthropic/models"
}

# Probe one Claude model via Vertex rawPredict. Echoes the HTTP code.
probe_claude() {
  local token="$1" proj="$2" region="$3" model="$4"
  curl -s -o /dev/null -w "%{http_code}" -X POST \
    "$(claude_base "$proj" "$region")/${model}:rawPredict" \
    -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    -d "{\"anthropic_version\":\"vertex-2023-10-16\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1}"
}

# ---- Non-interactive probe-only mode (for testing/CI) ----
if [[ "${1:-}" == "--probe-only" ]]; then
  need gcloud
  PROJECT="${2:?usage: --probe-only PROJECT REGION}"; REGION="${3:?usage: --probe-only PROJECT REGION}"
  TOKEN="$(gcloud auth print-access-token 2>/dev/null)"
  say "Probing Gemini models in ${PROJECT}/${REGION}:"
  for m in "${GEMINI_CANDIDATES[@]}"; do
    code="$(probe_gemini "$TOKEN" "$PROJECT" "$REGION" "$m")"
    [[ "$code" == "200" ]] && printf "  \033[1;32m✓ %s\033[0m\n" "$m" || printf "  \033[0;90m✗ %s (%s)\033[0m\n" "$m" "$code"
  done
  say "Probing Claude (Vertex Model Garden):"
  for m in "${CLAUDE_CANDIDATES[@]}"; do
    code="$(probe_claude "$TOKEN" "$PROJECT" "$REGION" "$m")"
    [[ "$code" == "200" ]] && printf "  \033[1;32m✓ %s\033[0m\n" "$m" || printf "  \033[0;90m✗ %s (%s)\033[0m\n" "$m" "$code"
  done
  exit 0
fi

# =====================  Interactive wizard  =====================
need gcloud; need curl; need python3

say "== Vertex-native agent setup =="
echo

# 1) Auth
if ! gcloud auth print-access-token >/dev/null 2>&1; then
  warn "You're not logged in to gcloud."
  read -r -p "Run 'gcloud auth login' now? [Y/n] " a; a="${a:-Y}"
  [[ "$a" =~ ^[Yy] ]] && gcloud auth login || { err "Login required. Aborting."; exit 1; }
fi
ACCOUNT="$(gcloud config get-value account 2>/dev/null)"
say "Signed in as: ${ACCOUNT}"

# 2) Pick project
echo; say "Your GCP projects:"
mapfile -t PROJECTS < <(gcloud projects list --format="value(projectId)" 2>/dev/null)
if [[ ${#PROJECTS[@]} -eq 0 ]]; then err "No projects found for ${ACCOUNT}."; exit 1; fi
i=1; for p in "${PROJECTS[@]}"; do printf "  %2d) %s\n" "$i" "$p"; ((i++)); done
read -r -p "Choose a project [1]: " pn; pn="${pn:-1}"
PROJECT="${PROJECTS[$((pn-1))]:-${PROJECTS[0]}}"
say "Project: ${PROJECT}"

# 3) Region
echo; read -r -p "Vertex region [us-central1] (use 'global' for Gemini 3.x): " REGION
REGION="${REGION:-us-central1}"

# 4) Billing + API
echo; say "Checking billing + Vertex AI API on ${PROJECT}…"
if ! gcloud billing projects describe "$PROJECT" --format="value(billingEnabled)" 2>/dev/null | grep -qi true; then
  warn "Billing is NOT enabled on ${PROJECT}. Inference will fail until you enable it:"
  warn "  https://console.cloud.google.com/billing/enable?project=${PROJECT}"
fi
gcloud services enable aiplatform.googleapis.com --project "$PROJECT" >/dev/null 2>&1 \
  && say "Vertex AI API enabled." || warn "Could not enable aiplatform.googleapis.com (enable it manually)."

# 5) Discover + probe models
echo; say "Probing which models ${PROJECT}/${REGION} actually serves…"
TOKEN="$(gcloud auth print-access-token 2>/dev/null)"
WORKING_GEMINI=()
for m in "${GEMINI_CANDIDATES[@]}"; do
  code="$(probe_gemini "$TOKEN" "$PROJECT" "$REGION" "$m")"
  if [[ "$code" == "200" ]]; then WORKING_GEMINI+=("$m"); printf "  \033[1;32m✓ %s\033[0m\n" "$m"
  else printf "  \033[0;90m✗ %s (%s)\033[0m\n" "$m" "$code"; fi
done
if [[ ${#WORKING_GEMINI[@]} -eq 0 ]]; then
  err "No Gemini models responded in ${REGION}. Try 'global', or check billing/API. Aborting."
  exit 1
fi
DEFAULT_MODEL="${WORKING_GEMINI[0]}"

# Claude on Vertex (Model Garden). 404 until enabled + terms accepted in the
# Console; the wizard just skips any that don't respond.
WORKING_CLAUDE=()
say "Probing Claude (Vertex Model Garden) in ${PROJECT}/${REGION}…"
for m in "${CLAUDE_CANDIDATES[@]}"; do
  code="$(probe_claude "$TOKEN" "$PROJECT" "$REGION" "$m")"
  if [[ "$code" == "200" ]]; then WORKING_CLAUDE+=("$m"); printf "  \033[1;32m✓ %s\033[0m\n" "$m"
  else printf "  \033[0;90m✗ %s (%s) — enable in Model Garden if wanted\033[0m\n" "$m" "$code"; fi
done

# 6) Write token bridge + config + MCP + picker
mkdir -p "$DEST"
# token bridge pinned to the signed-in account
cat > "$DEST/gcp-token.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
token="\$(gcloud auth print-access-token ${ACCOUNT} 2>/dev/null)"
printf '{"access_token":"%s","expires_in":3300,"issuer":"google"}\n' "\$token"
EOF
chmod +x "$DEST/gcp-token.sh"

CFG="$DEST/config.toml"
{
  echo "# Generated by setup-wizard.sh on project ${PROJECT} / ${REGION}."
  echo "disable_web_search = true"
  echo
  echo "[auth]"
  echo "auth_provider_command = \"${DEST}/gcp-token.sh\""
  echo "auth_provider_label   = \"Google Cloud (Vertex AI)\""
  echo "auth_token_ttl        = 3300"
  echo
  echo "[models]"
  echo "default = \"${DEFAULT_MODEL}\""
  echo
  base="$(openapi_base "$PROJECT" "$REGION")"
  for m in "${WORKING_GEMINI[@]}"; do
    echo "[model.\"${m}\"]"
    echo "model          = \"google/${m}\""
    echo "base_url       = \"${base}\""
    echo "name           = \"${m}\""
    echo "api_backend    = \"chat_completions\""
    echo "context_window = 1048576"
    echo
  done
  cbase="$(claude_base "$PROJECT" "$REGION")"
  for m in "${WORKING_CLAUDE[@]}"; do
    # Vertex Claude via the patched `messages` backend (streamRawPredict).
    echo "[model.\"${m}\"]"
    echo "model          = \"${m}\""
    echo "base_url       = \"${cbase}\""
    echo "name           = \"${m} (Vertex)\""
    echo "api_backend    = \"messages\""
    echo "context_window = 200000"
    echo
  done
  echo "[cli]"
  echo "auto_update = false"
  echo
  echo "[features]"
  echo "telemetry = false"
  echo
  echo "# Default MCP: keyless web search/fetch (replaces xAI web_search)."
  echo "[mcp_servers.ddg-search]"
  echo "command = \"uvx\""
  echo "args = [\"duckduckgo-mcp-server\"]"
} > "$CFG"
say "Wrote ${CFG} with ${#WORKING_GEMINI[@]} verified model(s)."

# launch-time picker
cp "$SRC/grok-pick.zsh" "$DEST/grok-pick.zsh" 2>/dev/null || true
ZSHRC="$HOME/.zshrc"; LINE="source ${DEST}/grok-pick.zsh"
if [[ -f "$ZSHRC" ]] && ! grep -qF "$LINE" "$ZSHRC"; then
  printf '\n# Vertex agent: launch-time model picker\n%s\n' "$LINE" >> "$ZSHRC"
  say "Added model picker to ~/.zshrc."
fi

echo; say "Done. Default model: ${DEFAULT_MODEL}"
echo "  Start:  source ~/.zshrc && grok"
[[ "$REGION" != "global" && "$DEFAULT_MODEL" == gemini-3* ]] && warn "Note: Gemini 3.x needs the PATCHED binary for tool use."
