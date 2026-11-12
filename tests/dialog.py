#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 The Blueberry Pie OS Authors
"""
Answer a program's prompts, or a serial console's.

usage: dialog.py [--timeout S] -- COMMAND...
       dialog.py [--timeout S] --log FILE --input FIFO

The steps come from standard input, one per line:

  expect REGEX  wait until the output since the last match matches REGEX
  send TEXT     send TEXT and a newline
  secret VAR    send the value of the environment variable VAR and a newline
  status N      close the input and wait for COMMAND; it must exit with N
  failure       close the input and wait for COMMAND; it must exit nonzero

With COMMAND, the output is its standard output and error. With --log, it
is what FILE gains from the start, and the input goes to FIFO. Each wait
ends after S seconds, 60 by default. The output goes to standard output.
The exit status is 0 if every step succeeded and 1 if not.
"""
import argparse
import os
import re
import subprocess
import sys
import threading
import time


class Command:
    def __init__(self, argv):
        self.proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT)
        self.buf = bytearray()
        self.lock = threading.Lock()
        self.thread = threading.Thread(target=self.read, daemon=True)
        self.thread.start()

    def read(self):
        while True:
            data = self.proc.stdout.read1(4096)
            if not data:
                break
            with self.lock:
                self.buf += data

    def output(self):
        with self.lock:
            return bytes(self.buf)

    def alive(self):
        return self.proc.poll() is None

    def send(self, data):
        self.proc.stdin.write(data)
        self.proc.stdin.flush()

    def finish(self, timeout):
        try:
            self.proc.stdin.close()
        except BrokenPipeError:
            pass
        try:
            status = self.proc.wait(timeout)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
            status = None
        self.thread.join(5)
        return status


class Console:
    def __init__(self, log, fifo):
        self.log = log
        self.start = os.path.getsize(log)
        self.fd = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)

    def output(self):
        with open(self.log, "rb") as f:
            f.seek(self.start)
            return f.read()

    def alive(self):
        return True

    def send(self, data):
        for i in range(0, len(data), 64):
            os.write(self.fd, data[i:i + 64])
            time.sleep(0.05)

    def finish(self, timeout):
        return None


def main():
    ap = argparse.ArgumentParser(usage=__doc__.strip().split("\n\n")[1])
    ap.add_argument("--timeout", type=float, default=60)
    ap.add_argument("--log")
    ap.add_argument("--input")
    ap.add_argument("command", nargs="*")
    args = ap.parse_args()
    if bool(args.log) != bool(args.input) or bool(args.log) == bool(args.command):
        ap.error("give COMMAND, or --log and --input")
    steps = [line.rstrip("\n") for line in sys.stdin if line.strip()]
    target = Console(args.log, args.input) if args.log else Command(args.command)
    pos, ok, why = 0, True, ""
    for step in steps:
        verb, _, arg = step.partition(" ")
        if verb == "expect":
            pattern = re.compile(arg.encode())
            end = time.monotonic() + args.timeout
            while True:
                m = pattern.search(target.output(), pos)
                if m:
                    pos = m.end()
                    break
                if time.monotonic() > end or not target.alive():
                    m = pattern.search(target.output(), pos)
                    if m:
                        pos = m.end()
                        break
                    ok, why = False, "no match for %r" % arg
                    break
                time.sleep(0.1)
        elif verb == "send":
            target.send(arg.encode() + b"\n")
        elif verb == "secret":
            value = os.environ.get(arg)
            if value is None:
                ok, why = False, "%s is not set" % arg
            else:
                target.send(value.encode() + b"\n")
        elif verb in ("status", "failure"):
            status = target.finish(args.timeout)
            if status is None:
                ok, why = False, "no exit status"
            elif verb == "status" and status != int(arg):
                ok, why = False, "exit status %d, not %s" % (status, arg)
            elif verb == "failure" and status == 0:
                ok, why = False, "exit status 0"
        else:
            ok, why = False, "unknown step %r" % step
        if not ok:
            break
    if isinstance(target, Command) and target.alive():
        target.finish(5)
    sys.stdout.write(target.output().decode(errors="replace").replace("\r", ""))
    if not ok:
        sys.stdout.write("\ndialog.py: %s\n" % why)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
