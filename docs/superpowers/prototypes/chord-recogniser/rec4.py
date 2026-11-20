# analysis that also stores tonal fraction
import numpy as np
from math import *
from rec import make_fir, Params
from tonal import tonal_fraction
from numpy.lib.stride_tricks import sliding_window_view
def analyse4(x, fs, p, tuning_seconds=20.0, tk=5.0):
    D = max(1, int(fs // 11025)); fsd = fs / D; N = 4096; hopD = 512
    h = make_fir(D); P = len(h)
    xp = np.concatenate([np.zeros(P//2), x.astype(np.float64)])
    nout = (len(xp) - P)//D + 1
    win = sliding_window_view(xp, P)[::D][:nout]
    y = win @ h
    y = np.concatenate([np.zeros(N//2), y])
    hann = 0.5 - 0.5*np.cos(2*np.pi*np.arange(N)/N)
    binHz = fsd / N
    frames = []; m = 0
    tr_re = tr_im = 0.0; heard = 0.0
    hopSec = hopD*D/fs
    while m*hopD + N <= len(y):
        seg = y[m*hopD: m*hopD+N] * hann
        X = np.abs(np.fft.rfft(seg))[:N//2]
        energy = np.sum(seg**2)
        silent = energy < 1e-10
        if not silent and heard < tuning_seconds:
            heard += hopSec
            kLo = int(80/binHz); kHi = int(1500/binHz)
            mx = X[kLo:kHi].max()
            for k in range(kLo, kHi):
                v = X[k]
                if v > X[k-1] and v >= X[k+1] and v > mx*0.01:
                    loc = X[max(1,k-10):k+11].mean()
                    if v < 3*loc: continue
                    a, b, c = log(X[k-1]+1e-12), log(v+1e-12), log(X[k+1]+1e-12)
                    d = a - 2*b + c
                    off = 0.5*(a-c)/d if d != 0 else 0
                    cts = 1200*log2((k+off)*binHz/440.0)
                    dev = cts - 100*round(cts/100)
                    tr_re += v*cos(2*pi*dev/100); tr_im += v*sin(2*pi*dev/100)
        tuning = atan2(tr_im, tr_re)*100/(2*pi) if (tr_re**2+tr_im**2) > 0 else 0.0
        S = np.zeros(p.highMidi - p.lowMidi + 1)
        for i, mm in enumerate(range(p.lowMidi, p.highMidi+1)):
            fc = 440*2**((mm-69)/12 + tuning/1200)
            kc = fc/binHz; k0 = int(floor(kc)); fr = kc - k0
            v = X[k0]*(1-fr) + X[k0+1]*fr
            lo = int(ceil(fc*2**(-1/24)/binHz)); hi = int(floor(fc*2**(1/24)/binHz))
            if hi >= lo: v = max(v, X[lo:hi+1].max())
            S[i] = v
        tf = 0.0 if silent else tonal_fraction(X, binHz, k=tk)
        frames.append((S, silent, tuning, tf))
        m += 1
    return frames, hopSec
