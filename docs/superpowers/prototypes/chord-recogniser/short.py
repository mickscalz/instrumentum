import numpy as np
from synth import *
from rec import Params, events
from rec4 import analyse4
from rec5 import *
fs = 44100
def build(seq, harmonics=5):
    total = sum(d for c, d in seq); out = np.zeros(int(total*fs)); t = 0
    for c, d in seq:
        notes = [midi(n) for n in VOICINGS[c]]
        k = max(1, int(round(d/0.5)))
        for s in range(k): strum(out, fs, t + s*d/k, notes, d/k, harmonics=harmonics)
        t += d
    out += 1e-3*np.random.default_rng(0).standard_normal(len(out))*0.003
    return out.astype(np.float32)
seq = [('C',2.0),('F',0.5),('G',1.5),('Am',1.0),('Dm',0.5),('G',0.5),('C',2.0),('Em',0.5),('Am',1.5)]
x = build(seq)
fr, hs = analyse4(x, fs, Params())
for pen in [4, 6, 8, 11]:
    p = P5(nnS=0.6, nnH=6, chromaPow=0.7, triadBias=0.04, beta=0.5, whitenHalf=6, nnIters=24, penalty=pen)
    E = emissions5(fr, hs, p); path = viterbi(E, p)
    print(pen, [(round(t,2), c) for t, c in events(path, hs)])
print('truth', np.cumsum([0]+[d for c,d in seq])[:-1], [c for c,d in seq])
