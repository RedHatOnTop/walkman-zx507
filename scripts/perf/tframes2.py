import pickle, sys, collections
d = pickle.load(open(sys.argv[1], 'rb'))
sl = d['slices']; comm = d['comm']; tg = d['tgid']
t0 = min(s[4] for s in sl)
def outer(lst):
    lst = sorted(lst, key=lambda s: s[4]); out = []
    for s in lst:
        if out and s[4] < out[-1][5]: continue
        out.append(s)
    return out
pids = {}
for s in sl:
    if s[3].startswith('Choreographer#doFrame'): pids[s[0]] = s[2]
print(pids)
for pid, c in pids.items():
    fr = outer([s for s in sl if s[0] == pid and s[1] == pid and s[3].startswith('Choreographer#doFrame')])
    rt_tids = {t for t in tg if tg[t] == pid and comm.get(t) == "RenderThread"}
    df = outer([s for s in sl if s[1] in rt_tids and s[3].startswith('DrawFrame')])
    print('\n==', c, pid, len(fr), 'doFrame', len(df), 'DrawFrame', 'RT', rt_tids)
    bursts = []; cur = []
    for s in fr:
        if cur and s[4] - cur[-1][4] > 0.3: bursts.append(cur); cur = []
        cur.append(s)
    if cur: bursts.append(cur)
    for b in bursts:
        a, z = b[0][4], b[-1][5] + 0.05
        durs = [(s[5]-s[4])*1000 for s in b]
        dfs = [s for s in df if a <= s[4] <= z]
        ddur = [(s[5]-s[4])*1000 for s in dfs]
        gaps = [(b[i+1][4]-b[i][4])*1000 for i in range(len(b)-1)]
        sub = collections.defaultdict(float)
        for s in sl:
            if s[1] in rt_tids and a <= s[4] <= z and s[3].split(' ')[0] in ('dequeueBuffer','eglSwapBuffersWithDamageKHR','eglSwapBuffers','queueBuffer','flush','syncFrameState','prepareTree','Flush'):
                sub[s[3].split(' ')[0]] += (s[5]-s[4])*1000
        print(f'  @{a-t0:6.2f}s span {(b[-1][5]-a)*1000:5.0f}ms n={len(b):3d} doFrame avg {sum(durs)/len(durs):5.1f} max {max(durs):5.1f} | DrawFrame n={len(dfs)} avg {sum(ddur)/max(1,len(ddur)):5.1f} max {max(ddur or [0]):5.1f} | gaps>20:{sum(g>20 for g in gaps)} max {max(gaps or [0]):5.1f} |', ' '.join(f'{k}={v:.0f}' for k,v in sub.items()))
