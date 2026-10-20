import re, sys, collections, pickle
# Parse an atrace text dump into slices and sched intervals; pickle for reuse.
LINE = re.compile(r'^\s*(.+?)-(\d+)\s+\(\s*(\d+|-+)\)\s+\[(\d+)\]\s+\S+\s+([\d.]+):\s+(\w+):\s+(.*)$')
path = sys.argv[1]
slices = []   # (tgid, tid, comm, name, start, end, depth)
stacks = collections.defaultdict(list)
asyncs = {}
counters = collections.defaultdict(list)
sched = collections.defaultdict(list)  # tid -> list of (ts, state, event) ; state: 'R' running on cpu, or prev_state when switched out
comm_of = {}
tgid_of = {}
wakes = collections.defaultdict(list)
for line in open(path, errors='replace'):
    m = LINE.match(line)
    if not m: continue
    comm, tid, tgid, cpu, ts, ev, rest = m.groups()
    tid = int(tid); ts = float(ts)
    if tgid.isdigit(): tgid_of[tid] = int(tgid)
    comm_of.setdefault(tid, comm)
    if ev == 'tracing_mark_write':
        if rest.startswith('B|'):
            p = rest.split('|', 2)
            stacks[tid].append((p[2] if len(p) > 2 else '', ts))
        elif rest.startswith('E|') or rest == 'E':
            if stacks[tid]:
                name, st = stacks[tid].pop()
                slices.append((tgid_of.get(tid, int(rest.split('|')[1]) if '|' in rest else 0), tid, comm, name, st, ts, len(stacks[tid])))
        elif rest.startswith('C|'):
            p = rest.split('|')
            try: counters[(int(p[1]), p[2])].append((ts, float(p[3])))
            except Exception: pass
        elif rest.startswith('S|') or rest.startswith('F|'):
            p = rest.split('|')
            key = (p[1], p[2], p[3] if len(p) > 3 else '')
            if rest[0] == 'S': asyncs[key] = ts
            elif key in asyncs:
                slices.append((int(p[1]), -1, 'async', p[2], asyncs.pop(key), ts, 0))
    elif ev == 'sched_switch':
        d = dict(re.findall(r'(\w+)=(\S+)', rest))
        pp, np_ = int(d['prev_pid']), int(d['next_pid'])
        comm_of.setdefault(np_, d.get('next_comm', '?'))
        sched[pp].append((ts, d['prev_state'], int(cpu)))
        sched[np_].append((ts, 'RUN', int(cpu)))
    elif ev in ('sched_wakeup', 'sched_waking'):
        d = dict(re.findall(r'(\w+)=(\S+)', rest))
        if ev == 'sched_wakeup':
            sched[int(d['pid'])].append((ts, 'WAKE', tid))
pickle.dump(dict(slices=slices, counters=dict(counters), sched=dict(sched), comm=comm_of, tgid=tgid_of), open(sys.argv[2], 'wb'))
print(len(slices), 'slices', len(sched), 'sched threads')
