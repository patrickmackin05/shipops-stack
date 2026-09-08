#!/usr/bin/env bash
# Authenticate this server to a private container registry.
#
#   ./registry-login.sh ghcr.io <github-username>
#
# Why this exists: the CI runner logs in to push the image, but the SERVER has
# to log in separately to pull it. Nothing in the deploy pipeline does that for
# you, so without this step the very first real deploy fails at `docker pull`
# with "denied" - on the client's server, during the 48-hour window.
#
# Skip it entirely if the package is public.
#
# The token is read from stdin so it never lands in your shell history or in
# the process list. Create it at:
#   github.com/settings/tokens  ->  classic token  ->  read:packages ONLY
#
# Scope it to read:packages and nothing else. This token sits on the client's
# server; it must not be able to touch source, issues or actions.

set -Eeuo pipefail

REGISTRY="${1:?usage: registry-login.sh <registry> <username>}"
USERNAME="${2:?usage: registry-login.sh <registry> <username>}"

echo "Paste the access token (read:packages), then press Enter."
echo "Nothing will be echoed."
read -rs TOKEN
echo

[[ -n "$TOKEN" ]] || { echo "no token given" >&2; exit 1; }

printf '%s' "$TOKEN" | docker login "$REGISTRY" --username "$USERNAME" --password-stdin
unset TOKEN

echo
echo "Credentials stored in ${HOME}/.docker/config.json (base64, not encrypted)."
echo "chmod 600 it and treat the file as a secret:"
chmod 600 "${HOME}/.docker/config.json" 2>/dev/null || true
echo "  ls -l ${HOME}/.docker/config.json"
echo
echo "Verify with a pull of a known tag:"
echo "  docker pull ${REGISTRY}/<owner>/<repo>:<tag>"
