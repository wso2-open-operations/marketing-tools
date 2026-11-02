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

import ballerina/test;

final TokenAad ROW = {tokenId: "01890a5d-ac96-774b-bcce-b302099a8057", ownerId: "emp-1", provider: "linkedin"};
const string TOKEN = "AQV-linkedin-access-token-value";

function key(string id, int seed) returns TokenKey {
    byte[] k = [];
    foreach int i in 0 ..< KEY_BYTES {
        k.push(<byte>((i * 7 + seed) % 256));
    }
    return {keyId: id, key: k};
}

function cipher(string current = "k1") returns TokenCipher|error => new ([key("k1", 1), key("k2", 2)], current);

@test:Config
function testSealOpenRoundTrip() returns error? {
    TokenCipher c = check cipher();
    SealedToken sealed = check c.seal(TOKEN, ROW);
    test:assertEquals(sealed.nonce.length(), NONCE_BYTES);
    test:assertEquals(sealed.keyId, "k1");
    test:assertEquals(sealed.ciphertext.length(), TOKEN.length() + TAG_BITS / 8);
    test:assertEquals(check c.open(sealed, ROW), TOKEN);
}

@test:Config
function testNonceIsFreshEachTime() returns error? {
    TokenCipher c = check cipher();
    SealedToken a = check c.seal(TOKEN, ROW);
    SealedToken b = check c.seal(TOKEN, ROW);
    test:assertNotEquals(a.nonce, b.nonce);
    test:assertNotEquals(a.ciphertext, b.ciphertext);
}

@test:Config
function testCiphertextCopiedToAnotherRowFails() returns error? {
    TokenCipher c = check cipher();
    SealedToken sealed = check c.seal(TOKEN, ROW);
    foreach TokenAad other in [
        {tokenId: "01890a5d-ac96-774b-bcce-b302099a8058", ownerId: ROW.ownerId, provider: ROW.provider},
        {tokenId: ROW.tokenId, ownerId: "emp-2", provider: ROW.provider},
        {tokenId: ROW.tokenId, ownerId: ROW.ownerId, provider: "medium"}
    ] {
        string|error opened = c.open(sealed, other);
        test:assertTrue(opened is error, "AAD mismatch must fail");
    }
}

@test:Config
function testTamperedCiphertextOrNonceFails() returns error? {
    TokenCipher c = check cipher();
    SealedToken sealed = check c.seal(TOKEN, ROW);
    byte[] flipped = sealed.ciphertext.clone();
    flipped[0] = <byte>(flipped[0] ^ 1);
    string|error opened = c.open({ciphertext: flipped, nonce: sealed.nonce, keyId: sealed.keyId}, ROW);
    test:assertTrue(opened is error);
    if opened is error {
        test:assertFalse(opened.message().includes(TOKEN), "errors never carry the token");
    }
    byte[] nonce = sealed.nonce.clone();
    nonce[11] = <byte>(nonce[11] ^ 1);
    test:assertTrue(c.open({ciphertext: sealed.ciphertext, nonce, keyId: sealed.keyId}, ROW) is error);
}

@test:Config
function testKeyRotationOldRowsStillOpen() returns error? {
    SealedToken old = check (check cipher("k1")).seal(TOKEN, ROW);
    TokenCipher rotated = check cipher("k2");
    test:assertEquals(check rotated.open(old, ROW), TOKEN);
    test:assertTrue(rotated.needsRotation(old.keyId));
    SealedToken fresh = check rotated.seal(TOKEN, ROW);
    test:assertEquals(fresh.keyId, "k2");
    test:assertFalse(rotated.needsRotation(fresh.keyId));
    // A key id claimed by the row but holding the wrong key fails.
    test:assertTrue(rotated.open({ciphertext: old.ciphertext, nonce: old.nonce, keyId: "k2"}, ROW) is error);
}

@test:Config
function testKeyRingValidation() {
    TokenCipher|error short = new ([{keyId: "short", key: [1, 2, 3]}], "short");
    test:assertTrue(short is error);
    TokenCipher|error missing = new ([key("k1", 1)], "k9");
    test:assertTrue(missing is error);
    TokenCipher|error dup = new ([key("k1", 1), key("k1", 2)], "k1");
    test:assertTrue(dup is error);
    TokenKey|error bad = keyFromBase64("k", "bm90LTMyLWJ5dGVz");
    test:assertTrue(bad is error);
}

