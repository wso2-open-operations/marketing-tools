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
# Fails when the deployment descriptors drift (plan M8c). Per component it compares:
#   Choreo .choreo/component.yaml  <->  OpenChoreo workload.yaml : endpoint names, ports, env names (exact)
#   Dockerfile EXPOSE                                            : same ports
#   compose.yaml service env                                     : subset of the descriptor env + LOCAL_ONLY
#   Docker context (ADR-027)                                     : the descriptor is <context>/.choreo/component.yaml,
#                                                                  no two components share a context, schemaFilePath
#                                                                  exists under the context, and compose builds the
#                                                                  same context and Dockerfile
# No yq needed: the descriptors are written one key per line on purpose.
#
# Usage: scripts/check-descriptors.sh [apps/amplify root]   scripts/check-descriptors.sh --self-test
set -uo pipefail  # no -e on purpose: report every drift, then exit non-zero at the end
LINKEDIN=linkedin/apps/mock_linkedin

# component | Choreo descriptor | workload.yaml | Dockerfile | compose service | Docker context
# (every path is relative to apps/amplify; jobs builds from its parent `apps`, the unique ancestor ADR-027 needs)
COMPONENTS=(
  "amplify-api|.choreo/component.yaml|amplify-api/workload.yaml|amplify-api/Dockerfile|amplify-api|."
  "amplify-jobs|../.choreo/component.yaml|amplify-jobs/workload.yaml|amplify-jobs/Dockerfile|amplify-jobs|.."
  "amplify-database|amplify-database/.choreo/component.yaml|amplify-database/workload.yaml|amplify-database/Dockerfile|amplify-db-migrate|amplify-database"
  "amplify-scheduler|amplify-scheduler/.choreo/component.yaml|amplify-scheduler/workload.yaml|amplify-scheduler/Dockerfile|scheduler|amplify-scheduler"
  "mock-linkedin|$LINKEDIN/.choreo/component.yaml|$LINKEDIN/workload.yaml|$LINKEDIN/Dockerfile|mock-linkedin|$LINKEDIN"
)
# Set only in local Compose, never in Choreo/OpenChoreo (dev JWT, plain-http stub, fast schedules, no TLS to
# the local Postgres, browser-facing mock OAuth URL).
LOCAL_ONLY="BAL_CONFIG_VAR_DEVLOCALJWTENABLED BAL_CONFIG_VAR_DEVJWKSFILE BAL_CONFIG_VAR_CHATALLOWINSECUREHTTP BAL_CONFIG_VAR_NOVERAALLOWINSECUREHTTP
BAL_CONFIG_VAR_MINRUNINTERVALSECONDS BAL_CONFIG_VAR_RECONCILEDELAYSECONDS BAL_CONFIG_VAR_DBSSLMODE
BAL_CONFIG_VAR_LINKEDINAUTHORIZEBASEURL
BAL_CONFIG_VAR_ENABLEMOCKADMIN BAL_CONFIG_VAR_MOCKADMINKEY"

envs()  { grep -E '^\s*- name: (BAL_CONFIG_[A-Z_]+|DSN)\s*$' "$1" | awk '{print $3}' | sort -u; }
ports() { grep -E '^\s+port: [0-9]+' "$1" | awk '{print $2}' | sort -u; }
epnames() { awk '/^endpoints:/{e=1;next} /^[a-z]/{e=0} e && /^  - name:/{print $3}' "$1" | sort; }
exposed() { grep -E '^EXPOSE' "$1" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u; }
compose_envs() {  # env keys of one compose service, including the x-db-common anchor when merged
  awk -v svc="$1" '
    /^x-db-common:/ {a=1; next} a && /^[^ ]/ {a=0}
    a && /^  [A-Z_]+:/ {sub(":","",$1); anchor[$1]=1}
    /^  [a-z][a-z0-9-]*:$/ {s=($1==svc":")}
    s && /<<: \*db-common/ {for (k in anchor) print k}
    s && /^      (BAL_CONFIG_[A-Z_]+|DSN):/ {sub(":","",$1); print $1}
  ' compose.yaml | sort -u
}

