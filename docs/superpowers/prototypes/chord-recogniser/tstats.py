import numpy as np, pickle, os
from synth import *
from rec import Params
from rec4 import analyse4
from evalr import random_song
import scen
fs = 44100
p = Params()
rng = np.random.default_rng(2)
sc = scen.scenarios()
out = {}
for name, (x, exp) in sc.items():
    fr, hs = analyse4(x, fs, p)
    tf = np.array([f[3] for f in fr])
    print('%-10s tonal p5=%.2f p50=%.2f p95=%.2f' % (name, np.percentile(tf,5), np.median(tf), np.percentile(tf,95)))
for style in ['piano','guitar']:
    for noise_db in [-50, -35, -28]:
        x, truth = random_song(8, rng, style=style, harmonics=5, noise_db=noise_db)
        fr, hs = analyse4(x, fs, p)
        tf = np.array([f[3] for f in fr])
        print('%s noise %d: tonal p1=%.2f p5=%.2f p50=%.2f  (signal rms %.3f)' % (style, noise_db, np.percentile(tf,1), np.percentile(tf,5), np.median(tf), np.sqrt(np.mean(x**2))))
# chord + drums mix
x, truth = random_song(8, rng, style='guitar', harmonics=5)
d = sc['drums'][0]
mix = x[:len(d)] + d[:len(x)]
fr, hs = analyse4(mix, fs, p)
tf = np.array([f[3] for f in fr])
print('guitar+drums: tonal p1=%.2f p5=%.2f p50=%.2f' % (np.percentile(tf,1), np.percentile(tf,5), np.median(tf)))
