# Synth mirroring the planned Swift test synth
import numpy as np
from math import *
class XorShift:
    def __init__(self, seed): self.s = seed & 0xFFFFFFFFFFFFFFFF or 1
    def next(self):
        x = self.s; x ^= (x << 13) & 0xFFFFFFFFFFFFFFFF; x ^= x >> 7; x ^= (x << 17) & 0xFFFFFFFFFFFFFFFF; self.s = x; return x
    def uniform(self): return (self.next() >> 11) / float(1 << 53) * 2 - 1
NAMES = {'C':0,'C#':1,'Db':1,'D':2,'Eb':3,'E':4,'F':5,'F#':6,'G':7,'Ab':8,'A':9,'Bb':10,'B':11}
def note(n):
    return 12*(int(n[-1])+1) + NAMES[n[:-1]]
SHAPES = {
 'C': 'C3 E3 G3 C4 E4', 'G': 'G2 B2 D3 G3 B3 G4', 'Am': 'A2 E3 A3 C4 E4', 'F': 'F2 C3 F3 A3 C4 F4',
 'C7': 'C3 E3 Bb3 C4 E4', 'Cmaj7': 'C3 E3 G3 B3 E4', 'Cm7': 'C3 G3 Bb3 Eb4 G4',
}
class Song:
    def __init__(self, rate, seconds, cents=0.0):
        self.rate = rate; self.cents = cents; self.x = np.zeros(int(round(seconds*rate)))
    def strum(self, notes, at, seconds, amp=0.12, harmonics=5, decay=1.2, spread=0.012):
        n0 = int(round(at*self.rate)); n1 = min(len(self.x), int(round((at+seconds)*self.rate)))
        for i, m in enumerate(notes):
            f = 440*2**((m-69)/12 + self.cents/1200)
            s0 = n0 + int(round(i*spread*self.rate))
            if s0 >= n1: continue
            t = np.arange(n1-s0)/self.rate
            env = np.exp(-t/decay)*np.minimum(1, t/0.004)
            fade = np.minimum(1, (n1-s0-1-np.arange(n1-s0))/(0.01*self.rate)); env *= np.maximum(0, fade)
            sig = np.zeros_like(t)
            for h in range(1, harmonics+1):
                if f*h > 0.45*self.rate: break
                sig += np.sin(2*pi*f*h*t + 0.7*h + i)/h
            self.x[s0:n1] += amp*env*sig
    def chord(self, name, at, seconds, strums=4):
        notes = [note(n) for n in SHAPES[name].split()]
        for k in range(strums): self.strum(notes, at + k*seconds/strums, seconds/strums)
    def noise(self, level, seed):
        r = XorShift(seed)
        for i in range(len(self.x)): self.x[i] += level*(r.uniform()+r.uniform()+r.uniform())  # ~ sd level
    def samples(self): return self.x.astype(np.float32)
def progression(rate=44100.0, cents=0.0, names=('C','G','Am','F'), each=2.0, tail=3.0):
    s = Song(rate, len(names)*each + tail, cents)
    for k, n in enumerate(names): s.chord(n, k*each, each)
    s.noise(0.003, 7)
    return s.samples()
