import pickle, sys, json
from rec import events
from rec5 import *
scf = pickle.load(open('scen5.pkl','rb'))
for arg in sys.argv[1:]:
    p = P5(**json.loads(arg)); out = []
    for name, (fr, hs, exp) in scf.items():
        E = emissions5(fr, hs, p); path = viterbi(E, p); ev = events(path, hs)
        out.append('%s:%s' % (name, ' '.join(c for t, c in ev[:5]) or '-'))
    print(' | '.join(out))
