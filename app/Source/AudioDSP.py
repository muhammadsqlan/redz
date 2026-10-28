"""Remove subsonic bias without changing speech length or timing."""
import math
import numpy as np


def clean_audio(samples, rate):
    samples = np.asarray(samples, dtype=np.float64)
    if not np.all(np.isfinite(samples)):
        raise ValueError("Speech audio contains invalid samples.")
    if not len(samples):
        return samples.astype(np.float32)
    # A 30 Hz Butterworth high-pass removes varying DC offsets and rumble.
    # Zero padding lets the causal filter settle rather than wrapping its tail
    # into the first word. Filtering adds no samples and removes none.
    k = math.tan(math.pi * 30 / rate)
    norm = 1 / (1 + math.sqrt(2) * k + k * k)
    a1 = 2 * (k * k - 1) * norm
    a2 = (1 - math.sqrt(2) * k + k * k) * norm
    size = 1 << (len(samples) + rate // 2 - 1).bit_length()
    z = np.exp(-2j * math.pi * np.fft.rfftfreq(size))
    response = norm * (1 - 2*z + z*z) / (1 + a1*z + a2*z*z)
    response[0] = 0
    filtered = np.fft.irfft(np.fft.rfft(samples, n=size) * response, n=size)[:len(samples)].copy()
    # Speech starts after the model's silent lead-in. These short edge ramps
    # remove residual filter transients without fading a word's first sound.
    edge = min(int(rate * .01), len(filtered) // 2)
    if edge:
        ramp = np.sin(np.linspace(0, math.pi/2, edge)) ** 2
        filtered[:edge] *= ramp
        filtered[-edge:] *= ramp[::-1]
    peak = float(np.max(np.abs(filtered)))
    if peak > .9:
        filtered *= .9 / peak
    return filtered.astype(np.float32)
