"""PC client for the toy homomorphic encryption FPGA.

Steps:
  1. Encrypt:         the FPGA encrypts the message with the private key p.
  2. Send to server:  the FPGA capitalizes the ciphertexts. It gets only x0.
  3. Decrypt:         the PC decrypts the result with p.

Run:
  python fhe_gui.py              (select the port in the window)
  python fhe_gui.py --port COM5
  python fhe_gui.py --sim        (no board: use the simulated FPGA)
"""

import argparse
import tkinter as tk
from tkinter import messagebox, ttk

import fhe_crypto as fc
import fhe_serial as fs

APP_TITLE = "FHE Client"
LOG_MAX_BYTES = 96          # bytes of each request/reply shown in the log


def fmt_num(n: int, hex_digits: int) -> str:
    return f"{n}  (0x{n:0{hex_digits}X})"


def hex_preview(data: bytes) -> str:
    text = data[:LOG_MAX_BYTES].hex(" ").upper()
    if len(data) > LOG_MAX_BYTES:
        text += f" ... ({len(data)} bytes)"
    return text


class CipherTable(ttk.Frame):
    """Table with one row for each character and one column for each ciphertext."""

    COLUMNS = ("idx", "char") + tuple(f"c{i}" for i in range(7, -1, -1))

    def __init__(self, master, on_select):
        super().__init__(master)
        self.tree = ttk.Treeview(self, columns=self.COLUMNS, show="headings",
                                 selectmode="browse", height=8)
        self.tree.heading("idx", text="#")
        self.tree.heading("char", text="Char")
        self.tree.column("idx", width=36, anchor="e", stretch=False)
        self.tree.column("char", width=48, anchor="center", stretch=False)
        for i in range(7, -1, -1):
            self.tree.heading(f"c{i}", text=f"Bit {i}")
            self.tree.column(f"c{i}", width=86, anchor="e")

        ysb = ttk.Scrollbar(self, orient="vertical", command=self.tree.yview)
        self.tree.configure(yscrollcommand=ysb.set)
        self.tree.grid(row=0, column=0, sticky="nsew")
        ysb.grid(row=0, column=1, sticky="ns")
        self.rowconfigure(0, weight=1)
        self.columnconfigure(0, weight=1)

        self.tree.bind("<<TreeviewSelect>>", lambda e: on_select(self.selected_index()))

    def fill(self, chars, labels):
        self.tree.delete(*self.tree.get_children())
        for k, (words, label) in enumerate(zip(chars, labels)):
            values = (k, label) + tuple(f"{words[i]:08X}" for i in range(7, -1, -1))
            self.tree.insert("", "end", iid=str(k), values=values)

    def set_labels(self, labels):
        for k, label in enumerate(labels):
            if self.tree.exists(str(k)):
                self.tree.set(str(k), "char", label)

    def clear(self):
        self.tree.delete(*self.tree.get_children())

    def selected_index(self):
        sel = self.tree.selection()
        return int(sel[0]) if sel else None


