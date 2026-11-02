#!/usr/bin/env bash
# Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
#
# WSO2 LLC. licenses this file to you under the Apache License,
# Version 2.0 (the "License"); you may not use this file except
# in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
#
# Ubiquitous-language lint for the OpenAPI contracts (plan M2/M5): L2-era words `post` and `submission`
# must not appear in paths, operationIds, schema names or property names. Use Campaign, Share,
# External share. Enum values (e.g. the OWN_POST action), descriptions and the HTTP `post:` method key
# are not names and are skipped.
#
# External-API names are allowed: a name that starts with an external provider (`linkedinPosts`, the
# count of LinkedIn `/rest/posts` calls in the jobs run report) speaks LinkedIn's language about
# LinkedIn's resource, not Amplify's. The rule is about Amplify's own nouns. Add a provider to
# `external` only when the name really counts or carries that provider's resource.
#
# Usage: scripts/lint-openapi-names.sh [openapi.yaml ...]   scripts/lint-openapi-names.sh --self-test
#        (default: every amplify-*/openapi.yaml)
set -euo pipefail
# A banned word as a whole name segment: at the start (any case) or a camel/snake segment (`Post`,
# `_post`). `reposters` and `OWN_POST`-style enum values don't match.
seg='(post|submission)'
word="(^|[^A-Za-z])(${seg}|Post|Submission|POST|SUBMISSION)|[a-z0-9](Post|Submission)"
external='^(linkedin)[A-Z]'

lint_files() {
  local status=0 f
  for f in "$@"; do
    [ -f "$f" ] && [ -r "$f" ] || { echo "lint-openapi-names: $f is not a readable file" >&2; return 2; }
  done
  for f in "$@"; do
  # 1. Paths: top-level keys under `paths:` (two-space indent, start with /). Same whole-segment rule as the
  # names below, so `/campaigns/{id}/reposts` passes and `/posts` does not.
  hits=$(grep -nE '^  /' "$f" | grep -E "$word" || true)
  # 2. operationId values.
  hits+=$'\n'$(grep -nE 'operationId:' "$f" | sed -E 's/.*operationId: *//' | grep -E "$word" || true)
  # 3. Mapping keys (schema and property names), minus the HTTP method keys at four-space indent.
  # Quoted keys (`"Post":`) are names too.
  hits+=$'\n'$(grep -nE '^ *["'"'"']?[A-Za-z_][A-Za-z0-9_]*["'"'"']?:' "$f" \
    | grep -vE '^[0-9]+:    (get|post|put|patch|delete|options|head):' \
    | sed -E 's/^([0-9]+:) *["'"'"']?([A-Za-z0-9_]+)["'"'"']?:.*/\1 \2/' \
    | awk '{print $2}' | grep -E "$word" | grep -vE "$external" || true)
  # 4. Keys in flow mappings, e.g. `{name: postId, ...}` parameter names.
  hits+=$'\n'$(grep -oE 'name: *[A-Za-z0-9_-]+' "$f" | sed -E 's/name: *//' | grep -E "$word" | grep -vE "$external" || true)
  # 5. Every other key in a flow mapping, e.g. `properties: {postId: {type: string}}`. The HTTP method keys
  # (`{post: {...}}`) are not names.
  hits+=$'\n'$(grep -oE '[{,] *["'"'"']?[A-Za-z_][A-Za-z0-9_]*["'"'"']? *:' "$f" | sed -E 's/^[{,] *["'"'"']?//; s/["'"'"']? *:$//' \
    | grep -vxE '(get|post|put|patch|delete|options|head)' | grep -E "$word" | grep -vE "$external" || true)
  hits=$(printf '%s\n' "$hits" | sed '/^$/d')
  if [ -n "$hits" ]; then
    echo "$f: banned names (use the ubiquitous language: Campaign, Share, External share):"
    echo "$hits"
    status=1
  fi
  done
  [ $status -eq 0 ] && echo "lint-openapi-names: OK ($*)"
  return $status
}

if [ "${1:-}" = "--self-test" ]; then
  TMPDIR_SELF=$(mktemp -d)
  trap 'rm -rf "$TMPDIR_SELF"' EXIT
  cat > "$TMPDIR_SELF/good.yaml" <<'YAML'
paths:
  /campaigns/{id}/reposts:
    get:
      operationId: listReposts
  /campaigns/{id}/shares:
    post:
      operationId: createShare
components:
  schemas:
    RunReport:
      properties:
        linkedinPosts: {type: integer}
YAML
  cat > "$TMPDIR_SELF/bad-path.yaml" <<'YAML'
paths:
  /posts:
    get:
      operationId: listPosts
YAML
  cat > "$TMPDIR_SELF/bad-name.yaml" <<'YAML'
components:
  schemas:
    PostSummary:
      properties:
        title: {type: string}
YAML
  cat > "$TMPDIR_SELF/bad-op.yaml" <<'YAML'
paths:
  /campaigns:
    post:
      operationId: createPost
YAML
  cat > "$TMPDIR_SELF/bad-quoted.yaml" <<'YAML'
components:
  schemas:
    "Post": {type: string}
YAML
  cat > "$TMPDIR_SELF/bad-flow.yaml" <<'YAML'
components:
  schemas:
    Summary:
      properties: {postId: {type: string}}
YAML
  lint_files "$TMPDIR_SELF/good.yaml" >/dev/null || { echo "self-test: a segment match (reposts) or a provider name (linkedinPosts) was rejected"; exit 1; }
  lint_files "$TMPDIR_SELF/bad-path.yaml" >/dev/null && { echo "self-test: /posts passed"; exit 1; }
  lint_files "$TMPDIR_SELF/bad-name.yaml" >/dev/null && { echo "self-test: PostSummary passed"; exit 1; }
  lint_files "$TMPDIR_SELF/bad-op.yaml" >/dev/null && { echo "self-test: operationId createPost passed"; exit 1; }
  lint_files "$TMPDIR_SELF/bad-quoted.yaml" >/dev/null && { echo "self-test: a quoted \"Post\" key passed"; exit 1; }
  lint_files "$TMPDIR_SELF/bad-flow.yaml" >/dev/null && { echo "self-test: a flow-mapping postId key passed"; exit 1; }
  # A path that cannot be read must fail, not print OK: that was the silent no-op.
  lint_files "$TMPDIR_SELF/missing.yaml" 2>/dev/null && { echo "self-test: an unreadable file reported OK"; exit 1; }
  # A directory is readable but is not a contract: it must fail too, not scan nothing and print OK.
  lint_files "$TMPDIR_SELF" 2>/dev/null && { echo "self-test: a directory reported OK"; exit 1; }
  echo "lint-openapi-names self-test passed."
  exit 0
fi

caller="$PWD"
cd "$(dirname "$0")/.."
files=()
for a in "$@"; do
  # Arguments are relative to where the caller ran this, not to the folder the script moves into.
  case "$a" in /*) files+=("$a") ;; *) files+=("$caller/$a") ;; esac
done
if [ ${#files[@]} -eq 0 ]; then
  shopt -s nullglob
  files=(amplify-*/openapi.yaml)
  shopt -u nullglob
fi
[ ${#files[@]} -gt 0 ] || { echo "lint-openapi-names: no OpenAPI files to lint" >&2; exit 2; }
lint_files "${files[@]}"
