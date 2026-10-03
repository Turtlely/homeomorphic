# Toy homomorphic encryption on an FPGA

This project is a learning step toward a hardware accelerator for fully
homomorphic encryption (FHE). It implements a small integer scheme in
Verilog, runs it on a Real Digital Urbana board (Spartan-7), and controls it
from a Python GUI on the PC.

The example task:

1. The user types `hello world`.
2. **Encrypt:** the FPGA encrypts the text with the user's private key.
3. **Send to server:** the FPGA changes the text to uppercase. For this step
   it gets only the ciphertexts and the public value `x0`, not the key.
4. **Decrypt:** the PC decrypts the result and shows `HELLO WORLD`.

> **Warning:** This scheme is **not secure**. The parameters are very
> small, so an attacker can find the key in seconds. Use this project only
> to learn.

## The scheme

The scheme is a simplified, symmetric version of DGHV
(van Dijk, Gentry, Halevi, Vaikuntanathan, 2010). Each ciphertext holds
**one plaintext bit**.

| Item | Formula | Width in this project |
|---|---|---|
| Secret key | `p`, an odd integer | 16 bits (the RTL sets bit 0 to 1) |
| Random multiplier | `q`, new for each bit | 16 bits |
| Random noise | `r`, new for each bit | 4 bits |
| Encrypt bit `m` | `c = q·p + 2r + m` | 32 bits |
| Decrypt | `m = (c mod p) mod 2` | |
| Public value | `x0 = q0·p`, with no noise and `x0 < 2^32` | 32 bits |

Operations on ciphertexts:

| Ciphertext operation | Plaintext result |
|---|---|
| `c1 + c2` | `m1 XOR m2` |
| `c1 × c2` | `m1 AND m2` |
| `c + 1` | `NOT m` |
| `c mod x0` | No change. This keeps the ciphertext at 32 bits. |

`c mod p` is the noise, `2r + m`. Decryption is correct only while the
noise is less than `p/2`. A multiplication multiplies the noise values.
Fresh noise is at most 31, so after one AND the noise is at most
31 × 31 = 961. Thus `p` must be larger than 1922. The GUI makes keys with
`p` between 32769 and 65535.

## The capitalize circuit

In ASCII, a lowercase letter and its uppercase letter differ only in bit 5.
Letters have bit 6 = 1. Space has bit 6 = 0. So one rule capitalizes
every character in `"hello world"`:

```
b5_new = b5 AND (NOT b6)        all other bits do not change
```

On ciphertexts, this rule is:

```
c5_new = (c5 × (c6 + 1)) mod x0
```

The server runs the same circuit on every character. It does not branch
on the data, so it does not learn which characters are letters.

This rule is not a general `toupper`. For example, it changes `{` to `[`.
It is correct for lowercase letters, uppercase letters, and space. The GUI
accepts only lowercase letters and spaces.

## Ciphertext layout

One ASCII character becomes eight 32-bit ciphertexts in a 256-bit bus.
Slice `i` encrypts bit `i` of the character:

```
c[32*i +: 32]  encrypts  s[i]        (slice 0 = least significant bit)
```

On the UART, the bus is sent as 32 bytes, most significant byte first
(`c[255:248]` first, so bit 7 comes first).

`fhe_demo.py` uses the opposite order: list index 0 is bit 7.

## System

```
 PC (sw/fhe_gui.py)                         FPGA (rtl/fhe_top.v)
 ┌───────────────────────┐   USB-UART     ┌──────────────────────────────────────┐
 │ key generation (p, x0) │  115200 8-N-1  │ uart_rx ─┐                           │
 │ decryption             │ ─────────────► │          ▼                           │
 │ ciphertext inspection  │                │     fhe_controller ── buffer (BRAM)  │
 │                        │ ◄───────────── │      │        │                      │
 └───────────────────────┘                │      ▼        ▼                      │
                                           │ fhe_encrypt  fhe_capitalize_seq      │
                                           │  _byte  ▲                            │
                                           │ fhe_prng┘ (q, r)        uart_tx ──►  │
                                           └──────────────────────────────────────┘
```

The FPGA has two roles in this demo:

- **Encryption accelerator (client side).** The PC sends the plaintext and
  `p`. The FPGA adds random `q` and `r` from its PRNG.
