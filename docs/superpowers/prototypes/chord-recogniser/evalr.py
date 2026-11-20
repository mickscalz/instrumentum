import numpy as np, sys
from synth import *
from rec import *

def chord_notes(root, q, rng, style):
    ints = INTS[q]
    if style == 'piano':
        base = 60 + root if root < 6 else 48 + root   # C4..F4 / F#3..B3
        notes = [base + i for i in ints]
        notes.append(base - 12)          # root below
        if rng.random() < 0.5: notes.append(base + 12)
    elif style == 'guitar':
        base = 40 + ((root - 4) % 12)    # E2..D#3 root
        notes = [base, base + 7, base + 12]
        for i in ints[1:]:
            notes.append(base + 12 + i)
        if len(ints) == 3: notes.append(base + 24)
    elif style == 'spread':
        base = 48 + root
        notes = [base - 12] + [base + i + (12 if k % 2 else 0) for k, i in enumerate(ints)]
    return sorted(set(notes))

def random_song(n, rng, fs=44100, seconds_each=2.0, cents=0.0, harmonics=5, style='piano', quals=QUALS, noise_db=-50):
    truth = []
    out = np.zeros(int(round(n*seconds_each*fs)))
    prev = None
    for k in range(n):
        while True:
            r = int(rng.integers(12)); q = quals[int(rng.integers(len(quals)))]
            if (r, q) != prev: break
        prev = (r, q)
        notes = chord_notes(r, q, rng, style)
        for s in range(4):
            strum(out, fs, k*seconds_each + s*seconds_each/4, notes, seconds_each/4, cents=cents, harmonics=harmonics)
        truth.append(1 + QUALS.index(q)*12 + r)
    out += 10**(noise_db/20)*rng.standard_normal(len(out))
    return out.astype(np.float32), truth

def score(path, truth, hopSec, seconds_each=2.0, guard=0.3):
    ok = tot = 0
    conf = {}
    for j, s in enumerate(path):
        t = j*hopSec
        k = int(t // seconds_each)
        if k >= len(truth): continue
        if (t - k*seconds_each) < guard or ((k+1)*seconds_each - t) < guard: continue
        tot += 1
        if s == truth[k]: ok += 1
        else:
            key = (cname(truth[k]), cname(s)); conf[key] = conf.get(key, 0) + 1
    return ok/tot, conf

if __name__ == '__main__':
    fs = 44100
    p = Params()
    for style in ['piano','guitar','spread']:
        for harm in [1, 3, 5, 8]:
            rng = np.random.default_rng(7)
            x, truth = random_song(30, rng, harmonics=harm, style=style)
            fr, hs = analyse(x, fs, p)
            path, E = decode(fr, hs, p)
            acc, conf = score(path, truth, hs)
            top = sorted(conf.items(), key=lambda kv: -kv[1])[:6]
            print(style, harm, 'acc=%.3f' % acc, top)
