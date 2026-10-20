import sys, collections
# Count missed vsyncs per gesture from gfxinfo framestats (IntendedVsync cadence).
res = collections.defaultdict(lambda: [0, 0, 0, 0.0, []])  # frames, missed, gestures, span, worst
cur = None; hdr = None; rows = []
def flush():
    if cur is None: return
    ts = sorted(int(r[hdr['IntendedVsync']]) for r in rows if r[0] == '0')
    if len(ts) < 2: res[cur][2] += 1; return
    period = 16_666_667
    missed = 0; worst = 0
    for a, b in zip(ts, ts[1:]):
        d = b - a
        if d > 250_000_000: continue
        m = round(d / period) - 1
        missed += max(0, m); worst = max(worst, d / 1e6)
    r = res[cur]; r[0] += len(ts); r[1] += missed; r[2] += 1; r[3] += (ts[-1] - ts[0]) / 1e9; r[4].append(round(worst))
for line in open(sys.argv[1]):
    line = line.strip()
    if line.startswith('### '):
        flush(); cur = line[4:]; rows = []; hdr = None; continue
    if line.startswith('Flags,'):
        hdr = {k: i for i, k in enumerate(line.rstrip(',').split(','))}; continue
    if hdr and line and line[0].isdigit():
        rows.append(line.split(','))
flush()
tot = [0, 0]
for k, (f, m, g, span, worst) in res.items():
    tot[0] += f; tot[1] += m
    print(f'{k:13s} gestures {g} frames {f:4d} missed vsyncs {m:3d} ({m/(f+m)*100 if f+m else 0:4.1f}%) worst gaps ms {worst}')
print(f'TOTAL frames {tot[0]} missed {tot[1]} ({tot[1]/(tot[0]+tot[1])*100:.1f}%)')
