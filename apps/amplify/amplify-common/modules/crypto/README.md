# amplify_common.crypto

Token encryption and constant-time comparison. No database access: callers store the sealed values in `connection.provider_token`.

## Token cipher

Files: `modules/crypto/token_cipher.bal`, `modules/crypto/gcm.bal`.

- `TokenCipher` is an isolated class built from a key ring (`TokenKey[]`) and the current key id.
  - `seal(plaintext, aad)` returns a `SealedToken` (`ciphertext` with the tag appended, 96-bit random `nonce`, `keyId`).
  - `open(sealed, aad)` decrypts. It fails if the row identity, nonce, key or ciphertext does not match.
  - `needsRotation(keyId)`, `activeKeyId()`.
  - `reseal(sealed, aad)` decrypts with the old key and seals with the current one and a fresh nonce. It returns `()` when the row already uses the current key.
- `TokenAad` binds the ciphertext to its row: `tokenId`, `ownerId`, `provider` (the `connection.provider_token` columns `token_id`, `owner_id`, `provider`).
- `keyFromBase64(keyId, base64Key)` builds a `TokenKey` from a config secret (32 raw bytes).
- Constants: `KEY_BYTES` (32), `NONCE_BYTES` (12), `TAG_BITS` (128).
- `gcm.bal` calls `javax.crypto` (`AES/GCM/NoPadding`) through Ballerina Java interop. Arrays cross the boundary as base64. Its functions are private.
- Errors never contain token material.

## Constant-time compare

File: `modules/crypto/compare.bal`. `constantTimeEquals(a, b)` takes the same time wherever the strings first differ. Only the lengths are visible.

## Depends on

Nothing in this package. Uses `ballerina/jballerina.java` and `ballerina/lang.array`.

## Does not do

- No key storage or key generation. Keys come from config.
- No database reads or writes. Re-sealing stale rows is `connection:resealToken` and `resealStaleTokens` in `amplify_domain`.
- No password hashing or signing.

## Tests

`modules/crypto/tests/token_cipher_test.bal`, `modules/crypto/tests/compare_test.bal`. Run `bal test` from `amplify-common`.
