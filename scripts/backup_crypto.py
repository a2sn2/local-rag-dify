"""
Stage E.1 Authenticated Encryption Engine (AES-256-GCM)
Provides:
  - AES-256-GCM AEAD encryption and decryption
  - Key derivation via PBKDF2-HMAC-SHA256 (100,000 iterations)
  - Cryptographic tamper detection (InvalidTag on single-bit modification)
  - External key management (CLI, Env Var, Keyfile; zero hardcoded passwords)
Author: a2sn2
Date: 2026-11-01
"""

import os
import sys
import argparse
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
from cryptography.hazmat.primitives import hashes
from cryptography.exceptions import InvalidTag

MAGIC_HEADER = b"RAGGCM2"
SALT_SIZE = 32
NONCE_SIZE = 12
PBKDF2_ITERATIONS = 100000
DEFAULT_AAD = b"LOCAL_RAG_BACKUP_V2_AUTHENTICATED"

def get_passphrase(args):
    # 1. Command-line argument
    if args.passphrase and args.passphrase.strip():
        return args.passphrase.strip()

    # 2. Environment variable
    env_key = os.environ.get("LOCAL_RAG_BACKUP_KEY", "").strip()
    if env_key:
        return env_key

    # 3. Explicit key file argument
    if args.key_file and os.path.exists(args.key_file):
        with open(args.key_file, "r", encoding="utf-8") as f:
            key = f.read().strip()
            if key:
                return key

    # 4. Default secrets file
    default_key_file = os.path.join(os.path.dirname(__file__), "..", ".secrets", "backup.key")
    default_key_file = os.path.abspath(default_key_file)
    if os.path.exists(default_key_file):
        with open(default_key_file, "r", encoding="utf-8") as f:
            key = f.read().strip()
            if key:
                return key

    sys.stderr.write("ERROR: No backup encryption passphrase found!\n")
    sys.stderr.write("Must specify --passphrase, set $env:LOCAL_RAG_BACKUP_KEY, or create .secrets/backup.key\n")
    sys.stderr.write("Hardcoded default passwords are strictly prohibited for production backups.\n")
    sys.exit(1)

def derive_key(passphrase: str, salt: bytes) -> bytes:
    kdf = PBKDF2HMAC(
        algorithm=hashes.SHA256(),
        length=32,
        salt=salt,
        iterations=PBKDF2_ITERATIONS,
    )
    return kdf.derive(passphrase.encode("utf-8"))

def encrypt_file(input_path: str, output_path: str, passphrase: str, aad: bytes = DEFAULT_AAD):
    salt = os.urandom(SALT_SIZE)
    nonce = os.urandom(NONCE_SIZE)
    key = derive_key(passphrase, salt)

    with open(input_path, "rb") as f:
        plaintext = f.read()

    aesgcm = AESGCM(key)
    # encrypt returns: ciphertext + 16-byte auth tag
    ciphertext_and_tag = aesgcm.encrypt(nonce, plaintext, aad)

    with open(output_path, "wb") as f:
        f.write(MAGIC_HEADER)
        f.write(salt)
        f.write(nonce)
        f.write(ciphertext_and_tag)

    print(f"ENCRYPT_OK: Encrypted {len(plaintext)} bytes -> {len(ciphertext_and_tag) + len(MAGIC_HEADER) + SALT_SIZE + NONCE_SIZE} bytes (AES-256-GCM)")

def decrypt_file(input_path: str, output_path: str, passphrase: str, aad: bytes = DEFAULT_AAD):
    with open(input_path, "rb") as f:
        magic = f.read(len(MAGIC_HEADER))
        if magic != MAGIC_HEADER:
            sys.stderr.write(f"ERROR: Invalid backup format. Magic: {magic}, expected: {MAGIC_HEADER}\n")
            sys.exit(2)

        salt = f.read(SALT_SIZE)
        nonce = f.read(NONCE_SIZE)
        ciphertext_and_tag = f.read()

    key = derive_key(passphrase, salt)
    aesgcm = AESGCM(key)

    try:
        plaintext = aesgcm.decrypt(nonce, ciphertext_and_tag, aad)
    except InvalidTag:
        sys.stderr.write("CRITICAL_TAMPER_DETECTED: Authentication tag verification failed!\n")
        sys.stderr.write("The backup file has been altered, corrupted, or tampered with.\n")
        sys.exit(3)

    with open(output_path, "wb") as f:
        f.write(plaintext)

    print(f"DECRYPT_OK: Verified & Decrypted {len(plaintext)} bytes (AES-256-GCM Authenticated)")

def main():
    parser = argparse.ArgumentParser(description="Stage E.1 AES-256-GCM Backup Encryption Engine")
    subparsers = parser.add_subparsers(dest="action", required=True)

    # Encrypt subparser
    enc_p = subparsers.add_parser("encrypt")
    enc_p.add_argument("--input", required=True, help="Path to input plaintext bundle")
    enc_p.add_argument("--output", required=True, help="Path to output encrypted archive (*.enc)")
    enc_p.add_argument("--passphrase", default="", help="Encryption passphrase")
    enc_p.add_argument("--key-file", default="", help="Path to key file")

    # Decrypt subparser
    dec_p = subparsers.add_parser("decrypt")
    dec_p.add_argument("--input", required=True, help="Path to encrypted archive (*.enc)")
    dec_p.add_argument("--output", required=True, help="Path to output decrypted bundle")
    dec_p.add_argument("--passphrase", default="", help="Decryption passphrase")
    dec_p.add_argument("--key-file", default="", help="Path to key file")

    args = parser.parse_args()
    passphrase = get_passphrase(args)

    if args.action == "encrypt":
        encrypt_file(args.input, args.output, passphrase)
    elif args.action == "decrypt":
        decrypt_file(args.input, args.output, passphrase)

if __name__ == "__main__":
    main()
