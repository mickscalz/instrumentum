import numpy as np, pickle, sys
from synth import *
from rec import Params, QUALS, INTS
from rec4 import analyse4
import scen
fs = 44100
def tone(out, fs, t0, f, dur, amp, harmonics, hdecay, decay, vib=0.0, odd=False, detune_c=0.0):
    n0 = int(round(t0*fs)); n1 = min(len(out), int(round((t0+dur)*fs)))
    if n1 <= n0: return
    t = np.arange(n1-n0)/fs
    env = (np.exp(-t/decay) if decay > 0 else np.ones_like(t)) * np.minimum(1, t/0.01)
    tail = min(len(t), int(0.02*fs)); env[-tail:] *= np.linspace(1,0,tail)
    f = f*2**(detune_c/1200)
    ph = 2*np.pi*f*t
    if vib > 0: ph += (vib*f/5.5/1200*np.log(2)*1200/ (2*np.pi*5.5)) * 0 + (f*(2**(vib/1200)-1)/5.5)*np.sin(2*np.pi*5.5*t)
    sig = np.zeros_like(t)
    for h in range(1, harmonics+1):
        if odd and h % 2 == 0: continue
        if f*h > fs/2*0.9: break
        sig += hdecay**(h-1) * np.sin(h*ph + 1.3*h)
    out[n0:n1] += amp*env*sig
QW = {'maj':0.4,'min':0.3,'7':0.15,'maj7':0.07,'m7':0.08}
def stress_song(n, rng, each=2.0, cents=0.0, melody=True, inversions=0.2, bass=True, drums=0.0, timbre='mix', pad=False):
    out = np.zeros(int(round(n*each*fs)))
    truth = []
    prev = None
    qs = list(QW.keys()); pw = np.array([QW[q] for q in qs])
    key = int(rng.integers(12))
    for k in range(n):
        while True:
            r = int(rng.integers(12)); q = qs[rng.choice(len(qs), p=pw)]
            if (r,q) != prev: break
        prev = (r,q)
        truth.append(1 + QUALS.index(q)*12 + r)
        ints = INTS[q]
        base = 52 + ((r - 4) % 12)  # E3..D#4 region
        notes = [base + i for i in ints] + [base + 12]
        if rng.random() < 0.5: notes = [base + ints[0]] + [base + i + 12 for i in ints[1:]] + [base+12]
        # timbre
        if timbre == 'mix': tb = rng.choice(['soft','bright','odd'])
        else: tb = timbre
        H, hd, odd = {'soft':(4,0.5,False),'bright':(10,0.8,False),'odd':(9,0.7,True)}[tb]
        strums = 1 if pad else 4
        sd = each/strums
        for s in range(strums):
            for i, m in enumerate(notes):
                f = 440*2**((m-69)/12 + cents/1200)
                tone(out, fs, k*each + s*sd + i*0.008, f, sd, 0.08, H, hd, 0 if pad else 1.0, odd=odd, detune_c=rng.normal(0,4))
        if bass:
            inv = rng.random() < inversions
            bnote = r if not inv else (r + ints[rng.integers(1,3)]) % 12
            bm = 36 + ((bnote - 4) % 12) + 4   # E2..D#3 ... (40..51)
            bm = 28 + ((bnote - 4) % 12)        # E1..D#2
            for s in range(2):
                tone(out, fs, k*each + s*each/2, 440*2**((bm-69)/12 + cents/1200), each/2, 0.25, 6, 0.6, 1.5)
            if inv: truth[-1] = truth[-1]  # still the chord
        if melody:
            # melody: 4 notes per chord, chord tones on strong beats, scale tones between
            scale = [(key + d) % 12 for d in (0,2,4,5,7,9,11)]
            for s in range(4):
                if s % 2 == 0: pc = (r + ints[rng.integers(len(ints))]) % 12
                else: pc = scale[rng.integers(7)]
                mm = 72 + ((pc - 0) % 12)  # C5..B5
                tone(out, fs, k*each + s*each/4, 440*2**((mm-69)/12 + cents/1200), each/4, 0.10, 6, 0.55, 0, vib=15)
    if drums > 0:
        sc = scen.scenarios(); d = sc['drums'][0]
        out += drums*np.tile(d, int(np.ceil(len(out)/len(d))))[:len(out)]
    out += 10**(-55/20)*rng.standard_normal(len(out))
    return out.astype(np.float32), truth
if __name__ == '__main__':
    p = Params()
    data = []
    cfgs = [dict(), dict(melody=False), dict(cents=-37), dict(drums=0.7), dict(pad=True), dict(each=1.0), dict(inversions=0.6), dict(timbre='bright')]
    for i, cfg in enumerate(cfgs):
        rng = np.random.default_rng(100+i)
        each = cfg.get('each', 2.0)
        x, truth = stress_song(int(40/each), rng, **cfg)
        fr, hs = analyse4(x, fs, p)
        data.append((str(cfg), each, fr, hs, truth))
        print('done', cfg, file=sys.stderr)
    pickle.dump(data, open('stress.pkl','wb'))