@test:Config
function testAadRejectsSeparator() returns error? {
    TokenCipher c = check cipher();
    test:assertTrue(c.seal(TOKEN, {tokenId: "a|b", ownerId: "c", provider: "linkedin"}) is error);
}

@test:Config
function testKeyFromBase64() returns error? {
    TokenKey k = key("k1", 1);
    TokenKey decoded = check keyFromBase64("k1", k.key.toBase64());
    test:assertEquals(decoded.key, k.key);
}

@test:Config
function testResealMovesOldRowToCurrentKey() returns error? {
    SealedToken old = check (check cipher("k1")).seal(TOKEN, ROW);
    TokenCipher rotated = check cipher("k2");
    test:assertEquals(rotated.activeKeyId(), "k2");
    SealedToken? fresh = check rotated.reseal(old, ROW);
    if fresh is () {
        test:assertFail("an old-key row must be re-sealed");
    }
    test:assertEquals(fresh.keyId, "k2");
    test:assertNotEquals(fresh.nonce, old.nonce, "re-seal uses a fresh nonce");
    test:assertEquals(check rotated.open(fresh, ROW), TOKEN);
    test:assertFalse(rotated.needsRotation(fresh.keyId));
}

@test:Config
function testResealLeavesCurrentKeyRowAlone() returns error? {
    TokenCipher c = check cipher("k1");
    SealedToken current = check c.seal(TOKEN, ROW);
    test:assertEquals(check c.reseal(current, ROW), ());
}

@test:Config
function testResealFailsClosedOnWrongRowOrUnknownKey() returns error? {
    SealedToken old = check (check cipher("k1")).seal(TOKEN, ROW);
    TokenCipher rotated = check cipher("k2");
    SealedToken|error? moved = rotated.reseal(old, {tokenId: ROW.tokenId, ownerId: "emp-2", provider: ROW.provider});
    test:assertTrue(moved is error, "a ciphertext from another row is never re-sealed");
    if moved is error {
        test:assertFalse(moved.message().includes(TOKEN));
    }
    TokenCipher onlyNew = check new ([key("k2", 2)], "k2");
    test:assertTrue(onlyNew.reseal(old, ROW) is error, "a retired key can't be re-sealed");
}

@test:Config
function testOpenRejectsUnknownKeyAndShortNonce() returns error? {
    TokenCipher c = check cipher();
    SealedToken sealed = check c.seal(TOKEN, ROW);
    test:assertTrue(c.open({ciphertext: sealed.ciphertext, nonce: sealed.nonce, keyId: "k9"}, ROW) is error);
    test:assertTrue(c.open({ciphertext: sealed.ciphertext, nonce: [1, 2, 3], keyId: "k1"}, ROW) is error);
    test:assertTrue(c.open({ciphertext: [1, 2], nonce: sealed.nonce, keyId: "k1"}, ROW) is error,
            "ciphertext shorter than the tag fails closed");
}

@test:Config
function testKeyRingRejectsBadIds() {
    byte[] k = key("x", 1).key;
    TokenCipher|error blank = new ([{keyId: "  ", key: k}], "  ");
    test:assertTrue(blank is error);
    string long = "";
    foreach int i in 0 ..< 65 {
        long += "a";
    }
    TokenCipher|error tooLong = new ([{keyId: long, key: k}], long);
    test:assertTrue(tooLong is error);
    test:assertTrue(keyFromBase64("k", "%%not-base64%%") is error);
}

@test:Config
function testAadRejectsBlankParts() returns error? {
    TokenCipher c = check cipher();
    test:assertTrue(c.seal(TOKEN, {tokenId: "", ownerId: "c", provider: "linkedin"}) is error);
    test:assertTrue(c.seal(TOKEN, {tokenId: "t", ownerId: "", provider: "linkedin"}) is error);
    test:assertTrue(c.seal(TOKEN, {tokenId: "t", ownerId: "c", provider: ""}) is error);
}
