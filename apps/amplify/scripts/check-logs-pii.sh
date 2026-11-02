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

# Log hygiene check (plan M9): no PII, tokens or commentary in logs. Scans every `log:print*` call in the
# Ballerina sources (tests and build output excluded), joining multi-line calls, and fails when a call
# passes a sensitive value as a key-value field (`email = ...`) or interpolates one into the message
# (`${p.email}`). A reviewed exception carries `// log-pii: ok <why>` on the call's first line.
#
# Usage: scripts/check-logs-pii.sh [root]   scripts/check-logs-pii.sh --self-test
#        (default root: the folder above this script)
set -euo pipefail

# Field names and identifiers that hold PII, credentials or member content.
sensitive='email|e_mail|displayName|display_name|fullName|name|givenName|familyName|phone|sub|memberUrn|member_urn|token|accessToken|access_token|refreshToken|bearer|idToken|jwt|assertion|authorization|password|passwd|secret|clientSecret|client_secret|apiKey|webhookUrl|webhook_url|commentary|comment|body|payload|code|state|nonce|cookie'

scan() {
  local root="$1" files
  files=$(find "$root" -name '*.bal' -not -path '*/target/*' -not -path '*/tests/*' -not -path '*/node_modules/*' | sort)
  [ -n "$files" ] || { echo "check-logs-pii: no .bal files under $root" >&2; return 2; }
# shellcheck disable=SC2086
perl -e '
    my $sensitive = shift @ARGV;
    my $bad = 0; my $calls = 0;
    for my $file (@ARGV) {
        open(my $fh, "<", $file) or die "$file: $!";
        my @lines = <$fh>; close $fh;
        for (my $i = 0; $i < @lines; $i++) {
            next unless $lines[$i] =~ /\blog:print(Info|Warn|Error|Debug)\s*\(/;
            # A trailing `//` comment is not code: dropped (outside string literals) before the call is joined, so a
            # bracket in it cannot close the call early and a word in it is not mistaken for a field.
            my $nocomment = sub { my $s = shift; $s =~ s{("(?:[^"\\]|\\.)*"|`[^`]*`)|//[^\n]*}{defined $1 ? $1 : ""}ge; return $s; };
            my $start = $i; my $call = $nocomment->($lines[$i]);
            # Brackets inside string literals ("user )") are not call brackets.
            my $code = sub { my $s = shift; $s =~ s/"(?:[^"\\]|\\.)*"//g; $s =~ s/`[^`]*`//g; return $s; };
            my $depth = () = $code->($call) =~ /\(/g; $depth -= () = $code->($call) =~ /\)/g;
            while ($depth > 0 && $i + 1 < @lines) {
                $i++; my $more = $nocomment->($lines[$i]); $call .= $more;
                $depth += () = $code->($more) =~ /\(/g; $depth -= () = $code->($more) =~ /\)/g;
            }
            $calls++;
            next if $lines[$start] =~ m{//\s*log-pii:\s*ok};
            my @hits;
            # Key-value fields: `email = x`, `\x27token = x` (not `==`).
            while ($call =~ /[,(]\s*\x27?($sensitive)\s*=(?!=)/gi) { push @hits, "field \x27$1\x27"; }
            # A sensitive value passed as the message itself: `log:printInfo(email)`, `log:printWarn(p.email)`.
            if ($call =~ /\blog:print\w+\s*\(\s*(?:[A-Za-z_][A-Za-z0-9_]*\.)*($sensitive)\s*[,)]/i) { push @hits, "message \x27$1\x27"; }
            # Interpolations: `${p.email}`, `${token}`, `${body.commentary}`.
            while ($call =~ /\$\{([^}]*)\}/g) {
                my $expr = $1;
                for my $part (split /[^A-Za-z0-9_]+/, $expr) {
                    push @hits, "interpolates \x27$expr\x27" if $part =~ /^($sensitive)$/i;
                }
            }
            if (@hits) {
                $bad++;
                my %seen; my @u = grep { !$seen{$_}++ } @hits;
                printf "%s:%d: %s\n", $file, $start + 1, join(", ", @u);
            }
        }
    }
    printf "check-logs-pii: %d log call(s) scanned, %d flagged\n", $calls, $bad;
    exit($bad ? 1 : 0);
' "$sensitive" $files
}

# The scanner's whole job is to say "clean" only when it really looked, so each bypass a reviewer found
# by reading it is a case here.
if [ "${1:-}" = "--self-test" ]; then
  TMPDIR_SELF=$(mktemp -d)
  trap 'rm -rf "$TMPDIR_SELF"' EXIT
  fx="$TMPDIR_SELF/fx"; mkdir -p "$fx"

  write() { printf '%s\n' "$2" > "$fx/$1.bal"; }

  write ok 'public function f() { log:printInfo("amplify run finished"); }'
  write ok2 'public function g(string email) { log:printInfo("user email sent"); }'
  write exc 'public function h(string email) { log:printInfo(email); } // log-pii: ok a test fixture, not a real address'
  if ! scan "$fx" >/dev/null; then echo "self-test: a clean call, or a reviewed exception, was flagged"; exit 1; fi
  # The same call without the marker must be flagged, or the exception above proves nothing.
  write nomark 'public function h(string email) { log:printInfo(email); }'
  if scan "$fx" >/dev/null; then echo "self-test: the exception fixture passes without its marker"; exit 1; fi
  rm "$fx/nomark.bal"

  write field 'public function f() { log:printInfo("x", email = e); }'
  if scan "$fx" >/dev/null; then echo "self-test: a sensitive key-value field passed"; exit 1; fi
  rm "$fx/field.bal"

  write msg 'public function f(string email) { log:printInfo(email); }'
  if scan "$fx" >/dev/null; then echo "self-test: a sensitive message expression passed"; exit 1; fi
  rm "$fx/msg.bal"

  write interp 'public function f(P p) { log:printWarn(`seen ${p.email}`); }'
  if scan "$fx" >/dev/null; then echo "self-test: a sensitive interpolation passed"; exit 1; fi
  rm "$fx/interp.bal"

  # A `)` inside the message must not close the call early and hide the field on the next line.
  cat > "$fx/bracket.bal" <<'BAL'
public function f(P user) {
    log:printInfo("user )",
        email = user.email);
}
BAL
  if scan "$fx" >/dev/null; then echo "self-test: a parenthesis inside a string hid a later field"; exit 1; fi
  rm "$fx/bracket.bal"

  # A `)` in a trailing comment must not close the call early and hide the field on the next line.
  cat > "$fx/comment.bal" <<'BAL'
public function f(P user) {
    log:printInfo("x", // done )
        email = user.email);
}
BAL
  if scan "$fx" >/dev/null; then echo "self-test: a parenthesis inside a comment hid a later field"; exit 1; fi
  rm "$fx/comment.bal"

  echo "check-logs-pii self-test passed."
  exit 0
fi

root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
scan "$root"
