import numpy as np
from synth import *
from rec import *
from evalr import chord_notes
fs=44100
p = Params()
rng = np.random.default_rng(3)
for (r,q,style) in [(4,'m7','piano'),(11,'maj7','piano'),(9,'maj7','guitar'),(3,'m7','guitar')]:
    notes = chord_notes(r,q,rng,style)
    out = np.zeros(int(4*fs))
    for s in range(8): strum(out, fs, s*0.5, notes, 0.5, harmonics=5)
    out += 10**(-50/20)*np.random.default_rng(1).standard_normal(len(out))
    fr, hs = analyse(out.astype(np.float32), fs, p)
    T = templates(p)
    S = np.mean([chroma_from(f[0], p)[0]/max(1e-9,chroma_from(f[0], p)[0].sum()) for f in fr[20:60]], axis=0)
    c = corr(S, T)
    order = np.argsort(-c)[:4]
    print(NAMES[r], q, style, notes, 'chroma', np.round(S/S.max(),2))
    print('   ', [(cname(k+1), round(c[k],3)) for k in order])
