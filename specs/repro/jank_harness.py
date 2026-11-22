"""Drive the real jank for the reproduction scripts: run jank commands, and
start an nREPL server and talk to it over bencode. (The conformance harnesses,
which used it too, are jank code now: src/jank_specs/harness.jank.)

Only the standard library is used. jank is `/opt/homebrew/bin/jank` unless
`JANK` is set.
"""

import json
import os
import re
import select
import socket
import subprocess
import tempfile
import threading
import time

JANK = os.environ.get("JANK", "jank")


# Bencode.

def bencode(x):
    if isinstance(x, bool):
        raise TypeError("bencode has no booleans")
    if isinstance(x, int):
        return b"i%de" % x
    if isinstance(x, str):
        x = x.encode()
    if isinstance(x, bytes):
        return b"%d:%s" % (len(x), x)
    if isinstance(x, (list, tuple)):
        return b"l" + b"".join(bencode(i) for i in x) + b"e"
    if isinstance(x, dict):
        items = sorted((k.encode() if isinstance(k, str) else k, v) for k, v in x.items())
        return b"d" + b"".join(bencode(k) + bencode(v) for k, v in items) + b"e"
    raise TypeError(f"can't bencode {x!r}")


def bdecode(b, i=0):
    """Decodes one value from `b` at `i`, returning (value, next index).
    Raises IndexError or ValueError if `b` holds an incomplete value."""
    c = b[i:i + 1]
    if c == b"i":
        j = b.index(b"e", i)
        return int(b[i + 1:j]), j + 1
    if c == b"l":
        i += 1
        r = []
        while b[i:i + 1] != b"e":
            if i >= len(b):
                raise IndexError("incomplete list")
            v, i = bdecode(b, i)
            r.append(v)
        return r, i + 1
    if c == b"d":
        i += 1
        r = {}
        while b[i:i + 1] != b"e":
            if i >= len(b):
                raise IndexError("incomplete dict")
            k, i = bdecode(b, i)
            v, i = bdecode(b, i)
            r[k] = v
        return r, i + 1
    if not c:
        raise IndexError("no data")
    j = b.index(b":", i)
    n = int(b[i:j])
    if j + 1 + n > len(b):
        raise IndexError("incomplete string")
    s = b[j + 1:j + 1 + n]
    try:
        s = s.decode()
    except UnicodeDecodeError:
        pass
    return s, j + 1 + n


# Running jank.

def jank_args(module_path=None, build_dir=None, binary_version=None):
    args = []
    if module_path:
        args += ["--module-path", ":".join(module_path)]
    if build_dir:
        args += ["--build-dir", build_dir]
    if binary_version:
        args += ["--force-binary-version", binary_version]
    return args


def run_jank(args, cwd, timeout=600):
    """Runs `jank args...` in `cwd`, returning (exit code, stdout+stderr)."""
    p = subprocess.run([JANK] + args, cwd=cwd, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, timeout=timeout, text=True)
    return p.returncode, p.stdout


# nREPL.

class Server:
    """A `jank repl` process with its nREPL server, started in `cwd` (it writes
    `.nrepl-port` there, so `cwd` must be a scratch directory)."""

    def __init__(self, cwd, args=(), ready_timeout=300):
        self.cwd = cwd
        # The REPL exits when stdin closes, so keep it open.
        self.proc = subprocess.Popen([JANK] + list(args) + ["repl"], cwd=cwd,
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT)
        self.output = []
        self.port = None
        ready = threading.Event()

        def pump():
            for line in iter(self.proc.stdout.readline, b""):
                text = line.decode(errors="replace")
                self.output.append(text)
                m = re.search(r"nREPL server started on port (\d+)", text)
                if m and not ready.is_set():
                    self.port = int(m.group(1))
                    ready.set()
            ready.set()

        threading.Thread(target=pump, daemon=True).start()
        if not ready.wait(ready_timeout) or self.port is None:
            self.stop()
            raise RuntimeError("nREPL server didn't start:\n" + "".join(self.output))

    def connect(self, timeout=60):
        return Connection(self.port, timeout)

    def stop(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()


class Connection:
    def __init__(self, port, timeout=60):
        self.sock = socket.create_connection(("127.0.0.1", port))
        self.timeout = timeout
        self.buf = b""
        self.next_id = 0

    def send(self, msg):
        """Sends `msg`, adding an id if it has none. Returns the id."""
        msg = dict(msg)
        if "id" not in msg:
            self.next_id += 1
            msg["id"] = str(self.next_id)
        self.sock.sendall(bencode(msg))
        return msg["id"]

    def send_raw(self, data):
        self.sock.sendall(data)

    def read(self, timeout=None):
        """Reads one response, or returns None after `timeout` seconds (or if
        the connection closed)."""
        deadline = time.time() + (self.timeout if timeout is None else timeout)
        while True:
            try:
                v, i = bdecode(self.buf)
                self.buf = self.buf[i:]
                return v
            except (IndexError, ValueError):
                pass
            left = deadline - time.time()
            if left <= 0:
                return None
            r, _, _ = select.select([self.sock], [], [], left)
            if not r:
                return None
            data = self.sock.recv(65536)
            if not data:
                return None
            self.buf += data

    def until_done(self, msg_id, timeout=None):
        """Reads responses until one for `msg_id` has the `done` status.
        Returns (responses, done?)."""
        out = []
        while True:
            r = self.read(timeout)
            if r is None:
                return out, False
            out.append(r)
            if r.get("id") == msg_id and "done" in (r.get("status") or []):
                return out, True

    def request(self, msg, timeout=None):
        """Sends `msg` and returns its responses up to `done`."""
        return self.until_done(self.send(msg), timeout)[0]

    def eval(self, code, timeout=None, **extra):
        resps = self.request(dict(op="eval", code=code, **extra), timeout)
        return {
            "value": [r["value"] for r in resps if "value" in r],
            "out": "".join(r.get("out", "") for r in resps),
            "err": "".join(r.get("err", "") for r in resps),
            "ex": [r["ex"] for r in resps if "ex" in r],
            "status": [r.get("status") for r in resps if "status" in r],
            "responses": resps,
        }

    def close(self):
        self.sock.close()


def scratch_dir(prefix):
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "conformance", "out")
    os.makedirs(root, exist_ok=True)
    return tempfile.mkdtemp(prefix=prefix, dir=root)


def dump(path, obj):
    with open(path, "w") as f:
        json.dump(obj, f, indent=1)
