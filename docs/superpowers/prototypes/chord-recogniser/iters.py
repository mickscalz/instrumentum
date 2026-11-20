import json, sys
from multiprocessing import Pool
from grid import job
if __name__ == '__main__':
    base = {"nnS":0.6,"nnH":6,"chromaPow":0.7,"triadBias":0.04,"beta":0.5,"whitenHalf":6}
    grid = [dict(base, nnIters=i) for i in [10, 20, 30]] + [dict(base, noChord=0.6), dict(base, kappa=6), dict(base, penalty=6)]
    with Pool(2) as pool:
        for kw, s, e in pool.map(job, grid):
            print('%-100s stress %.3f/%.3f  easy %.3f/%.3f' % (kw, s[0], s[1], e[0], e[1]))
