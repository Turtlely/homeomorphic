"""Tests for fhe_crypto and fhe_serial. Run with: python -m pytest -q"""

import random

import pytest

import fhe_crypto as fc
import fhe_serial as fs

# Output of tb/fhe_top_tb.v (PRNG_SEED = 0x12345678, p = 40009): the bus for 'h'
# after encrypt and after capitalize. These check that Python and the RTL use the
# same byte order and the same arithmetic.
RTL_P = 40009
RTL_X0 = (0xFFFF_FFFF // RTL_P) * RTL_P
RTL_ENCRYPT_H = "0b8bfcbc0f833b0040308790140471b84128ffb57d0b98825cb7cef6603eb8b9"
RTL_CAPITALIZE_H = "0b8bfcbc0f833b00a7a6973e140471b84128ffb57d0b98825cb7cef6603eb8b9"


def test_keys_are_valid():
    rng = random.Random(1)
    for _ in range(1000):
        k = fc.generate_keys(rng)
        assert k.p % 2 == 1
        assert 0x8001 <= k.p <= 0xFFFF
        assert (1 << 31) < k.x0 <= 0xFFFF_FFFF
        assert k.x0 % k.p == 0


def test_byte_format_round_trip():
    words = tuple(range(0x11111111, 0x11111111 * 9, 0x11111111))
    data = fc.char_to_bytes(words)
    assert len(data) == 32
    assert data[:4] == words[7].to_bytes(4, "big")      # bit 7 is sent first
    assert fc.char_from_bytes(data) == words


def test_rtl_vectors():
    enc = fc.char_from_bytes(bytes.fromhex(RTL_ENCRYPT_H))
    cap = fc.char_from_bytes(bytes.fromhex(RTL_CAPITALIZE_H))
    assert fc.decrypt_char(enc, RTL_P) == "h"
    assert fc.decrypt_char(cap, RTL_P) == "H"
    assert fc.capitalize_char(enc, RTL_X0) == cap


def test_reference_model_hello_world():
    rng = random.Random(2)
    keys = fc.generate_keys(rng)
    chars = [fc.encrypt_char(ch, keys.p, rng) for ch in "hello world"]
    assert fc.decrypt(chars, keys.p) == "hello world"
    result = [fc.capitalize_char(w, keys.x0) for w in chars]
    assert fc.decrypt(result, keys.p) == "HELLO WORLD"


@pytest.mark.parametrize("text", ["", "Hello", "hello!", "a" * 65])
def test_validate_rejects(text):
    with pytest.raises(ValueError):
        fc.validate_text(text)


def test_validate_accepts():
    fc.validate_text("hello world")
    fc.validate_text("z" * 64)


def test_link_with_simulated_fpga():
    link = fs.FheLink(fs.SimulatedFpga(seed=3))
    keys = fc.generate_keys(random.Random(3))
    assert link.ping() == fs.VERSION

    text = "the quick brown fox jumps over the lazy dog"
    enc = link.encrypt(text, keys.p)
    assert len(link.last_request) == 4 + len(text)
    assert len(link.last_reply) == 2 + 32 * len(text)
    assert fc.decrypt(enc, keys.p) == text

    res = link.capitalize(enc, keys.x0)
    assert fc.decrypt(res, keys.p) == text.upper()


def test_link_error_reply(monkeypatch):
    monkeypatch.setattr(fs, "ERROR_RECOVERY_SECONDS", 0)
    sim = fs.SimulatedFpga()
    link = fs.FheLink(sim)
    link._send(b"Z")
    with pytest.raises(fs.FpgaError, match="unknown command"):
        link._expect_code(fs.RSP_PING)


def test_link_no_reply():
    class Silent:
        def write(self, data): return len(data)
        def read(self, n): return b""
        def reset_input_buffer(self): pass
        def close(self): pass

    with pytest.raises(fs.FpgaError, match="no reply"):
        fs.FheLink(Silent()).ping()
