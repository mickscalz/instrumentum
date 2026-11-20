import numpy as np, pickle
from synth import *
from rec import Params
from rec4 import analyse4
from evalr import random_song
import scen
fs = 44100
p = Params()
data = []
for style in ['piano','guitar','spread']:
    for harm in [1, 4, 8]:
        rng = np.random.default_rng(11 + harm)
        x, truth = random_song(24, rng, harmonics=harm, style=style)
        fr, hs = analyse4(x, fs, p)
        data.append((style, harm, fr, hs, truth))
# chords + drums
rng = np.random.default_rng(99)
x, truth = random_song(24, rng, harmonics=5, style='guitar')
sc = scen.scenarios()
d = sc['drums'][0]
dd = np.tile(d, int(np.ceil(len(x)/len(d))))[:len(x)]
fr, hs = analyse4(x + dd, fs, p); data.append(('guitar+drums', 5, fr, hs, truth))
x, truth = random_song(24, rng, harmonics=5, style='piano', noise_db=-30)
fr, hs = analyse4(x, fs, p); data.append(('piano+noise-30', 5, fr, hs, truth))
pickle.dump(data, open('cache5.pkl','wb'))
scf = {}
for name, (x, exp) in sc.items():
    fr, hs = analyse4(x, fs, p); scf[name] = (fr, hs, exp)
pickle.dump(scf, open('scen5.pkl','wb'))
