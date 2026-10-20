import pickle, sys, collections
d = pickle.load(open(sys.argv[1], 'rb'))
sl = d['slices']; comm = d['comm']; tg = d['tgid']; sched = d['sched']
tid = int(sys.argv[2]); prefix = sys.argv[3]; a0 = float(sys.argv[4]); a1 = float(sys.argv[5]); mind = float(sys.argv[6]) if len(sys.argv) > 6 else 1.0
t0 = min(s[4] for s in sl)
def states(tid, a, z):
    ev = sorted(sched.get(tid, []))
    st = collections.defaultdict(float); cur = None; last = a
    for ts, s, x in ev:
        if ts < a:
            cur = 'Run' if s == 'RUN' else ('R' if s == 'WAKE' else s); continue
        if ts > z: break
        st[cur] += ts - last; last = ts
        cur = 'Run' if s == 'RUN' else ('R' if s == 'WAKE' else s)
    st[cur] += z - last
    return {k: round(v*1000,1) for k, v in st.items() if v > 0.0005}
mine = [s for s in sl if s[1] == tid]
tops = sorted([s for s in mine if s[3].startswith(prefix) and a0 <= s[4]-t0 <= a1], key=lambda s: s[4])
agg = collections.defaultdict(float); n = 0
for f in tops:
    n += 1
    print(f'\n@{f[4]-t0:6.3f} {f[3][:40]} {(f[5]-f[4])*1000:6.1f}ms {states(tid, f[4], f[5])}')
    for s in sorted([s for s in mine if f[4] <= s[4] and s[5] <= f[5] and s is not f and s[6] > f[6]], key=lambda s: s[4]):
        dd = (s[5]-s[4])*1000
        if s[6] - f[6] <= 4 and dd >= mind: print(f'   {"  "*(s[6]-f[6]-1)}{dd:6.1f} {s[3][:100]}')
        agg[(s[6]-f[6], s[3].split(' ')[0][:60])] += dd
print('\nagg per frame:')
for (dp, k), v in sorted(agg.items(), key=lambda x: -x[1])[:30]: print(f'  d{dp} {v/n:6.2f} {k}')
