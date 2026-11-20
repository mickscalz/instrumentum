import numpy as np
from math import *
from rec import QUALS, INTS, NAMES, cname, Params, corr, events
from scipy.optimize import nnls as sp_nnls

def dictionary(p):
    n = p.highMidi - p.lowMidi + 1
    A = np.zeros((n, n))
    for j in range(n):
        for h in range(1, p.nnH+1):
            k = j + int(round(12*log2(h)))
            if k >= n: break
            A[k, j] += p.nnS**(h-1)
    return A

def note_profile(p):
    # weights for treble and bass per midi
    mids = np.arange(p.lowMidi, p.highMidi+1)
    tw = np.clip((mids - p.trebleLow)/max(1, p.trebleRamp), 0, 1)   # ramp up from trebleLow
    bw = np.clip((p.bassHigh - mids)/max(1, p.bassRamp), 0, 1)
    return tw, bw

_cache = {}
def nnls_mu(A, s, iters):
    AtA = A.T @ A; Ats = A.T @ s
    x = np.maximum(Ats, 1e-9).copy()
    for _ in range(iters):
        x = x * Ats / (AtA @ x + 1e-12)
    return x

def notes_from(S, p):
    s = S.astype(np.float64).copy()
    n = len(s)
    if p.whiten in ('mean','median'):
        w = np.zeros(n)
        for i in range(n):
            a = max(0, i-p.whitenHalf); b = min(n, i+p.whitenHalf+1)
            ref = s[a:b].mean() if p.whiten == 'mean' else np.median(s[a:b])
            w[i] = max(0.0, s[i] - p.whitenK*ref)
        s = w
    if p.semiPow != 1.0: s = s**p.semiPow
    if p.nn == 'none': return s
    key = (p.nnS, p.nnH, p.lowMidi, p.highMidi)
    if key not in _cache: _cache[key] = dictionary(p)
    A = _cache[key]
    if p.nn == 'exact': x, _ = sp_nnls(A, s); return x
    return nnls_mu(A, s, p.nnIters)

def chroma3(S, p):
    x = notes_from(S, p)
    tw, bw = note_profile(p)
    mids = np.arange(p.lowMidi, p.highMidi+1)
    tre = np.zeros(12); bas = np.zeros(12)
    np.add.at(tre, mids % 12, x*tw)
    np.add.at(bas, mids % 12, x*bw)
    if p.chromaPow != 1.0: tre = tre**p.chromaPow
    return tre, bas

def binary_templates():
    T = np.zeros((60,12))
    for qi,q in enumerate(QUALS):
        for r in range(12):
            for iv in INTS[q]: T[qi*12+r, (r+iv)%12] = 1
    return T

def emissions(frames, hopSec, p):
    T = binary_templates()
    if p.tplPow != 1.0: pass
    n = len(frames)
    tre = np.zeros((n,12)); bas = np.zeros((n,12)); sil = np.zeros(n, bool)
    for j, fr in enumerate(frames):
        S, silent = fr[0], fr[1]
        if silent: sil[j] = True; continue
        t, b = chroma3(S, p)
        nt = t.sum()
        if nt > 0: t = t/nt; b = b/nt
        tre[j] = t; bas[j] = b
    w = int(round(p.smoothSec/hopSec))
    E = np.zeros((n, 61))
    # bass fit weights
    BW = np.zeros((60,12))
    for qi,q in enumerate(QUALS):
        for r in range(12):
            for k, iv in enumerate(INTS[q]):
                BW[qi*12+r, (r+iv)%12] = 1.0 if k == 0 else p.bassOther
    for j in range(n):
        a = max(0, j-w); b = min(n, j+w+1)
        st = tre[a:b].mean(axis=0); sb = bas[a:b].mean(axis=0)
        if sil[a:b].mean() > 0.5 or st.sum() <= 0:
            E[j, 0] = p.kappa; continue
        c = corr(st, T)
        if p.beta > 0 and sb.sum() > 1e-12:
            bn = sb/sb.sum()
            c = c + p.beta*(BW @ bn)
        E[j, 1:] = p.kappa*c
        E[j, 0] = p.kappa*p.noChord
    return E, tre, bas

def viterbi(E, p):
    n = len(E)
    delta = E[0].copy(); bp = np.zeros((n, 61), int)
    for j in range(1, n):
        best = delta.argmax(); move = delta[best] - p.penalty
        keep = delta >= move
        bp[j] = np.where(keep, np.arange(61), best)
        delta = np.where(keep, delta, move) + E[j]
    path = np.zeros(n, int); path[-1] = delta.argmax()
    for j in range(n-1, 0, -1): path[j-1] = bp[j, path[j]]
    return path

def P3(**kw):
    d = dict(whiten='mean', whitenHalf=9, whitenK=1.0, semiPow=1.0, nn='mu', nnS=0.6, nnH=6, nnIters=40,
             trebleLow=45, trebleRamp=12, bassHigh=57, bassRamp=12, chromaPow=1.0, tplPow=1.0, beta=0.0, bassOther=0.5,
             noChord=0.45, kappa=10.0, penalty=4.0, smoothSec=0.25)
    d.update(kw)
    return Params(**d)
