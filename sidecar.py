#!/usr/bin/env python3
"""
neocursor.nvim sidecar — persistent stdio server speaking Cursor's StreamCpp.

Protocol (one JSON object per line, both directions):
  in : {"id":N,"path":str,"content":str,"line":int0,"col":int0,"language":str,
        "additional_files"?:[{path,is_open,last_viewed_at?,ranges:[{start,stop,content}]}],
        "linter_errors"?:{path,errors:[{message,source?,severity,range:{sl,sc,el,ec}}]},
        "file_diff_histories"?:[{file_name,diff_history:[str],diff_history_timestamps:[ms]}]}
  Request purpose: "foreground" (default) or "prefetch"; each has one worker.
  Config advertises {"config":{"protocol":2,...}} before requests are served.
  Cancellation (protocol 2): {"op":"cancel","id":N}
  out: {"id":N,"event":"edit","index":int1,
        "edit":{"text":str,"range":{"start":int1,"endInclusive":int1}}}
       {"id":N,"event":"prediction","prediction":{"path":str,"line":int1}}
       {"id":N,"event":"done"}
       {"id":N,"event":"error","error":str}
       {"id":N,"event":"cancelled","aborted":true}

An edit is emitted only after doneEdit. Indices preserve backend order;
request ranges refer to the original snapshot. Neovim also accepts legacy
single-result replies from custom sidecars.

line/col in the request are 0-indexed (neovim). range in the reply is
1-indexed inclusive (as Cursor's backend returns it).

Launch:  uv run --with 'httpx[http2]' sidecar.py
"""
import io, os, sys, json, base64, time, sqlite3, struct, socket, subprocess, threading
import httpx
import cursor_paths

# Pin the stdio codec instead of inheriting the platform's: Windows text mode
# would rewrite our "\n" record separator to "\r\n" (the client frames replies
# on LF), and a POSIX C locale would give us ASCII, mangling any non-ASCII
# buffer content on the way through.
sys.stdout = io.TextIOWrapper(
    sys.stdout.buffer, encoding="utf-8", newline="\n", line_buffering=True
)
sys.stdin = io.TextIOWrapper(sys.stdin.buffer, encoding="utf-8")

# --- resolver resilience -----------------------------------------------------
# macOS mDNSResponder occasionally negative-caches a CNAME hop (Cursor's hosts
# chain api2 -> api2geo -> api2direct), so getaddrinfo fails while `dig` still
# resolves. Fall back to dig and connect by IP; httpx keeps the hostname for
# SNI/cert verification, so TLS stays valid.
_ORIG_GAI = socket.getaddrinfo


def _dig_ipv4(host: str):
    for cmd in (["dig", "+short", host, "A"], ["host", "-t", "A", host]):
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=3).stdout
        except Exception:
            continue
        for ln in out.splitlines():
            tok = ln.strip().rstrip(".").split()[-1:] or [""]
            ip = tok[0]
            parts = ip.split(".")
            if len(parts) == 4 and all(p.isdigit() for p in parts):
                return ip
    return None


def _getaddrinfo(host, port, *a, **kw):
    try:
        return _ORIG_GAI(host, port, *a, **kw)
    except socket.gaierror:
        ip = _dig_ipv4(host)
        if not ip:
            raise
        return [(socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, "", (ip, int(port or 0)))]


if sys.platform == "darwin":  # the bug is mDNSResponder's; elsewhere getaddrinfo is fine
    socket.getaddrinfo = _getaddrinfo
# -----------------------------------------------------------------------------

# The signed-in session lives in Cursor's user-data dir, which moves per
# platform (macOS Application Support / Linux XDG / Windows APPDATA) —
# cursor_paths resolves it.
URL = "https://api2.cursor.sh/aiserver.v1.AiService/StreamCpp"


def read_token() -> str:
    if not cursor_paths.state_db().is_file():
        raise RuntimeError(cursor_paths.not_found_message())
    con = sqlite3.connect(cursor_paths.state_db_uri(), uri=True)
    row = con.execute(
        "SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken'"
    ).fetchone()
    con.close()
    if not row:
        raise RuntimeError(
            f"no cursorAuth/accessToken in {cursor_paths.state_db()} — is Cursor signed in?"
        )
    return row[0]


