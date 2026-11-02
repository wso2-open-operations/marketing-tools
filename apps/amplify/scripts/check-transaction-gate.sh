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

# Transaction gate check (round 2 item 12, R-13: docs/reviews/2026-10-17-r13-transaction-race.md). On
# Ballerina 2201.13.x concurrent `transaction` blocks race inside the runtime (ballerina-lang #44737), so
# every product transaction runs under the one process-wide gate in amplify_domain.store (`inTransaction`
# / `inTransactionValue`). Convention this script enforces, over amplify-domain, amplify-api and
# amplify-jobs (tests and build output excluded):
#   1. every `transaction {` sits in a non-public function whose name ends in `Tx`;
#   2. every call of a `...Tx(` function that holds a transaction is on a line that calls `inTransaction`
#      (so the only way into the block is through the gate);
#   3. no `retry ... transaction` anywhere (it made the race ~15x worse on 13.x).
# Remove this script together with `store:inTransaction` after the upgrade to 2201.14.1+.
#
# Usage: scripts/check-transaction-gate.sh [root]     scripts/check-transaction-gate.sh --self-test
set -euo pipefail

scan() {
  local root="$1"
  local files
  files=$(find "$root"/amplify-domain "$root"/amplify-api "$root"/amplify-jobs -name '*.bal' \
            -not -path '*/target/*' -not -path '*/tests/*' 2>/dev/null | sort)
  [ -n "$files" ] || { echo "no Ballerina sources under $root"; return 1; }
  # Pass 1: functions that contain a transaction block, and rule 1 / rule 3 violations.
  # shellcheck disable=SC2086
  awk '
    /^[[:space:]]*(\/\/|#)/ { next }
    match($0, /function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(/) {
      fn = substr($0, RSTART, RLENGTH); sub(/^function[[:space:]]+/, "", fn); sub(/[[:space:]]*\($/, "", fn)
      fnline = $0; fnfile = FILENAME
    }
    /retry[^;]*transaction/ { printf "%s:%d: retry transaction is not allowed (R-13)\n", FILENAME, FNR; bad = 1 }
    /(^|[^A-Za-z0-9_])transaction[[:space:]]*\{/ {
      if (fnfile != FILENAME || fn !~ /Tx$/ || fnline ~ /public/) {
        printf "%s:%d: transaction block outside a non-public ...Tx function (got %s)\n", FILENAME, FNR, fn; bad = 1
      } else { print "TXFN " fn > "/dev/stderr" }
    }
    END { exit bad }
  ' $files 2> "$tmp/txfns" || rc=1
  local names
  names=$(awk '/^TXFN /{print $2}' "$tmp/txfns" | sort -u | paste -sd'|' -)
  [ -n "$names" ] || { [ "${rc:-0}" -eq 0 ] && echo "no transaction blocks found"; return "${rc:-0}"; }
  # Pass 2: every call of one of those functions runs inside the gate's callback.
  # "Inside" is decided by parenthesis nesting, not by the line mentioning the gate: on
  # `check store:inTransaction(() => saveTx(v)); check saveTx(v);` the second call is outside the
  # callback and used to pass because the line contained `inTransaction(`. String literals are blanked
  # first so a `)` or a `saveTx(` inside one cannot open or close a region, and the region may span
  # lines (`store:inTransaction(` followed by the callback on the next line).
  # shellcheck disable=SC2086
  awk -v names="$names" '
    # Replace string-literal contents with spaces, keeping the length so offsets line up.
    function blank_strings(s,   out, i, n, c, q) {
      out = ""; i = 1; n = length(s); q = ""
      while (i <= n) {
        c = substr(s, i, 1)
        if (q == "") {
          # A trailing `//` comment is not code: blank the rest of the line so a bracket in it cannot move the gate.
          if (c == "/" && substr(s, i + 1, 1) == "/") { while (i <= n) { out = out " "; i++ } break }
          if (c == "\"" || c == "`") { q = c; out = out " " }
          else out = out c
          i++; continue
        }
        if (c == "\\") { out = out "  "; i += 2; continue }
        if (c == q) { q = ""; out = out " " } else out = out " "
        i++
      }
      return out
    }

    # Mark every character that sits inside an inTransaction( / inTransactionValue( call.
    # depth/top/stack carry across lines: a gate callback may start on the next line.
    function mark_gates(s,   i, n, c, j, k, word, prev) {
      n = length(s)
      for (i = 1; i <= n; i++) inside[i] = 0
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "(") {
          j = i - 1
          while (j >= 1 && substr(s, j, 1) == " ") j--
          k = j
          while (k >= 1 && substr(s, k, 1) ~ /[A-Za-z0-9_]/) k--
          word = substr(s, k + 1, j - k)
          prev = (k >= 1) ? substr(s, k, 1) : ""
          depth++
          if ((word == "inTransaction" || word == "inTransactionValue") && prev !~ /[A-Za-z0-9_]/) {
            top++; stack[top] = depth
          }
        } else if (c == ")") {
          if (top > 0 && stack[top] == depth) top--
          depth--
          if (depth < 0) depth = 0
        }
        inside[i] = (top > 0) ? 1 : 0
      }
    }

    FNR == 1 { depth = 0; top = 0 }
    /^[[:space:]]*(\/\/|#)/ { next }
    {
      s = blank_strings($0)
      mark_gates(s)
      if (s ~ ("function[[:space:]]+(" names ")[[:space:]]*\\(")) next
      rest = s; off = 0
      while (match(rest, "(^|[^A-Za-z0-9_])(" names ")[[:space:]]*\\(")) {
        hit = substr(rest, RSTART, RLENGTH)
        lead = (substr(hit, 1, 1) ~ /[A-Za-z0-9_]/) ? 0 : 1
        pos = off + RSTART + lead
        if (inside[pos] != 1) {
          name = hit; sub(/^[^A-Za-z0-9_]/, "", name); sub(/[[:space:]]*\($/, "", name)
          printf "%s:%d: %s called outside store:inTransaction\n", FILENAME, FNR, name; bad = 1
        }
        rest = substr(rest, RSTART + RLENGTH); off = off + RSTART + RLENGTH - 1
      }
    }
    END { exit bad }
  ' $files || rc=1
  return "${rc:-0}"
}

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

if [ "${1:-}" = "--self-test" ]; then
  fx="$tmp/fx"; mkdir -p "$fx/amplify-domain" "$fx/amplify-api" "$fx/amplify-jobs"
  cat > "$fx/amplify-domain/ok.bal" <<'BAL'
public isolated function save(int v) returns error? => store:inTransaction(() => saveTx(v));
isolated function saveTx(int v) returns error? {
    transaction {
        check commit;
    }
}
BAL
  ( scan "$fx" >/dev/null ) || { echo "self-test: a gated transaction was rejected"; exit 1; }
  cat > "$fx/amplify-api/bad1.bal" <<'BAL'
isolated function direct() returns error? {
    transaction {
        check commit;
    }
}
BAL
  ( scan "$fx" >/dev/null ) && { echo "self-test: a transaction outside a Tx function passed"; exit 1; }
  rm "$fx/amplify-api/bad1.bal"
  cat > "$fx/amplify-jobs/bad2.bal" <<'BAL'
isolated function bypass() returns error? => saveTx(1);
BAL
  ( scan "$fx" >/dev/null ) && { echo "self-test: an ungated Tx call passed"; exit 1; }
  rm "$fx/amplify-jobs/bad2.bal"
  cat > "$fx/amplify-jobs/bad3.bal" <<'BAL'
isolated function againTx() returns error? {
    retry transaction {
        check commit;
    }
}
BAL
  ( scan "$fx" >/dev/null ) && { echo "self-test: retry transaction passed"; exit 1; }
  rm "$fx/amplify-jobs/bad3.bal"
  # The gate has to enclose the call, not merely share its line.
  cat > "$fx/amplify-jobs/bad4.bal" <<'BAL'
isolated function sameLine() returns error? {
    check store:inTransaction(() => saveTx(1)); check saveTx(2);
}
BAL
  ( scan "$fx" >/dev/null ) && { echo "self-test: a call beside the gate on the same line passed"; exit 1; }
  rm "$fx/amplify-jobs/bad4.bal"
  cat > "$fx/amplify-jobs/bad5.bal" <<'BAL'
isolated function nested() returns error? {
    check someOtherWrapper(() => saveTx(1));
}
BAL
  ( scan "$fx" >/dev/null ) && { echo "self-test: a call inside a non-gate callback passed"; exit 1; }
  rm "$fx/amplify-jobs/bad5.bal"
  # A `)` or a call inside a string literal must not open or close a region, and a
  # callback may start on the line after the gate.
  cat > "$fx/amplify-jobs/ok2.bal" <<'BAL'
isolated function strings() returns error? {
    log:printInfo("saveTx(1) )");
    check store:inTransaction(
        () => saveTx(2));
}
BAL
  ( scan "$fx" >/dev/null ) || { echo "self-test: a next-line callback or a string literal was rejected"; exit 1; }
  rm "$fx/amplify-jobs/ok2.bal"
  # An unbalanced `(` in a trailing comment must not leave the gate open for the ungated call after it.
  cat > "$fx/amplify-jobs/bad6.bal" <<'BAL'
isolated function commented() returns error? {
    check store:inTransaction(
        () => saveTx(1)); // retry (up to 3
    check saveTx(2);
}
BAL
  ( scan "$fx" >/dev/null ) && { echo "self-test: a bracket in a comment kept the gate open"; exit 1; }
  rm "$fx/amplify-jobs/bad6.bal"
  echo "Transaction gate check self-test passed."
  exit 0
fi

root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
if scan "$root"; then
  n=$(grep -c '^TXFN ' "$tmp/txfns" || true)
  echo "Transaction gate: all $n transaction blocks run through store:inTransaction."
else
  echo "Transaction gate check FAILED (R-13): route the block through store:inTransaction."
  exit 1
fi
