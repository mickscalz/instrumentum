import numpy as np
from math import *
from rec import QUALS, INTS, NAMES, cname, Params, templates, corr, events

def chroma2(S, p):
    s = S.astype(np.float64).copy()
    n = len(s)
    if p.whiten in ('mean', 'median', 'min'):
        w = np.zeros(n)
        for i in range(n):
            a = max(0, i-p.whitenHalf); b = min(n, i+p.whitenHalf+1)
            if p.whiten == 'mean': ref = s[a:b].mean()
            elif p.whiten == 'median': ref = np.median(s[a:b])
            w[i] = max(0.0, s[i] - p.whitenK*ref)
        s = w
    if p.semiPow != 1.0: s = s**p.semiPow
    tre = np.zeros(12); bas = np.zeros(12)
    mids = np.arange(p.lowMidi, p.highMidi+1)
    for i, mm in enumerate(mids):
        wt = 1.0
        if mm >= p.trebleLow:
            if p.octMode == 'sum': tre[mm % 12] += s[i]
            else: tre[mm % 12] = max(tre[mm % 12], s[i])
        if mm <= p.bassHigh: bas[mm % 12] += s[i]
    if p.chromaPow != 1.0: tre = tre**p.chromaPow
    return tre, bas

def decode2(frames, hopSec, p):
    T = templates(p)
    if p.templateMode == 'binary':
        T = np.zeros((60,12))
        for qi,q in enumerate(QUALS):
            for r in range(12):
                for iv in INTS[q]: T[qi*12+r, (r+iv)%12] = 1
    n = len(frames)
    tre = np.zeros((n,12)); bas = np.zeros((n,12)); sil = np.zeros(n, bool)
    for j, (S, silent, tun, rms) in enumerate(frames):
        if silent: sil[j] = True; continue
        t, b = chroma2(S, p)
        nt = np.linalg.norm(t) if p.frameNorm == 'l2' else t.sum()
        if nt > 0: t = t/nt; b = b/nt
        tre[j] = t; bas[j] = b
    w = int(round(p.smoothSec/hopSec))
    E = np.zeros((n, 61))
    for j in range(n):
        a = max(0, j-w); b = min(n, j+w+1)
        st = tre[a:b].mean(axis=0); sb = bas[a:b].mean(axis=0)
        silfrac = sil[a:b].mean()
        if silfrac > 0.5 or st.sum() <= 0:
            E[j, 0] = p.kappa*1.0; continue
        c = corr(st, T)
        if p.beta > 0 and sb.sum() > 0:
            bn = sb/sb.sum()
            c = c + p.beta*np.array([bn[k % 12] for k in range(60)])
        E[j, 1:] = p.kappa*c
        E[j, 0] = p.kappa*p.noChord
    delta = E[0].copy(); bp = np.zeros((n, 61), int)
    for j in range(1, n):
        best = delta.argmax()
        move = delta[best] - p.penalty
        keep = delta >= move
        bp[j] = np.where(keep, np.arange(61), best)
        delta = np.where(keep, delta, move) + E[j]
    path = np.zeros(n, int); path[-1] = delta.argmax()
    for j in range(n-1, 0, -1): path[j-1] = bp[j, path[j]]
    return path, E, tre
