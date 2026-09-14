#!/usr/bin/python3
#
# systemd's `Accept=no` socket activation, in forty lines, for a test that
# cannot reach systemd.
#
#   dev/socket-activate.py <socket path> <command…>
#
# The sandbox the F5 suite runs in has a tmpfs over /run and no connection to
# the system manager, so `systemctl start omarchy-faced.socket` is not available
# there -- and the properties this phase has to prove are properties of that
# model: the daemon is handed a LISTENING socket on fd 3, it exits when idle,
# the next connection starts it again, and a connection that arrives while it is
# exiting must still be answered rather than left pending.
#
# So this does what systemd does, and nothing else:
#
#   * create the listening socket once, mode 0666, and keep it for ever;
#   * wait for a connection, WITHOUT accepting it;
#   * start the daemon with LISTEN_FDS=1, LISTEN_PID=<its pid> and the socket on
#     fd 3, exactly as sd_listen_fds(3) expects;
#   * wait for it to exit, and go back to waiting.
#
# It prints one line per activation to stderr, which is how the suite counts
# them. SIGTERM stops it.

import os
import select
import signal
import socket
import sys

if len(sys.argv) < 3:
    print("usage: socket-activate.py <socket path> <command…>", file=sys.stderr)
    sys.exit(2)

path = sys.argv[1]
command = sys.argv[2:]

if os.path.exists(path):
    os.unlink(path)
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
os.chmod(path, 0o666)
server.listen(64)
print("ACTIVATOR listening %s" % path, file=sys.stderr, flush=True)

running = True


def stop(_number, _frame):
    global running
    running = False


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)

activations = 0
while running:
    try:
        ready, _, _ = select.select([server], [], [], 0.5)
    except OSError:
        break
    if not ready:
        continue

    activations += 1
    print("ACTIVATOR start %d" % activations, file=sys.stderr, flush=True)
    child = os.fork()
    if child == 0:
        # The child becomes the daemon. fd 3 is the listening socket, and
        # LISTEN_PID has to be the pid that will run it -- which is only knowable
        # here, after the fork.
        os.dup2(server.fileno(), 3)
        os.set_inheritable(3, True)
        os.environ["LISTEN_FDS"] = "1"
        os.environ["LISTEN_PID"] = str(os.getpid())
        os.environ["LISTEN_FDNAMES"] = "connection"
        os.execv(command[0], command)
        os._exit(127)
    # The daemon's pid, said out loud: a test that needs to signal it cannot find
    # it by name, because this process's own argv ends in the same path.
    print("ACTIVATOR pid %d" % child, file=sys.stderr, flush=True)
    _, status = os.waitpid(child, 0)
    print("ACTIVATOR exit %d status %d" % (activations, status), file=sys.stderr, flush=True)

server.close()
try:
    os.unlink(path)
except OSError:
    pass
