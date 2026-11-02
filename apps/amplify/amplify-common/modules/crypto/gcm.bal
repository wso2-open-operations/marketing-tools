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

// AES/GCM/NoPadding with AAD through the JDK (javax.crypto). Ballerina byte[] can't bind to Java byte[]
// directly, so arrays cross the boundary as base64 through java.util.Base64 (tokens are a few hundred bytes).

import ballerina/jballerina.java;
import ballerina/lang.array;

const int ENCRYPT_MODE = 1;
const int DECRYPT_MODE = 2;
const string TRANSFORMATION = "AES/GCM/NoPadding";

# Runs one AES-GCM operation.
#
# + mode - `ENCRYPT_MODE` or `DECRYPT_MODE`
# + key - 32-byte key
# + nonce - 12-byte nonce
# + aad - Additional authenticated data
# + input - Plaintext or ciphertext+tag
# + return - Output bytes, or an error (bad tag on decrypt)
isolated function gcm(int mode, byte[] key, byte[] nonce, byte[] aad, byte[] input) returns byte[]|error {
    handle cipher = check cipherGetInstance(java:fromString(TRANSFORMATION));
    check cipherInit(cipher, mode, newSecretKeySpec(toJava(key), java:fromString("AES")),
            newGcmParameterSpec(TAG_BITS, toJava(nonce)));
    cipherUpdateAad(cipher, toJava(aad));
    return fromJava(check cipherDoFinal(cipher, toJava(input)));
}

# Random bytes straight from `java.security.SecureRandom` (the JDK's cryptographically strong generator).
#
# + length - Number of bytes
# + return - The bytes, or an error crossing the Java boundary
isolated function secureRandomBytes(int length) returns byte[]|error {
    byte[] zeros = [];
    foreach int i in 0 ..< length {
        zeros.push(0);
    }
    handle buffer = toJava(zeros);
    secureRandomNextBytes(newSecureRandom(), buffer);
    return fromJava(buffer);
}

isolated function toJava(byte[] bytes) returns handle =>
    base64Decode(base64Decoder(), java:fromString(bytes.toBase64()));

isolated function fromJava(handle bytes) returns byte[]|error =>
    array:fromBase64(java:toString(base64Encode(base64Encoder(), bytes)) ?: "");

isolated function cipherGetInstance(handle transformation) returns handle|error = @java:Method {
    'class: "javax.crypto.Cipher",
    name: "getInstance",
    paramTypes: ["java.lang.String"]
} external;

isolated function cipherInit(handle cipher, int mode, handle key, handle spec) returns error? = @java:Method {
    'class: "javax.crypto.Cipher",
    name: "init",
    paramTypes: ["int", "java.security.Key", "java.security.spec.AlgorithmParameterSpec"]
} external;

isolated function cipherUpdateAad(handle cipher, handle aad) = @java:Method {
    'class: "javax.crypto.Cipher",
    name: "updateAAD",
    paramTypes: [{'class: "byte", dimensions: 1}]
} external;

isolated function cipherDoFinal(handle cipher, handle input) returns handle|error = @java:Method {
    'class: "javax.crypto.Cipher",
    name: "doFinal",
    paramTypes: [{'class: "byte", dimensions: 1}]
} external;

isolated function newSecretKeySpec(handle key, handle algorithm) returns handle = @java:Constructor {
    'class: "javax.crypto.spec.SecretKeySpec",
    paramTypes: [{'class: "byte", dimensions: 1}, "java.lang.String"]
} external;

isolated function newGcmParameterSpec(int tagBits, handle nonce) returns handle = @java:Constructor {
    'class: "javax.crypto.spec.GCMParameterSpec",
    paramTypes: ["int", {'class: "byte", dimensions: 1}]
} external;

isolated function newSecureRandom() returns handle = @java:Constructor {
    'class: "java.security.SecureRandom"
} external;

isolated function secureRandomNextBytes(handle random, handle buffer) = @java:Method {
    'class: "java.security.SecureRandom",
    name: "nextBytes",
    paramTypes: [{'class: "byte", dimensions: 1}]
} external;

isolated function base64Decoder() returns handle = @java:Method {
    'class: "java.util.Base64",
    name: "getDecoder"
} external;

isolated function base64Encoder() returns handle = @java:Method {
    'class: "java.util.Base64",
    name: "getEncoder"
} external;

isolated function base64Decode(handle decoder, handle text) returns handle = @java:Method {
    'class: "java.util.Base64$Decoder",
    name: "decode",
    paramTypes: ["java.lang.String"]
} external;

isolated function base64Encode(handle encoder, handle bytes) returns handle = @java:Method {
    'class: "java.util.Base64$Encoder",
    name: "encodeToString",
    paramTypes: [{'class: "byte", dimensions: 1}]
} external;