# Absolute, symlink-free form of a path whose directory exists.
norm() { local d; d="$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)" || return 1; printf '%s/%s' "$d" "$(basename "$1")"; }
# `context:` and `dockerfile:` of one compose service's build block (dockerfile defaults to Dockerfile).
compose_build() {  # service -> "context dockerfile"
  awk -v svc="$1" '
    /^  [a-z][a-z0-9-]*:$/ {s=($1==svc":"); b=0}
    s && /^    build:/ {b=1; next}
    s && b && /^      context:/ {ctx=$2}
    s && b && /^      dockerfile:/ {df=$2}
    s && b && /^    [a-z_]+:/ {b=0}
    END {if (ctx != "") print ctx, (df == "" ? "Dockerfile" : df)}
  ' compose.yaml
}

fail=0
err() { echo "DRIFT [$1]: $2"; fail=1; }

# scan: compare the descriptors under one apps/amplify root. Reports every drift, then returns non-zero.
scan() {
  cd "$1" || { echo "check-descriptors: cannot enter $1" >&2; return 2; }
  fail=0
  seen_contexts=""
for row in "${COMPONENTS[@]}"; do
  IFS='|' read -r name desc wl dockerfile svc ctx <<<"$row"
  for f in "$desc" "$wl" "$dockerfile"; do [[ -f "$f" ]] || { err "$name" "missing $f"; continue 2; }; done
  # Docker context (ADR-027): Choreo reads <context>/.choreo/component.yaml, so the descriptor must live there and
  # two components on one context would read the same file.
  ctx_abs="$(cd "$ctx" 2>/dev/null && pwd -P)"
  [[ "$(norm "$desc")" == "$ctx_abs/.choreo/component.yaml" ]] || err "$name" "descriptor $desc is not <context $ctx>/.choreo/component.yaml"
  if [[ -n "$ctx_abs" ]]; then
    case " $seen_contexts " in *" $ctx_abs "*) err "$name" "Docker context $ctx is shared with another component" ;; esac
    seen_contexts="$seen_contexts $ctx_abs"
    schema="$(awk '/^ +schemaFilePath:/{print $2}' "$desc" | head -1)"
    [[ -z "$schema" || -f "$ctx/$schema" ]] || err "$name" "schemaFilePath $schema does not exist under context $ctx"
    # Choreo only sees files inside the Docker context, so a schema that resolves outside it is as good as missing.
    if [[ -n "$schema" && -f "$ctx/$schema" ]]; then
      case "$(norm "$ctx/$schema")" in "$ctx_abs"/*) ;; *) err "$name" "schemaFilePath $schema resolves outside context $ctx" ;; esac
    fi
    read -r c_ctx c_df <<<"$(compose_build "$svc")"
    if [[ -z "${c_ctx:-}" ]]; then err "$name" "compose service $svc has no build context"
    else
      [[ "$(cd "$c_ctx" 2>/dev/null && pwd -P)" == "$ctx_abs" ]] || err "$name" "compose builds $svc from $c_ctx, not the descriptor's context $ctx"
      [[ "$(norm "$c_ctx/$c_df")" == "$(norm "$dockerfile")" ]] || err "$name" "compose builds $svc with Dockerfile $c_df, not $dockerfile"
    fi
  fi
  grep -q '^schemaVersion: "1.2"' "$desc" || err "$name" "$desc is not schemaVersion 1.2"
  [[ "$(envs "$desc")" == "$(envs "$wl")" ]] || err "$name" "env names differ: $(diff <(envs "$desc") <(envs "$wl") | grep '^[<>]' | tr '\n' ' ')"
  [[ "$(ports "$desc")" == "$(ports "$wl")" ]] || err "$name" "ports differ ($desc vs $wl)"
  [[ "$(epnames "$desc")" == "$(epnames "$wl")" ]] || err "$name" "endpoint names differ"
  [[ "$(ports "$desc")" == "$(exposed "$dockerfile")" ]] || err "$name" "Dockerfile EXPOSE $(exposed "$dockerfile" | xargs) != descriptor ports $(ports "$desc" | xargs)"
  # The final stage only: a USER set in a build stage does not carry into the image that runs.
  # Dockerfile instruction names are case-insensitive (`from`, `User`), so both scans match them that way.
  final_stage="$(awk 'tolower($1)=="from"{s=""} {s=s $0 "\n"} END{printf "%s", s}' "$dockerfile")"
  [[ "$(grep -iE '^USER ' <<<"$final_stage" | tail -1 | tr 'a-z' 'A-Z')" == "USER 10014" ]] || err "$name" "the final stage must end as USER 10014"
  # Base images pinned by digest (tag kept for readers), mock-linkedin included (same digests, jobs H5). A bare
  # `FROM name` passes only when `name` is an earlier stage (`AS name`), never as an unpinned base image.
  stages="$(grep -iE '^FROM .* AS ' "$dockerfile" | awk '{print tolower($NF)}')"
  unpinned=$(grep -iE '^FROM ' "$dockerfile" | grep -v '@sha256:[0-9a-f]\{64\}' | while read -r _ ref rest; do
    [[ "$(tr 'A-Z' 'a-z' <<<"$ref")" == "scratch" ]] && continue        # no digest exists for scratch
    if [[ -z "$rest" ]] && grep -qxF "$(tr 'A-Z' 'a-z' <<<"$ref")" <<<"$stages"; then continue; fi
    echo "FROM $ref $rest"
  done || true)
  [[ -z "$unpinned" ]] || err "$name" "base image not pinned by digest: $(echo $unpinned)"
  allowed=$(printf '%s\n' $(envs "$desc") $LOCAL_ONLY | sort -u)
  extra=$(comm -23 <(compose_envs "$svc") <(echo "$allowed"))
  [[ -z "$extra" ]] || err "$name" "compose service $svc sets names unknown to $desc: $(echo $extra)"
  [[ -n "$(compose_envs "$svc")" ]] || err "$name" "compose service $svc has no config env (parse error?)"
done
# Every compose image and the local-only Dockerfiles (chat-stub, people-stub) are pinned by digest too.
for f in local/chat-stub/Dockerfile local/people-stub/Dockerfile; do
  unpinned=$(grep -iE '^FROM ' "$f" | grep -v '@sha256:[0-9a-f]\{64\}' || true)
  [[ -z "$unpinned" ]] || err "$f" "base image not pinned by digest: $(echo $unpinned)"
done
unpinned=$(grep -E '^\s+image: ' compose.yaml | grep -v '@sha256:[0-9a-f]\{64\}' || true)
[[ -z "$unpinned" ]] || err compose.yaml "image not pinned by digest: $(echo $unpinned)"
# Only amplify-api (9090), the mock OAuth page (19091) and the local people-stub (19092) reach the host, on
# loopback (cell rules).
#
# Every entry under a `ports:` key must be the short quoted loopback form this scan can resolve. A Compose
# long-form mapping (`- target: 9090` with no `host_ip`) publishes on every interface, and an unquoted or
# partial mapping hides the host side; both used to slip through because the scan only selected
# `- "..."` lines. Rejecting the forms it cannot inspect is the safe answer (docs.docker.com/compose-file).
unparsed_ports=$(awk '
  /^  [a-z][a-z0-9-]*:$/ { svc = $1; sub(":$", "", svc); p = 0; next }
  /^    ports:/ { p = 1; next }
  p && /^    [a-z_]+:/ { p = 0; next }
  !p { next }
  !/^      - "127\.0\.0\.1:[0-9]+:[0-9]+(\/(tcp|udp))?"$/ { printf "%s %s\n", svc, $0 }
' compose.yaml)
while read -r svc entry; do
  [[ -z "$svc" ]] && continue
  err compose.yaml "port form this scan cannot verify (want - \"127.0.0.1:HOST:CONTAINER\"): $svc $entry"
done <<<"$unparsed_ports"

host_ports=$(awk '/^  [a-z][a-z0-9-]*:$/{svc=$1} /^    ports:/{p=1; next} /^    [a-z_]+:/{p=0} p && /^      - "/{print svc, $2}' compose.yaml)
while read -r svc port; do
  [[ -z "$svc" ]] && continue
  case "$svc $port" in
    'amplify-api: "127.0.0.1:9090:9090"'|'mock-linkedin: "127.0.0.1:19091:9091"') ;;
    'people-stub: "127.0.0.1:19092:9096"') ;;  # local stub only, so a local One WSO2 can read photos
    'apim: '*) ;;  # optional profile (`make up PROFILE=apim`), loopback only
    *) err compose.yaml "unexpected host port: $svc $port" ;;
  esac
  [[ "$port" == '"127.0.0.1:'* ]] || err compose.yaml "host port not on loopback: $svc $port"
done <<<"$host_ports"
[[ $fail -eq 0 ]] && echo "Descriptors in sync: ${#COMPONENTS[@]} components."
  return $fail
}

# The gate is the only thing standing between a drift and production, so it carries its own fixtures:
# every bypass below is one a reviewer had to find by reading the script.
if [ "${1:-}" = "--self-test" ]; then
  SELFTEST_TMP=$(mktemp -d)
  trap 'rm -rf "$SELFTEST_TMP"' EXIT
  DIGEST_A="sha256:$(printf 'a%.0s' {1..64})"
  DIGEST_B="sha256:$(printf 'b%.0s' {1..64})"
  COMPONENTS=("amplify-api|.choreo/component.yaml|amplify-api/workload.yaml|amplify-api/Dockerfile|amplify-api|.")

  fixture() {  # (re)write a clean, in-sync tree
    cd "$SELFTEST_TMP"
    rm -rf root; mkdir -p root/.choreo root/amplify-api root/local/chat-stub root/local/people-stub
    cat > root/.choreo/component.yaml <<EOF
schemaVersion: "1.2"
endpoints:
  - name: amplify-api
    port: 9090
configurations:
  - name: BAL_CONFIG_FOO
EOF
    cat > root/amplify-api/workload.yaml <<EOF
endpoints:
  - name: amplify-api
    port: 9090
configurations:
  - name: BAL_CONFIG_FOO
EOF
    cat > root/amplify-api/Dockerfile <<EOF
FROM alpine:3.20@$DIGEST_A AS build
RUN true
FROM alpine:3.20@$DIGEST_B
USER 10014
EXPOSE 9090
EOF
    for f in root/local/chat-stub/Dockerfile root/local/people-stub/Dockerfile; do
      printf 'FROM alpine:3.20@%s\n' "$DIGEST_A" > "$f"
    done
    cat > root/compose.yaml <<EOF
x-db-common: &db-common
  BAL_CONFIG_DB: 1

services:
  amplify-api:
    image: alpine:3.20@$DIGEST_A
    build:
      context: .
      dockerfile: amplify-api/Dockerfile
    ports:
      - "127.0.0.1:9090:9090"
    environment:
      BAL_CONFIG_FOO: 1
EOF
  }

  expect_ok() {  # label
    local out; out=$(scan "$SELFTEST_TMP/root" 2>&1)
    [[ $? -eq 0 ]] || { echo "self-test: $1 was rejected"; echo "$out"; exit 1; }
  }
  expect_drift() {  # label expected-substring
    local out; out=$(scan "$SELFTEST_TMP/root" 2>&1) && { echo "self-test: $1 passed"; exit 1; }
    grep -qF "$2" <<<"$out" || { echo "self-test: $1 failed for the wrong reason"; echo "$out"; exit 1; }
  }

  fixture; expect_ok "an in-sync tree"

  fixture
  python3 - "$SELFTEST_TMP/root/compose.yaml" <<'PYFIX'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = s.replace('''    ports:
      - "127.0.0.1:9090:9090"''', '''    ports:
      - target: 9090
        published: 9090''')
p.write_text(s)
PYFIX
  expect_drift "a long-form compose port with no host_ip" "port form this scan cannot verify"

  fixture
  printf 'FROM ubuntu:24.04\n' >> "$SELFTEST_TMP/root/amplify-api/Dockerfile"
  expect_drift "an unpinned base image" "base image not pinned by digest"

  fixture
  printf 'from ubuntu:24.04\n' >> "$SELFTEST_TMP/root/amplify-api/Dockerfile"
  expect_drift "an unpinned lowercase from" "base image not pinned by digest"

  fixture
  sed -i.bak 's/^USER 10014$//' "$SELFTEST_TMP/root/amplify-api/Dockerfile"
  expect_drift "USER 10014 only in the build stage" "the final stage must end as USER 10014"

  # A lowercase `from` starts the final stage too: the USER in the pinned build stage before it does not count.
  fixture
  cat > "$SELFTEST_TMP/root/amplify-api/Dockerfile" <<EOF
FROM alpine:3.20@$DIGEST_A AS build
USER 10014
EXPOSE 9090
from alpine:3.20@$DIGEST_B
EOF
  expect_drift "a lowercase final from after a USER in the build stage" "the final stage must end as USER 10014"

  # schemaFilePath: a file inside the context is fine, one that resolves outside it is not.
  fixture
  : > "$SELFTEST_TMP/root/schema.yaml"
  printf '    schemaFilePath: schema.yaml\n' >> "$SELFTEST_TMP/root/.choreo/component.yaml"
  expect_ok "a schemaFilePath inside the Docker context"
  fixture
  : > "$SELFTEST_TMP/outside.yaml"
  printf '    schemaFilePath: ../outside.yaml\n' >> "$SELFTEST_TMP/root/.choreo/component.yaml"
  expect_drift "a schemaFilePath that resolves outside the Docker context" "resolves outside context"

  fixture
  sed -i.bak '/BAL_CONFIG_FOO/d' "$SELFTEST_TMP/root/amplify-api/workload.yaml"
  expect_drift "an env name in one descriptor but not the other" "env names differ"

  fixture
  sed -i.bak 's/^EXPOSE 9090$/EXPOSE 9090 9091/' "$SELFTEST_TMP/root/amplify-api/Dockerfile"
  expect_drift "an EXPOSE the descriptor does not list" "Dockerfile EXPOSE"

  # ADR-027: a descriptor that is not at <context>/.choreo, and two components on one context.
  fixture
  COMPONENTS=("amplify-api|.choreo/component.yaml|amplify-api/workload.yaml|amplify-api/Dockerfile|amplify-api|amplify-api")
  expect_drift "a context whose .choreo is not the descriptor" "is not <context"
  COMPONENTS=("amplify-api|.choreo/component.yaml|amplify-api/workload.yaml|amplify-api/Dockerfile|amplify-api|."
              "amplify-twin|.choreo/component.yaml|amplify-api/workload.yaml|amplify-api/Dockerfile|amplify-api|.")
  expect_drift "two components on one Docker context" "is shared with another component"
  COMPONENTS=("amplify-api|.choreo/component.yaml|amplify-api/workload.yaml|amplify-api/Dockerfile|amplify-api|.")
  fixture
  sed -i.bak 's#dockerfile: amplify-api/Dockerfile#dockerfile: other/Dockerfile#' "$SELFTEST_TMP/root/compose.yaml"
  expect_drift "compose building a different Dockerfile" "compose builds amplify-api with Dockerfile"

  # A stage alias and `scratch` are not unpinned images.
  fixture
  cat > "$SELFTEST_TMP/root/amplify-api/Dockerfile" <<EOF
FROM alpine:3.20@$DIGEST_A AS base
FROM base
USER 10014
EXPOSE 9090
EOF
  expect_ok "a final stage built on a stage alias"

  fixture
  cat > "$SELFTEST_TMP/root/amplify-api/Dockerfile" <<EOF
FROM alpine:3.20@$DIGEST_A AS build
FROM scratch
COPY --from=build /app /app
USER 10014
EXPOSE 9090
EOF
  expect_ok "a final stage from scratch"

  echo "check-descriptors self-test passed."
  exit 0
fi

root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
scan "$root"
exit $?