def alf(b: bytes) -> bytes:
    o, t = bytearray(b), 0xA5
    for i in range(len(o)):
        o[i] = ((o[i] ^ t) + (i % 256)) & 0xFF
        t = o[i]
    return bytes(o)


def checksum(mid: str, mac: str) -> str:
    ts = int(time.time() * 1000) // 1_000_000
    return base64.b64encode(alf(ts.to_bytes(6, "big"))).decode() + f"{mid}/{mac}"


def frame(b: bytes) -> bytes:
    return b"\x00" + struct.pack(">I", len(b)) + b


def read_session():
    """Token + machine ids from the local Cursor install."""
    tok = read_token()
    sj_path = cursor_paths.storage_json()
    try:
        with open(sj_path, encoding="utf-8") as fh:
            sj = json.load(fh)
    except OSError as e:
        raise RuntimeError(f"cannot read {sj_path}: {e}")
    mid = sj.get("telemetry.machineId")
    if not mid:
        raise RuntimeError(f"no telemetry.machineId in {sj_path} — launch Cursor once")
    # macMachineId is MAC-address-derived, not macOS-specific: VS Code (and so
    # Cursor) writes it everywhere. Fall back to machineId if it's missing.
    return tok, mid, sj.get("telemetry.macMachineId") or mid


TOK = MID = MAC = None
CLIENT = None
HEADERS = {
    "x-cursor-client-version": "1.1.3",
    "x-cursor-client-type": "ide",
    "connect-protocol-version": "1",
    "content-type": "application/connect+json",
}
STREAM_URL = URL


def fetch_config() -> dict:
    url = URL.rsplit("/", 1)[0] + "/CppConfig"
    h = dict(HEADERS)
    h["authorization"] = f"Bearer {TOK}"
    h["x-cursor-checksum"] = checksum(MID, MAC)
    h["content-type"] = "application/json"  # CppConfig is unary, not connect+json
    try:
        r = CLIENT.post(url, content=json.dumps({"model": "", "supportsCpt": True}).encode(), headers=h, timeout=10)
        return r.json() if r.status_code == 200 else {}
    except Exception:
        return {}


def _addl(a: dict) -> dict:
    # reshape a neutral nvim range-bundle into Cursor's AdditionalFile message
    ranges = a.get("ranges") or []
    out = {
        "relativeWorkspacePath": a.get("path") or "untitled",
        "isOpen": bool(a.get("is_open")),
        "visibleRangeContent": [r.get("content", "") for r in ranges],
        "startLineNumberOneIndexed": [r.get("start", 1) for r in ranges],
        "visibleRanges": [
            {
                "startLineNumber": r.get("start", 1),
                "endLineNumberInclusive": r.get("stop", r.get("start", 1)),
            }
            for r in ranges
        ],
    }
    if a.get("last_viewed_at") is not None:
        out["lastViewedAt"] = a["last_viewed_at"]
    return out


def _fdh(h: dict) -> dict:
    # neutral nvim bundle -> Cursor CppFileDiffHistory
    out = {
        "fileName": h.get("file_name") or "untitled",
        "diffHistory": h.get("diff_history") or [],
    }
    ts = h.get("diff_history_timestamps")
    if ts:
        out["diffHistoryTimestamps"] = ts
    return out


def _linter(l: dict) -> dict:
    # neutral nvim bundle -> Cursor LinterErrors (positions are 0-indexed)
    errors = []
    for e in l.get("errors") or []:
        item = {"message": e.get("message", ""), "severity": e.get("severity", 1)}
        if e.get("source"):
            item["source"] = e["source"]
        r = e.get("range")
        if r:
            item["range"] = {
                "startPosition": {"line": r.get("sl", 0), "column": r.get("sc", 0)},
                "endPosition": {"line": r.get("el", 0), "column": r.get("ec", 0)},
            }
        errors.append(item)
    return {"relativeWorkspacePath": l.get("path") or "untitled", "errors": errors}


