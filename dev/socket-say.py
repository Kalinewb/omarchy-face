#!/usr/bin/python3
#
# One request on omarchy-faced's socket, for tests that need the protocol rather
# than the two shipped clients (plan-engine.md §6.1).
#
#   dev/socket-say.py <socket> 'VERIFY-PERSON anna'        send, print the answer
#   dev/socket-say.py <socket> 'VERIFY-PERSON anna' --hangup-after 1
#                                                          send, then close the
#                                                          socket after N seconds
#                                                          without reading
#   dev/socket-say.py <socket> --connect-only --hold 5      connect and say nothing
#
# `--hangup-after` is how the E11 test is written: the daemon polls the client
# while the engine runs and must kill compare.py when it goes. `--connect-only`
# is the backlog: a connection that exists but has not been accepted is what a
# daemon exiting without draining leaves behind.

import socket
import sys
import time

argv = sys.argv[1:]
if not argv:
    print("usage: socket-say.py <socket> [request] [--hangup-after N] [--connect-only] [--hold N]",
          file=sys.stderr)
    sys.exit(2)

path = argv[0]
request = ""
hangup = None
hold = 0.0
connect_only = False

index = 1
while index < len(argv):
    word = argv[index]
    if word == "--hangup-after":
        index += 1
        hangup = float(argv[index])
    elif word == "--hold":
        index += 1
        hold = float(argv[index])
    elif word == "--connect-only":
        connect_only = True
    else:
        request = word
    index += 1

connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    connection.connect(path)
except OSError as problem:
    print("CONNECT-FAILED %s" % problem.strerror)
    sys.exit(3)

if connect_only:
    time.sleep(hold)
    connection.close()
    print("CONNECTED")
    sys.exit(0)

connection.sendall((request + "\n").encode())

if hangup is not None:
    time.sleep(hangup)
    # Closed without reading the answer: from the daemon's side this is
    # indistinguishable from the client having been killed, which is the point.
    connection.close()
    print("HUNG-UP")
    sys.exit(0)

connection.settimeout(20)
blob = b""
try:
    while b"\n" not in blob and len(blob) < 256:
        piece = connection.recv(256)
        if not piece:
            break
        blob += piece
except OSError as problem:
    print("RECV-FAILED %s" % problem.strerror)
    sys.exit(4)

answer = blob.split(b"\n", 1)[0].decode("utf-8", "replace")
print(answer if answer else "NOTHING")
sys.exit(0)