class App(tk.Tk):
    def __init__(self, port=None):
        super().__init__()
        self.title(APP_TITLE)
        self.minsize(860, 700)

        self.link = None
        self.keys = fc.generate_keys()
        self.plaintext = ""          # the text that was encrypted
        self.encrypted = []          # list of 8-tuples from the encrypt step
        self.result = []             # list of 8-tuples from the server step
        self.decrypted = ""

        self.port_var = tk.StringVar()
        self.status_var = tk.StringVar(value="Not connected.")
        self.conn_var = tk.StringVar(value="Not connected")
        self.msg_var = tk.StringVar(value="hello world")
        self.dec_var = tk.StringVar()
        self.p_var = tk.StringVar()
        self.q0_var = tk.StringVar()
        self.x0_var = tk.StringVar()

        self._build_menu()
        self._build_widgets()
        self._show_keys()
        self.refresh_ports()
        if port:
            self.port_var.set(port)
            self.after(100, self.toggle_connection)
        self._update_buttons()

        self.protocol("WM_DELETE_WINDOW", self.on_exit)

    # ------------------------------------------------------------------
    # Layout
    # ------------------------------------------------------------------

    def _build_menu(self):
        menubar = tk.Menu(self)

        file_menu = tk.Menu(menubar, tearoff=False)
        file_menu.add_command(label="New Key", command=self.new_key)
        file_menu.add_separator()
        file_menu.add_command(label="Exit", command=self.on_exit)
        menubar.add_cascade(label="File", menu=file_menu)

        help_menu = tk.Menu(menubar, tearoff=False)
        help_menu.add_command(label="How It Works", command=self.show_help)
        help_menu.add_command(label="About", command=self.show_about)
        menubar.add_cascade(label="Help", menu=help_menu)

        self.config(menu=menubar)

    def _build_widgets(self):
        outer = ttk.Frame(self, padding=8)
        outer.pack(fill="both", expand=True)
        outer.columnconfigure(0, weight=1)
        outer.rowconfigure(3, weight=1)
        outer.rowconfigure(4, weight=1)

        # -- connection --
        conn = ttk.LabelFrame(outer, text="Connection", padding=6)
        conn.grid(row=0, column=0, sticky="ew")
        ttk.Label(conn, text="Port:").grid(row=0, column=0, padx=(0, 4))
        self.port_box = ttk.Combobox(conn, textvariable=self.port_var, width=34, state="readonly")
        self.port_box.grid(row=0, column=1)
        ttk.Button(conn, text="Refresh", command=self.refresh_ports).grid(row=0, column=2, padx=4)
        self.conn_button = ttk.Button(conn, text="Connect", command=self.toggle_connection)
        self.conn_button.grid(row=0, column=3)
        ttk.Label(conn, textvariable=self.conn_var).grid(row=0, column=4, padx=(12, 0))

        # -- keys --
        keys = ttk.LabelFrame(outer, text="Keys", padding=6)
        keys.grid(row=1, column=0, sticky="ew", pady=(6, 0))
        keys.columnconfigure(1, weight=1)
        keys.columnconfigure(4, weight=1)

        ttk.Label(keys, text="Private key (stays on the PC)").grid(row=0, column=0, columnspan=2, sticky="w")
        ttk.Label(keys, text="p:").grid(row=1, column=0, sticky="e", padx=(8, 4))
        ttk.Entry(keys, textvariable=self.p_var, state="readonly", width=24).grid(row=1, column=1, sticky="w")
        ttk.Label(keys, text="q0:").grid(row=2, column=0, sticky="e", padx=(8, 4))
        ttk.Entry(keys, textvariable=self.q0_var, state="readonly", width=24).grid(row=2, column=1, sticky="w")

        ttk.Separator(keys, orient="vertical").grid(row=0, column=2, rowspan=3, sticky="ns", padx=12)

        ttk.Label(keys, text="Public key (sent to the server)").grid(row=0, column=3, columnspan=2, sticky="w")
        ttk.Label(keys, text="x0 = q0 × p:").grid(row=1, column=3, sticky="e", padx=(8, 4))
        ttk.Entry(keys, textvariable=self.x0_var, state="readonly", width=28).grid(row=1, column=4, sticky="w")

        ttk.Button(keys, text="New Key", command=self.new_key).grid(row=2, column=4, sticky="e")

        # -- message and steps --
        msg = ttk.LabelFrame(outer, text="Message", padding=6)
        msg.grid(row=2, column=0, sticky="ew", pady=(6, 0))
        msg.columnconfigure(1, weight=1)

        ttk.Label(msg, text="Plaintext:").grid(row=0, column=0, sticky="w", padx=(0, 4))
        vcmd = (self.register(self._validate_message), "%P")
        icmd = (self.register(self._reject_message), "%S")
        self.msg_entry = ttk.Entry(msg, textvariable=self.msg_var, validate="key",
                                   validatecommand=vcmd, invalidcommand=icmd)
        self.msg_entry.grid(row=0, column=1, sticky="ew")
        ttk.Label(msg, text=f"Lowercase a-z and spaces, up to {fc.MAX_LEN} characters.").grid(
            row=1, column=1, sticky="w")
        self.msg_var.trace_add("write", lambda *a: self._message_changed())

        steps = ttk.Frame(msg)
        steps.grid(row=2, column=0, columnspan=2, sticky="ew", pady=(6, 0))
        self.enc_button = ttk.Button(steps, text="1. Encrypt", width=18, command=self.do_encrypt)
        self.srv_button = ttk.Button(steps, text="2. Send to Server", width=18, command=self.do_server)
        self.dec_button = ttk.Button(steps, text="3. Decrypt", width=18, command=self.do_decrypt)
        self.enc_button.pack(side="left")
        self.srv_button.pack(side="left", padx=6)
        self.dec_button.pack(side="left")
        ttk.Entry(steps, textvariable=self.dec_var, state="readonly", width=40).pack(side="right")
        ttk.Label(steps, text="Decrypted:").pack(side="right", padx=(12, 4))

        # -- tables and log --
        self.book = ttk.Notebook(outer)
        self.book.grid(row=3, column=0, sticky="nsew", pady=(6, 0))

        self.enc_table = CipherTable(self.book, lambda k: self.show_details("enc", k))
        self.res_table = CipherTable(self.book, lambda k: self.show_details("res", k))
        log_frame = ttk.Frame(self.book)
        self.log = tk.Text(log_frame, height=8, wrap="word", font="TkFixedFont", state="disabled")
        log_sb = ttk.Scrollbar(log_frame, orient="vertical", command=self.log.yview)
        self.log.configure(yscrollcommand=log_sb.set)
        self.log.pack(side="left", fill="both", expand=True)
        log_sb.pack(side="right", fill="y")

        self.book.add(self.enc_table, text="Encrypted (from FPGA)")
        self.book.add(self.res_table, text="Server Result (from FPGA)")
        self.book.add(log_frame, text="Serial Log")

        # -- details --
        det = ttk.LabelFrame(outer, text="Selected Character (client view, uses the private key p)", padding=6)
        det.grid(row=4, column=0, sticky="nsew", pady=(6, 0))
        self.details = tk.Text(det, height=14, wrap="none", font="TkFixedFont", state="disabled")
        self.details.pack(fill="both", expand=True)

        # -- status bar --
        ttk.Label(self, textvariable=self.status_var, relief="sunken", anchor="w",
                  padding=(4, 1)).pack(side="bottom", fill="x")

    # ------------------------------------------------------------------
    # Connection
    # ------------------------------------------------------------------

    def refresh_ports(self):
        try:
            ports = fs.list_ports()
        except ImportError:
            ports = []
            self.set_status("pyserial is not installed. Only the simulated FPGA is available.")
        values = [f"{dev} - {desc}" for dev, desc in ports] + [fs.SIMULATED_PORT]
        self.port_box["values"] = values
        if self.port_var.get() not in values and not self.link:
            self.port_var.set(values[0])

    def _selected_device(self):
        value = self.port_var.get()
        if value == fs.SIMULATED_PORT:
            return value
        return value.split(" - ")[0].strip()

    def toggle_connection(self):
        if self.link:
            self.link.close()
            self.link = None
            self.conn_var.set("Not connected")
            self.conn_button.config(text="Connect")
            self.port_box.config(state="readonly")
            self.set_status("Disconnected.")
            self._update_buttons()
            return

        device = self._selected_device()
        if not device:
            return
        try:
            with self.busy():
                link = fs.FheLink.open(device)
                version = link.ping()
        except Exception as exc:  # serial errors have many types
            try:
                link.close()
            except Exception:
                pass
            messagebox.showerror(APP_TITLE, f"Cannot connect to {device}.\n\n{exc}")
            self.set_status(f"Cannot connect to {device}.")
            return

        self.link = link
        self.conn_var.set(f"Connected to {device} (protocol version {version})")
        self.conn_button.config(text="Disconnect")
        self.port_box.config(state="disabled")
        self.write_log(f"Connected to {device}. Ping reply: version {version}.")
        self.set_status("Connected.")
        self._update_buttons()

    # ------------------------------------------------------------------
    # Keys and message
    # ------------------------------------------------------------------

    def _show_keys(self):
        self.p_var.set(fmt_num(self.keys.p, 4))
        self.q0_var.set(fmt_num(self.keys.q0, 4))
        self.x0_var.set(fmt_num(self.keys.x0, 8))

    def new_key(self):
        self.keys = fc.generate_keys()
        self._show_keys()
        self._clear_results()
        self.write_log(f"New key: p = {self.keys.p}, q0 = {self.keys.q0}, x0 = {self.keys.x0}.")
        self.set_status("New key made. Encrypt the message again.")

    def _validate_message(self, proposed):
        return len(proposed) <= fc.MAX_LEN and set(proposed) <= fc.ALLOWED_CHARS

    def _reject_message(self, inserted):
        self.bell()
        self.set_status("Only lowercase letters a-z and spaces are allowed, "
                        f"up to {fc.MAX_LEN} characters.")

    def _message_changed(self):
        if self.encrypted and self.msg_var.get() != self.plaintext:
            self._clear_results()
            self.set_status("The message changed. Encrypt it again.")
        self._update_buttons()

    def _clear_results(self):
        self.plaintext = ""
        self.encrypted = []
        self.result = []
        self.decrypted = ""
        self.dec_var.set("")
        self.enc_table.clear()
        self.res_table.clear()
        self._set_details("")
        self._update_buttons()

    def _update_buttons(self):
        connected = self.link is not None
        has_text = bool(self.msg_var.get())
        self.enc_button.state(["!disabled"] if connected and has_text else ["disabled"])
        self.srv_button.state(["!disabled"] if connected and self.encrypted else ["disabled"])
        self.dec_button.state(["!disabled"] if self.result else ["disabled"])

    # ------------------------------------------------------------------
    # The three steps
    # ------------------------------------------------------------------

    def do_encrypt(self):
        text = self.msg_var.get()
        try:
            fc.validate_text(text)
            with self.busy():
                chars = self.link.encrypt(text, self.keys.p)
        except Exception as exc:
            self._request_failed("Encrypt", exc)
            return
        finally:
            self._log_traffic("Encrypt")

        self._clear_results()
        self.plaintext = text
        self.encrypted = chars
        self.enc_table.fill(chars, list(text))
        self.book.select(self.enc_table)
        self._select_first(self.enc_table)
        self.set_status(f"Encrypted {len(text)} characters into {len(text) * 8} ciphertexts.")
        self._update_buttons()

    def do_server(self):
        try:
            with self.busy():
                chars = self.link.capitalize(self.encrypted, self.keys.x0)
        except Exception as exc:
            self._request_failed("Send to server", exc)
            return
        finally:
            self._log_traffic("Send to server")

        self.result = chars
        self.decrypted = ""
        self.dec_var.set("")
        self.res_table.fill(chars, ["?"] * len(chars))
        self.book.select(self.res_table)
        self._select_first(self.res_table)
        self.set_status("The server returned the result. It did not see the key p or the plaintext.")
        self._update_buttons()

    def do_decrypt(self):
        self.decrypted = fc.decrypt(self.result, self.keys.p)
        self.dec_var.set(self.decrypted)
        self.res_table.set_labels(list(self.decrypted))
        k = self.res_table.selected_index()
        if k is not None:
            self.show_details("res", k)
        self.write_log(f"Decrypted on the PC: {self.decrypted!r}")
        self.set_status("Decrypted on the PC with the private key p.")

    def _request_failed(self, what, exc):
        self.write_log(f"{what} failed: {exc}")
        messagebox.showerror(APP_TITLE, f"{what} failed.\n\n{exc}")
        self.set_status(f"{what} failed.")

    def _log_traffic(self, what):
        if not self.link:
            return
        self.write_log(f"{what}:\n"
                       f"  PC -> FPGA: {hex_preview(self.link.last_request)}\n"
                       f"  FPGA -> PC: {hex_preview(self.link.last_reply)}")

    def _select_first(self, table):
        if table.tree.exists("0"):
            table.tree.selection_set("0")
            table.tree.focus("0")

    # ------------------------------------------------------------------
    # Details pane
    # ------------------------------------------------------------------

    def show_details(self, which, k):
        if k is None:
            return
        chars = self.encrypted if which == "enc" else self.result
        if k >= len(chars):
            return
        p = self.keys.p
        words = chars[k]
        value = sum(fc.decrypt_bit(c, p) << i for i, c in enumerate(words))
        half = p // 2

        lines = []
        if which == "enc":
            lines.append(f"Character {k} after encryption.  c = q·p + 2r + m,  p = {p}")
        else:
            lines.append(f"Character {k} after the server.  Bit 5 is now c5·(c6 + 1) mod x0,  p = {p}")
        lines.append("")
        lines.append(f"{'Bit':>3}  {'Ciphertext c':>12}  {'Hex':>8}  {'c mod p (noise)':>15}  {'Bit = noise mod 2':>17}")
        for i in range(7, -1, -1):
            c = words[i]
            n = fc.noise(c, p)
            mark = "  (noise > p/2: wrong)" if n >= half else ""
            lines.append(f"{i:>3}  {c:>12}  {c:08X}  {n:>15}  {n % 2:>17}{mark}")
        lines.append("")
        ch = chr(value)
        shown = repr(ch) if ch.isprintable() else "(not printable)"
        lines.append(f"Plaintext bits: {value:08b} = 0x{value:02X} = {shown}")
        lines.append(f"Noise limit: p/2 = {half}")
        self._set_details("\n".join(lines))

    def _set_details(self, text):
        self.details.config(state="normal")
        self.details.delete("1.0", "end")
        self.details.insert("1.0", text)
        self.details.config(state="disabled")

    # ------------------------------------------------------------------
    # Misc
    # ------------------------------------------------------------------

    def write_log(self, text):
        self.log.config(state="normal")
        self.log.insert("end", text + "\n")
        self.log.see("end")
        self.log.config(state="disabled")

    def set_status(self, text):
        self.status_var.set(text)

    def busy(self):
        app = self

        class _Busy:
            def __enter__(self):
                app.config(cursor="watch")
                app.update_idletasks()

            def __exit__(self, *exc):
                app.config(cursor="")
                return False

        return _Busy()

    def show_help(self):
        messagebox.showinfo(
            "How It Works",
            "1. Encrypt: the PC sends the message and the private key p to the FPGA. "
            "The FPGA encrypts each bit as c = q·p + 2r + m with random q and r.\n\n"
            "2. Send to Server: the PC sends only the ciphertexts and the public value x0. "
            "The FPGA computes c5 = c5·(c6 + 1) mod x0 for each character. "
            "This is b5 = b5 AND (NOT b6), which makes lowercase letters uppercase.\n\n"
            "3. Decrypt: the PC computes (c mod p) mod 2 for each ciphertext.\n\n"
            "This scheme is not secure. It is for learning only.")

    def show_about(self):
        messagebox.showinfo("About", f"{APP_TITLE}\n\nToy homomorphic encryption on an FPGA.")

    def on_exit(self):
        if self.link:
            self.link.close()
        self.destroy()


def main():
    parser = argparse.ArgumentParser(description=APP_TITLE)
    parser.add_argument("--port", help="serial port, for example COM5")
    parser.add_argument("--sim", action="store_true", help="use the simulated FPGA")
    args = parser.parse_args()

    port = fs.SIMULATED_PORT if args.sim else args.port
    app = App(port=port)
    app.mainloop()


if __name__ == "__main__":
    main()
