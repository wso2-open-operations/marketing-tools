// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.


// Recognition lock order (round 2, item 11). Two transaction-scoped advisory locks guard recognition
// writes: the app-level `store:RECOGNITION_LOCK_KEY` (4242101, `store:lockRecognition`) and the SQL-level
// `store:RECOGNITION_SQL_LOCK_KEY` (1634561133, inside the V012 `recognition.*` functions). They must be
// taken in that order. The SQL key is only ever taken inside those functions, so the order holds when
// every Ballerina call of one of them is preceded, in the same function, by `lockRecognition`. This test
// reads the source of this package (and of amplify-api / amplify-jobs when they sit next to it) and fails
// on a call site that isn't. The database IT checks the other half: no SQL function takes 4242101.

import amplify_domain.store;

import ballerina/file;
import ballerina/io;
import ballerina/test;

const string LOCK_CALL = "lockRecognition(";

@test:Config
function testRecognitionLocksAreTakenInOrder() returns error? {
    test:assertNotEquals(store:RECOGNITION_LOCK_KEY, store:RECOGNITION_SQL_LOCK_KEY);
    string[] files = [];
    foreach string root in ["modules", "../amplify-api", "../amplify-jobs"] {
        if check file:test(root, file:EXISTS) {
            check collectBal(root, files);
        }
    }
    int callSites = 0;
    foreach string path in files {
        string src = stripComments(check io:fileReadString(path));
        foreach var span in re `recognition\.(apply_ledger_entry|rebuild|rerank)\s*\(`.findAll(src) {
            int at = span.startIndex;
            int fnStart = src.lastIndexOf("function ", at) ?: 0;
            int? lockAt = src.lastIndexOf(LOCK_CALL, at);
            boolean ordered = lockAt is int && lockAt > fnStart;
            test:assertTrue(ordered, string `${path}: a recognition.* call at offset ${at} isn't preceded by `
                + "store:lockRecognition in the same function (lock order: 4242101 before 1634561133)");
            callSites += 1;
        }
    }
    test:assertTrue(callSites >= 2, "found the ledger append and rebuild call sites");
}

# Blanks `//` comments (whole-line and trailing), whole-line `#` doc comments and double-quoted string
# literals, so a comment or a string that mentions `lockRecognition(` (or the `//` in a URL) can't satisfy
# or confuse the scan. Template literals are kept: the SQL calls the scan looks for live inside them. It is
# a text scan: a `//` or a call inside a template's `${...}` interpolation isn't seen, which can only make
# it miss a call, never invent one.
#
# + src - Ballerina source
# + return - The source with comment and string bytes blanked to spaces (line breaks kept)
function stripComments(string src) returns string {
    string[] docFree = from string line in re `\n`.split(src)
        select line.trim().startsWith("#") ? "" : line;
    int[] cps = string:'join("\n", ...docFree).toCodePointInts();
    int[] out = [];
    boolean inDouble = false;
    boolean inTemplate = false;
    boolean inComment = false;
    int i = 0;
    while i < cps.length() {
        int c = cps[i];
        if inComment {
            inComment = c != 10;
            out.push(inComment ? 32 : c);
        } else if inDouble || inTemplate {
            boolean quoted = inDouble;
            if c == 92 && i + 1 < cps.length() {
                out.push(quoted ? 32 : c);
                out.push(quoted ? 32 : cps[i + 1]);
                i += 2;
                continue;
            }
            inDouble = inDouble && c != 34;
            inTemplate = inTemplate && c != 96;
            out.push(quoted ? 32 : c);
        } else if c == 47 && i + 1 < cps.length() && cps[i + 1] == 47 {
            inComment = true;
            out.push(32);
            out.push(32);
            i += 2;
            continue;
        } else {
            inDouble = c == 34;
            inTemplate = c == 96;
            out.push(c);
        }
        i += 1;
    }
    return checkpanic string:fromCodePointInts(out);
}

@test:Config
function testLockOrderScanIgnoresComments() {
    string src = stripComments("// see lockRecognition( below\nisolated function bad() {\n"
        + "  _ = db->queryRow(`SELECT recognition.rebuild(3)`);\n}\n");
    int at = <int>src.indexOf("recognition.rebuild(");
    int fnStart = src.lastIndexOf("function ", at) ?: 0;
    int? lockAt = src.lastIndexOf(LOCK_CALL, at);
    test:assertFalse(lockAt is int && lockAt > fnStart, "a comment naming the lock call doesn't count as taking it");
}

@test:Config
function testLockOrderScanIgnoresTrailingComments() {
    string src = stripComments("isolated function bad() {\n"
        + "  _ = db->queryRow(`SELECT recognition.rebuild(3)`); // lockRecognition( is called elsewhere\n}\n");
    int at = <int>src.indexOf("recognition.rebuild(");
    int fnStart = src.lastIndexOf("function ", at) ?: 0;
    int? lockAt = src.lastIndexOf(LOCK_CALL, at);
    test:assertFalse(lockAt is int && lockAt > fnStart, "a trailing `//` comment naming the lock call doesn't count");
}

@test:Config
function testLockOrderScanIgnoresStringLiterals() {
    string src = stripComments("isolated function bad() {\n"
        + "  string url = \"https://example.com/lockRecognition(\";\n"
        + "  _ = db->queryRow(`SELECT recognition.rebuild(3)`);\n}\n");
    int at = <int>src.indexOf("recognition.rebuild(");
    int fnStart = src.lastIndexOf("function ", at) ?: 0;
    int? lockAt = src.lastIndexOf(LOCK_CALL, at);
    test:assertFalse(lockAt is int && lockAt > fnStart,
        "a string literal naming the lock call (and the `//` in a URL) doesn't count");
}

@test:Config
function testLockOrderScanFindsTheCallInsideATemplate() {
    string src = stripComments("isolated function ok() {\n  check store:lockRecognition(db);\n"
        + "  _ = db->queryRow(`SELECT recognition.rebuild(3)`);\n}\n");
    int at = <int>src.indexOf("recognition.rebuild(");
    int fnStart = src.lastIndexOf("function ", at) ?: 0;
    int? lockAt = src.lastIndexOf(LOCK_CALL, at);
    test:assertTrue(at > 0, "the SQL template is still scanned");
    test:assertTrue(lockAt is int && lockAt > fnStart, "a real call inside a template is found and ordered");
}

@test:Config
function testLockOrderScanCatchesAReversedCall() {
    string reversed = "isolated function bad() {\n  _ = db->queryRow(`SELECT recognition.rebuild(3)`);\n"
        + "  check store:lockRecognition(db);\n}\n";
    int at = <int>reversed.indexOf("recognition.rebuild(");
    int fnStart = reversed.lastIndexOf("function ", at) ?: 0;
    int? lockAt = reversed.lastIndexOf(LOCK_CALL, at);
    test:assertFalse(lockAt is int && lockAt > fnStart, "a lock taken after the SQL call is reported");
}

function collectBal(string dir, string[] out) returns error? {
    foreach file:MetaData m in check file:readDir(dir) {
        string name = check file:basename(m.absPath);
        if m.dir {
            if name != "target" && name != "tests" {
                check collectBal(m.absPath, out);
            }
        } else if name.endsWith(".bal") {
            out.push(m.absPath);
        }
    }
}
