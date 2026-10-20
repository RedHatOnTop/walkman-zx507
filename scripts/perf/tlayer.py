import pickle, sys, collections
d = pickle.load(open(sys.argv[1], 'rb'))
sl = d['slices']; comm = d['comm']; tg = d['tgid']
t0 = min(s[4] for s in sl)
rows = sorted([s for s in sl if s[3].startswith('drawLayer') or s[3].startswith('flush layers') or s[3].startswith('Texture upload')], key=lambda s: s[4])
last = None
for s in rows:
    print(f'{s[4]-t0:7.3f} {tg.get(s[1],s[0]):6d} {comm.get(s[1],"?")[:12]:12s} {(s[5]-s[4])*1000:6.1f} {s[3][:80]}')
