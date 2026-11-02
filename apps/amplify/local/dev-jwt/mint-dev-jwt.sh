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
# DEV-ONLY (ADR-023). Mints RS256 tokens that amplify-api accepts only when
# devLocalJwtEnabled=true AND environment=local. Never use these keys anywhere else.
#
#   ./mint-dev-jwt.sh init                                   # once: dev-key.pem + jwks.json (both gitignored)
#   ./mint-dev-jwt.sh token <sub> <email> [group ...]        # prints a token valid for 30 minutes
#
# Then: curl -H "x-jwt-assertion: $(./mint-dev-jwt.sh token emp-1 ada@example.com amplify_po)" localhost:9090/me
set -euo pipefail
cd "$(dirname "$0")"

ISSUER="${DEV_ISSUER:-amplify-local-dev}"
AUDIENCE="${DEV_AUDIENCE:-amplify-local}"
KID="amplify-local-dev-1"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

case "${1:-}" in
  init)
    umask 077
    openssl genrsa -out dev-key.pem 2048 2>/dev/null
    n=$(openssl rsa -in dev-key.pem -noout -modulus | cut -d= -f2 | xxd -r -p | b64url)
    printf '{"keys":[{"kty":"RSA","use":"sig","alg":"RS256","kid":"%s","n":"%s","e":"AQAB"}]}\n' "$KID" "$n" > jwks.json
    chmod 644 jwks.json
    echo "Wrote dev-key.pem and jwks.json (gitignored)."
    ;;
  token)
    sub="${2:?sub}"; email="${3:?email}"; shift 3
    groups=$(printf '"%s",' "$@"); groups="[${groups%,}]"
    [ "$groups" = '[""]' ] && groups='[]'
    now=$(date +%s)
    header=$(printf '{"alg":"RS256","typ":"JWT","kid":"%s"}' "$KID" | b64url)
    payload=$(printf '{"iss":"%s","aud":"%s","sub":"%s","email":"%s","groups":%s,"iat":%d,"exp":%d}' \
      "$ISSUER" "$AUDIENCE" "$sub" "$email" "$groups" "$now" "$((now + 1800))" | b64url)
    sig=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign dev-key.pem -binary | b64url)
    printf '%s.%s.%s\n' "$header" "$payload" "$sig"
    ;;
  *)
    sed -n '18,24p' "$0"; exit 1 ;;
esac
