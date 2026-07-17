#!/usr/bin/env bash
# Grok Build external auth provider for Google Cloud (Vertex AI).
# Installed to ~/.grok/gcp-token.sh by install.sh.
#
# Grok runs this whenever it needs a token (and again, with
# GROK_AUTH_EXPIRED=1, once the previous one is near expiry). It prints a
# JSON object on stdout with the access token and its lifetime so Grok
# knows when to refresh. GCP access tokens live ~3600s.
#
# Auth used: gcloud user login. Prefers Application Default Credentials,
# falls back to the active gcloud user token.
set -euo pipefail

token="$(gcloud auth application-default print-access-token 2>/dev/null \
  || gcloud auth print-access-token)"

# 3300s (55 min) refresh margin under the ~60 min GCP token lifetime.
printf '{"access_token":"%s","expires_in":3300,"issuer":"google"}\n' "$token"
