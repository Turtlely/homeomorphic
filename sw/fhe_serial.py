"""UART link to the FPGA, and a simulated FPGA for use without a board.

Protocol (all multi-byte numbers are big-endian):

    PC -> FPGA                                  FPGA -> PC
    'P'                                         'p', VERSION
    'E', p (2 bytes), LEN, LEN chars            'e', LEN, LEN x 32 bytes
    'C', x0 (4 bytes), LEN, LEN x 32 bytes      'c', LEN, LEN x 32 bytes
    (error)                                     '!', code

See rtl/fhe_controller.v for the hardware side.
"""

import random
import time

import fhe_crypto as fc

BAUD_RATE = 115_200
VERSION = 0x01

CMD_PING, CMD_ENCRYPT, CMD_CAPITALIZE = b"P", b"E", b"C"
RSP_PING, RSP_ENCRYPT, RSP_CAPITALIZE, RSP_ERROR = b"p", b"e", b"c", b"!"

ERROR_TEXT = {
    1: "unknown command",
    2: "bad length",
    3: "timeout (the request was not complete)",
}

# after error 1 or 2 the FPGA ignores bytes until the line is quiet for 100 ms
ERROR_RECOVERY_SECONDS = 0.3

SIMULATED_PORT = "Simulated FPGA"


class FpgaError(Exception):
    """The FPGA sent an error reply, or the reply was not correct."""


def list_ports():
    """Return a list of (device, description) for the serial ports."""
    from serial.tools import list_ports as lp

    return [(p.device, p.description) for p in sorted(lp.comports(), key=lambda p: p.device)]


class FheLink:
    """Sends requests to the FPGA and reads the replies."""

    def __init__(self, port):
        # port is a serial.Serial or a SimulatedFpga
        self.port = port
        self.last_request = b""
        self.last_reply = b""

    @classmethod
    def open(cls, device: str, timeout: float = 2.0):
        if device == SIMULATED_PORT:
            return cls(SimulatedFpga())
        import serial

        port = serial.Serial(device, BAUD_RATE, timeout=timeout)
        port.reset_input_buffer()
        return cls(port)

    def close(self):
        self.port.close()

    # -- requests ----------------------------------------------------------

    def ping(self) -> int:
        self._send(CMD_PING)
        self._expect_code(RSP_PING)
        version = self._read(1)[0]
        return version

    def encrypt(self, text: str, p: int) -> list:
        """The FPGA encrypts text with key p. Returns one 8-tuple for each character."""
        fc.validate_text(text)
        request = CMD_ENCRYPT + p.to_bytes(2, "big") + bytes([len(text)]) + text.encode("ascii")
        self._send(request)
        return self._read_chars(RSP_ENCRYPT, len(text))

    def capitalize(self, chars, x0: int) -> list:
        """The FPGA runs the homomorphic capitalize. It gets only x0 and the ciphertexts."""
        if not 1 <= len(chars) <= fc.MAX_LEN:
            raise ValueError("bad number of characters")
        payload = b"".join(fc.char_to_bytes(w) for w in chars)
        request = CMD_CAPITALIZE + x0.to_bytes(4, "big") + bytes([len(chars)]) + payload
        self._send(request)
        return self._read_chars(RSP_CAPITALIZE, len(chars))

    # -- helpers -----------------------------------------------------------

    def _send(self, data: bytes):
        self.port.reset_input_buffer()
        self.last_request = data
        self.last_reply = b""
        self.port.write(data)

    def _read(self, n: int) -> bytes:
        data = self.port.read(n)
        self.last_reply += data
        if len(data) != n:
            raise FpgaError(f"no reply from the FPGA (received {len(data)} of {n} bytes)")
        return data

    def _expect_code(self, expected: bytes):
        code = self._read(1)
        if code == RSP_ERROR:
            err = self._read(1)[0]
            time.sleep(ERROR_RECOVERY_SECONDS)
            self.port.reset_input_buffer()
            raise FpgaError(f"FPGA error {err}: {ERROR_TEXT.get(err, 'unknown error')}")
        if code != expected:
            raise FpgaError(f"unexpected reply code {code!r}, expected {expected!r}")

    def _read_chars(self, code: bytes, length: int) -> list:
        self._expect_code(code)
        n = self._read(1)[0]
        if n != length:
            raise FpgaError(f"reply has {n} characters, expected {length}")
        data = self._read(n * fc.CHAR_BYTES)
        return [fc.char_from_bytes(data[k:k + fc.CHAR_BYTES]) for k in range(0, len(data), fc.CHAR_BYTES)]


class SimulatedFpga:
    """Acts like the serial port of a programmed board.

    It runs the same byte protocol as rtl/fhe_controller.v and the same
    arithmetic as the RTL, so the GUI works without a board.
    """

    def __init__(self, seed=None):
        self._rng = random.Random(seed)
        self._out = bytearray()

    def write(self, data: bytes):
        self._out += self._handle(bytes(data))
        return len(data)

    def read(self, n: int) -> bytes:
        data = bytes(self._out[:n])
        del self._out[:n]
        return data

    def reset_input_buffer(self):
        self._out.clear()

    def close(self):
        pass

    def _handle(self, req: bytes) -> bytes:
        if not req:
            return b""
        cmd = req[:1]
        if cmd == CMD_PING:
            return RSP_PING + bytes([VERSION])
        if cmd == CMD_ENCRYPT:
            p = int.from_bytes(req[1:3], "big")
            n = req[3] if len(req) > 3 else 0
            if not 1 <= n <= fc.MAX_LEN:
                return RSP_ERROR + b"\x02"
            text = req[4:4 + n]
            if len(text) != n:
                return RSP_ERROR + b"\x03"
            body = b"".join(fc.char_to_bytes(fc.encrypt_char(chr(b), p, self._rng)) for b in text)
            return RSP_ENCRYPT + bytes([n]) + body
        if cmd == CMD_CAPITALIZE:
            x0 = int.from_bytes(req[1:5], "big")
            n = req[5] if len(req) > 5 else 0
            if not 1 <= n <= fc.MAX_LEN:
                return RSP_ERROR + b"\x02"
            payload = req[6:6 + n * fc.CHAR_BYTES]
            if len(payload) != n * fc.CHAR_BYTES:
                return RSP_ERROR + b"\x03"
            chars = [fc.char_from_bytes(payload[k:k + fc.CHAR_BYTES])
                     for k in range(0, len(payload), fc.CHAR_BYTES)]
            body = b"".join(fc.char_to_bytes(fc.capitalize_char(w, x0)) for w in chars)
            return RSP_CAPITALIZE + bytes([n]) + body
        return RSP_ERROR + b"\x01"
