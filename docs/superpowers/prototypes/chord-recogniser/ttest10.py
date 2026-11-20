import numpy as np, time
from stream import ChordRecognizer
from tsynth import *
R = 44100.0
s = Song(R, 8.0)
for k, n in enumerate(['C','G','Am','F']): s.chord(n, k*2.0, 2.0)
s.noise(0.003, 7)
x = s.samples()
r = ChordRecognizer(R)
t0 = time.time()
for rep in range(75):
    i = 0
    while i < len(x):
        k = min(4096, len(x)-i); r.feed(x[i:i+k], rep*8.0 + i/R); i += k
ev = r.chords(600.0)
names = [c for t, c in ev]
print('events', len(ev), names[:8], names[-4:], 'took', time.time()-t0)
bad = [(round(t,2), c) for k, (t, c) in enumerate(ev) if c != ['C','G','Am','F'][k % 4] or abs(t - 2.0*k) > 0.3]
print('bad', bad[:10])
