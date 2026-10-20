import pickle, sys, collections
d = pickle.load(open(sys.argv[1], 'rb'))
sl = d['slices']; comm = d['comm']; tg = d['tgid']
t0 = min(s[4] for s in sl)
sfpid = [p for p in set(tg.values()) if comm.get(p, '').startswith('surfaceflinger')]
sfpid = sfpid[0] if sfpid else None
a0, a1 = float(sys.argv[2]), float(sys.argv[3])
names = ('HwcPresentDisplay', 'composite', 'commit', 'onMessageInvalidate', 'onMessageRefresh', 'HwcPresentOrValidateDisplay', 'waitForever', 'latchBuffers', 'presentAndGetReleaseFences', 'HIDL::IComposerClient::executeCommands::client')
agg = collections.defaultdict(list)
for s in sl:
    if tg.get(s[1], s[0]) != sfpid: continue
    st = s[4]-t0
    if not (a0 <= st <= a1): continue
    n = s[3].split(' ')[0]
    if n in names: agg[(comm.get(s[1]), n)].append((s[5]-s[4])*1000)
for k, v in sorted(agg.items()):
    print(f'{k[0][:16]:16s} {k[1][:40]:40s} n={len(v):4d} avg {sum(v)/len(v):6.2f} max {max(v):6.1f}')
# composer HAL process
hal = collections.defaultdict(list)
for s in sl:
    st = s[4]-t0
    if not (a0 <= st <= a1): continue
    c = comm.get(s[1], '')
    p = comm.get(tg.get(s[1], 0), '')
    if 'composer' in p or 'hwc' in p.lower() or 'composer' in c:
        hal[(p[:20], s[3].split(' ')[0][:40])].append((s[5]-s[4])*1000)
for k, v in sorted(hal.items(), key=lambda x: -sum(x[1]))[:15]:
    print(f'HAL {k[0]:20s} {k[1]:40s} n={len(v):4d} avg {sum(v)/len(v):6.2f} max {max(v):6.1f}')
