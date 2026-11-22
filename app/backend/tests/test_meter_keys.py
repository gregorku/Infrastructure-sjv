"""Meter-key wrapping. Uses throwaway keys and does not read the production KEK."""

import importlib.util
import logging
import os
import pathlib
import stat
import subprocess
import tempfile
import unittest

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from sjv_keys.meter_key import (
    APP_KEK_PATH,
    FORMAT_VERSION,
    MeterKeyError,
    decrypt_meter_key,
    encrypt_meter_key,
    load_kek,
)

REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
METER_KEY = b"SJVMETERKEY12345"
KEK = bytes(range(32))
OTHER_KEK = bytes(reversed(range(32)))
NONCE = bytes(range(12))
AAD = bytes((FORMAT_VERSION,))


def _code(function, *args):
    try:
        function(*args)
    except MeterKeyError as exc:
        text = str(exc)
        if METER_KEY.hex() in text or KEK.hex() in text or OTHER_KEK.hex() in text:
            raise AssertionError("key material leaked into an error") from None
        return exc.code
    return None


def _library_blob(kek, meter_key, nonce, aad=AAD):
    return bytes((FORMAT_VERSION,)) + nonce + AESGCM(kek).encrypt(nonce, meter_key, aad)


class MeterKeyWrappingTest(unittest.TestCase):
    def test_round_trip_and_library_format(self):
        blob = encrypt_meter_key(KEK, METER_KEY, NONCE)
        self.assertEqual(blob, _library_blob(KEK, METER_KEY, NONCE))
        self.assertEqual(blob[0], FORMAT_VERSION)
        self.assertEqual(blob[1:13], NONCE)
        self.assertEqual(len(blob), 1 + 12 + len(METER_KEY) + 16)
        self.assertTrue(decrypt_meter_key(KEK, blob) == METER_KEY)
        long_key = bytes(range(32))
        long_blob = encrypt_meter_key(KEK, long_key, NONCE)
        self.assertEqual(long_blob, _library_blob(KEK, long_key, NONCE))
        self.assertTrue(decrypt_meter_key(KEK, long_blob) == long_key)

    def test_each_encryption_uses_a_new_nonce(self):
        first = encrypt_meter_key(KEK, METER_KEY)
        second = encrypt_meter_key(KEK, METER_KEY)
        self.assertNotEqual(first, second)
        self.assertNotEqual(first[1:13], second[1:13])
        self.assertTrue(decrypt_meter_key(KEK, first) == decrypt_meter_key(KEK, second) == METER_KEY)

    def test_wrong_kek_is_rejected(self):
        blob = encrypt_meter_key(KEK, METER_KEY, NONCE)
        self.assertEqual(_code(decrypt_meter_key, OTHER_KEK, blob), "authentication_failed")

    def test_damaged_ciphertext_is_rejected(self):
        blob = bytearray(encrypt_meter_key(KEK, METER_KEY, NONCE))
        blob[-1] ^= 0x01
        self.assertEqual(_code(decrypt_meter_key, KEK, bytes(blob)), "authentication_failed")

    def test_unknown_version_is_rejected(self):
        blob = bytearray(encrypt_meter_key(KEK, METER_KEY, NONCE))
        blob[0] = 2
        self.assertEqual(_code(decrypt_meter_key, KEK, bytes(blob)), "invalid_format")
        self.assertEqual(_code(decrypt_meter_key, KEK, b""), "invalid_format")
        self.assertEqual(_code(decrypt_meter_key, KEK, b"\x01" + bytes(10)), "invalid_format")

    def test_aad_is_bound_to_the_version_byte(self):
        foreign = _library_blob(KEK, METER_KEY, NONCE, b"\x00")
        self.assertEqual(foreign[0], FORMAT_VERSION)
        self.assertEqual(_code(decrypt_meter_key, KEK, foreign), "authentication_failed")

    def test_key_length_is_rejected(self):
        self.assertEqual(_code(encrypt_meter_key, b"", METER_KEY, NONCE), "invalid_kek")
        self.assertEqual(_code(encrypt_meter_key, b"\x00" * 31, METER_KEY, NONCE), "invalid_kek")
        self.assertEqual(_code(encrypt_meter_key, b"\x00" * 33, METER_KEY, NONCE), "invalid_kek")
        self.assertEqual(_code(decrypt_meter_key, b"\x00" * 31, b"\x01" + bytes(44)), "invalid_kek")
        self.assertEqual(_code(encrypt_meter_key, KEK, b"short-key", NONCE), "invalid_meter_key")
        self.assertEqual(_code(encrypt_meter_key, KEK, METER_KEY, b"short-nonce"), "invalid_nonce")

    def test_errors_and_logs_do_not_contain_key_material(self):
        records = []

        class Capture(logging.Handler):
            def emit(self, record):
                records.append(record.getMessage())

        handler = Capture()
        root = logging.getLogger()
        previous = root.level
        root.setLevel(logging.DEBUG)
        root.addHandler(handler)
        try:
            blob = encrypt_meter_key(KEK, METER_KEY, NONCE)
            self.assertEqual(_code(decrypt_meter_key, OTHER_KEK, blob), "authentication_failed")
        finally:
            root.removeHandler(handler)
            root.setLevel(previous)
        visible = b" ".join(item.encode() for item in records)
        self.assertNotIn(METER_KEY, blob)
        self.assertNotIn(METER_KEY, visible)
        self.assertNotIn(METER_KEY.hex().encode(), visible)
        self.assertNotIn(KEK, visible)

    def test_collector_grant_excludes_wrapped_columns(self):
        sql = (REPO_ROOT / "app/backend/alembic/versions/0001_post.sql").read_text(encoding="utf-8")
        end = sql.index(") ON meters TO sjv_collector;")
        start = sql.rindex("GRANT SELECT (", 0, end)
        grant = sql[start:end]
        self.assertNotIn("aes_key_enc", grant)
        self.assertNotIn("aes_key_fingerprint", grant)

    def test_private_aes_implementation_is_gone(self):
        self.assertIsNone(importlib.util.find_spec("sjv_keys.aesgcm"))
        source = "\n".join(
            path.read_text(encoding="utf-8")
            for path in (REPO_ROOT / "app/backend/sjv_keys").glob("*.py")
        )
        self.assertNotIn("def encrypt_block", source)
        self.assertNotIn("_SBOX", source)


