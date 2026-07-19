#!/usr/bin/env bash
# Grok Build external auth provider for Google Cloud (Vertex AI).
#
# Grok runs this whenever it needs a token (and again, with
# GROK_AUTH_EXPIRED=1, once the previous one is near expiry). It prints a
# JSON object on stdout with the access token and its lifetime so Grok
# knows when to refresh. GCP access tokens live ~3600s.
#
# Auth used: gcloud user login (jintan2013@gmail.com). Prefers Application
# Default Credentials, falls back to the active gcloud user token.
set -euo pipefail

# Use the project OWNER's gcloud credentials explicitly. ADC on this machine
# resolves to a different Google account (jintan2013@) that lacks Vertex access,
# so pin to the account that owns shutterstock-asset-processor.
token="$(gcloud auth print-access-token jtanruan@gmail.com 2>/dev/null)"

# 3300s (55 min) refresh margin under the ~60 min GCP token lifetime.
printf '{"access_token":"%s","expires_in":3300,"issuer":"google"}\n' "$token"
