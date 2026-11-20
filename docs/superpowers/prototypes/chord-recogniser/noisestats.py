import numpy as np, pickle, sys, json
from rec3 import *
from rec import corr
from evalall import data, scf
def stats(fr, hs, p):
    E, tre, bas = emissions(fr, hs, p)
    T = binary_templates()
    w = int(round(p.smoothSec/hs)); n = len(fr)
    mc = []; pk = []
    for j in range(n):
        a = max(0, j-w); b = min(n, j+w+1)
        st = tre[a:b].mean(axis=0)
        if st.sum() <= 0: continue
        c = corr(st, T); mc.append(c.max())
        s = np.sort(st)[::-1]; pk.append(s[:4].sum()/s.sum())
    return np.array(mc), np.array(pk)
for arg in sys.argv[1:]:
    kw = json.loads(arg); p = P3(**kw); print(kw)
    for name in ['white-20','pink-20','drums','C+bassC']:
        fr, hs, _ = scf[name]
        mc, pk = stats(fr, hs, p)
        print('  %-9s corr p50=%.2f p95=%.2f max=%.2f | peak4 p50=%.2f p95=%.2f max=%.2f' % (name, np.median(mc), np.percentile(mc,95), mc.max(), np.median(pk), np.percentile(pk,95), pk.max()))
    allmc = []; allpk = []
    for style, harm, fr, hs, truth in data:
        mc, pk = stats(fr, hs, p); allmc.append(mc); allpk.append(pk)
    mc = np.concatenate(allmc); pk = np.concatenate(allpk)
    print('  chords    corr p1=%.2f p5=%.2f p50=%.2f | peak4 p1=%.2f p5=%.2f p50=%.2f' % (np.percentile(mc,1), np.percentile(mc,5), np.median(mc), np.percentile(pk,1), np.percentile(pk,5), np.median(pk)))
