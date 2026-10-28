"""Local, pipe-only Kokoro speech worker. No network or temporary audio files."""
import base64
import ctypes
import difflib
import hashlib
import io
import json
import os
import sys
import wave
import threading
from collections import deque, OrderedDict
from pathlib import Path

import numpy as np
import onnxruntime as ort
import espeakng_loader
from phonemizer.backend.espeak.api import EspeakAPI
from kokoro_onnx import Kokoro
from kokoro_onnx.trim import trim as trim_audio
from AudioDSP import clean_audio
from AudioTempo import AudioTempo

root = Path(__file__).resolve().parent
tempo = AudioTempo(root / "libReDZTempo.dylib")
# This worker serializes all phonemization. Share one native eSpeak instance
# instead of phonemizer's temporary-library copies and deleting finalizers.
# Pass the bundled data directory explicitly; the library's compiled-in path
# points at its build machine and is unavailable on this Mac.
espeak_library = Path(espeakng_loader.get_library_path())
espeak = ctypes.CDLL(str(espeak_library))
espeak.espeak_Initialize.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
espeak.espeak_Initialize.restype = ctypes.c_int
data_path = espeakng_loader.get_data_path()
# eSpeak has a short internal path buffer. Keep a stable, short symlink so the
# app also works when its bundle lives in a long workspace path.
links = Path.home() / "Library/Application Support/ReadAlong/SpeechLinks"
links.mkdir(parents=True, exist_ok=True)
data_link = links / hashlib.sha256(data_path.encode()).hexdigest()[:16]
if not os.path.lexists(data_link):
    data_link.symlink_to(data_path, target_is_directory=True)
elif not data_link.is_symlink() or os.readlink(data_link) != data_path:
    raise RuntimeError("Pronunciation link already exists with a different target.")
if espeak.espeak_Initialize(2, 0, str(data_link).encode(), 0) <= 0:
    raise RuntimeError("Could not initialize pronunciation data.")


def shared_espeak_init(self, library, data_path=None):
    self._library = espeak
    self._library_path = espeak_library


EspeakAPI.__init__ = shared_espeak_init
options = ort.SessionOptions()
options.intra_op_num_threads = 2
options.inter_op_num_threads = 1
session = ort.InferenceSession(str(root / "kokoro-v1.0.onnx"), options, providers=["CPUExecutionProvider"])
engine = Kokoro.from_session(session, str(root / "voices-v1.0.bin"))
if not engine.has_timings:
    raise RuntimeError("The speech model must provide phoneme timings.")

jobs = deque()
condition = threading.Condition()
epoch = None
closed = False
active_request = None
active_run = None
original_run = session.run
# Retain the natural recording across speed changes and cancellation, so a
# tempo change never requires running the neural model again for recent text.
natural_cache = OrderedDict()
natural_bytes = 0


def cancellable_run(outputs, inputs):
    global active_run
    with condition:
        if active_request is None or superseded(active_request):
            raise RuntimeError("Speech request was cancelled.")
        run = ort.RunOptions()
        active_run = run
    try:
        return original_run(outputs, inputs, run_options=run)
    finally:
        with condition:
            if active_run is run:
                active_run = None


session.run = cancellable_run


def superseded(request):
    return request.get("epoch", "initial") != epoch


def read_requests():
    global epoch, closed
    for line in sys.stdin:
        request = json.loads(line)
        with condition:
            if request.get("op") == "cancel":
                epoch = request["epoch"]
                jobs.clear()
                if active_run is not None:
                    active_run.terminate = True
            else:
                request_epoch = request.get("epoch", "initial")
                if epoch is None:
                    epoch = request_epoch
                if request_epoch == epoch:
                    if request.get("priority") == "foreground":
                        jobs.appendleft(request)
                    else:
                        jobs.append(request)
            condition.notify()
    with condition:
        closed = True
        condition.notify()


