#!/usr/bin/env python3
"""
Pushes test files to the CameraTransfer app's FTP server, the way the Sony A7CR's "FTP Transfer" does.
Stdlib only (ftplib). Run it from a Mac on the same network as the iPhone (or against the Simulator):

  python3 tools/ftp_push_test.py --host 172.20.10.1 --port 2121 --user camera --password <shown in app>
  python3 tools/ftp_push_test.py --host 127.0.0.1 ... --active      # also try active mode (PORT)

What it checks: login, wrong password rejected, PWD/MKD/CWD, PASV (or PORT) upload, SIZE matches,
LIST/NLST show the file, RNFR/RNTO, DELE of our own upload, '..' traversal rejected, QUIT.
Exit status is 0 only if every check passes.
"""

import argparse
import ftplib
import io
import os
import sys
import time

PASS = 0
FAIL = 0


def check(name, condition, detail=""):
    global PASS, FAIL
    if condition:
        PASS += 1
        print("  ok    %s" % name)
    else:
        FAIL += 1
        print("  FAIL  %s %s" % (name, detail))


def expect_error(name, func, *args):
    try:
        func(*args)
    except ftplib.error_perm as e:
        check(name, True)
        return str(e)
    except ftplib.Error as e:
        check(name, True)
        return str(e)
    check(name, False, "(command unexpectedly succeeded)")
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, default=2121)
    parser.add_argument("--user", default="camera")
    parser.add_argument("--password", required=True)
    parser.add_argument("--active", action="store_true", help="use active mode (PORT) instead of passive")
    parser.add_argument("--size-kb", type=int, default=512, help="size of the test upload")
    parser.add_argument("--keep", action="store_true", help="keep the uploaded file (do not delete it)")
    args = parser.parse_args()

    stamp = time.strftime("%H%M%S")
    folder = "FTPTEST"
    name = "DSC%s.JPG" % stamp
    payload = b"\xff\xd8\xff\xe0" + os.urandom(args.size_kb * 1024) + b"\xff\xd9"

    print("Connecting to %s:%d (%s mode)" % (args.host, args.port, "active" if args.active else "passive"))

    # Wrong password must be rejected.
    bad = ftplib.FTP()
    bad.connect(args.host, args.port, timeout=15)
    expect_error("wrong password rejected", bad.login, args.user, args.password + "x")
    try:
        bad.quit()
    except ftplib.all_errors:
        bad.close()

    ftp = ftplib.FTP()
    welcome = ftp.connect(args.host, args.port, timeout=30)
    check("greeting is 220", welcome.startswith("220"), welcome)
    ftp.login(args.user, args.password)
    check("login", True)
    ftp.set_pasv(not args.active)

    check("SYST", ftp.sendcmd("SYST").startswith("215"))
    check("TYPE I", ftp.voidcmd("TYPE I").startswith("200"))
    check("PWD is /", ftp.pwd() == "/", ftp.pwd())
    try:
        ftp.mkd(folder)
    except ftplib.error_perm:
        pass
    ftp.cwd(folder)
    check("CWD into folder", ftp.pwd() == "/" + folder, ftp.pwd())

    started = time.time()
    reply = ftp.storbinary("STOR " + name, io.BytesIO(payload), blocksize=64 * 1024)
    elapsed = max(time.time() - started, 0.001)
    check("STOR reply 226", reply.startswith("226"), reply)
    print("        uploaded %d KB in %.2fs (%.1f MB/s)" % (len(payload) // 1024, elapsed, len(payload) / elapsed / 1e6))
    check("SIZE matches", ftp.size(name) == len(payload), str(ftp.size(name)))
    check("MDTM works", ftp.sendcmd("MDTM " + name).startswith("213"))

    names = ftp.nlst()
    check("NLST lists the file", name in names, str(names))
    lines = []
    ftp.retrlines("LIST", lines.append)
    check("LIST lists the file", any(line.endswith(" " + name) for line in lines), str(lines))

    renamed = "R" + name
    ftp.rename(name, renamed)
    check("RNFR/RNTO", renamed in ftp.nlst())

    expect_error("'..' traversal rejected (CWD)", ftp.cwd, "../..")
    expect_error("'..' traversal rejected (STOR)", ftp.storbinary, "STOR ../../escape.jpg", io.BytesIO(b"x"))
    expect_error("RETR refused (upload-only server)", ftp.retrbinary, "RETR " + renamed, lambda b: None)

    if not args.keep:
        ftp.delete(renamed)
        check("DELE own upload", renamed not in ftp.nlst())

    check("QUIT", ftp.quit().startswith("221"))
    print("\n%d passed, %d failed" % (PASS, FAIL))
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
