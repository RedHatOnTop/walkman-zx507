import sys, collections
# Phase breakdown per gesture kind from framestats: frames followed by a missed vsync vs. on-time frames.
P = ['IntendedVsync','HandleInputStart','AnimationStart','PerformTraversalsStart','DrawStart','SyncQueued','SyncStart','IssueDrawCommandsStart','SwapBuffers','FrameCompleted']
cur = None; hdr = None; data = collections.defaultdict(list)
for line in open(sys.argv[1]):
    line = line.strip()
    if line.startswith('### '): cur = line[4:]; hdr = None; continue
    if line.startswith('Flags,'): hdr = {k: i for i, k in enumerate(line.rstrip(',').split(','))}; continue
    if hdr and line and line[0].isdigit():
        r = line.split(',')
        if r[0] != '0': continue
        data[cur].append({k: int(r[hdr[k]]) for k in P + ['DequeueBufferDuration','QueueBufferDuration','GpuCompleted']})
want = sys.argv[2:] or list(data)
for k in want:
    fr = sorted(data[k], key=lambda f: f['IntendedVsync'])
    groups = {'slow': [], 'ok': []}
    for a, b in zip(fr, fr[1:]):
        d = b['IntendedVsync'] - a['IntendedVsync']
        if d > 250e6: continue
        groups['slow' if d > 25e6 else 'ok'].append(a)
    print(f'== {k}')
    for g, lst in groups.items():
        if not lst: continue
        def avg(x, y): return sum((f[y]-f[x]) for f in lst)/len(lst)/1e6
        print(f'  {g:4s} n={len(lst):3d} input {avg("HandleInputStart","AnimationStart"):5.1f} anim {avg("AnimationStart","PerformTraversalsStart"):5.1f} '
              f'layout {avg("PerformTraversalsStart","DrawStart"):5.1f} draw {avg("DrawStart","SyncQueued"):5.1f} syncwait {avg("SyncQueued","SyncStart"):5.1f} '
              f'sync {avg("SyncStart","IssueDrawCommandsStart"):5.1f} issue {avg("IssueDrawCommandsStart","SwapBuffers"):5.1f} swap {avg("SwapBuffers","FrameCompleted"):5.1f} '
              f'gpu {sum((f["GpuCompleted"]-f["SwapBuffers"]) for f in lst if f["GpuCompleted"]>0)/max(1,sum(1 for f in lst if f["GpuCompleted"]>0))/1e6:5.1f} '
              f'deq {sum(f["DequeueBufferDuration"] for f in lst)/len(lst)/1e6:4.1f} total {avg("IntendedVsync","FrameCompleted"):5.1f}')
