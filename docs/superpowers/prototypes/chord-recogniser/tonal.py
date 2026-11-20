import numpy as np
from math import *
def tonal_fraction(X, binHz, k=5.0, band=32, pct=0.25, fmin=55.0, fmax=2000.0, halfw=2):
    """fraction of power (fmin..fmax) within +-halfw bins of prominent local maxima."""
    kLo = int(ceil(fmin/binHz)); kHi = int(floor(fmax/binHz))
    P = X**2
    tot = P[kLo:kHi+1].sum()
    if tot <= 0: return 0.0
    tonal = 0.0
    nb = (kHi - kLo + 1 + band - 1)//band
    floor_ = np.zeros(len(X))
    for b in range(nb):
        a = kLo + b*band; e = min(kHi+1, a+band)
        seg = np.sort(X[a:e]); fl = seg[int(pct*(len(seg)-1))]
        floor_[a:e] = fl
    last = -10
    for i in range(kLo, kHi+1):
        v = X[i]
        if v > X[i-1] and v >= X[i+1] and v > k*floor_[i]:
            lo = max(kLo, i-halfw, last+halfw+1); hi = min(kHi, i+halfw)
            tonal += P[lo:hi+1].sum(); last = i
    return tonal/tot
