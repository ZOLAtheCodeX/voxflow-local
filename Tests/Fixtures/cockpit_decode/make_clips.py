"""Generate the cockpit decode probe clips.

Usage: python make_clips.py <speech.wav> <out_dir>
<speech.wav> is 16 kHz mono s16 `say` output of: "The quarterly review covers three
areas. First, the governance program now tracks every model in production, with an
owner and a review date for each one. Second, the vendor assessments moved from
spreadsheets into a shared register, which cut the turnaround from two weeks to
four days." (macOS default voice, then ffmpeg -ac 1 -ar 16000 -sample_fmt s16).

Committed fixtures, renamed from this script's outputs:
  speech_then_quiet_normal.wav = n4_s8_speech4_noise3.wav
  speech_then_quiet_weak.wav   = n6_s3_speech4_noise3.wav
  room_noise_6s.wav            = n4_noise_6s.wav
"""
import sys, wave, numpy as np
src, out = sys.argv[1], sys.argv[2]
rng = np.random.default_rng(7)
with wave.open(src) as w:
    sr = w.getframerate(); x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float64) / 32767
def rms(a): return float(np.sqrt(np.mean(a**2))) if len(a) else 0.0
def pink(n, level):
    white = rng.standard_normal(n); f = np.fft.rfft(white); f /= np.maximum(np.arange(len(f)), 1) ** 0.5
    p = np.fft.irfft(f, n); return p / rms(p) * level
speech = x / rms(x[x != 0]) if rms(x) else x
def write(name, a):
    a = np.clip(a, -1, 1); 
    with wave.open(f"{out}/{name}.wav", "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr); w.writeframes((a * 32767).astype(np.int16).tobytes())
    print(f"{name}: {len(a)/sr:.1f}s rms={rms(a):.4f}")
S = lambda sec0, sec1, level: speech[int(sec0*sr):int(sec1*sr)] * level
N = lambda sec, level: pink(int(sec*sr), level)
for nl in (0.004, 0.006):
    tag = f"n{int(nl*1000)}"
    write(f"{tag}_noise_6s", N(6, nl))
    for sl in (0.03, 0.08):
        st = f"s{int(sl*100)}"
        seg = S(0, 6, sl); write(f"{tag}_{st}_speech_6s", seg + N(len(seg)/sr, nl))
        lead = N(3, nl); seg = S(0, 4, sl)
        write(f"{tag}_{st}_noise3_speech4", np.concatenate([lead, seg + N(len(seg)/sr, nl)]))
        seg = S(6, 10, sl); write(f"{tag}_{st}_speech4_noise3", np.concatenate([seg + N(len(seg)/sr, nl), N(3, nl)]))
