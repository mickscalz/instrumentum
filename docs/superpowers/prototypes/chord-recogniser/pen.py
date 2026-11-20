import json, sys, pickle, numpy as np
from multiprocessing import Pool
from rec import events
from rec5 import *
from evalr import score
stress = pickle.load(open('stress.pkl','rb')); easy = pickle.load(open('cache5.pkl','rb'))
def berr(path, truth, hs, each):
    ev = events(path, hs); errs = []
    for k in range(1, len(truth)):
        if truth[k] == truth[k-1]: continue
        t = k*each; cand = [abs(e[0]-t) for e in ev]
        errs.append(min(cand) if cand else 9)
    return errs
def job(kw):
    p = P5(**kw); res = []
    for data in (stress, easy):
        accs = []; be = []
        for name, each, fr, hs, truth in data:
            e = each if isinstance(each, float) else 2.0
            E = emissions5(fr, hs, p); path = viterbi(E, p)
            a, c = score(path, truth, hs, seconds_each=e, guard=0.3 if e >= 2 else 0.2); accs.append(a)
            be += berr(path, truth, hs, e)
        be = np.array(be)
        res.append((np.mean(accs), min(accs), np.percentile(be, 90), np.mean(be > 0.3)))
    return kw, res
if __name__ == '__main__':
    base = {"nnS":0.6,"nnH":6,"chromaPow":0.7,"triadBias":0.04,"beta":0.5,"whitenHalf":6,"nnIters":24}
    grid = [dict(base, penalty=x) for x in [4, 6, 8, 11, 15]]
    with Pool(2) as pool:
        for kw, res in pool.map(job, grid):
            print('pen %-4s' % kw['penalty'], ' '.join('acc %.3f/%.3f bnd90 %.2f miss>0.3 %.3f |' % r for r in res))
