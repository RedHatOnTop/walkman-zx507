import pickle, sys, collections
d = pickle.load(open(sys.argv[1], 'rb'))
sl = d['slices']; comm = d['comm']; tg = d['tgid']
t0 = min(s[4] for s in sl)
sfpid = [p for p in set(tg.values()) if comm.get(p, '').startswith('surfaceflinger')][0]
comp = sorted(s[4] for s in sl if tg.get(s[1]) == sfpid and s[3] == 'composite' or (tg.get(s[1]) == sfpid and s[3].startswith('composite ')))
for pname in ('ndroid.systemui', 'droid.launcher3'):
    pid = [p for p in set(tg.values()) if comm.get(p) == pname][0]
    rt = {t for t in tg if tg[t] == pid and comm.get(t) == 'RenderThread'}
    q = sorted(s[4] for s in sl if s[1] in rt and s[3].startswith('queueBuffer') and s[6] >= 0)
    # dedupe nested queueBuffer (outer+inner)
    qq = []
    for t in q:
        if not qq or t - qq[-1] > 0.002: qq.append(t)
    bursts = []; cur = []
    for t in qq:
        if cur and t - cur[-1] > 0.25: bursts.append(cur); cur = []
        cur.append(t)
    if cur: bursts.append(cur)
    for b in bursts:
        if len(b) < 5: continue
        span = b[-1] - b[0]
        gaps = [(b[i+1]-b[i])*1000 for i in range(len(b)-1)]
        sfn = sum(1 for c in comp if b[0] <= c <= b[-1])
        print(f'{pname[:10]} @{b[0]-t0:6.2f}s {span*1000:5.0f}ms frames {len(b):3d} -> {(len(b)-1)/span:5.1f} fps | gaps>25ms {sum(g>25 for g in gaps):2d} max {max(gaps):5.1f} | SF composites {sfn}')
