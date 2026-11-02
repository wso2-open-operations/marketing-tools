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

# The Chat webhook URL carries the space key and the secret token in its query. Any `ballerina/http` client
# call puts the request URL on the client span (`http.url`) when observability is on, so the token would reach
# the trace backend. The googlechat module therefore sends through the JDK client (transport.bal) and must
# never create an `http:Client`. Fails if a non-test source in the module does, or if it logs the URL.
#
# Usage: scripts/check-chat-transport.sh [root]   (default root: the folder above this script)
set -euo pipefail
root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
dir="$root/amplify-common/modules/googlechat"
[ -d "$dir" ] || { echo "check-chat-transport: $dir not found" >&2; exit 2; }
files=$(find "$dir" -name '*.bal' -not -path '*/tests/*' | sort)
# Nothing to scan means the module moved or was renamed: say so, never print "ok" after looking at nothing.
[ -n "$files" ] || { echo "check-chat-transport: no .bal files under $dir" >&2; exit 2; }
bad=0
# Executable lines only: comments may talk about http:Client.
if grep -nE '^[^/]*(http:Client\b|new http:|ballerina/http\.client)' $files; then
  echo "check-chat-transport: googlechat must not create an http:Client (its spans would carry the webhook token as http.url)" >&2
  bad=1
fi
if grep -nE 'log:print' $files; then
  echo "check-chat-transport: googlechat must not log (the call target holds the webhook token)" >&2
  bad=1
fi
[ "$bad" -eq 0 ] && echo "check-chat-transport: ok"
exit "$bad"
