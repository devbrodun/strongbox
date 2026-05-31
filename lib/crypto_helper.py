#!/usr/bin/env python3
"""
lib/crypto_helper.py — Python-based cryptographic helper for AES-256-GCM.
Used because standard OpenSSL CLI `enc` does not support GCM (AEAD) modes natively.
"""
import sys
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

def encrypt(key_hex, nonce_hex, plaintext_hex):
    try:
        key = bytes.fromhex(key_hex)
        nonce = bytes.fromhex(nonce_hex)
        plaintext = bytes.fromhex(plaintext_hex)
        aesgcm = AESGCM(key)
        # The cryptography library appends the 16-byte tag to the ciphertext automatically.
        ct_with_tag = aesgcm.encrypt(nonce, plaintext, None)
        print(ct_with_tag.hex())
    except Exception as e:
        print(f"Error encrypting: {e}", file=sys.stderr)
        sys.exit(1)

def decrypt(key_hex, nonce_hex, tag_hex, ct_hex):
    try:
        key = bytes.fromhex(key_hex)
        nonce = bytes.fromhex(nonce_hex)
        tag = bytes.fromhex(tag_hex)
        ct = bytes.fromhex(ct_hex)
        aesgcm = AESGCM(key)
        # The cryptography library expects the tag to be appended to the ciphertext.
        plaintext = aesgcm.decrypt(nonce, ct + tag, None)
        print(plaintext.hex())
    except Exception as e:
        print(f"Error decrypting: {e}", file=sys.stderr)
        sys.exit(1)

def main():
    if len(sys.argv) < 2:
        print("Usage: crypto_helper.py <encrypt|decrypt> ...", file=sys.stderr)
        sys.exit(1)
    
    op = sys.argv[1]
    if op == "encrypt":
        if len(sys.argv) < 5:
            sys.exit(1)
        encrypt(sys.argv[2], sys.argv[3], sys.argv[4])
    elif op == "decrypt":
        if len(sys.argv) < 6:
            sys.exit(1)
        decrypt(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
    else:
        print(f"Unknown operation: {op}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
