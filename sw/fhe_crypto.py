"""Client-side math for the toy DGHV scheme.

Each ciphertext holds one plaintext bit:

    encrypt:  c = q*p + 2r + m
    decrypt:  m = (c mod p) mod 2

One character is 8 ciphertexts. In this module a character is a tuple of
8 integers, and index i holds the ciphertext of bit i (index 0 = LSB).
This is the same order as the RTL bus: bus[32*i +: 32] encrypts bit i.
"""

import secrets
from dataclasses import dataclass

MAX_LEN = 64
ALLOWED_CHARS = frozenset("abcdefghijklmnopqrstuvwxyz ")

WORD_BYTES = 4
CHAR_BYTES = 8 * WORD_BYTES          # 32 bytes for one character
WORD_MASK = 0xFFFF_FFFF


@dataclass(frozen=True)
class KeyPair:
    """p and q0 are private. x0 = q0 * p is public."""

    p: int
    q0: int

    @property
    def x0(self) -> int:
        return self.q0 * self.p


def generate_keys(rng=None) -> KeyPair:
    """Make a random key.

    p is odd and has bit 15 set (32769..65535). The noise after one AND is
    at most 31 * 31 = 961, so p/2 is always much larger than the noise.

    q0 is random, so that 2^31 < x0 < 2^32.
    """
    rng = rng or secrets.SystemRandom()
    p = rng.randrange(0x8001, 0x10000, 2)
    q0_min = (1 << 31) // p + 1
    q0_max = WORD_MASK // p
    q0 = rng.randint(q0_min, q0_max)
    return KeyPair(p=p, q0=q0)


def validate_text(text: str) -> None:
    """Raise ValueError if the FPGA cannot take this text."""
    if not text:
        raise ValueError("The message is empty.")
    if len(text) > MAX_LEN:
        raise ValueError(f"The message is longer than {MAX_LEN} characters.")
    bad = sorted(set(text) - ALLOWED_CHARS)
    if bad:
        raise ValueError("Only lowercase letters a-z and spaces are allowed.")


# ---------------------------------------------------------------------------
# Byte format: one character = 256-bit bus, most significant byte first
# ---------------------------------------------------------------------------

def char_from_bytes(data: bytes) -> tuple:
    """32 bytes (bus[255:248] first) -> 8 ciphertexts, index i = bit i."""
    if len(data) != CHAR_BYTES:
        raise ValueError(f"expected {CHAR_BYTES} bytes, got {len(data)}")
    bus = int.from_bytes(data, "big")
    return tuple((bus >> (32 * i)) & WORD_MASK for i in range(8))


def char_to_bytes(words) -> bytes:
    """8 ciphertexts -> 32 bytes (bus[255:248] first)."""
    bus = 0
    for i, w in enumerate(words):
        bus |= (w & WORD_MASK) << (32 * i)
    return bus.to_bytes(CHAR_BYTES, "big")


# ---------------------------------------------------------------------------
# Decryption (client side)
# ---------------------------------------------------------------------------

def noise(c: int, p: int) -> int:
    """c mod p = 2r + m. Decryption is correct while this is less than p/2."""
    return c % p


def decrypt_bit(c: int, p: int) -> int:
    return noise(c, p) % 2


def decrypt_char(words, p: int) -> str:
    value = 0
    for i, c in enumerate(words):
        value |= decrypt_bit(c, p) << i
    return chr(value)


def decrypt(chars, p: int) -> str:
    return "".join(decrypt_char(w, p) for w in chars)


# ---------------------------------------------------------------------------
# Reference model of the FPGA operations (used by the simulated FPGA and tests)
# ---------------------------------------------------------------------------

def encrypt_char(ch: str, p: int, rng) -> tuple:
    """Same arithmetic as rtl/fhe_encrypt_byte.v."""
    m = ord(ch)
    p_odd = p | 1
    words = []
    for i in range(8):
        q = rng.getrandbits(16)
        r = rng.getrandbits(4)
        words.append((q * p_odd + 2 * r + ((m >> i) & 1)) & WORD_MASK)
    return tuple(words)


def capitalize_char(words, x0: int) -> tuple:
    """Same arithmetic as rtl/fhe_capitalize_byte.v: c5 = c5 * (c6 + 1) mod x0."""
    out = list(words)
    out[5] = (words[5] * (words[6] + 1)) % x0
    return tuple(out)
