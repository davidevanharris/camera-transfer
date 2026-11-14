#!/usr/bin/env python3
"""
Mock camera servers for testing CameraTransfer in the iOS Simulator (stdlib only).

  python3 tools/mock_cameras.py                # Ricoh on :8001, OM System on :8002
  python3 tools/mock_cameras.py --big-mb 20    # make "large" files to watch progress bars
  python3 tools/mock_cameras.py --add-every 10 # add a new JPEG every 10 s (to test auto-transfer)
  python3 tools/mock_cameras.py --battery 60   # Ricoh reports 60% (to test the auto-transfer policy)

Then in the app's Settings set:
  Ricoh GR IV base URL      -> http://localhost:8001
  OM System OM-3 base URL   -> http://localhost:8002
(On a real iPhone on the same Wi-Fi as your Mac, use http://<mac-ip>:8001 and start with --host 0.0.0.0.)

Ricoh endpoints (reverse-engineered GR II/III/IV API):
  GET /v1/ping                          {"errCode":200,...}
  GET /v1/props                         JSON with "model", "firmwareVersion", "battery", "storages"
  GET /v1/photos[?storageId=in|sd1]     {"errCode":200,"dirs":[{"name":"100RICOH","files":[...]}]}
                                        (no storageId -> SD card, like a single-storage camera)
  GET /v1/photos/<dir>/<file>?size=thumb|view[&storageId=..]   small JPEG
  GET /v1/photos/<dir>/<file>[?storageId=..]                   full file
  GET /v1/device/wlan/finish            {"errCode":200}

OM System / Olympus endpoints (OI.Share API; requests must send User-Agent "OI.Share v2"):
  GET /get_caminfo.cgi                  XML with <model>
  GET /switch_cammode.cgi?mode=play
  GET /get_imglist.cgi?DIR=/DCIM        VER_100 + "dir,name,size,attrib,date,time" lines
  GET /get_thumbnail.cgi?DIR=<path>     small JPEG
  GET /DCIM/<folder>/<file>             full file
"""

import argparse
import base64
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

# A real 64x48 baseline JPEG (generated once and embedded so no image library is needed).
TINY_JPEG = base64.b64decode(
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAA0JCgsKCA0LCgsODg0PEyAVExISEyccHhcgLikxMC4pLSwzOko+MzZGNywtQFdBRkxOUlNSMj5aYVpQYEpRUk//"
    "2wBDAQ4ODhMREyYVFSZPNS01T09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0//wAARCAAwAEADASIAAhEBAxEB/8QA"
    "HwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkK"
    "FhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXG"
    "x8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAEC"
    "AxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOE"
    "hYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDOoor1+uOn"
    "T5z3sTifYW0vc8gor1+itPq/mcv9pf3fx/4B5BRXr9eWax/yGb7/AK+JP/QjWdSnydTpw2K9u2rWsU6KKKyOwK9fryCvU/7V03/oIWn/AH+X/Guig0rnmZjF"
    "vlsu/wChcoqn/aum/wDQQtP+/wAv+NH9q6b/ANBC0/7/AC/410XR5ns5di5Xlmsf8hm+/wCviT/0I16P/aum/wDQQtP+/wAv+Neb6q6yateOjBkadyrA5BG4"
    "8isK7TSPQy6LUpXRUooormPWCiiigAooooAKKKKACiiigD//2Q=="
)

OI_SHARE_UA = "OI.Share v2"


def fat_date(year, month, day):
    return ((year - 1980) << 9) | (month << 5) | day