def complete(req: dict, cancelled=lambda: False, emit=None, bind_response=None):
    body = {
        "currentFile": {
            "relativeWorkspacePath": req.get("path") or "untitled",
            "contents": req["content"],
            "cursorPosition": {"line": req["line"], "column": req["col"]},
            "languageId": req.get("language") or "plaintext",
        },
        "modelName": "",
        "diffHistory": [],
        "supportsCpt": True,       # opt into Cursor Prediction Target (tab-tab chain)
        "supportsCrlfCpt": True,
    }
    adds = req.get("additional_files") or []
    if adds:
        body["additionalFiles"] = [_addl(a) for a in adds]
    fdh = req.get("file_diff_histories") or []
    if fdh:
        body["fileDiffHistories"] = [_fdh(h) for h in fdh]
    lint = req.get("linter_errors")
    if lint and lint.get("errors"):
        body["linterErrors"] = _linter(lint)
    h = dict(HEADERS)
    h["authorization"] = f"Bearer {TOK}"
    h["x-cursor-checksum"] = checksum(MID, MAC)

    # The multidiff model streams a SEQUENCE of edits in one response, each
    # bracketed by beginEdit/doneEdit, plus a cursorPredictionTarget pointing at
    # the chain's first jump. Split them into an ordered list so the client can
    # walk the chain locally (one Tab per edit) with no extra round-trips.
    edits, cur, prediction = [], None, None
    emit = emit or (lambda event: None)

    def flush():
        nonlocal cur
        if cur is not None and (cur["text"] or cur["range"] is not None):
            t = cur["text"]
            if cur["eol"]:  # shouldRemoveLeadingEol: drop the leading newline
                if t.startswith("\r\n"):
                    t = t[2:]
                elif t.startswith("\n"):
                    t = t[1:]
            edit = {"text": t, "range": cur["range"]}
            edits.append(edit)
            emit({"event": "edit", "index": len(edits), "edit": edit})
        cur = None

    def feed(flag, msg):
        nonlocal cur, prediction
        if flag & 0x02:
            trailer = json.loads(msg)
            if trailer.get("error"):
                raise RuntimeError("StreamCpp: " + json.dumps(trailer["error"]))
            return
        if flag & 0x01:
            raise RuntimeError("unsupported compressed Connect frame")
        try:
            j = json.loads(msg)
        except (ValueError, UnicodeDecodeError) as exc:
            raise RuntimeError("invalid StreamCpp JSON frame") from exc
        if j.get("beginEdit"):
            flush()
            cur = {"text": "", "range": None, "eol": False}
        if "text" in j:
            if cur is None:
                cur = {"text": "", "range": None, "eol": False}
            cur["text"] += j.get("text", "")
        rr = j.get("rangeToReplace")
        if rr:
            if cur is None:
                cur = {"text": "", "range": None, "eol": False}
            cur["range"] = {
                "start": rr.get("startLineNumber"),
                "endInclusive": rr.get("endLineNumberInclusive"),
            }
        if j.get("shouldRemoveLeadingEol") and cur is not None:
            cur["eol"] = True
        cpt = j.get("cursorPredictionTarget")
        if cpt and prediction is None:
            prediction = {
                "path": cpt.get("relativePath"),
                "line": cpt.get("lineNumberOneIndexed"),
            }
            emit({"event": "prediction", "prediction": prediction})
        if j.get("doneEdit"):
            flush()

    # Stream the reply and bail between chunks once superseded: exiting the
    # `with` closes the HTTP/2 stream, i.e. Cursor's cancelCpp-on-abort. The
    # connect frames (1B flag + 4B len) can split across chunks, so buffer.
    buf = b""
    with CLIENT.stream(
        "POST", STREAM_URL, content=frame(json.dumps(body).encode()), headers=h
    ) as r:
        if bind_response:
            bind_response(r)
        r.raise_for_status()
        for chunk in r.iter_bytes():
            if cancelled():
                return None
            buf += chunk
            while len(buf) >= 5:
                ln = struct.unpack(">I", buf[1:5])[0]
                if len(buf) < 5 + ln:
                    break
                feed(buf[0], buf[5 : 5 + ln])
                buf = buf[5 + ln :]
    if cancelled():
        return None
    if buf:
        raise RuntimeError("truncated Connect frame")
    # Only doneEdit makes an edit acceptable; an interrupted edit is discarded.
    if cur is not None:
        raise RuntimeError("stream ended before doneEdit")

    first = edits[0] if edits else {"text": "", "range": None}
    return {
        "text": first["text"],
        "range": first["range"],
        "edits": edits,
        "prediction": prediction,
    }


