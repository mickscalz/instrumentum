import numpy as np
from math import *

QUALS = ['maj','min','7','maj7','m7']
INTS = {'maj':(0,4,7),'min':(0,3,7),'7':(0,4,7,10),'maj7':(0,4,7,11),'m7':(0,3,7,10)}
NAMES = ['C','C#','D','Eb','E','F','F#','G','Ab','A','Bb','B']
def cname(s):
    if s < 0: return '?'
    if s == 0: return 'N'
    s -= 1; q = QUALS[s // 12]; r = s % 12
    return NAMES[r] + {'maj':'','min':'m','7':'7','maj7':'maj7','m7':'m7'}[q]

class Params:
    def __init__(self, **kw):
        self.lowMidi = 33; self.highMidi = 95
        self.bassHigh = 55   # bass chroma from lowMidi..bassHigh
        self.trebleLow = 45
        self.whiten = 'mean'  # 'none' | 'mean'
        self.whitenHalf = 9  # semitones each side
        self.compress = 'none'
        self.harm_s = 0.6; self.harm_H = 4
        self.beta = 0.0
        self.noChord = 0.45
        self.kappa = 10.0
        self.penalty = 4.0
        self.smoothSec = 0.25
        self.silenceRMS = 10**(-70/20)
        self.peakFloorRatio = 3.0
        self.minDur = 0.4
        self.lagSec = 2.0
        for k, v in kw.items(): setattr(self, k, v)

def make_fir(D):
    if D == 1: return np.array([1.0], dtype=np.float64)
    P = 16*D
    n = np.arange(P) - (P-1)/2
    fc = 0.5/D
    h = 2*fc*np.sinc(2*fc*n)
    w = np.blackman(P)
    h = h*w; h /= h.sum()
    return h

def templates(p):
    T = np.zeros((60, 12))
    for qi, q in enumerate(QUALS):
        for r in range(12):
            t = np.zeros(12)
            for iv in INTS[q]:
                for h in range(1, p.harm_H+1):
                    t[(r + iv + int(round(12*log2(h)))) % 12] += p.harm_s**(h-1)
            T[qi*12 + r] = t
    return T

def analyse(x, fs, p, cents_override=None, tuning_seconds=20.0):
    """Offline analysis of a whole signal starting at time 0, mirroring the online frame grid."""
    D = max(1, int(fs // 11025)); fsd = fs / D; N = 4096; hopD = 512
    h = make_fir(D); P = len(h)
    xp = np.concatenate([np.zeros(P//2), x.astype(np.float64)])
    # decimate
    nout = (len(xp) - P)//D + 1
    idx = np.arange(nout)*D
    # convolution via strided
    from numpy.lib.stride_tricks import sliding_window_view
    win = sliding_window_view(xp, P)[::D][:nout]
    y = win @ h
    # frames centred at m*hopD
    y = np.concatenate([np.zeros(N//2), y, np.zeros(0)])
    hann = np.hanning(N+1)[:N]  # periodic-ish; vDSP_HANN_NORM is symmetric? use this
    binHz = fsd / N
    frames = []
    m = 0
    tr_re = 0.0; tr_im = 0.0; tr_heard = 0.0
    hopSec = hopD*D/fs
    while m*hopD + N <= len(y):
        seg = y[m*hopD: m*hopD+N] * hann
        X = np.abs(np.fft.rfft(seg))[:N//2] * (2.0/ (N/2))   # rough scale
        rms = sqrt(np.mean(seg**2)/np.mean(hann**2)) if True else 0
        silent = rms < p.silenceRMS
        # tuning
        if not silent and tr_heard < tuning_seconds:
            tr_heard += hopSec
            kLo = int(80/binHz); kHi = int(1500/binHz)
            mx = X[kLo:kHi].max()
            for k in range(kLo, kHi):
                v = X[k]
                if v > X[k-1] and v >= X[k+1] and v > mx*0.01:
                    loc = X[max(1,k-10):k+11].mean()
                    if v < p.peakFloorRatio*loc: continue
                    a, b, c = log(X[k-1]+1e-12), log(v+1e-12), log(X[k+1]+1e-12)
                    d = a - 2*b + c
                    off = 0.5*(a-c)/d if d != 0 else 0
                    f = (k+off)*binHz
                    cts = 1200*log2(f/440.0)
                    dev = cts - 100*round(cts/100)
                    tr_re += v*cos(2*pi*dev/100); tr_im += v*sin(2*pi*dev/100)
        tuning = atan2(tr_im, tr_re)*100/(2*pi) if (tr_re**2+tr_im**2) > 0 else 0.0
        if cents_override is not None: tuning = cents_override
        # semitone spectrum
        S = np.zeros(p.highMidi - p.lowMidi + 1)
        for i, mm in enumerate(range(p.lowMidi, p.highMidi+1)):
            fc = 440*2**((mm-69)/12 + tuning/1200)
            kc = fc/binHz
            k0 = int(floor(kc)); fr = kc - k0
            v = X[k0]*(1-fr) + X[k0+1]*fr
            lo = int(ceil(fc*2**(-1/24)/binHz)); hi = int(floor(fc*2**(1/24)/binHz))
            if hi >= lo: v = max(v, X[lo:hi+1].max())
            S[i] = v
        frames.append((S, silent, tuning, rms))
        m += 1
    return frames, hopSec

def chroma_from(S, p):
    s = S.copy()
    if p.compress == 'log':
        mx = s.max()
        s = np.log1p(1000*s/mx) if mx > 0 else s
    if p.whiten == 'mean':
        n = len(s); w = np.zeros(n)
        for i in range(n):
            a = max(0, i-p.whitenHalf); b = min(n, i+p.whitenHalf+1)
            w[i] = max(0.0, s[i] - s[a:b].mean())
        s = w
    tre = np.zeros(12); bas = np.zeros(12)
    for i, mm in enumerate(range(p.lowMidi, p.highMidi+1)):
        if mm >= p.trebleLow: tre[mm % 12] += s[i]
        if mm <= p.bassHigh: bas[mm % 12] += s[i]
    return tre, bas

def corr(x, T):
    xm = x - x.mean(); xn = np.linalg.norm(xm)
    if xn < 1e-12: return np.zeros(len(T))
    Tm = T - T.mean(axis=1, keepdims=True)
    return (Tm @ xm) / (np.linalg.norm(Tm, axis=1) * xn)

def decode(frames, hopSec, p):
    T = templates(p)
    n = len(frames)
    tre = np.zeros((n,12)); bas = np.zeros((n,12)); sil = np.zeros(n, bool)
    for j, (S, silent, tun, rms) in enumerate(frames):
        if silent: sil[j] = True; continue
        t, b = chroma_from(S, p)
        nt = t.sum()
        if nt > 0: t /= nt; b /= nt   # normalise both by treble sum
        tre[j] = t; bas[j] = b
    w = int(round(p.smoothSec/hopSec))
    E = np.zeros((n, 61))
    for j in range(n):
        a = max(0, j-w); b = min(n, j+w+1)
        st = tre[a:b].mean(axis=0); sb = bas[a:b].mean(axis=0)
        silfrac = sil[a:b].mean()
        if silfrac > 0.5 or st.sum() <= 0:
            E[j, 0] = p.kappa*1.0; E[j, 1:] = 0; continue
        c = corr(st, T)
        if p.beta > 0 and sb.sum() > 0:
            bn = sb / (sb.sum())
            bonus = np.array([bn[k % 12] for k in range(60)])
            c = c + p.beta*bonus
        E[j, 1:] = p.kappa*c
        E[j, 0] = p.kappa*p.noChord
    # viterbi (offline)
    delta = E[0].copy(); bp = np.zeros((n, 61), int)
    for j in range(1, n):
        best = delta.argmax()
        stay = delta; move = delta[best] - p.penalty
        nd = np.where(stay >= move, stay, move)
        bp[j] = np.where(stay >= move, np.arange(61), best)
        delta = nd + E[j]
    path = np.zeros(n, int); path[-1] = delta.argmax()
    for j in range(n-1, 0, -1): path[j-1] = bp[j, path[j]]
    return path, E

def events(path, hopSec, minDur=0.4):
    # runs
    runs = []
    for j, s in enumerate(path):
        if runs and runs[-1][0] == s: runs[-1][2] = j
        else: runs.append([s, j, j])
    minSlots = int(ceil(minDur/hopSec - 1e-9))
    out = []
    for r in runs:
        ln = r[2]-r[1]+1
        if ln < minSlots and out:
            out[-1][2] = r[2]; continue
        if out and out[-1][0] == r[0]: out[-1][2] = r[2]; continue
        out.append(list(r))
    # leading short run
    ev = []
    for s, a, b in out:
        if s > 0: ev.append((max(0, (a-0.5)*hopSec), cname(s)))
    return ev