- **Server.** The PC sends only `x0` and the ciphertexts. The FPGA runs the
  capitalize circuit.

In a real system, these roles are on different machines, and the key never
leaves the client.

### RTL modules

| File | Function |
|---|---|
| `rtl/fhe_top.v` | Urbana top level: reset, UART, controller, LEDs |
| `rtl/fhe_controller.v` | Protocol state machine and 2 KB payload buffer |
| `rtl/fhe_encrypt_byte.v` | Encrypt one character (combinational) |
| `rtl/fhe_capitalize_seq.v` | Homomorphic capitalize: shift-and-add multiply (33 cycles), then restoring modulo (64 cycles) |
| `rtl/fhe_prng.v` | xorshift32 PRNG that fills a 160-bit pool for `q` and `r` |
| `rtl/uart_rx.v`, `rtl/uart_tx.v` | 8-N-1 UART, 115200 baud |
| `rtl/fhe_capitalize_byte.v` | Combinational capitalize with `*` and `%`. Reference for simulation only. |
| `rtl/fhe_decrypt_byte.v` | Decrypt one character. Reference for simulation only. |

`fhe_capitalize_byte.v` uses a 64-by-32 `%`. That becomes a very large,
slow divider in hardware, so the FPGA uses `fhe_capitalize_seq.v`, which
gives the same result with one small adder per step.

### Randomness

`fhe_prng.v` is a xorshift32 generator. It makes 32 new bits in each clock
cycle and runs all the time, so the values depend on the time of each
request. Each bitstream gets a new random seed: `tools/build_urbana.tcl`
picks it and passes it to Vivado as the `PRNG_SEED` parameter. The seed is
written to `build/vivado/prng_seed.txt`.

xorshift32 is **not** cryptographically secure.

### LEDs

| LED | Meaning |
|---|---|
| LED0 | Heartbeat. Blinks when the bitstream is loaded. |
| LED1 | A byte was received. |
| LED2 | A byte was sent. |
| LED3 | On for 1 second after a protocol error or a UART framing error. |

BTN0 resets the design.

### Build results

Vivado 2025.2, XC7S50-CSGA324-1, 100 MHz clock:

| Resource | Used |
|---|---|
| LUTs | 867 (2.7 %) |
| Registers | 1772 (2.7 %) |
| DSP slices | 8 (the 8 multipliers in the encryptor) |
| Block RAM | 0.5 tile |
| Worst setup slack | +3.28 ns |

## UART protocol

115200 baud, 8 data bits, no parity, 1 stop bit. All multi-byte numbers are
big-endian. `LEN` is 1 to 64.

| PC → FPGA | FPGA → PC |
|---|---|
| `'P'` | `'p'`, version (`0x01`) |
| `'E'`, `p` (2 bytes), `LEN`, `LEN` ASCII characters | `'e'`, `LEN`, `LEN` × 32 ciphertext bytes |
| `'C'`, `x0` (4 bytes), `LEN`, `LEN` × 32 ciphertext bytes | `'c'`, `LEN`, `LEN` × 32 ciphertext bytes |
| (error) | `'!'`, code |

Error codes:

| Code | Meaning | After the error |
|---|---|---|
| 1 | Unknown command | The FPGA ignores bytes until the line is quiet for 100 ms. |
| 2 | `LEN` is 0 or larger than 64 | The same as code 1. |
| 3 | Timeout: no byte for 100 ms in the middle of a request | The FPGA is ready at once. |

## Directory layout

```
rtl/            synthesizable Verilog (see the table above)
tb/             testbenches
constraints/    urbana.xdc: pins and clock for the Urbana board
tools/          build_urbana.tcl, program_urbana.tcl (Vivado batch scripts)
sw/             Python: GUI, serial link, client math, tests
fhe_demo.py     first Python version of the scheme
build/          generated files (make creates this directory)
Makefile
```

## Requirements

