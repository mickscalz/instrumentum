import numpy as np, pickle, sys, json
from rec import events, cname
from rec5 import *
from evalr import score
data = pickle.load(open('stress.pkl','rb'))
def evaluate(p, verbose=True):
    accs = []; conf = {}
    for name, each, fr, hs, truth in data:
        E = emissions5(fr, hs, p); path = viterbi(E, p)
        a, c = score(path, truth, hs, seconds_each=each, guard=0.3 if each >= 2 else 0.2); accs.append(a)
        for k,v in c.items(): conf[k] = conf.get(k,0)+v
    print('stress mean=%.3f min=%.3f' % (np.mean(accs), min(accs)), ' '.join('%s=%.2f' % (d[0][:18], a) for d, a in zip(data, accs)))
    print('   ', sorted(conf.items(), key=lambda kv:-kv[1])[:10])
    return np.mean(accs)
if __name__ == '__main__':
    for arg in sys.argv[1:]:
        kw = json.loads(arg); print(kw); evaluate(P5(**kw))
