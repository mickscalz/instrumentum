import numpy as np
from synth import *
from rec import Params
from rec4 import analyse4
from rec3 import chroma3
from rec5 import P5
fs = 44100
MAJ = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
MIN = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])
VOICINGS['E'] = ['E2','B2','E3','G#3','B3','E4']
VOICINGS['Bb'] = ['Bb2','F3','Bb3','D4','F4']
VOICINGS['Gm'] = ['G2','D3','G3','Bb3','D4','G4']
VOICINGS['Eb'] = ['Eb3','G3','Bb3','Eb4']
VOICINGS['D7'] = ['D3','A3','C4','F#4']
p = P5(nnS=0.6, nnH=6, chromaPow=0.7, triadBias=0.04, beta=0.5, whitenHalf=6, nnIters=24, penalty=8)
names = ['C','C#','D','Eb','E','F','F#','G','Ab','A','Bb','B']
for prog in [['C','G','Am','F'], ['Am','F','C','G'], ['Am','Dm','E','Am'], ['Gm','Eb','Bb','F'], ['G','C','D7','G'], ['F','Bb','C','F']]:
    x = song(prog)
    fr, hs = analyse4(x, fs, Params())
    acc = np.zeros(12)
    for S, sil, tun, tf in fr:
        if sil: continue
        t, b = chroma3(S, p); 
        if t.sum() > 0: acc += t/t.sum()*min(1, max(0, (tf-0.15)/0.2))
    sc = []
    for r in range(12):
        sc.append((np.corrcoef(acc, np.roll(MAJ, r))[0,1], names[r]))
        sc.append((np.corrcoef(acc, np.roll(MIN, r))[0,1], names[r]+'m'))
    sc.sort(reverse=True)
    print(prog, [(n, round(c,2)) for c, n in sc[:3]])
