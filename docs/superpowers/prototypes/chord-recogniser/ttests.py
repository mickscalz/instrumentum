import numpy as np, time, sys
from stream import ChordRecognizer, cname
from tsynth import *
def feed(r, x, start, piece, rate):
    i = 0
    while i < len(x):
        k = min(piece, len(x)-i); r.feed(x[i:i+k], start + i/rate); i += k
t0 = time.time()
# 1 progression
x = progression(); r = ChordRecognizer(44100.0); feed(r, x, 0.0, 4096, 44100.0)
ev = r.chords(11.0); print('progression', [(round(t,2), c) for t, c in ev], 'key', r.key, 'tuning %.1f' % r.tuning)
ev = r.chords(3.0); print('  upTo 3', ev)
# 2 tuning at 48k
x = progression(48000.0, cents=-30); r = ChordRecognizer(48000.0); feed(r, x, 0.0, 4096, 48000.0)
print('flat30@48k', [(round(t,2), c) for t, c in r.chords(11)], 'tuning %.1f' % r.tuning)
# 3 sevenths
x = progression(names=('C','C7','Cmaj7','Cm7')); r = ChordRecognizer(44100.0); feed(r, x, 0.0, 4096, 44100.0)
print('sevenths', [(round(t,2), c) for t, c in r.chords(11)])
# 4 settle look-back
x = progression(); r = ChordRecognizer(44100.0); feed(r, x[:5*44100], 0.0, 4096, 44100.0)
print('after 5 s', [(round(t,2), c) for t, c in r.chords(5.0)])
# 5 seek
r = ChordRecognizer(44100.0); feed(r, x, 0.0, 4096, 44100.0)
feed(r, x[2*44100:5*44100], 2.0, 4096, 44100.0)
print('after seek back to 2..5', [(round(t,2), c) for t, c in r.chords(11)])
feed(r, x, 0.0, 4096, 44100.0)
print('after second full pass', [(round(t,2), c) for t, c in r.chords(11)])
# seek to the middle first then the start
r = ChordRecognizer(44100.0); feed(r, x[4*44100:], 4.0, 4096, 44100.0); a = r.chords(11)
feed(r, x[:4*44100], 0.0, 4096, 44100.0)
print('middle first', [(round(t,2), c) for t, c in a], '-> then start', [(round(t,2), c) for t, c in r.chords(11)])
# 6 pieces
r1 = ChordRecognizer(44100.0); feed(r1, x, 0.0, len(x), 44100.0)
r2 = ChordRecognizer(44100.0); feed(r2, x, 0.0, 512, 44100.0)
print('one piece == 512 pieces', r1.chords(11) == r2.chords(11), r1.tuning, r2.tuning)
print('took %.1f s' % (time.time()-t0))
