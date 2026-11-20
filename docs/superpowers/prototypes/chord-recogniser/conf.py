import numpy as np, pickle, sys, json
from rec5 import *
from evalr import score
stress = pickle.load(open('stress.pkl','rb')); easy = pickle.load(open('cache5.pkl','rb'))
for arg in sys.argv[1:]:
    kw = json.loads(arg); p = P5(**kw); print(kw)
    for nm, data in [('stress', stress), ('easy', easy)]:
        conf = {}; accs = []
        for name, each, fr, hs, truth in data:
            E = emissions5(fr, hs, p); path = viterbi(E, p)
            e = each if isinstance(each, float) else 2.0
            a, c = score(path, truth, hs, seconds_each=e, guard=0.3 if e >= 2 else 0.2); accs.append(a)
            for k,v in c.items(): conf[k] = conf.get(k,0)+v
        print('  %s %.3f/%.3f' % (nm, np.mean(accs), min(accs)), sorted(conf.items(), key=lambda kv:-kv[1])[:8])
