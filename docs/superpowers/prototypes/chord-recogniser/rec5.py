import numpy as np
from math import *
from rec import QUALS, INTS, cname, corr, events
from rec3 import P3, chroma3, binary_templates
def emissions5(frames, hopSec, p):
    T = binary_templates()
    n = len(frames)
    tre = np.zeros((n,12)); bas = np.zeros((n,12)); sil = np.zeros(n, bool); ton = np.zeros(n)
    for j, fr in enumerate(frames):
        S, silent, tun, tf = fr
        if silent: sil[j] = True; continue
        t, b = chroma3(S, p)
        nt = t.sum()
        if nt > 0: t = t/nt; b = b/nt
        tre[j] = t; bas[j] = b; ton[j] = tf
    w = int(round(p.smoothSec/hopSec))
    E = np.zeros((n, 61))
    BW = np.zeros((60,12))
    for qi,q in enumerate(QUALS):
        for r in range(12):
            for k, iv in enumerate(INTS[q]):
                BW[qi*12+r, (r+iv)%12] = 1.0 if k == 0 else p.bassOther
    for j in range(n):
        a = max(0, j-w); b = min(n, j+w+1)
        st = tre[a:b].mean(axis=0); sb = bas[a:b].mean(axis=0); tb = ton[a:b].mean()
        E[j, 0] = p.kappa*p.noChord
        if sil[a:b].mean() > 0.5 or st.sum() <= 0: continue
        c = corr(st, T)
        if p.beta > 0 and sb.sum() > 1e-12:
            c = c + p.beta*(BW @ (sb/sb.sum()))
        g = min(1.0, max(0.0, (tb - p.tonLo)/(p.tonHi - p.tonLo)))
        if getattr(p, 'triadBias', 0) > 0:
            c = c.copy(); c[:24] += p.triadBias
        E[j, 1:] = p.kappa*g*c
    return E
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
def P5(**kw):
    d = dict(beta=0.3, chromaPow=0.5, tonLo=0.15, tonHi=0.35, noChord=0.5)
    d.update(kw)
    return P3(**d)