def main():
    global STREAM_URL, TOK, MID, MAC, CLIENT
    try:
        TOK, MID, MAC = read_session()
    except Exception as exc:
        sys.stderr.write(f"neocursor sidecar: {exc}\n")
        raise SystemExit(1)
    CLIENT = httpx.Client(http2=True, timeout=30)
    cfg = fetch_config()
    if cfg.get("cppUrl"):
        STREAM_URL = cfg["cppUrl"].rstrip("/") + "/aiserver.v1.AiService/StreamCpp"
    sys.stderr.write("neocursor sidecar ready\n")
    sys.stderr.flush()
    sys.stdout.write(json.dumps({"config": {
        "protocol": 2,
        "debounce": cfg.get("clientDebounceDurationMillis"),
        "exclude_patterns": cfg.get("excludeRecentlyViewedFilesPatterns") or [],
        "heuristics": cfg.get("heuristics") or [],
        "reject_hard": (cfg.get("recentlyRejectedEditThresholds") or {}).get("hardRejectThreshold"),
        "max_cleared": cfg.get("maxNumberOfClearedSuggestionsSinceLastAccept"),
        "is_fused": cfg.get("isFusedCursorPredictionModel"),
    }}) + "\n")
    sys.stdout.flush()
    # One worker per lane. Pending work is replaceable, so typing cannot create
    # an unbounded number of network threads. Cancellation also closes the
    # active response instead of waiting for the next chunk to arrive.
    wlock = threading.Lock()

    def emit(obj):
        with wlock:
            sys.stdout.write(json.dumps(obj) + "\n")
            sys.stdout.flush()

    lanes = {name: RequestLane(emit) for name in ("foreground", "prefetch")}
    try:
        for line in sys.stdin:
            if not line.strip():
                continue
            try:
                req = json.loads(line)
            except ValueError as exc:
                emit({"id": None, "event": "error", "error": str(exc)})
                continue
            if not isinstance(req, dict):
                emit({"id": None, "event": "error", "error": "request must be an object"})
                continue
            if req.get("op") == "cancel":
                for lane in lanes.values():
                    lane.cancel(req.get("id"))
                continue
            lane = lanes.get(req.get("purpose", "foreground"))
            if lane is None:
                emit({"id": req.get("id"), "event": "error", "error": "unknown request purpose"})
                continue
            lane.submit(req)
    finally:
        for lane in lanes.values():
            lane.close()
        CLIENT.close()


class RequestLane:
    """A single network worker with a newest-wins pending slot."""

    def __init__(self, emit):
        self.emit = emit
        self.condition = threading.Condition()
        self.pending = None
        self.active = None
        self.stopped = False
        self.worker = threading.Thread(target=self.run, daemon=True)
        self.worker.start()

    def _cancel_active(self, rid=None):
        active = self.active
        if active and (rid is None or active["req"].get("id") == rid):
            active["cancelled"].set()
            response = active.get("response")
            if response is not None:
                try:
                    response.close()
                except Exception:
                    pass

    def cancel(self, rid=None):
        with self.condition:
            if self.pending and (rid is None or self.pending.get("id") == rid):
                self.pending = None
            self._cancel_active(rid)

    def submit(self, req):
        with self.condition:
            self._cancel_active()
            self.pending = req
            self.condition.notify()

    def close(self):
        with self.condition:
            self.stopped = True
            self.pending = None
            self._cancel_active()
            self.condition.notify()
        self.worker.join(timeout=1)

    def run(self):
        while True:
            with self.condition:
                self.condition.wait_for(lambda: self.pending is not None or self.stopped)
                if self.stopped:
                    return
                req, self.pending = self.pending, None
                active = {"req": req, "cancelled": threading.Event(), "response": None}
                self.active = active
            rid = req.get("id")

            def publish(event):
                if not active["cancelled"].is_set():
                    self.emit(dict(event, id=rid))

            def bind(response):
                # No lock around network close: cancellation may arrive before
                # headers, and the response must close as soon as it is bound.
                active["response"] = response
                if active["cancelled"].is_set():
                    response.close()

            try:
                result = complete(req, active["cancelled"].is_set, publish, bind)
                if result is not None:
                    publish({"event": "done"})
            except Exception as exc:
                publish({"event": "error", "error": str(exc)})
            finally:
                if active["cancelled"].is_set():
                    self.emit({"id": rid, "event": "cancelled", "aborted": True})
                with self.condition:
                    if self.active is active:
                        self.active = None


if __name__ == "__main__":
    main()
