"""Offline pitch-preserving tempo. Playback receives ordinary PCM at 1x."""
import ctypes as C
from pathlib import Path
import numpy as np


class CancelledTempo(Exception):
    pass


class AudioTempo:
    def __init__(self, library):
        self.lib = C.CDLL(str(Path(library)))
        state = C.c_void_p
        samples = C.POINTER(C.c_float)
        channels = C.POINTER(samples)
        functions = {
            "new": ([C.c_uint, C.c_uint, C.c_int, C.c_double, C.c_double], state),
            "delete": ([state], None),
            "get_engine_version": ([state], C.c_int),
            "set_expected_input_duration": ([state, C.c_uint], None),
            "set_max_process_size": ([state, C.c_uint], None),
            "set_key_frame_map": ([state, C.c_uint, C.POINTER(C.c_uint), C.POINTER(C.c_uint)], None),
            "study": ([state, channels, C.c_uint, C.c_int], None),
            "process": ([state, channels, C.c_uint, C.c_int], None),
            "available": ([state], C.c_int),
            "retrieve": ([state, channels, C.c_uint], C.c_uint),
        }
        for name, (args, result) in functions.items():
            function = getattr(self.lib, "rubberband_" + name)
            function.argtypes = args
            function.restype = result

    @staticmethod
    def timeline(length, rate, speed, starts):
        """Map each input sample boundary to its intended output clock."""
        speed = float(speed)
        if speed not in (.75, 1., 1.25, 1.5, 1.75, 2.):
            raise ValueError("Unsupported reading speed.")
        first = starts[0] if starts else 0
        second = next((start for start in starts[1:] if start > first), None)
        if speed == 1:
            return None, []
        if speed < 1:
            return np.arange(length + 1, dtype=np.float64) / speed, []
        # Start one 0.25x step below the selected fast speed, rather than
        # dropping every sentence all the way to 1x. A single-word unit uses
        # that lead-in speed throughout because there is no following word.
        lead = speed - .25
        if second is None:
            return (None, []) if lead == 1 else (np.arange(length + 1, dtype=np.float64) / lead, [])
        boundary = min(length, max(1, int(round(second * rate))))
        ramp = max(1, int(round(.25 * rate)))
        progress = np.clip((np.arange(length, dtype=np.float64) - boundary) / ramp, 0, 1)
        eased = progress * progress * (3 - 2 * progress)
        increments = 1 / (lead + (speed - lead) * eased)
        mapping = np.concatenate(([0.], np.cumsum(increments)))
        # R3 needs positive, spaced key frames; zero is the implicit origin.
        keys = [boundary] + [boundary + round(ramp * i / 4) for i in range(1, 5)]
        return mapping, sorted(set(k for k in keys if 0 < k < length))

    def render(self, audio, rate, speed, starts, cancelled=lambda: False):
        audio = np.ascontiguousarray(audio, dtype=np.float32)
        mapping, keys = self.timeline(len(audio), rate, speed, starts)
        if mapping is None or len(audio) == 0:
            return audio, list(starts)
        expected = int(round(mapping[-1]))
        # Offline R3/Finer, single-threaded, pitch unchanged. The two passes
        # finish before the Mac audio device sees any samples.
        handle = self.lib.rubberband_new(rate, 1, 0x20000000 | 0x00010000, expected / len(audio), 1.)
        if not handle:
            raise RuntimeError("Could not initialize tempo processing.")
        output = []
        block = 1024
        try:
            if self.lib.rubberband_get_engine_version(handle) != 3:
                raise RuntimeError("The offline R3 tempo engine is required.")
            self.lib.rubberband_set_expected_input_duration(handle, len(audio))
            self.lib.rubberband_set_max_process_size(handle, block)
            if keys:
                before = (C.c_uint * len(keys))(*keys)
                after = (C.c_uint * len(keys))(*(round(mapping[k]) for k in keys))
                self.lib.rubberband_set_key_frame_map(handle, len(keys), before, after)
            for operation in (self.lib.rubberband_study, self.lib.rubberband_process):
                for offset in range(0, len(audio), block):
                    if cancelled():
                        raise CancelledTempo()
                    part = audio[offset:offset + block]
                    pointers = (C.POINTER(C.c_float) * 1)(part.ctypes.data_as(C.POINTER(C.c_float)))
                    operation(handle, pointers, len(part), offset + len(part) == len(audio))
                    if operation is self.lib.rubberband_process:
                        self._drain(handle, output)
            self._drain(handle, output)
            result = np.concatenate(output) if output else np.empty(0, dtype=np.float32)
            if len(result) != expected or not np.all(np.isfinite(result)):
                raise RuntimeError("Tempo processing returned invalid audio.")
            positions = [float(mapping[min(len(audio), max(0, round(start * rate)))]) / rate for start in starts]
            return result, positions
        finally:
            # This releases native memory; it does not remove any files.
            self.lib.rubberband_delete(handle)

    def _drain(self, handle, output):
        while (available := self.lib.rubberband_available(handle)) > 0:
            chunk = np.empty(available, dtype=np.float32)
            pointers = (C.POINTER(C.c_float) * 1)(chunk.ctypes.data_as(C.POINTER(C.c_float)))
            count = self.lib.rubberband_retrieve(handle, pointers, available)
            if not count:
                raise RuntimeError("Tempo processing stalled.")
            output.append(chunk[:count])
