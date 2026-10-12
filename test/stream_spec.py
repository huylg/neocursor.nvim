"""Offline tests for the real StreamCpp decoder and bounded request workers."""
import json
import sys
import asyncio
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import sidecar

sidecar.TOK, sidecar.MID, sidecar.MAC = 'fake', 'fake', 'fake'


def frame(obj, flag=0):
    raw = json.dumps(obj).encode()
    return bytes([flag]) + len(raw).to_bytes(4, 'big') + raw


class Response:
    def __init__(self, chunks, status_error=False):
        self.chunks = chunks
        self.status_error = status_error
        self.closed = False

    async def __aenter__(self):
        return self

    async def __aexit__(self, *args):
        self.close()

    def close(self):
        self.closed = True

    def raise_for_status(self):
        if self.status_error:
            raise RuntimeError('HTTP 401')

    async def aiter_bytes(self):
        for chunk in self.chunks:
            yield chunk


class Client:
    def __init__(self, response):
        self.response = response

    def stream(self, *args, **kwargs):
        return self.response


req = dict(content='old\nsecond', line=0, col=0, path='fixture.py')
events = []
first = frame(dict(beginEdit=True, text='new', rangeToReplace=dict(startLineNumber=1, endLineNumberInclusive=1), doneEdit=True))
second = frame(dict(beginEdit=True, text='', rangeToReplace=dict(startLineNumber=2, endLineNumberInclusive=2), doneEdit=True,
                    cursorPredictionTarget=dict(relativePath='other.py', lineNumberOneIndexed=3)))


def chunks():
    yield first[:3]
    yield first[3:9]
    yield first[9:]
    assert len(events) == 1 and events[0]['event'] == 'edit', 'first edit must be emitted before stream tail'
    yield second + frame({}, 2)


sidecar.CLIENT = Client(Response(chunks()))
result = asyncio.run(sidecar.complete(req, emit=lambda e: events.append(e) if e["event"] != "timing" else None))
assert [e['event'] for e in events] == ['edit', 'prediction', 'edit']
assert result['edits'][1]['text'] == '' and events[-1]['index'] == 2
print('ok completed edits stream early, combined fields, split frames, deletion')

for response, expected in [
    (Response([frame({'error': {'message': 'backend failed'}}, 2)]), 'backend failed'),
    (Response([first[:-1]]), 'truncated'),
    (Response([frame({'beginEdit': True, 'text': 'partial'})]), 'before doneEdit'),
    (Response([], status_error=True), 'HTTP 401'),
]:
    sidecar.CLIENT = Client(response)
    try:
        asyncio.run(sidecar.complete(req))
        raise AssertionError('expected protocol failure')
    except RuntimeError as exc:
        assert expected in str(exc), str(exc)
    assert response.closed
print('ok HTTP, trailer, truncated-frame and incomplete-edit errors')

# Hold the real HTTP transport before headers or between body chunks. A newer
# request must finish while the old peer is STILL blocked (no release/timeout).
async def cancellation_cases():
    for phase in ("headers", "body"):
        blocked = asyncio.Event()
        release = asyncio.Event()
        handlers = set()

        async def serve(reader, writer):
            handlers.add(asyncio.current_task())
            try:
                header = await reader.readuntil(b"\r\n\r\n")
                length = int(next(line.split(b":", 1)[1] for line in header.split(b"\r\n")
                                  if line.lower().startswith(b"content-length:")))
                body = await reader.readexactly(length)
                slow = b"slow.py" in body
                payload = first + frame({}, 2)
                if slow and phase == "headers":
                    blocked.set()
                    await release.wait()
                writer.write(b"HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: " +
                             str(len(payload)).encode() + b"\r\n\r\n")
                await writer.drain()
                if slow and phase == "body":
                    writer.write(payload[:3])  # blocked mid-frame
                    await writer.drain()
                    blocked.set()
                    await release.wait()
                writer.write(payload[3:] if slow and phase == "body" else payload)
                await writer.drain()
            except (ConnectionError, asyncio.IncompleteReadError):
                pass
            finally:
                writer.close()
                await writer.wait_closed()
                handlers.discard(asyncio.current_task())

        server = await asyncio.start_server(serve, "127.0.0.1", 0)
        sidecar.STREAM_URL = "http://127.0.0.1:%d/cpp" % server.sockets[0].getsockname()[1]
        events, done = [], asyncio.Event()
        def emit(event):
            events.append(event)
            if event['id'] == 100 and event['event'] == 'done':
                done.set()
        async with sidecar.httpx.AsyncClient(timeout=30, trust_env=False) as client:
            sidecar.CLIENT = client
            lane = sidecar.RequestLane(emit)
            lane.submit(dict(req, id=1, path='slow.py'))
            try:
                await asyncio.wait_for(blocked.wait(), 2)
                start = time.monotonic()
                for i in range(2, 101):
                    lane.submit(dict(req, id=i))
                await asyncio.wait_for(done.wait(), 1)
                elapsed = (time.monotonic() - start) * 1000
                assert not release.is_set()
                assert [e['id'] for e in events if e['event'] == 'edit'] == [100]
                assert any(e['id'] == 1 and e['event'] == 'cancelled' for e in events)
                print('ok cancellation during %s: newest reply %.1fms, old peer still blocked' % (phase, elapsed))
            finally:
                await lane.close()
                release.set()
                server.close()
                await server.wait_closed()
                if handlers:
                    await asyncio.gather(*handlers, return_exceptions=True)

    # Cancelling only pending work must never start it; lanes stay independent.
    original = sidecar.complete
    entered, finish = asyncio.Event(), asyncio.Event()
    started, events = [], []
    async def held(request, emit):
        started.append(request['id'])
        entered.set()
        await finish.wait()
        emit({'event': 'edit'})
    sidecar.complete = held
    fg, bg = sidecar.RequestLane(events.append), sidecar.RequestLane(events.append)
    fg.submit({'id': 1})
    await entered.wait()
    bg.submit({'id': 2})
    bg.cancel(2)
    fg.cancel(99)  # wrong id does not cancel active work
    finish.set()
    await asyncio.sleep(.01)
    await fg.close()
    await bg.close()
    sidecar.complete = original
    assert started == [1]
    assert any(e['id'] == 1 and e['event'] == 'done' for e in events)
    print('ok pending cancellation and unrelated cancellation')

asyncio.run(cancellation_cases())
print('ALL PASS')
