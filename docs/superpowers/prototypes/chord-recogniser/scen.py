import numpy as np
from synth import *
from rec import *
from rec2 import *
fs = 44100
def pink(n, rng):
    w = rng.standard_normal(n)
    X = np.fft.rfft(w); f = np.arange(len(X)); f[0] = 1
    X /= np.sqrt(f)
    y = np.fft.irfft(X, n)
    return y / np.sqrt(np.mean(y**2))
def scenarios():
    rng = np.random.default_rng(5)
    sc = {}
    sc['white-20'] = (0.1*rng.standard_normal(6*fs)).astype(np.float32), []
    sc['pink-20'] = (0.1*pink(6*fs, rng)).astype(np.float32), []
    sc['silence'] = np.zeros(6*fs, np.float32), []
    # percussion: noise bursts every 0.25 s
    x = np.zeros(6*fs)
    for k in range(24):
        n0 = int(k*0.25*fs); t = np.arange(int(0.2*fs))/fs
        x[n0:n0+len(t)] += 0.3*np.exp(-t/0.03)*rng.standard_normal(len(t))
        if k % 2 == 0:  # kick: decaying low sine sweep
            x[n0:n0+len(t)] += 0.5*np.exp(-t/0.08)*np.sin(2*np.pi*(50+80*np.exp(-t/0.02))*t)
    sc['drums'] = x.astype(np.float32), []
    # C with loud bass root
    def c_with_bass(bassnotes, bass_amp=0.35, each=0.5, total=6.0):
        x = np.zeros(int(total*fs))
        for s in range(int(total/0.5)):
            strum(x, fs, s*0.5, [midi(n) for n in ['C4','E4','G4','C5']], 0.5, harmonics=5)
        nb = int(total/each)
        for k in range(nb):
            m = midi(bassnotes[k % len(bassnotes)])
            strum(x, fs, k*each, [m], each, amp=bass_amp, harmonics=6, decay=2.0)
        x += 10**(-50/20)*rng.standard_normal(len(x))
        return x.astype(np.float32)
    sc['C+bassC'] = c_with_bass(['C2']), [(0,'C')]
    sc['C+bassCG'] = c_with_bass(['C2','G2']), [(0,'C')]
    sc['C+walk'] = c_with_bass(['C2','B1','A1','G1']), [(0,'C')]
    sc['C+bassA'] = c_with_bass(['A1'], each=0.5), [(0,'Am7')]  # legit Am7?
    sc['C+bassE'] = c_with_bass(['E2'], each=0.5), [(0,'C')]
    return sc
def run(p, sc, verbose=True):
    res = {}
    for name, (x, exp) in sc.items():
        fr, hs = analyse(x, fs, p)
        path, E, _ = decode2(fr, hs, p)
        ev = events(path, hs)
        res[name] = ev
        if verbose: print('   %-10s' % name, [(round(t,2), c) for t, c in ev][:8])
    return res
if __name__ == '__main__':
    sc = scenarios()
    for kw in [dict(whiten='mean', chromaPow=0.5), dict(whiten='median', chromaPow=0.5), dict(whiten='mean', chromaPow=0.5, beta=0.3)]:
        p = Params(**{**dict(whitenHalf=9, whitenK=1.0, semiPow=1.0, octMode='sum', chromaPow=1.0, templateMode='harm', frameNorm='sum'), **kw})
        print(kw)
        run(p, sc)