def fat_time(hour, minute, second):
    return (hour << 11) | (minute << 5) | (second // 2)


def make_file(name, big_bytes):
    """Full-size payload: a real JPEG for .JPG, padded with filler to big_bytes if requested."""
    body = TINY_JPEG if name.upper().endswith(".JPG") else (b"MOCKRAW-" + name.encode() + b"\n") * 64
    if big_bytes and len(body) < big_bytes:
        # Padding after the JPEG EOI marker is ignored by decoders.
        body = body + b"\0" * (big_bytes - len(body))
    return body


class Store:
    def __init__(self, big_bytes):
        self.big_bytes = big_bytes
        self.lock = threading.Lock()
        self.battery = 87
        self.next_number = 10
        # storage -> folder -> names. The same filename exists in both storages on purpose.
        self.ricoh = {
            "sd1": {
                "100RICOH": ["R0000001.JPG", "R0000001.DNG", "R0000002.JPG", "R0000003.MOV"],
                "101RICOH": ["R0000004.JPG", "R0000004.DNG"],
            },
            "in": {
                "100RICOH": ["R0000001.JPG"],
            },
        }
        today = time.localtime()
        d = fat_date(today.tm_year, today.tm_mon, today.tm_mday)
        self.om_dirs = {
            "/DCIM/100OMSYS": [
                ("P1010001.JPG", d, fat_time(9, 15, 0)),
                ("P1010001.ORF", d, fat_time(9, 15, 0)),
                ("P1010002.JPG", d, fat_time(9, 16, 30)),
                ("P1010003.MOV", d, fat_time(9, 20, 10)),
            ],
            "/DCIM/101OMSYS": [],  # empty -> 404, like the real cameras
        }
        self.files = {}
        for storage, dirs in self.ricoh.items():
            for folder, names in dirs.items():
                for n in names:
                    self.files[("ricoh", storage, folder, n)] = make_file(n, big_bytes)
        for folder, entries in self.om_dirs.items():
            for n, _, _ in entries:
                self.files[("om", folder, n)] = make_file(n, big_bytes)

    def add_new_shot(self):
        """Simulates a new photo on both cameras (for auto-transfer testing)."""
        with self.lock:
            self.next_number += 1
            n = self.next_number
            ricoh_name = "R%07d.JPG" % n
            self.ricoh["sd1"]["100RICOH"].append(ricoh_name)
            self.files[("ricoh", "sd1", "100RICOH", ricoh_name)] = make_file(ricoh_name, self.big_bytes)
            om_name = "P101%04d.JPG" % n
            now = time.localtime()
            self.om_dirs["/DCIM/100OMSYS"].append(
                (om_name, fat_date(now.tm_year, now.tm_mon, now.tm_mday), fat_time(now.tm_hour, now.tm_min, now.tm_sec)))
            self.files[("om", "/DCIM/100OMSYS", om_name)] = make_file(om_name, self.big_bytes)
        sys.stderr.write("[mock] new shot: %s (Ricoh sd1), %s (OM)\n" % (ricoh_name, om_name))


class BaseHandler(BaseHTTPRequestHandler):
    server_version = "MockCamera/1.0"
    store = None  # set on the subclass
    label = "?"

    def log_message(self, fmt, *args):
        sys.stderr.write("[%s] %s - %s\n" % (self.label, self.address_string(), fmt % args))

    def send_bytes(self, body, content_type="application/octet-stream", status=200, throttle=False):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command == "HEAD":
            return
        if throttle and len(body) > 1_000_000:
            # Stream slowly so progress is visible.
            chunk = 256 * 1024
            for i in range(0, len(body), chunk):
                self.wfile.write(body[i:i + chunk])
                self.wfile.flush()
                time.sleep(0.05)
        else:
            self.wfile.write(body)

    def send_text(self, text, content_type="text/plain", status=200):
        self.send_bytes(text.encode("utf-8"), content_type, status)

    def not_found(self):
        self.send_text("not found\n", status=404)

    def do_HEAD(self):
        self.do_GET()


class RicohHandler(BaseHandler):
    label = "ricoh"

    def do_GET(self):
        url = urlparse(self.path)
        query = parse_qs(url.query)
        path = unquote(url.path)
        store = self.store
        if path == "/v1/ping":
            return self.send_text(json.dumps({"errCode": 200, "errMsg": "OK"}), "application/json")
        if path == "/v1/device/wlan/finish":
            return self.send_text(json.dumps({"errCode": 200, "errMsg": "OK"}), "application/json")
        if path == "/v1/props":
            with store.lock:
                storages = [{"name": name, "equipped": True,
                             "numOfPhotos": sum(1 for d in dirs.values() for f in d if not f.upper().endswith(".MOV")),
                             "numOfMovies": sum(1 for d in dirs.values() for f in d if f.upper().endswith(".MOV"))}
                            for name, dirs in store.ricoh.items()]
            body = {"errCode": 200, "errMsg": "OK", "model": "RICOH GR IV (mock)", "serialNo": "00000001",
                    "firmwareVersion": "1.11", "battery": store.battery, "storages": storages}
            return self.send_text(json.dumps(body), "application/json")
        storage = query.get("storageId", ["sd1"])[0]
        if path == "/v1/photos":
            if storage not in store.ricoh:
                return self.send_text(json.dumps({"errCode": 404, "errMsg": "no such storage"}), "application/json")
            dirs = []
            with store.lock:
                for folder, names in store.ricoh[storage].items():
                    files = []
                    for i, n in enumerate(names):
                        # Mix plain strings and objects, as different firmware versions do.
                        if i % 2 == 0:
                            files.append(n)
                        else:
                            files.append({"n": n, "s": len(store.files[("ricoh", storage, folder, n)])})
                    dirs.append({"name": folder, "files": files})
            return self.send_text(json.dumps({"errCode": 200, "errMsg": "OK", "dirs": dirs}), "application/json")
        parts = path.strip("/").split("/")
        if len(parts) == 4 and parts[0] == "v1" and parts[1] == "photos":
            folder, name = parts[2], parts[3]
            key = ("ricoh", storage, folder, name)
            if key not in store.files:
                return self.not_found()
            size = query.get("size", [None])[0]
            if size in ("thumb", "view"):
                if name.upper().endswith(".MOV"):
                    return self.not_found() if size == "thumb" else self.send_bytes(TINY_JPEG, "image/jpeg")
                return self.send_bytes(TINY_JPEG, "image/jpeg")
            ctype = "image/jpeg" if name.upper().endswith(".JPG") else "application/octet-stream"
            return self.send_bytes(store.files[key], ctype, throttle=True)
        return self.not_found()


class OlympusHandler(BaseHandler):
    label = "om"

    def do_GET(self):
        if self.headers.get("User-Agent", "") != OI_SHARE_UA:
            return self.send_text("User-Agent must be '%s'\n" % OI_SHARE_UA, status=400)
        url = urlparse(self.path)
        query = parse_qs(url.query)
        path = unquote(url.path)
        if path == "/get_caminfo.cgi":
            return self.send_text('<?xml version="1.0"?><caminfo><model>OM-3 (mock)</model></caminfo>', "text/xml")
        if path == "/switch_cammode.cgi":
            if query.get("mode", [""])[0] != "play":
                return self.send_text("bad mode", status=400)
            return self.send_text("")
        if path == "/get_imglist.cgi":
            d = query.get("DIR", [""])[0]
            today = time.localtime()
            date = fat_date(today.tm_year, today.tm_mon, today.tm_mday)
            if d == "/DCIM":
                lines = ["VER_100"] + ["/DCIM,%s,0,16,%d,%d" % (folder.rsplit("/", 1)[1], date, fat_time(8, 0, 0))
                                       for folder in self.store.om_dirs]
                return self.send_text("\r\n".join(lines) + "\r\n")
            if d in self.store.om_dirs:
                with self.store.lock:
                    entries = list(self.store.om_dirs[d])
                if not entries:
                    return self.not_found()
                lines = ["VER_100"]
                for n, fd, ft in entries:
                    size = len(self.store.files[("om", d, n)])
                    lines.append("%s,%s,%d,0,%d,%d" % (d, n, size, fd, ft))
                return self.send_text("\r\n".join(lines) + "\r\n")
            return self.not_found()
        if path == "/get_thumbnail.cgi":
            full = query.get("DIR", [""])[0]
            folder, _, name = full.rpartition("/")
            if ("om", folder, name) not in self.store.files:
                return self.not_found()
            return self.send_bytes(TINY_JPEG, "image/jpeg")
        if path.startswith("/DCIM/"):
            folder, _, name = path.rpartition("/")
            key = ("om", folder, name)
            if key not in self.store.files:
                return self.not_found()
            return self.send_bytes(self.store.files[key], throttle=True)
        return self.not_found()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="127.0.0.1", help="bind address (0.0.0.0 to reach it from a device)")
    parser.add_argument("--ricoh-port", type=int, default=8001)
    parser.add_argument("--om-port", type=int, default=8002)
    parser.add_argument("--big-mb", type=float, default=0, help="pad full-size files to this many MB")
    parser.add_argument("--add-every", type=float, default=0, help="add a new JPEG to both cameras every N seconds")
    parser.add_argument("--battery", type=int, default=87, help="battery percentage the Ricoh mock reports")
    args = parser.parse_args()

    store = Store(int(args.big_mb * 1024 * 1024))
    store.battery = args.battery
    RicohHandler.store = store
    OlympusHandler.store = store

    servers = [
        ThreadingHTTPServer((args.host, args.ricoh_port), RicohHandler),
        ThreadingHTTPServer((args.host, args.om_port), OlympusHandler),
    ]
    for s in servers:
        threading.Thread(target=s.serve_forever, daemon=True).start()
    print("Ricoh mock     on http://%s:%d" % (args.host, args.ricoh_port))
    print("OM System mock on http://%s:%d" % (args.host, args.om_port))
    if args.add_every > 0:
        def adder():
            while True:
                time.sleep(args.add_every)
                store.add_new_shot()
        threading.Thread(target=adder, daemon=True).start()
        print("Adding a new JPEG every %.0f s" % args.add_every)
    print("Ctrl-C to stop.")
    sys.stdout.flush()
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass
    for s in servers:
        s.shutdown()


if __name__ == "__main__":
    main()
