#!/usr/bin/python3 -I
#
# Press one key on a throwaway kernel keyboard.
#
#   dev/uinput-key.py <linux key code>...
#
# For dev/g9-enter-live.sh. `wtype` types through the Wayland virtual-keyboard
# protocol, and Hyprland does not run its bindings for that; a uinput device is
# a kernel input device like the laptop's own keyboard, and it does. Needs write
# access to /dev/uinput (logind grants the seat's user an ACL on it). The device
# exists for about two seconds and is destroyed before this exits.

import fcntl
import os
import struct
import sys
import time

UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_DEV_SETUP = 0x405C5503
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502
EV_SYN, EV_KEY = 0, 1


def main():
    keys = [int(k) for k in sys.argv[1:]]
    if not keys:
        print("usage: uinput-key.py <key code>...", file=sys.stderr)
        return 2
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    try:
        fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
        for key in keys:
            fcntl.ioctl(fd, UI_SET_KEYBIT, key)
        # struct uinput_setup: input_id {bustype, vendor, product, version},
        # name[80], ff_effects_max
        fcntl.ioctl(fd, UI_DEV_SETUP,
                    struct.pack("HHHH80sI", 0x03, 0x1234, 0x5678, 1, b"omarchy-face-g9", 0))
        fcntl.ioctl(fd, UI_DEV_CREATE)
        # The compositor has to notice the new device before its keys count.
        time.sleep(1.5)

        def event(kind, code, value):
            os.write(fd, struct.pack("qqHHi", 0, 0, kind, code, value))

        for key in keys:
            event(EV_KEY, key, 1)
            event(EV_SYN, 0, 0)
            time.sleep(0.05)
            event(EV_KEY, key, 0)
            event(EV_SYN, 0, 0)
            time.sleep(0.2)
        time.sleep(0.3)
        fcntl.ioctl(fd, UI_DEV_DESTROY)
    finally:
        os.close(fd)
    return 0


sys.exit(main())
