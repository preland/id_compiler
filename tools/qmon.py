#!/usr/bin/env python3
"""Drive the kernel under QEMU: type at it, photograph it, read what it said.

A graphical kernel cannot be tested by reading stdout, and QEMU's text monitor
over a pipe drops input in a way that depends on timing. QMP is a socket and a
JSON protocol, so a test can wait for the machine to be ready, send keys, ask
for the framebuffer, and know each one happened.

    tools/qmon.py build/kernel.elf --wait 2 --type "ls;uname" --shot out.ppm

`--type` writes lines to the guest's serial port, which the kernel reads as
keystrokes -- so a shell can be driven without emulating a keyboard, and the
same run can photograph the screen the shell drew. `--keys` sends real key
events instead, for testing the PS/2 path itself; they are QEMU key names
(`a`, `ret`, `spc`, `minus`), which is what `send-key` takes.

Serial output goes to stdout.
"""
import argparse, json, os, socket, subprocess, sys, tempfile, threading, time


class Qmp:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX)
        for _ in range(200):
            try:
                self.s.connect(path)
                break
            except (FileNotFoundError, ConnectionRefusedError):
                time.sleep(0.05)
        else:
            sys.exit("qmon: QEMU never opened its QMP socket")
        self.f = self.s.makefile("rw")
        self.f.readline()                      # the greeting
        self.cmd("qmp_capabilities")

    def cmd(self, name, **args):
        """Run a monitor command. Returns None if the machine has already
        stopped -- a guest that powers itself off is a normal ending, and
        losing the serial output because the screenshot came too late is not."""
        try:
            self.f.write(json.dumps({"execute": name, "arguments": args}) + "\n")
            self.f.flush()
        except (BrokenPipeError, OSError):
            return None
        while True:
            try:
                line = self.f.readline()
            except OSError:
                return None
            if not line:
                return None
            msg = json.loads(line)
            if "event" in msg:
                continue
            if "error" in msg:
                print(f"qmon: {name}: {msg['error']['desc']}", file=sys.stderr)
                return None
            return msg.get("return")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("kernel")
    ap.add_argument("--wait", type=float, default=2.0,
                    help="seconds to let the machine boot before typing")
    ap.add_argument("--keys", default="",
                    help="QEMU key names, space separated; '|' pauses briefly")
    ap.add_argument("--type", dest="text", default="",
                    help="lines to send to the guest's serial port, ';' separated")
    ap.add_argument("--settle", type=float, default=1.0,
                    help="seconds to wait after the last key")
    ap.add_argument("--shot", help="write the framebuffer here, as PPM")
    ap.add_argument("--serial", help="write the serial output here")
    args = ap.parse_args()

    tmp = tempfile.mkdtemp(prefix="qmon.")
    sock = os.path.join(tmp, "qmp")
    ser = os.path.join(tmp, "ser")
    # A socket rather than a file, so the same port carries what the kernel
    # says and what the test types at it.
    qemu = ["qemu-system-x86_64", "-kernel", args.kernel,
            "-display", "none", "-vga", "std", "-no-reboot",
            "-chardev", f"socket,id=s0,path={ser},server=on,wait=off",
            "-serial", "chardev:s0",
            "-qmp", f"unix:{sock},server,nowait"]
    proc = subprocess.Popen(qemu, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)
    out = []
    try:
        q = Qmp(sock)
        s = connect(ser)
        drain = threading.Thread(target=reader, args=(s, out), daemon=True)
        drain.start()
        time.sleep(args.wait)
        for line in args.text.split(";") if args.text else []:
            s.sendall((line + "\n").encode())
            time.sleep(0.25)
        for tok in args.keys.split():
            if tok == "|":
                time.sleep(0.3)
                continue
            q.cmd("send-key", keys=[{"type": "qcode", "data": tok}])
            time.sleep(0.03)
        time.sleep(args.settle)
        if args.shot:
            q.cmd("screendump", filename=os.path.abspath(args.shot))
        q.cmd("quit")
    finally:
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
    text = b"".join(out).decode(errors="replace")
    if args.serial:
        open(args.serial, "w").write(text)
    sys.stdout.write(text)


def connect(path):
    s = socket.socket(socket.AF_UNIX)
    for _ in range(200):
        try:
            s.connect(path)
            return s
        except (FileNotFoundError, ConnectionRefusedError):
            time.sleep(0.05)
    sys.exit("qmon: QEMU never opened its serial socket")


def reader(s, out):
    while True:
        try:
            b = s.recv(4096)
        except OSError:
            return
        if not b:
            return
        out.append(b)


main()
