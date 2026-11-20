import numpy as np
NOTE = {'C':0,'C#':1,'Db':1,'D':2,'D#':3,'Eb':3,'E':4,'F':5,'F#':6,'Gb':6,'G':7,'G#':8,'Ab':8,'A':9,'A#':10,'Bb':10,'B':11}
def midi(name):
    # e.g. 'C4', 'Bb3'
    n = name[:-1]; o = int(name[-1])
    return 12*(o+1) + NOTE[n]

VOICINGS = {
    'C':   ['C3','E3','G3','C4','E4'],
    'G':   ['G2','B2','D3','G3','B3','G4'],
    'Am':  ['A2','E3','A3','C4','E4'],
    'F':   ['F2','C3','F3','A3','C4','F4'],
    'C7':  ['C3','E3','Bb3','C4','E4','G4'],
    'Cmaj7':['C3','E3','G3','B3','E4'],
    'Cm7': ['C3','G3','Bb3','Eb4','G4'],
    'Dm':  ['D3','A3','D4','F4'],
    'Em':  ['E2','B2','E3','G3','B3','E4'],
}

def strum(out, fs, t0, notes, dur, cents=0.0, amp=0.12, harmonics=5, decay=1.2, rng=None, start_spread=0.012):
    # adds a strum of `notes` (midi numbers) starting at t0 for dur seconds into out
    n0 = int(round(t0*fs)); n1 = min(len(out), int(round((t0+dur)*fs)))
    for i, m in enumerate(notes):
        f = 440.0 * 2**((m-69)/12 + cents/1200)
        s0 = n0 + int(i*start_spread*fs)
        if s0 >= n1: continue
        t = np.arange(n1-s0)/fs
        env = np.exp(-t/decay) * np.minimum(1, t/0.004)
        # fade the last 10 ms to avoid clicks
        tail = min(len(t), int(0.01*fs)); env[-tail:] *= np.linspace(1,0,tail)
        sig = np.zeros_like(t)
        for h in range(1, harmonics+1):
            if f*h > fs/2*0.9: break
            sig += (1.0/h) * np.sin(2*np.pi*f*h*t + 0.7*h + i)
        out[s0:n1] += amp*env*sig

def song(chords, fs=44100, seconds_each=2.0, cents=0.0, strums_per_chord=4, noise_db=-50, harmonics=5, bass=None, seed=1):
    rng = np.random.default_rng(seed)
    total = len(chords)*seconds_each
    out = np.zeros(int(round(total*fs)))
    for k, c in enumerate(chords):
        notes = [midi(n) for n in VOICINGS[c]] if isinstance(c, str) else c
        sd = seconds_each/strums_per_chord
        for s in range(strums_per_chord):
            strum(out, fs, k*seconds_each + s*sd, notes, sd if s < strums_per_chord-1 else sd, cents=cents, harmonics=harmonics, rng=rng)
    out += 10**(noise_db/20) * rng.standard_normal(len(out))
    return out.astype(np.float32)
