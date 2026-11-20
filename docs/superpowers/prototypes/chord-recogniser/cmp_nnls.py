import numpy as np, pickle
from rec3 import *
from evalr import score
data = pickle.load(open('cache.pkl','rb'))
# compare mu vs exact on a few frames
p = P3()
fr = data[0][2]
for j in [30, 80, 200]:
    S = fr[j][0]
    a = notes_from(S, P3(nn='exact')); b = notes_from(S, P3(nn='mu', nnIters=40)); c = notes_from(S, P3(nn='mu', nnIters=150))
    print(j, 'exact top', np.argsort(-a)[:5]+33, np.round(np.sort(a)[::-1][:5]/a.max(),2))
    print('   mu40 top', np.argsort(-b)[:5]+33, np.round(np.sort(b)[::-1][:5]/b.max(),2), ' rel err %.3f' % (np.linalg.norm(a-b)/np.linalg.norm(a)))
    print('   mu150   rel err %.3f' % (np.linalg.norm(a-c)/np.linalg.norm(a)))
