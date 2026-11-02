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

// Provider token encryption at rest (phase1-data-model › connection, "Token encryption").
// AES-256-GCM with our key, a fresh random 96-bit nonce per encryption, and
// AAD = `token_id|owner_id|provider`, so a ciphertext copied onto another row fails to decrypt.
// `ballerina/crypto` has no AAD parameter, so GCM runs through the JDK's javax.crypto.Cipher (interop).
// Plaintext never leaves this module except as the return of `open`; errors never carry it.

import ballerina/lang.array;

# Key length for AES-256, in bytes.
public const int KEY_BYTES = 32;
# GCM nonce length, in bytes (96 bits).
public const int NONCE_BYTES = 12;
# GCM tag length, in bits.
public const int TAG_BITS = 128;

# One encryption key. Rotation adds a key with a new `keyId`; old keys stay until the last partition
# holding them is dropped.
public type TokenKey record {|
    # Stored with each row (`provider_token.key_id`)
    string keyId;
    # 32 raw bytes
    byte[] key;
|};

# The row identity the ciphertext is bound to.
public type TokenAad record {|
    # `provider_token.token_id`
    string tokenId;
    # `provider_token.owner_id` (employee id or org URN)
    string ownerId;
    # `provider_token.provider`
    string provider;
|};

# What goes into `provider_token`.
public type SealedToken record {|
    # Ciphertext with the GCM tag appended
    byte[] ciphertext;
    # 96-bit nonce
    byte[] nonce;
    # Key used
    string keyId;
|};

# Encrypts and decrypts provider tokens with a key ring.
public isolated class TokenCipher {
    private final map<byte[] & readonly> & readonly keys;
    private final string currentKeyId;

    # Builds the cipher.
    #
    # + keys - Every key that may still be referenced by a stored row
    # + currentKeyId - Key used for new encryptions
    # + return - An error if a key isn't 32 bytes, ids repeat, or the current key is missing
    public isolated function init(TokenKey[] keys, string currentKeyId) returns error? {
        map<byte[] & readonly> ring = {};
        foreach TokenKey k in keys {
            if k.keyId.trim().length() == 0 || k.keyId.length() > 64 {
                return error("Token key id must be 1-64 characters");
            }
            if k.key.length() != KEY_BYTES {
                return error(string `Token key ${k.keyId} must be ${KEY_BYTES} bytes`);
            }
            if ring.hasKey(k.keyId) {
                return error(string `Token key ${k.keyId} is listed twice`);
            }
            ring[k.keyId] = k.key.cloneReadOnly();
        }
        if !ring.hasKey(currentKeyId) {
            return error(string `Current token key ${currentKeyId} is not in the key ring`);
        }
        self.keys = ring.cloneReadOnly();
        self.currentKeyId = currentKeyId;
    }

    # Encrypts a token with the current key and a fresh nonce.
    #
    # + plaintext - Bearer token
    # + aad - Row identity
    # + return - Ciphertext, nonce and key id, or an error
    public isolated function seal(string plaintext, TokenAad aad) returns SealedToken|error {
        byte[] & readonly key = <byte[] & readonly>self.keys[self.currentKeyId];
        byte[] nonce = check randomNonce();
        byte[] ciphertext = check gcm(ENCRYPT_MODE, key, nonce, check aadBytes(aad), plaintext.toBytes());
        return {ciphertext, nonce, keyId: self.currentKeyId};
    }

    # Decrypts a stored token. Fails if the row identity, nonce, key or ciphertext doesn't match.
    #
    # + sealed - Stored values
    # + aad - Row identity the token was sealed for
    # + return - The bearer token, or an error (never containing token material)
    public isolated function open(SealedToken sealed, TokenAad aad) returns string|error {
        (byte[] & readonly)? key = self.keys[sealed.keyId];
        if key is () {
            return error(string `Token key ${sealed.keyId} is not in the key ring`);
        }
        if sealed.nonce.length() != NONCE_BYTES {
            return error("Token nonce must be 96 bits");
        }
        byte[]|error plain = gcm(DECRYPT_MODE, key, sealed.nonce, check aadBytes(aad), sealed.ciphertext);
        if plain is error {
            return error("Token decryption failed: wrong key, row or tampered data");
        }
        return string:fromBytes(plain);
    }

    # Whether a row should be re-encrypted on next use (written with an older key).
    #
    # + keyId - Row's key id
    # + return - True when it isn't the current key
    public isolated function needsRotation(string keyId) returns boolean => keyId != self.currentKeyId;

    # Key id that `seal` uses now. A maintenance pass selects rows `WHERE key_id <> activeKeyId()`.
    #
    # + return - Current key id
    public isolated function activeKeyId() returns string => self.currentKeyId;

    # Re-encrypts a row written under an older key with the current key and a fresh nonce (key rotation:
    # decrypt with the old key, seal with the new one). The plaintext never leaves this method.
    # The row identity stays the same, so the caller updates `ciphertext`, `nonce` and `key_id` in place.
    #
    # + sealed - Stored values
    # + aad - Row identity the token was sealed for
    # + return - The re-sealed values, `()` when the row already uses the current key, or an error if the
    # stored values don't open (never containing token material)
    public isolated function reseal(SealedToken sealed, TokenAad aad) returns SealedToken|error? {
        if !self.needsRotation(sealed.keyId) {
            return ();
        }
        string plaintext = check self.open(sealed, aad);
        return self.seal(plaintext, aad);
    }
}

# Decodes a base64 key from config (Choreo secret).
#
# + keyId - Key id
# + base64Key - Standard base64 of 32 bytes
# + return - The key, or an error
public isolated function keyFromBase64(string keyId, string base64Key) returns TokenKey|error {
    byte[]|error key = array:fromBase64(base64Key.trim());
    if key is error || key.length() != KEY_BYTES {
        return error(string `Token key ${keyId} must be base64 of ${KEY_BYTES} bytes`);
    }
    return {keyId, key};
}

# AAD bytes: `token_id|owner_id|provider`. Parts can't contain `|`, so the encoding is unambiguous.
#
# + aad - Row identity
# + return - UTF-8 bytes, or an error for a blank part or one holding `|`
isolated function aadBytes(TokenAad aad) returns byte[]|error {
    foreach string part in [aad.tokenId, aad.ownerId, aad.provider] {
        if part.length() == 0 || part.includes("|") {
            return error("Token AAD parts must be non-blank and must not contain '|'");
        }
    }
    return string `${aad.tokenId}|${aad.ownerId}|${aad.provider}`.toBytes();
}

# 96 random bits from `java.security.SecureRandom`. Random-nonce GCM must stay under 2^32 seals per key
# (NIST SP 800-38D 8.3); far above Amplify's volume, and the reason `reseal` and key rotation exist.
#
# + return - 12 random bytes
isolated function randomNonce() returns byte[]|error => secureRandomBytes(NONCE_BYTES);
