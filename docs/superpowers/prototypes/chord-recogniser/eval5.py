import numpy as np, pickle, sys, json
from rec import events, cname
from rec5 import *
from evalr import score
data = pickle.load(open('cache5.pkl','rb')); scf = pickle.load(open('scen5.pkl','rb'))
def bounds_err(path, truth, hs, each=2.0):
    ev = events(path, hs)
    errs = []
    for k in range(1, len(truth)):
        t = k*each
        cand = [abs(e[0]-t) for e in ev]
        errs.append(min(cand) if cand else 9)
    return np.array(errs)
def evaluate(p):
    accs = []; conf = {}; be = []
    for style, harm, fr, hs, truth in data:
        E = emissions5(fr, hs, p); path = viterbi(E, p)
        a, c = score(path, truth, hs); accs.append(a)
        for k,v in c.items(): conf[k] = conf.get(k,0)+v
        be.append(bounds_err(path, truth, hs))
    be = np.concatenate(be)
    print('acc mean=%.3f min=%.3f  bound err p50=%.2f p95=%.2f max=%.2f' % (np.mean(accs), min(accs), np.median(be), np.percentile(be,95), be.max()), ['%s:%.2f' % (d[0][:6]+str(d[1]), a) for d, a in zip(data, accs) if a < 0.99], sorted(conf.items(), key=lambda kv:-kv[1])[:4])
    out = []
    for name, (fr, hs, exp) in scf.items():
        E = emissions5(fr, hs, p); path = viterbi(E, p)
        ev = events(path, hs)
        out.append('%s:%s' % (name, ' '.join(c for t, c in ev[:5]) or '-'))
    print('    ' + ' | '.join(out))
for arg in sys.argv[1:]:
    kw = json.loads(arg); print(kw); evaluate(P5(**kw))
