#!/usr/bin/env python3

"""Drive one `enroll-session` from a script, and say what happened.

    dev/enroll-client.py <script> -- <command…>

This is the GUI's half of `plan-merged.md §2.4` with the GUI taken out: it
writes JSON command lines on the session's stdin and reads JSON event lines back,
so the protocol can be tested without a shell, a popup or a camera preview.

The script is one directive per line:

    await <event> [seconds]   block until that event arrives (default 30 s)
    awaitany <a,b> [seconds]  block until any one of them arrives
    send <json>               one command line
    eof                       close stdin -- the only cancel (§2 rule 7)
    sleep <seconds>           wait, without sending anything

Output is one line per thing that happened, in order:

    EV <json>          an event from the session
    AWAIT <event> <ms> how long that event took to arrive, from the moment the
                       previous directive finished -- which is what the phase-4
                       gate's "a slow polkit dialog still yields a full 3-2-1"
                       is measured with
    ERR <line>         a line of the session's stderr (prose, §2 rule 3)
    EXIT <code>
"""

import json
import subprocess
import sys
import threading
import time


def main(argv):
    if "--" not in argv:
        sys.stderr.write(__doc__)
        return 2
    split = argv.index("--")
    script_path, command = argv[0], argv[split + 1:]
    directives = [line.strip() for line in open(script_path)]

    proc = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE)

    events = []
    seen = threading.Condition()

    def pump_stdout():
        for raw in proc.stdout:
            line = raw.decode("utf-8", "replace").strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except ValueError:
                print("ERR not-json: " + line, flush=True)
                continue
            with seen:
                events.append(event)
                seen.notify_all()
            print("EV " + json.dumps(event, separators=(",", ":")), flush=True)

    def pump_stderr():
        for raw in proc.stderr:
            print("ERR " + raw.decode("utf-8", "replace").rstrip(), flush=True)

    threads = [threading.Thread(target=pump_stdout, daemon=True),
               threading.Thread(target=pump_stderr, daemon=True)]
    for thread in threads:
        thread.start()

    def wait_for(names, seconds):
        deadline = time.time() + seconds
        with seen:
            while True:
                for event in events:
                    for name in names:
                        # `error` covers both shapes: the session's own
                        # {"event":"error"} and a caller-check {"error":…}.
                        if event.get("event") == name or (name == "error" and "error" in event):
                            return True
                if time.time() >= deadline:
                    return False
                seen.wait(0.05)

    for directive in directives:
        if not directive or directive.startswith("#"):
            continue
        verb, _, rest = directive.partition(" ")
        if verb in ("await", "awaitany"):
            parts = rest.split()
            names = parts[0].split(",")
            seconds = float(parts[1]) if len(parts) > 1 else 30.0
            started = time.time()
            ok = wait_for(names, seconds)
            print("AWAIT %s %d" % (parts[0], round((time.time() - started) * 1000)), flush=True)
            if not ok:
                print("EXIT timeout", flush=True)
                proc.kill()
                return 1
        elif verb == "send":
            try:
                proc.stdin.write(rest.encode("utf-8") + b"\n")
                proc.stdin.flush()
            except (BrokenPipeError, ValueError):
                print("ERR the session closed its stdin", flush=True)
        elif verb == "eof":
            try:
                proc.stdin.close()
            except (BrokenPipeError, ValueError):
                pass
        elif verb == "sleep":
            time.sleep(float(rest))
        else:
            sys.stderr.write("unknown directive: %s\n" % directive)
            proc.kill()
            return 2

    try:
        code = proc.wait(timeout=60)
    except subprocess.TimeoutExpired:
        proc.kill()
        code = "hung"
    for thread in threads:
        thread.join(timeout=2)
    print("EXIT %s" % code, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
