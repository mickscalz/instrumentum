import numpy as np
from math import *
QUALS = ['maj','min','7','maj7','m7']
INTS = [(0,4,7),(0,3,7),(0,4,7,10),(0,4,7,11),(0,3,7,10)]
NAMES = ['C','C#','D','Eb','E','F','F#','G','Ab','A','Bb','B']
SUF = ['','m','7','maj7','m7']
def cname(lbl):
    if lbl < 0: return '?'
    if lbl == 0: return 'N'
    s = lbl - 1; return NAMES[s % 12] + SUF[s // 12]
KK_MAJ = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
KK_MIN = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

class ChordRecognizer:
    frameSize = 4096; hopDec = 512; lowMidi = 33; highMidi = 95; notes = 63
    maxSeconds = 2400.0; tuningSeconds = 20.0; continuity = 0.25
    whitenHalf = 6; harmonicDecay = 0.6; harmonics = 6; nnIters = 24
    trebleLow = 45; trebleRamp = 12; bassHigh = 57; bassRamp = 12
    chromaPower = 0.7; bassWeight = 0.5; bassOther = 0.5; triadBias = 0.04
    noChord = 0.5; kappa = 10.0; penalty = 8.0; smoothSeconds = 0.25; lagSeconds = 2.0; minSeconds = 0.4
    tonalLow = 0.15; tonalHigh = 0.35; ringSlots = 128

    def __init__(self, fs):
        self.fs = fs
        self.D = max(1, int(fs / 11025.0))
        self.fsd = fs / self.D
        self.hop = self.hopDec * self.D
        self.slotSec = self.hop / fs
        self.slotCount = int(self.maxSeconds / self.slotSec) + 1
        self.binHz = self.fsd / self.frameSize
        D = self.D
        if D == 1: self.taps = np.array([1.0])
        else:
            P = 16*D; n = np.arange(P) - (P-1)/2; fc = 0.5/D
            h = 2*fc*np.sinc(2*fc*n) * (0.42 - 0.5*np.cos(2*np.pi*np.arange(P)/(P-1)) + 0.08*np.cos(4*np.pi*np.arange(P)/(P-1)))
            self.taps = h / h.sum()
        self.P = len(self.taps)
        self.window = (0.5 - 0.5*np.cos(2*np.pi*np.arange(self.frameSize)/self.frameSize))
        # dictionary
        A = np.zeros((63,63))
        for j in range(63):
            for h in range(1, self.harmonics+1):
                k = j + int(round(12*log2(h)))
                if k >= 63: break
                A[k, j] += self.harmonicDecay**(h-1)
        self.At = A.T.copy(); self.AtA = A.T @ A
        mids = np.arange(self.lowMidi, self.highMidi+1)
        self.trebleW = np.clip((mids - self.trebleLow)/self.trebleRamp, 0, 1)
        self.bassW = np.clip((self.bassHigh - mids)/self.bassRamp, 0, 1)
        # templates: centred, unit norm
        T = np.zeros((60,12)); BW = np.zeros((60,12))
        for q in range(5):
            for r in range(12):
                for k, iv in enumerate(INTS[q]):
                    T[q*12+r, (r+iv)%12] = 1
                    BW[q*12+r, (r+iv)%12] = 1.0 if k == 0 else self.bassOther
        T = T - T.mean(axis=1, keepdims=True); T /= np.linalg.norm(T, axis=1, keepdims=True)
        self.T = T; self.BW = BW
        self.smoothSlots = int(round(self.smoothSeconds/self.slotSec))
        self.lagSlots = int(round(self.lagSeconds/self.slotSec))
        self.minSlots = int(ceil(self.minSeconds/self.slotSec - 1e-9))
        # timeline
        self.chroma = np.zeros((self.slotCount, 12)); self.bass = np.zeros((self.slotCount, 12))
        self.tonal = np.zeros(self.slotCount); self.silent = np.zeros(self.slotCount); self.count = np.zeros(self.slotCount)
        self.labels = np.full(self.slotCount, -1, np.int8)
        self.reset_private()
        self.tuning = 0.0; self.key = None

    def reset_private(self):
        self.chroma[:] = 0; self.bass[:] = 0; self.tonal[:] = 0; self.silent[:] = 0; self.count[:] = 0
        self.inSegment = False
        self.tunRe = 0.0; self.tunIm = 0.0; self.heard = 0.0; self.tun = 0.0
        self.keyAcc = np.zeros(12); self.keyWeight = 0.0; self.framesSinceKey = 0
        self.delta = np.zeros(61); self.bp = np.zeros((self.ringSlots, 61), np.int16)

    def reset(self):
        self.labels[:] = -1; self.tuning = 0.0; self.key = None
        self.reset_private()

    # ---- segments
    def start_segment(self, time):
        self.inSegment = True
        self.segTime = time; self.segSamples = 0
        self.stage = np.zeros(self.P//2)   # P/2 zeros
        self.ring = np.zeros(self.frameSize); self.ringPos = 0
        self.untilFrame = self.frameSize//2
        self.frameIndex = 0
        self.slot0 = int(round(time/self.slotSec))
        self.vStart = None; self.vLast = None; self.settled = None; self.frontier = None

    def end_segment(self):
        if not self.inSegment: return
        # step remaining slots up to frontier, then settle everything pending
        if self.vStart is not None:
            j = (self.vLast + 1) if self.vLast is not None else self.vStart
            while j <= self.frontier:
                self.step(j); j += 1
            self.settle_all()
        self.inSegment = False

    def feed(self, x, time):
        x = np.asarray(x, dtype=np.float64)
        if self.inSegment:
            expected = self.segTime + self.segSamples/self.fs
            if abs(time - expected) > self.continuity:
                self.end_segment()
        if not self.inSegment: self.start_segment(time)
        self.segSamples += len(x)
        pos = 0
        while pos < len(x):
            k = min(4096, len(x) - pos)
            self.stage = np.concatenate([self.stage, x[pos:pos+k]]); pos += k
            if len(self.stage) >= self.P:
                n = (len(self.stage) - self.P)//self.D + 1
                idx = np.arange(n)*self.D
                out = np.array([self.stage[i:i+self.P] @ self.taps for i in idx])
                self.stage = self.stage[n*self.D:]
                self.push_decimated(out)

    def push_decimated(self, out):
        i = 0
        while i < len(out):
            k = min(self.untilFrame, len(out) - i)
            for v in out[i:i+k]:
                self.ring[self.ringPos] = v; self.ringPos = (self.ringPos + 1) % self.frameSize
            i += k; self.untilFrame -= k
            if self.untilFrame == 0:
                self.frame(); self.untilFrame = self.hopDec

    def frame(self):
        seg = np.concatenate([self.ring[self.ringPos:], self.ring[:self.ringPos]]) * self.window
        slot = self.slot0 + self.frameIndex; self.frameIndex += 1
        energy = np.sum(seg*seg)
        silent = energy < 1e-9
        X = np.abs(np.fft.rfft(seg))[:self.frameSize//2]; X[0] = 0
        tf = 0.0 if silent else self.tonal_fraction(X)
        if not silent and tf > 0.3 and self.heard < self.tuningSeconds:
            self.learn_tuning(X)
        t = np.zeros(12); b = np.zeros(12)
        if not silent:
            S = self.semitones(X)
            t, b = self.chroma_of(S)
        if 0 <= slot < self.slotCount:
            self.chroma[slot] += t; self.bass[slot] += b; self.tonal[slot] += tf
            self.silent[slot] += 1 if silent else 0; self.count[slot] += 1
            if not silent:
                g = min(1, max(0, (tf - self.tonalLow)/(self.tonalHigh - self.tonalLow)))
                self.keyAcc += g*t; self.keyWeight += g
            self.frontier = slot
            if self.vStart is None:
                self.vStart = slot
            # step the viterbi for slot - smooth
            j = slot - self.smoothSlots
            if j >= self.vStart:
                self.step(j)
        self.framesSinceKey += 1
        if self.framesSinceKey >= 43:
            self.framesSinceKey = 0; self.update_key()

    def tonal_fraction(self, X):
        binHz = self.binHz
        kLo = int(ceil(50/binHz)); kHi = int(floor(2000/binHz))
        P = X*X; tot = P[kLo:kHi+1].sum()
        if tot <= 0: return 0.0
        band = 32; fl = np.zeros(len(X))
        k = kLo
        while k <= kHi:
            e = min(kHi+1, k+band); seg = np.sort(X[k:e]); fl[k:e] = seg[(len(seg)-1)//4]; k = e
        tonal = 0.0; last = -100
        for i in range(kLo, kHi+1):
            v = X[i]
            if v > X[i-1] and v >= X[i+1] and v > 5*fl[i]:
                lo = max(kLo, i-2, last+3); hi = min(kHi, i+2)
                if hi >= lo: tonal += P[lo:hi+1].sum()
                last = i
        return tonal/tot

    def learn_tuning(self, X):
        binHz = self.binHz
        kLo = int(80/binHz); kHi = int(1500/binHz)
        mx = X[kLo:kHi].max()
        for k in range(kLo, kHi):
            v = X[k]
            if v > X[k-1] and v >= X[k+1] and v > mx*0.01:
                loc = X[k-10:k+11].mean()
                if v < 3*loc: continue
                a, b, c = log(X[k-1]+1e-20), log(v), log(X[k+1]+1e-20)
                d = a - 2*b + c
                off = 0.5*(a-c)/d if d < 0 else 0.0
                cts = 1200*log2((k+off)*binHz/440.0)
                dev = cts - 100*round(cts/100)
                self.tunRe += v*cos(2*pi*dev/100); self.tunIm += v*sin(2*pi*dev/100)
        self.heard += self.slotSec
        self.tun = atan2(self.tunIm, self.tunRe)*100/(2*pi) if (self.tunRe != 0 or self.tunIm != 0) else 0.0
        self.tuning = self.tun

    def semitones(self, X):
        S = np.zeros(63); binHz = self.binHz
        for i in range(63):
            m = self.lowMidi + i
            fc = 440*2**((m-69)/12 + self.tun/1200)
            kc = fc/binHz; k0 = int(kc); fr = kc - k0
            v = X[k0]*(1-fr) + X[k0+1]*fr
            lo = int(ceil(fc*2**(-1/24)/binHz)); hi = int(floor(fc*2**(1/24)/binHz))
            if hi >= lo: v = max(v, X[lo:hi+1].max())
            S[i] = v
        return S

    def chroma_of(self, S):
        n = 63; w = np.zeros(n)
        for i in range(n):
            a = max(0, i-self.whitenHalf); b = min(n, i+self.whitenHalf+1)
            w[i] = max(0.0, S[i] - S[a:b].mean())
        Ats = self.At @ w
        x = np.maximum(Ats, 1e-12)
        for _ in range(self.nnIters):
            x = x * Ats / (self.AtA @ x + 1e-12)
        t = np.zeros(12); b = np.zeros(12)
        for i in range(n):
            m = (self.lowMidi + i) % 12
            t[m] += x[i]*self.trebleW[i]; b[m] += x[i]*self.bassW[i]
        t = t**self.chromaPower
        s = t.sum()
        if s > 0: t = t/s; b = b/s
        return t, b

    def emission(self, j):
        a = max(0, j - self.smoothSlots); b = min(self.slotCount-1, j + self.smoothSlots)
        st = np.zeros(12); sb = np.zeros(12); ton = 0.0; sil = 0.0; n = 0
        for i in range(a, b+1):
            c = self.count[i]
            if c > 0:
                st += self.chroma[i]/c; sb += self.bass[i]/c; ton += self.tonal[i]/c; sil += self.silent[i]/c; n += 1
        E = np.zeros(61); E[0] = self.kappa*self.noChord
        if n == 0 or sil/n > 0.5: return E
        ton /= n
        mean = st.sum()/12; xm = st - mean; nrm = np.linalg.norm(xm)
        if nrm <= 1e-12: return E
        c = self.T @ (xm/nrm)
        bs = sb.sum()
        if bs > 1e-12: c = c + self.bassWeight*(self.BW @ (sb/bs))
        c[:24] += self.triadBias
        g = min(1, max(0, (ton - self.tonalLow)/(self.tonalHigh - self.tonalLow)))
        E[1:] = self.kappa*g*c
        return E

    def step(self, j):
        e = self.emission(j)
        if self.vLast is None:
            self.delta = e.copy(); self.bp[j % self.ringSlots] = np.arange(61)
            self.settled = j - 1
        else:
            best = int(np.argmax(self.delta)); move = self.delta[best] - self.penalty
            keep = self.delta >= move
            self.bp[j % self.ringSlots] = np.where(keep, np.arange(61), best)
            self.delta = np.where(keep, self.delta, move) + e
            self.delta -= self.delta.max()
        self.vLast = j
        if j - self.lagSlots > self.settled:
            # backtrack from best at j to j-lag
            s = int(np.argmax(self.delta)); k = j
            while k > j - self.lagSlots:
                s = int(self.bp[k % self.ringSlots, s]); k -= 1
            self.publish(k, s); self.settled = k

    def settle_all(self):
        if self.vLast is None: return
        s = int(np.argmax(self.delta)); k = self.vLast
        path = {}
        while k > self.settled:
            path[k] = s
            s = int(self.bp[k % self.ringSlots, s]); k -= 1
        for k in sorted(path): self.publish(k, path[k])
        self.settled = self.vLast

    def publish(self, slot, state):
        if 0 <= slot < self.slotCount: self.labels[slot] = state

    def update_key(self):
        if self.keyWeight * self.slotSec < 8.0: return
        acc = self.keyAcc
        best = -2; bk = None
        for r in range(12):
            for minor, prof in ((False, KK_MAJ), (True, KK_MIN)):
                c = np.corrcoef(acc, np.roll(prof, r))[0,1]
                if c > best: best = c; bk = (r, minor)
        self.key = bk

    def chords(self, upTo):
        last = min(self.slotCount-1, int(floor(upTo/self.slotSec)))
        if last < 0: return []
        return events_from(self.labels[:last+1].copy(), self.slotSec, self.minSlots)

def events_from(labels, slotSec, minSlots):
    runs = []
    for j, s in enumerate(labels):
        s = int(s)
        if runs and runs[-1][0] == s: runs[-1][2] = j
        else: runs.append([s, j, j])
    # absorb short known runs
    out = []
    i = 0
    pending_short = None
    for r in runs:
        lbl, a, b = r
        if lbl < 0:
            out.append(r); continue
        if b - a + 1 < minSlots:
            if out and out[-1][0] >= 0:
                out[-1][2] = b; continue
            # no known previous: carry into next known run
            r = [lbl, a, b]; r.append('short'); out.append(r); continue
        if out and len(out[-1]) == 4:   # previous was a short orphan: absorb into this run
            a = out[-1][1]; out.pop()
        if out and out[-1][0] == lbl and out[-1][2] == a - 1:
            out[-1][2] = b
        else: out.append([lbl, a, b])
    ev = []
    for r in out:
        if len(r) == 4: continue
        lbl, a, b = r
        if lbl >= 1: ev.append((max(0.0, (a - 0.5)*slotSec), cname(lbl)))
    return ev
