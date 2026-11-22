"""Wrap a meter AES key with the application KEK.

The stored blob stays version 1: one version byte, a 12-byte nonce, the
ciphertext and a 16-byte AES-256-GCM tag. The version byte is the AAD.
The fingerprint column is not filled. A bare hash of the meter key would
let a reader test guessed keys, and no separate fingerprint secret exists.
"""

from __future__ import annotations

import os
import secrets
import stat

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

APP_KEK_PATH = "/docker-data/infrastructure-sjv/secrets/app-kek"
FORMAT_VERSION = 1
KEK_LENGTH = 32
NONCE_LENGTH = 12
TAG_LENGTH = 16
METER_KEY_LENGTHS = (16, 32)
_HEADER_LENGTH = 1 + NONCE_LENGTH
_STORED_LENGTHS = frozenset(
    _HEADER_LENGTH + length + TAG_LENGTH for length in METER_KEY_LENGTHS
)


class MeterKeyError(Exception):
    """Failure that never includes key material in its message."""

    def __init__(self, code):
        self.code = code
        super().__init__(code)


def encrypt_meter_key(kek, meter_key, nonce=None):
    """Return the versioned blob for meters.aes_key_enc."""
    _require_kek(kek)
    _require_meter_key(meter_key)
    if nonce is None:
        nonce = secrets.token_bytes(NONCE_LENGTH)
    elif not isinstance(nonce, (bytes, bytearray)) or len(nonce) != NONCE_LENGTH:
        raise MeterKeyError("invalid_nonce")
    aad = bytes((FORMAT_VERSION,))
    try:
        sealed = AESGCM(bytes(kek)).encrypt(bytes(nonce), bytes(meter_key), aad)
    except Exception:
        raise MeterKeyError("invalid_kek") from None
    return aad + bytes(nonce) + sealed


def decrypt_meter_key(kek, blob):
    """Return the meter key, or fail without returning a partial value."""
    _require_kek(kek)
    if not isinstance(blob, (bytes, bytearray)) or len(blob) not in _STORED_LENGTHS:
        raise MeterKeyError("invalid_format")
    if blob[0] != FORMAT_VERSION:
        raise MeterKeyError("invalid_format")
    nonce = bytes(blob[1:_HEADER_LENGTH])
    sealed = bytes(blob[_HEADER_LENGTH:])
    try:
        opened = AESGCM(bytes(kek)).decrypt(nonce, sealed, bytes((FORMAT_VERSION,)))
    except InvalidTag:
        raise MeterKeyError("authentication_failed") from None
    except Exception:
        raise MeterKeyError("authentication_failed") from None
    _require_meter_key(opened)
    return opened


def load_kek(path=APP_KEK_PATH):
    """Read a 32-byte KEK. Never creates or replaces the file."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0))
    except FileNotFoundError:
        raise MeterKeyError("missing_kek") from None
    except OSError:
        raise MeterKeyError("kek_not_file") from None
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise MeterKeyError("kek_not_file")
        if stat.S_ISLNK(info.st_mode) or info.st_mode & 0o777 not in (0o600, 0o400):
            raise MeterKeyError("kek_permissions")
        if info.st_size != KEK_LENGTH:
            raise MeterKeyError("invalid_kek")
        kek = os.read(fd, KEK_LENGTH + 1)
    finally:
        os.close(fd)
    if len(kek) != KEK_LENGTH:
        raise MeterKeyError("invalid_kek")
    return kek


def _require_kek(kek):
    if not isinstance(kek, (bytes, bytearray)) or len(kek) != KEK_LENGTH:
        raise MeterKeyError("invalid_kek")


def _require_meter_key(meter_key):
    if not isinstance(meter_key, (bytes, bytearray)) or len(meter_key) not in METER_KEY_LENGTHS:
        raise MeterKeyError("invalid_meter_key")
