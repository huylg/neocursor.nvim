"""Controllable streaming fixture; deliberately delivers cancelled responses."""
import json
import sys
import threading
import time
from pathlib import Path

lock = threading.Lock()

def emit(obj):
    with lock:
        print(json.dumps(obj), flush=True)

print('ready', file=sys.stderr, flush=True)
emit({'config': {'protocol': 2, 'debounce': 5}})

def serve(req):
    rid = req['id']
    name = Path(req['path']).name
    def event(kind, **kw):
        emit(dict(id=rid, event=kind, **kw))
    def edit(index, text, start, end):
        event('edit', index=index, edit={'text': text, 'range': {'start': start, 'endInclusive': end}})
    time.sleep(.05)
    if name == 'stream.py':
        edit(1, 'first\ninserted', 1, 1)
        time.sleep(.3)
        edit(1, 'first\ninserted', 1, 1)  # duplicate must never reapply
        edit(2, 'THIRD', 3, 3)
        time.sleep(.1)
    elif name == 'retain.py':
        edit(1, 'foo(new_name)', 1, 1)
    elif name == 'inline.py':
        edit(1, 'foo(argument)', 1, 1)
    elif name == 'unicode.py':
        edit(1, 'local café = "茶"', 1, 1)
    elif name == 'blank_insert.py':
        edit(1, '', 2, 1)
    elif name == 'delete.py':
        edit(1, '', 2, 2)
    elif name in ('jump.py', 'slow.py', 'missing.py'):
        target = str(Path(req['path']).with_name('target.py' if name != 'missing.py' else 'absent.py'))
        event('prediction', prediction={'path': target, 'line': 1})
    elif name == 'same.py':
        if req['line'] == 0:
            event('prediction', prediction={'path': req['path'], 'line': 2})
        else:
            time.sleep(.25)
            edit(1, 'destination ready', 2, 2)
    elif name == 'target.py':
        time.sleep(.25)
        edit(1, req['content'].split('\n')[0] + ' ready', 1, 1)
    elif name == 'out_of_order.py':
        edit(2, 'SECOND', 2, 2)
        time.sleep(.1)
        edit(1, 'FIRST', 1, 1)
    elif name == 'error.py':
        event('error', error='fixture transport failure')
        return
    else:
        edit(1, 'suggested', 1, 1)
    event('done')

for line in sys.stdin:
    req = json.loads(line)
    if req.get('op') == 'cancel':
        continue
    threading.Thread(target=serve, args=(req,), daemon=True).start()
