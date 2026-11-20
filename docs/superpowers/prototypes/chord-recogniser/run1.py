import numpy as np, sys
from synth import *
from rec import *
fs = 44100
def show(x, p, label, cents=None):
    fr, hs = analyse(x, fs, p, cents)
    path, E = decode(fr, hs, p)
    ev = events(path, hs)
    print(label, 'tuning=%.1f' % fr[-1][2], [(round(t,2), c) for t, c in ev])
p = Params()
x = song(['C','G','Am','F'])
show(x, p, 'CGAmF')
x = song(['C','G','Am','F'], cents=-30)
show(x, p, 'flat30')
x = song(['C','C7','Cmaj7','Cm7'])
show(x, p, '7ths')
