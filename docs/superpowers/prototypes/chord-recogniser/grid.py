import numpy as np, pickle, sys, json, itertools
from multiprocessing import Pool
from rec import events
from rec5 import *
from evalr import score
stress = pickle.load(open('stress.pkl','rb')); easy = pickle.load(open('cache5.pkl','rb'))
def acc_set(p, data, guard_fn):
    accs = []
    for name, each, fr, hs, truth in data:
        E = emissions5(fr, hs, p); path = viterbi(E, p)
        e = each if isinstance(each, float) else 2.0
        a, c = score(path, truth, hs, seconds_each=e, guard=0.3 if e >= 2 else 0.2); accs.append(a)
    return np.mean(accs), min(accs)
def job(kw):
    p = P5(**kw)
    s = acc_set(p, stress, None); e = acc_set(p, easy, None)
    return kw, s, e
if __name__ == '__main__':
    grid = [dict(nnS=a, nnH=b, chromaPow=c, triadBias=d) for a in [0.6,0.7,0.8] for b in [6,8] for c in [0.5,0.7,1.0] for d in [0.0, 0.04]]
    with Pool(8) as pool:
        for kw, s, e in sorted(pool.map(job, grid), key=lambda r: -r[1][0]):
            print('%-60s stress %.3f/%.3f  easy %.3f/%.3f' % (kw, s[0], s[1], e[0], e[1]))
