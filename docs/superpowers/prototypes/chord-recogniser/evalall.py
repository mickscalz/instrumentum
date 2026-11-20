import numpy as np, pickle, os, sys
from rec import analyse, events, cname, Params
from rec3 import *
from evalr import score
import scen
fs = 44100
data = pickle.load(open('cache.pkl','rb'))
if os.path.exists('scen.pkl'):
    scf = pickle.load(open('scen.pkl','rb'))
else:
    sc = scen.scenarios(); scf = {}
    for name, (x, exp) in sc.items():
        fr, hs = analyse(x, fs, Params())
        scf[name] = (fr, hs, exp)
    pickle.dump(scf, open('scen.pkl','wb'))
def evaluate(p, verbose=False):
    accs = []; conf = {}
    for style, harm, fr, hs, truth in data:
        E, _, _ = emissions(fr, hs, p); path = viterbi(E, p)
        a, c = score(path, truth, hs); accs.append(a)
        for k,v in c.items(): conf[k] = conf.get(k,0)+v
    out = []
    for name, (fr, hs, exp) in scf.items():
        E, _, _ = emissions(fr, hs, p); path = viterbi(E, p)
        ev = events(path, hs)
        out.append('%s:%s' % (name, ' '.join(c for t, c in ev[:5]) or '-'))
    print('acc mean=%.3f min=%.3f' % (np.mean(accs), min(accs)), sorted(conf.items(), key=lambda kv:-kv[1])[:4])
    print('    ' + ' | '.join(out))
if __name__ == '__main__':
    import json
    for arg in sys.argv[1:]:
        kw = json.loads(arg); print(kw); evaluate(P3(**kw))
