#!/usr/bin/env python3
"""Relays the Debug Adapter Protocol between VS Code (on Linux) and vsdbg (in a
Windows VM, reached over ssh), translating source paths.

vsdbg on Windows rejects breakpoints with Linux paths ("Incorrect breakpoint
request format"). Builds made for the VM (Winvm.targets) have their source
paths in the PDB as C:\\winvm-linux\\home/... (PathMap), so:
  VS Code -> vsdbg   "path": "/home/me/src/A.cs"      -> "C:\\winvm-linux\\home\\me\\src\\A.cs"
  vsdbg -> VS Code   "path": "C:\\winvm-linux\\home..." -> "/home/me/src/A.cs"
Everything else passes unchanged. WINVM_DAP_LOG=FILE (e.g. pipeEnv in
launch.json) logs every message as relayed, for troubleshooting.

Usage (VS Code's pipeTransport): pipeProgram python3, pipeArgs
  [-I, .../dap-pathmap.py, ssh, SSH-ARGS...]; VS Code appends the vsdbg command.
"""
import json
import os
import subprocess
import sys
import threading

PREFIX = 'C:\\winvm-linux'


def to_windows(p):
    return PREFIX + p.replace('/', '\\') if p.startswith('/') else p


def to_linux(p):
    # vsdbg answers with either separator (C:/winvm-linux/home/... in stack frames)
    q = p.replace('\\', '/')
    if q[:len(PREFIX) + 1].lower() == PREFIX.replace('\\', '/').lower() + '/':
        return q[len(PREFIX):]
    return p


def walk(v, conv):
    if isinstance(v, dict):
        return {k: (conv(x) if k == 'path' and isinstance(x, str) else walk(x, conv)) for k, x in v.items()}
    if isinstance(v, list):
        return [walk(x, conv) for x in v]
    return v


def read_message(stream):
    """One DAP message (headers + body) or None at the end."""
    length = None
    while True:
        line = stream.readline()
        if not line:
            return None
        line = line.rstrip(b'\r\n')
        if not line:
            break
        name, _, value = line.partition(b':')
        if name.strip().lower() == b'content-length':
            length = int(value.strip())
    if length is None:
        return None
    body = b''
    while len(body) < length:
        chunk = stream.read(length - len(body))
        if not chunk:
            return None
        body += chunk
    return body


LOG = None
LOG_LOCK = threading.Lock()


def log(direction, body):
    if LOG:
        with LOG_LOCK:
            LOG.write(direction + ' ' + body.decode('utf-8', 'replace') + '\n')
            LOG.flush()


def pump(src, dst, conv, direction):
    try:
        while True:
            body = read_message(src)
            if body is None:
                break
            try:
                body = json.dumps(walk(json.loads(body), conv), ensure_ascii=False, separators=(',', ':')).encode('utf-8')
            except ValueError:
                pass   # not JSON: pass it on as it came
            log(direction, body)
            dst.write(b'Content-Length: %d\r\n\r\n' % len(body) + body)
            dst.flush()
    except (BrokenPipeError, OSError):
        pass
    finally:
        try:
            dst.close()
        except OSError:
            pass


def main():
    if len(sys.argv) < 2:
        sys.exit('usage: dap-pathmap.py COMMAND [ARGS...]   (e.g. ssh ... C:\\vsdbg\\vsdbg.exe --interpreter=vscode)')
    # VS Code joins the vsdbg command line into the last argument (quoteArgs false);
    # ssh passes it on to the VM's shell as it is.
    global LOG
    if os.environ.get('WINVM_DAP_LOG'):
        LOG = open(os.environ['WINVM_DAP_LOG'], 'a', encoding='utf-8')
    child = subprocess.Popen(sys.argv[1:], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    up = threading.Thread(target=pump, args=(sys.stdin.buffer, child.stdin, to_windows, '->'), daemon=True)
    up.start()
    pump(child.stdout, sys.stdout.buffer, to_linux, '<-')
    sys.exit(child.wait())


if __name__ == '__main__':
    main()
