#!/usr/bin/python3 -I

"""Run one PAM service's auth stack and say what libpam did with it.

    dev/pam-probe.py <service> <user>

Prints the numeric result of `pam_authenticate` and its text, one line. The
point is to ask the INSTALLED libpam rather than to read its documentation:
`pam.conf(5)` describes `success=N` as "jump over the next N modules", and what
the dispatcher actually does with a jump that runs off the end of a chain is not
in that sentence. dev/f4b-pam-semantics.sh is the caller, and the reason is that
Face's gate line is `[success=1 default=ignore]` -- a jump -- on a stack that
decides whether anybody can become root on this machine.

No prompting: the stacks it is pointed at are built from pam_exec, pam_permit and
pam_deny, none of which converse. The conversation function is still implemented
properly, because a PAM module is free to call it and a null one would be a
segfault rather than a test result.
"""

import ctypes
import sys

PAM_SUCCESS = 0

libpam = ctypes.CDLL("libpam.so.0")
libc = ctypes.CDLL("libc.so.6")


class PamMessage(ctypes.Structure):
    _fields_ = [("msg_style", ctypes.c_int), ("msg", ctypes.c_char_p)]


class PamResponse(ctypes.Structure):
    _fields_ = [("resp", ctypes.c_char_p), ("resp_retcode", ctypes.c_int)]


CONV_FUNC = ctypes.CFUNCTYPE(
    ctypes.c_int,
    ctypes.c_int,
    ctypes.POINTER(ctypes.POINTER(PamMessage)),
    ctypes.POINTER(ctypes.POINTER(PamResponse)),
    ctypes.c_void_p,
)


class PamConv(ctypes.Structure):
    _fields_ = [("conv", CONV_FUNC), ("appdata_ptr", ctypes.c_void_p)]


libc.calloc.restype = ctypes.c_void_p
libc.calloc.argtypes = [ctypes.c_size_t, ctypes.c_size_t]
libc.strdup.restype = ctypes.c_void_p
libc.strdup.argtypes = [ctypes.c_char_p]

libpam.pam_start.restype = ctypes.c_int
libpam.pam_start.argtypes = [ctypes.c_char_p, ctypes.c_char_p,
                             ctypes.POINTER(PamConv), ctypes.POINTER(ctypes.c_void_p)]
libpam.pam_authenticate.restype = ctypes.c_int
libpam.pam_authenticate.argtypes = [ctypes.c_void_p, ctypes.c_int]
libpam.pam_end.restype = ctypes.c_int
libpam.pam_end.argtypes = [ctypes.c_void_p, ctypes.c_int]
libpam.pam_strerror.restype = ctypes.c_char_p
libpam.pam_strerror.argtypes = [ctypes.c_void_p, ctypes.c_int]


def conversation(count, messages, response, appdata):
    # An empty answer to every message. PAM frees this array and each `resp`, so
    # both have to come from the C allocator.
    buffer = libc.calloc(count, ctypes.sizeof(PamResponse))
    if not buffer:
        return 5  # PAM_BUF_ERR
    array = ctypes.cast(buffer, ctypes.POINTER(PamResponse))
    for index in range(count):
        array[index].resp = ctypes.cast(libc.strdup(b""), ctypes.c_char_p)
        array[index].resp_retcode = 0
    response[0] = array
    return PAM_SUCCESS


def main(argv):
    if len(argv) != 2:
        sys.stderr.write(__doc__)
        return 2
    service, user = argv
    handle = ctypes.c_void_p()
    conv = PamConv(CONV_FUNC(conversation), None)
    status = libpam.pam_start(service.encode(), user.encode(),
                              ctypes.byref(conv), ctypes.byref(handle))
    if status != PAM_SUCCESS:
        print("start-failed %d" % status)
        return 1
    status = libpam.pam_authenticate(handle, 0)
    text = libpam.pam_strerror(handle, status)
    libpam.pam_end(handle, status)
    print("%d %s" % (status, (text or b"?").decode("utf-8", "replace")))
    return 0


sys.exit(main(sys.argv[1:]))