- [Icarus Verilog](https://steveicarus.github.io/iverilog/) (`iverilog`, `vvp`)
- GNU Make
- Python 3 with tkinter, and the packages in `sw/requirements.txt`
  (`pip install -r sw/requirements.txt`)
- Vivado, to build the bitstream and to program the board
- GTKWave, to see waveforms (optional)

On Windows, the Makefile uses the `sh` from Git for Windows, so you can run
`make` from Git Bash, PowerShell, or cmd. It also finds Vivado in
`C:\AMDDesignTools` or `C:\Xilinx` if `vivado` is not on `PATH`.

## Usage

### Simulation and tests

Run all testbenches and the Python tests:

```bash
make
```

Run one testbench:

```bash
make fhe_top_tb
```

### Build and program the board

Build the bitstream. This takes a few minutes:

```bash
make bitstream
```

To build with a fixed PRNG seed:

```bash
make bitstream SEED=12345
```

Connect the Urbana board over USB, and load the bitstream:

```bash
make program
```

The design is lost when the board loses power. Run `make program` again
after a power cycle.

### GUI

Start the GUI, then select the board's COM port and click **Connect**:

```bash
make gui
```

To select the port from the command line:

```bash
make gui PORT=COM5
```

To try the GUI without a board:

```bash
make gui-sim
```

The simulated FPGA uses the same byte protocol and the same arithmetic as
the RTL.

In the GUI:

1. The **Keys** box shows the private key (`p`, `q0`) and the public key
   (`x0`). **New Key** makes a new random key.
2. Type a message: lowercase letters and spaces, up to 64 characters.
3. Click **1. Encrypt**. The table shows the 8 ciphertexts of each character.
4. Click **2. Send to Server**. The second table shows the result. The
   server changed only the bit 5 column.
5. Click **3. Decrypt**. The PC decrypts the result.

Click a row to see the details of one character: each ciphertext, its
noise `c mod p`, and the decrypted bit. The **Serial Log** tab shows the
bytes on the UART.

### Other targets

`make help` shows all targets. `make clean` removes `build/`, which also
removes the bitstream.

## Testbenches

| Testbench | What it checks |
|---|---|
| `fhe_encrypt_byte_tb` | Each ciphertext against `q·p + 2r + m` for 1000 random inputs. The noise is `2r + m`. The largest inputs do not overflow 32 bits. An even key gives the same result as key + 1. Two encryptions of the same character are different. |
| `fhe_decrypt_byte_tb` | All 256 characters, 1000 random keys, the largest ciphertext, and an even key. |
| `fhe_capitalize_byte_tb` | `a`–`z` become `A`–`Z`. `A`–`Z` and space do not change. All 256 bytes follow the bit rule. The other seven slices do not change. The result is less than `x0`. The noise stays less than `p/2`. |
| `fhe_chain_tb` | `"hello world"` through encrypt, capitalize, and decrypt. Writes `build/fhe_chain_tb.vcd`. |
| `fhe_capitalize_seq_tb` | The sequential unit against the combinational reference for 500 random inputs and edge values. |
| `uart_tb` | UART loopback of all 256 byte values. |
| `fhe_top_tb` | The full design through its UART pins: ping, encrypt and capitalize `"hello world"`, 64 characters (the maximum), and all three errors. |
| `sw/test_fhe.py` | Key generation, byte format, the Python model against bus values from `fhe_top_tb`, input checks, and the serial link with the simulated FPGA. |

Each testbench writes its output to `build/<name>.log`. A testbench passes
only if its log contains `PASS` and does not contain `FAIL` or `ERROR`.

## Limitations

- **Not secure.** A secure DGHV key has about 1,000 bits, and a secure
  ciphertext has about 160,000 bits.
- **The key goes to the FPGA.** The encrypt step sends `p` over the UART,
  because the FPGA also acts as the encryption accelerator.
- **The PRNG is not secure.** xorshift32 output is linear.
- **One AND level only.** A second AND with a fresh ciphertext gives
  noise up to 961 × 31 = 29791. That needs `p` > 59582, which is near the
  16-bit limit. Deeper circuits need a larger `p` or bootstrapping.
- **`fhe_demo.py` uses fixed `q` and `r` and an even `p`.** It shows the
  arithmetic, but its ciphertexts leak the plaintext.

## Next steps

1. Replace the restoring modulo with Barrett reduction.
2. Pipeline the capitalize unit, so that it takes one character in each
   clock cycle.
3. Move to a lattice scheme (TFHE). Start with a modular multiplier and an
   NTT butterfly.