def natural_speech(request):
    global natural_bytes
    voice = request["voice"]
    if voice not in {"af_heart", "af_bella", "am_michael", "am_fenrir"}:
        raise ValueError("Unknown reading voice.")
    text = request["text"]
    words = request["words"]
    key = (voice, text, tuple(word["text"] for word in words))
    if key in natural_cache:
        cached = natural_cache.pop(key)
        natural_cache[key] = cached
        return cached
    phonemes = engine.tokenizer.phonemize(text, "en-us")
    if superseded(request):
        return None
    # Keep natural phoneme durations; tempo is prepared offline afterwards.
    # Preserve the complete onset, including quiet consonants and device lead-in.
    samples, rate, timings = engine.create_timed(phonemes, voice=voice, speed=1.0, is_phonemes=True, trim=False)
    if superseded(request):
        return None
    # Remove only excess silence at the end, retaining all timed speech and a
    # short release. Never apply an energy threshold to the beginning.
    _, (_, tail) = trim_audio(samples)
    release = int(((timings[-1].end if timings else 0) + 0.08) * rate)
    samples = samples[:min(len(samples), max(int(tail), release))]
    # Align word pronunciations to the complete sentence's contextual phonemes.
    # Audio positions come from the model, not a words-per-minute estimate.
    individual, offsets = "", []
    for word in words:
        if superseded(request):
            return None
        if individual:
            individual += " "
        offsets.append(len(individual))
        individual += engine.tokenizer.phonemize(word["text"], "en-us")
    spoken = "".join(t.phoneme for t in timings)
    matches = difflib.SequenceMatcher(None, individual, spoken, autojunk=False).get_matching_blocks()
    positions = []
    previous = 0.0
    for word, offset in zip(words, offsets):
        match = next((m for m in matches if m.a + m.size > offset), matches[-1])
        aligned = min(max(0, match.b + max(0, offset - match.a)), max(0, len(timings) - 1))
        start = max(previous, float(timings[aligned].start) if timings else 0.0)
        previous = start
        positions.append({"index": word["index"], "start": start})
    samples = clean_audio(samples, rate)
    cached = (samples, rate, [position["start"] for position in positions])
    natural_cache[key] = cached
    natural_bytes += samples.nbytes
    while len(natural_cache) > 32 or natural_bytes > 48 * 1024 * 1024:
        _, old = natural_cache.popitem(last=False)
        natural_bytes -= old[0].nbytes
    return cached


def render(request):
    global active_request
    with condition:
        active_request = request
    natural = natural_speech(request)
    if natural is None or superseded(request):
        return None
    samples, rate, starts = natural
    speed = float(request.get("speed", 1))
    samples, positions = tempo.render(samples, rate, speed, starts, lambda: superseded(request))
    if superseded(request):
        return None
    # The offline processor can create a small DC shift or edge transient.
    # Clean only processed recordings; 1x retains the original cleaned PCM.
    if positions != starts or len(samples) != len(natural[0]):
        samples = clean_audio(samples, rate)
    positions = [{"index": word["index"], "start": start} for word, start in zip(request["words"], positions)]
    output = io.BytesIO()
    with wave.open(output, "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(rate)
        audio.writeframes((np.clip(samples, -1, 1) * 32767).astype("<i2").tobytes())
    return {"id": request["id"], "audio": base64.b64encode(output.getvalue()).decode("ascii"), "words": positions, "duration": len(samples) / rate}


print(json.dumps({"ready": True}), flush=True)
threading.Thread(target=read_requests, daemon=True).start()
while True:
    with condition:
        while not jobs and not closed:
            condition.wait()
        if not jobs and closed:
            break
        request = jobs.popleft()
    if superseded(request):
        continue
    try:
        response = render(request)
    except Exception as error:
        response = {"id": request.get("id", ""), "error": str(error)}
    if response is not None and not superseded(request):
        print(json.dumps(response, separators=(",", ":")), flush=True)
