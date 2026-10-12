"""Offline tests for the real StreamCpp decoder and bounded request workers."""
import json
import sys
import threading
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

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()

    def close(self):
        self.closed = True

    def raise_for_status(self):
        if self.status_error:
            raise RuntimeError('HTTP 401')

    def iter_bytes(self):
        yield from self.chunks


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
result = sidecar.complete(req, emit=events.append)
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
        sidecar.complete(req)
        raise AssertionError('expected protocol failure')
    except RuntimeError as exc:
        assert expected in str(exc), str(exc)
    assert response.closed
print('ok HTTP, trailer, truncated-frame and incomplete-edit errors')

cancel = threading.Event()
emitted = []

def cancelled_chunks():
    yield first
    cancel.set()
    yield second

sidecar.CLIENT = Client(Response(cancelled_chunks()))
assert sidecar.complete(req, cancel.is_set, emitted.append) is None
assert len(emitted) == 1
print('ok cancelled stream emits no later edits')

# Flood a lane while its first worker is held: only the last pending request runs.
original = sidecar.complete
entered, release = threading.Event(), threading.Event()
started, results = [], []
lock = threading.Lock()
active = peak = 0

def held_complete(request, cancelled, publish, bind):
    global active, peak
    with lock:
        active += 1
        peak = max(peak, active)
        started.append(request['id'])
    response = Response([])
    bind(response)
    entered.set()
    if request['id'] == 1:
        release.wait(2)
        assert response.closed, 'cancel must close the active response'
    publish({'event': 'edit', 'index': 1, 'edit': {'text': 'x'}})
    with lock:
        active -= 1
    return None if cancelled() else {}

sidecar.complete = held_complete
lane = sidecar.RequestLane(results.append)
lane.submit({'id': 1})
assert entered.wait(1)
for i in range(2, 101):
    lane.submit({'id': i})
release.set()
deadline = time.monotonic() + 2
while not any(e.get('id') == 100 and e['event'] == 'done' for e in results) and time.monotonic() < deadline:
    time.sleep(.005)
lane.close()
sidecar.complete = original
assert started == [1, 100], started
assert peak == 1
assert not any(e['id'] == 1 and e['event'] == 'edit' for e in results)
print('ok bounded worker, newest pending request, transport cancellation')
print('ALL PASS')
