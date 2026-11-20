import numpy as np
from stream import ChordRecognizer
from tsynth import *
from ttests import feed
R = 44100.0
# silence
r = ChordRecognizer(R); feed(r, np.zeros(int(6*R), np.float32), 0.0, 4096, R); print('silence', r.chords(6), r.tuning, r.key)
# white noise
s = Song(R, 6.0); s.noise(0.1, 3); x = s.samples()
r = ChordRecognizer(R); feed(r, x, 0.0, 4096, R); print('white', r.chords(6), round(r.tuning,1), r.key)
# low-passed (brown-ish) noise
y = np.zeros_like(x); acc = 0.0
for i in range(len(x)): acc = 0.98*acc + x[i]; y[i] = acc*0.2
print('brown rms', np.sqrt(np.mean(y**2)))
r = ChordRecognizer(R); feed(r, y.astype(np.float32), 0.0, 4096, R); print('brown', r.chords(6), round(r.tuning,1), r.key)
# loud bass root under C
def c_over(bass_names, each=0.5, seconds=6.0, bass_amp=0.35):
    s = Song(R, seconds + 3)
    for k in range(int(seconds/0.5)): s.strum([note(n) for n in 'C4 E4 G4 C5'.split()], k*0.5, 0.5)
    for k in range(int(seconds/each)):
        s.strum([note(bass_names[k % len(bass_names)])], k*each, each, amp=bass_amp, harmonics=6, decay=2.0)
    s.noise(0.003, 5)
    return s.samples()
for bn in (['C2'], ['C2','B1','A1','G1'], ['C2','G2']):
    x = c_over(bn); r = ChordRecognizer(R); feed(r, x, 0.0, 4096, R)
    print('C over', bn, [(round(t,2), c) for t, c in r.chords(9)])
