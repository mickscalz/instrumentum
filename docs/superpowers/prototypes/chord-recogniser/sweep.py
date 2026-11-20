import numpy as np, pickle, os, sys, itertools
from synth import *
from rec import *
from rec2 import *
from evalr import random_song, score
fs = 44100
base = Params(whiten='mean', whitenHalf=9, whitenK=1.0, semiPow=1.0, octMode='sum', chromaPow=1.0, templateMode='harm', frameNorm='sum')
cache = 'cache.pkl'
if os.path.exists(cache): data = pickle.load(open(cache,'rb'))
else:
    data = []
    for style in ['piano','guitar','spread']:
        for harm in [1, 4, 8]:
            rng = np.random.default_rng(11 + harm)
            x, truth = random_song(24, rng, harmonics=harm, style=style)
            fr, hs = analyse(x, fs, base)
            data.append((style, harm, fr, hs, truth))
    pickle.dump(data, open(cache,'wb'))
def evaluate(p, verbose=False):
    accs = []; allconf = {}
    for style, harm, fr, hs, truth in data:
        path, E, _ = decode2(fr, hs, p)
        acc, conf = score(path, truth, hs)
        accs.append(acc)
        for k,v in conf.items(): allconf[k] = allconf.get(k,0)+v
        if verbose: print('  ', style, harm, round(acc,3))
    return np.mean(accs), min(accs), sorted(allconf.items(), key=lambda kv:-kv[1])[:5]
configs = {
 'base': {},
 'median': dict(whiten='median'),
 'none': dict(whiten='none'),
 'mean+sqrt': dict(semiPow=0.5),
 'median+sqrt': dict(whiten='median', semiPow=0.5),
 'none+sqrt': dict(whiten='none', semiPow=0.5),
 'mean+max': dict(octMode='max'),
 'median+max': dict(whiten='median', octMode='max'),
 'median+chromasqrt': dict(whiten='median', chromaPow=0.5),
 'mean+chromasqrt': dict(chromaPow=0.5),
 'median+sqrt+binary': dict(whiten='median', semiPow=0.5, templateMode='binary'),
 'median+chromasqrt+binary': dict(whiten='median', chromaPow=0.5, templateMode='binary'),
 'median+sqrt+H6': dict(whiten='median', semiPow=0.5, harm_H=6),
 'median+sqrt+s0.4': dict(whiten='median', semiPow=0.5, harm_s=0.4),
 'median+sqrt+s0.8': dict(whiten='median', semiPow=0.5, harm_s=0.8),
}
for name, kw in configs.items():
    p = Params(**{**base.__dict__, **kw})
    m, mn, conf = evaluate(p)
    print('%-28s mean=%.3f min=%.3f' % (name, m, mn), conf)
