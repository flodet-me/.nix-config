"""Minimal QMP client: qmp.py SOCKET COMMAND [JSON_ARGS]

Prints the command's return value (strings raw, everything else as JSON).
`hmp "<monitor command>"` is shorthand for human-monitor-command.
"""
import json
import os
import socket
import sys


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    path, cmd = sys.argv[1], sys.argv[2]
    if cmd == "hmp":
        cmd, args = "human-monitor-command", {"command-line": sys.argv[3]}
    else:
        args = json.loads(sys.argv[3]) if len(sys.argv) > 3 else None

    sock = socket.socket(socket.AF_UNIX)
    # Connect relative to the socket dir: AF_UNIX paths are limited to ~108 bytes.
    os.chdir(os.path.dirname(os.path.abspath(path)))
    sock.connect(os.path.basename(path))
    f = sock.makefile("rw")

    def call(execute, arguments=None):
        msg = {"execute": execute}
        if arguments is not None:
            msg["arguments"] = arguments
        f.write(json.dumps(msg) + "\n")
        f.flush()
        while True:
            line = f.readline()
            if not line:
                sys.exit("qmp: connection closed")
            reply = json.loads(line)
            if "return" in reply or "error" in reply:
                return reply

    f.readline()  # greeting
    call("qmp_capabilities")
    reply = call(cmd, args)
    if "error" in reply:
        sys.exit("qmp: " + reply["error"].get("desc", str(reply["error"])))
    ret = reply["return"]
    if isinstance(ret, str):
        sys.stdout.write(ret)
        # HMP reports failures as text, not as QMP errors.
        if cmd == "human-monitor-command" and ret.lstrip().lower().startswith("error"):
            sys.exit(1)
    elif ret != {}:
        print(json.dumps(ret, indent=2))


if __name__ == "__main__":
    main()
