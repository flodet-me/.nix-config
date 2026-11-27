"""Minimal QMP client: qmp.py SOCKET COMMAND [JSON_ARGS]

Prints the command's return value (strings raw, everything else as JSON).
`hmp "<monitor command>"` is shorthand for human-monitor-command.
`job COMMAND [JSON_ARGS]` runs a job command (e.g. snapshot-save) and waits
for it to finish.
"""
import json
import os
import socket
import sys


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    path, cmd = sys.argv[1], sys.argv[2]
    job = cmd == "job"
    if job:
        if len(sys.argv) < 4:
            sys.exit(__doc__)
        cmd = sys.argv[3]
        args = json.loads(sys.argv[4]) if len(sys.argv) > 4 else {}
        args["job-id"] = "winvm-%d" % os.getpid()
    elif cmd == "hmp":
        cmd, args = "human-monitor-command", {"command-line": sys.argv[3]}
    else:
        args = json.loads(sys.argv[3]) if len(sys.argv) > 3 else None

    sock = socket.socket(socket.AF_UNIX)
    # Connect relative to the socket dir: AF_UNIX paths are limited to ~108 bytes.
    os.chdir(os.path.dirname(os.path.abspath(path)))
    sock.connect(os.path.basename(path))
    f = sock.makefile("rw")
    events = []

    def read():
        line = f.readline()
        if not line:
            sys.exit("qmp: connection closed")
        return json.loads(line)

    def call(execute, arguments=None):
        msg = {"execute": execute}
        if arguments is not None:
            msg["arguments"] = arguments
        f.write(json.dumps(msg) + "\n")
        f.flush()
        while True:
            reply = read()
            if "return" in reply or "error" in reply:
                return reply
            events.append(reply)

    f.readline()  # greeting
    call("qmp_capabilities")
    reply = call(cmd, args)
    if "error" in reply:
        sys.exit("qmp: " + reply["error"].get("desc", str(reply["error"])))

    if job:
        def concluded(ev):
            return (ev.get("event") == "JOB_STATUS_CHANGE"
                    and ev["data"]["id"] == args["job-id"]
                    and ev["data"]["status"] == "concluded")
        while not any(concluded(ev) for ev in events):
            events.append(read())
        info = [j for j in call("query-jobs")["return"] if j["id"] == args["job-id"]]
        call("job-dismiss", {"id": args["job-id"]})
        if info and "error" in info[0]:
            sys.exit("qmp: %s: %s" % (cmd, info[0]["error"]))
        return

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