class KekFileTest(unittest.TestCase):
    def test_missing_kek_is_rejected(self):
        missing = pathlib.Path(tempfile.mkdtemp()) / "app-kek"
        self.assertEqual(_code(load_kek, missing), "missing_kek")
        self.assertFalse(missing.exists())

    def test_wrong_length_and_permissions_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "app-kek"
            path.write_bytes(b"\x11" * 31)
            os.chmod(path, 0o600)
            self.assertEqual(_code(load_kek, path), "invalid_kek")
            path.write_bytes(KEK)
            os.chmod(path, 0o644)
            self.assertEqual(_code(load_kek, path), "kek_permissions")
            os.chmod(path, 0o400)
            self.assertTrue(load_kek(path) == KEK)
            os.chmod(path, 0o600)
            self.assertTrue(load_kek(path) == KEK)

    def test_symlink_and_directory_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            target = root / "real"
            target.write_bytes(KEK)
            os.chmod(target, 0o600)
            link = root / "app-kek"
            link.symlink_to(target)
            self.assertEqual(_code(load_kek, link), "kek_not_file")
            self.assertEqual(_code(load_kek, root), "kek_not_file")

    def test_default_path_is_the_production_file(self):
        self.assertEqual(APP_KEK_PATH, "/docker-data/infrastructure-sjv/secrets/app-kek")


class CreateAppKekScriptTest(unittest.TestCase):
    def test_script_creates_once_and_does_not_print_the_key(self):
        script = REPO_ROOT / "scripts/create-app-kek.sh"
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "app-kek"
            first = subprocess.run([script, str(path)], capture_output=True, check=False)
            self.assertEqual(first.returncode, 0)
            stored = path.read_bytes()
            self.assertEqual(len(stored), 32)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertNotIn(stored, first.stdout)
            self.assertNotIn(stored, first.stderr)
            second = subprocess.run([script, str(path)], capture_output=True, check=False)
            self.assertNotEqual(second.returncode, 0)
            self.assertTrue(path.read_bytes() == stored)
            self.assertNotIn(stored, second.stdout)
            self.assertNotIn(stored, second.stderr)


if __name__ == "__main__":
    unittest.main()
