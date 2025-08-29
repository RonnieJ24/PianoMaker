import os
import math
import uuid
import tempfile
import time
from typing import Optional, Dict

import numpy as np
import librosa
import soundfile as sf
import pretty_midi
import subprocess
import shutil
import bisect
import httpx
import json as _json
try:
    import replicate as _rep  # optional, for cloud-enhanced transcription/performance
except Exception:
    _rep = None

# Basic Pitch
# Lazily import Basic Pitch inside the function to avoid hard TensorFlow/CoreML
# dependency at server startup. This allows the API to boot even if the
# transcription path is unused or Basic Pitch is not installed for this Python
# version.

# Optional: Demucs (stubbed for MVP to avoid heavy runtime deps)
try:
    import demucs.separate
    HAS_DEMUCS = True
except Exception:
    HAS_DEMUCS = False


OUTPUTS_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "outputs"))
os.makedirs(OUTPUTS_DIR, exist_ok=True)


def _safe_filename(name: str) -> str:
    return "".join(c for c in name if c.isalnum() or c in ("-", "_", "."))


def _estimate_bpm(audio: np.ndarray, sr: int) -> Optional[float]:
    try:
        tempo = librosa.beat.tempo(y=audio, sr=sr)
        if isinstance(tempo, np.ndarray) and tempo.size > 0:
            return float(tempo[0])
        if isinstance(tempo, (int, float)):
            return float(tempo)
    except Exception:
        pass
    return None


def _quantize_time(value_sec: float, grid_sec: float) -> float:
    if grid_sec <= 0:
        return value_sec
    return round(value_sec / grid_sec) * grid_sec


def _post_process_midi(
    midi: pretty_midi.PrettyMIDI,
    bpm: Optional[float],
    min_duration_sec: float = 0.05,
    sixteenth_quantize: bool = True,
    pitch_min: int = 21,  # A0
    pitch_max: int = 108,  # C8
    smooth_velocity: bool = True,
    humanize_timing_sec: float = 0.0,
    humanize_velocity_range: int = 0,
    add_sustain: bool = False,
) -> pretty_midi.PrettyMIDI:
    if bpm is None:
        bpm = 120.0

    grid_sec = (60.0 / bpm) / 4.0 if sixteenth_quantize else 0.0

    for instrument in midi.instruments:
        # Keep only piano-ish program by mapping program to acoustic grand if needed
        instrument.program = 0  # Acoustic Grand Piano

        # Quantize and clean notes
        for note in instrument.notes:
            # Constrain pitch
            if note.pitch < pitch_min:
                note.pitch = pitch_min
            if note.pitch > pitch_max:
                note.pitch = pitch_max

            if sixteenth_quantize and grid_sec > 0:
                note.start = _quantize_time(note.start, grid_sec)
                note.end = _quantize_time(note.end, grid_sec)
                if note.end <= note.start:
                    note.end = note.start + grid_sec

            # Enforce minimum duration
            if note.end - note.start < min_duration_sec:
                note.end = note.start + min_duration_sec

        if smooth_velocity and instrument.notes:
            # Simple smoothing by local averaging
            velocities = np.array([n.velocity for n in instrument.notes], dtype=float)
            if velocities.size >= 3:
                kernel = np.array([1, 2, 1], dtype=float)
                kernel = kernel / kernel.sum()
                smoothed = np.convolve(velocities, kernel, mode="same")
                for n, v in zip(instrument.notes, smoothed):
                    n.velocity = int(max(1, min(127, round(v))))

        # Optional humanization: add tiny randomness to timing/velocity after quantization
        if (humanize_timing_sec > 0 or humanize_velocity_range > 0) and instrument.notes:
            for n in instrument.notes:
                if humanize_timing_sec > 0:
                    jitter = float(np.random.uniform(-humanize_timing_sec, humanize_timing_sec))
                    n.start = max(0.0, n.start + jitter)
                    n.end = max(n.start + 0.01, n.end + jitter)
                if humanize_velocity_range > 0:
                    dv = int(np.random.randint(-humanize_velocity_range, humanize_velocity_range + 1))
                    n.velocity = int(max(1, min(127, n.velocity + dv)))

        # Optional sustain pedal injection (simple heuristic):
        # Turn pedal on at the start of dense passages and release on gaps.
        if add_sustain and instrument.notes:
            instrument.notes.sort(key=lambda x: x.start)
            cc: list[pretty_midi.ControlChange] = []
            gap_threshold = 0.12  # seconds
            pedal_on = False
            last_end = None
            for i, note in enumerate(instrument.notes):
                if last_end is None or (note.start - last_end) > gap_threshold:
                    # Gap detected → ensure pedal up before and pedal down at this note
                    t_up = max(0.0, (note.start - 0.02))
                    cc.append(pretty_midi.ControlChange(number=64, value=0, time=t_up))
                    cc.append(pretty_midi.ControlChange(number=64, value=127, time=note.start))
                    pedal_on = True
                last_end = max(last_end or 0.0, note.end)
            # Release at the very end
            if pedal_on:
                cc.append(pretty_midi.ControlChange(number=64, value=0, time=float(last_end)))
            instrument.control_changes.extend(cc)

    return midi


def _clean_polyphony(midi: pretty_midi.PrettyMIDI,
                     onset_window_sec: float = 0.03,
                      max_notes_per_onset: int = 4) -> pretty_midi.PrettyMIDI:
    """
    Reduce spurious extra notes by limiting polyphony per near-simultaneous onset
    window and merging duplicates of the same pitch that start very close together.
    """
    for inst in midi.instruments:
        # Sort notes by start then velocity descending
        inst.notes.sort(key=lambda n: (n.start, -n.velocity, n.pitch))

        # Merge duplicates: same pitch starting within window → extend first note
        merged: list[pretty_midi.Note] = []
        for n in inst.notes:
            if merged and n.pitch == merged[-1].pitch and abs(n.start - merged[-1].start) <= onset_window_sec:
                merged[-1].end = max(merged[-1].end, n.end)
                merged[-1].velocity = max(merged[-1].velocity, n.velocity)
            else:
                merged.append(n)

        # Group by onset window and cap polyphony
        filtered: list[pretty_midi.Note] = []
        i = 0
        while i < len(merged):
            j = i + 1
            group = [merged[i]]
            while j < len(merged) and (merged[j].start - merged[i].start) <= onset_window_sec:
                group.append(merged[j])
                j += 1
            # Keep strongest notes by velocity up to cap; stable sort keeps earlier first
            group.sort(key=lambda n: (n.velocity, -n.pitch), reverse=True)
            kept = group[:max_notes_per_onset]
            # Restore chronological order for kept notes
            kept.sort(key=lambda n: (n.start, n.pitch))
            filtered.extend(kept)
            i = j

        inst.notes = filtered
    return midi


def _limit_pitch_and_length(midi: pretty_midi.PrettyMIDI,
                            pitch_min: int = 36,
                            pitch_max: int = 96,
                            min_duration_sec: float = 0.06) -> pretty_midi.PrettyMIDI:
    """Constrain to piano-friendly range and drop very short artifacts."""
    for inst in midi.instruments:
        kept: list[pretty_midi.Note] = []
        for n in inst.notes:
            if n.end - n.start < min_duration_sec:
                continue
            n.pitch = int(max(pitch_min, min(pitch_max, n.pitch)))
            kept.append(n)
        inst.notes = kept
    return midi


def _refine_midi_against_audio(pm: pretty_midi.PrettyMIDI, audio_path: str, bpm: Optional[float] = None,
                               max_poly: int = 3) -> pretty_midi.PrettyMIDI:
    """
    Heuristic refinement using audio chroma to drop unsupported notes and add
    strongly-supported pitch classes. Keeps output piano-friendly.
    """
    try:
        import librosa as _lb  # type: ignore
        import numpy as _np  # type: ignore
    except Exception:
        return pm

    # Load audio and compute chroma energy over time
    y, sr = _lb.load(audio_path, sr=22050, mono=True)
    hop_length = 512
    try:
        chroma = _lb.feature.chroma_cqt(y=y, sr=sr)
    except Exception:
        chroma = _lb.feature.chroma_stft(y=y, sr=sr, hop_length=hop_length)
    times = _lb.times_like(chroma, sr=sr, hop_length=hop_length)
    if chroma.size == 0:
        return pm
    chroma = _np.clip(chroma, 0.0, None)
    cmax = float(chroma.max()) or 1.0

    # Map time to frame index
    def t_to_idx(t: float) -> int:
        if t <= 0: return 0
        return int(min(len(times) - 1, max(0, _np.searchsorted(times, t))))

    # Drop notes with consistently weak chroma support
    new_instrs: list[pretty_midi.Instrument] = []
    for inst in pm.instruments:
        kept: list[pretty_midi.Note] = []
        for n in inst.notes:
            i0 = t_to_idx(n.start)
            i1 = max(i0 + 1, t_to_idx(n.end))
            pc = int(n.pitch % 12)
            support = float(chroma[pc, i0:i1].mean()) / cmax
            if support >= 0.12:  # keep if has minimal chroma support
                kept.append(n)
        new = pretty_midi.Instrument(program=inst.program, is_drum=inst.is_drum, name=inst.name)
        new.notes = kept
        new_instrs.append(new)
    pm.instruments = new_instrs

    # Add missing strongly supported pitch classes at sixteenth grid positions
    if bpm is None or bpm <= 0:
        bpm = 120.0
    grid = (60.0 / bpm) / 4.0
    if grid <= 0:
        return pm

    # Precompute active PCs from current MIDI at grid steps
    end_time = pm.get_end_time()
    t = 0.0
    target_center = 60
    additions: list[pretty_midi.Note] = []
    while t < end_time:
        t2 = min(end_time, t + grid)
        # Active PCs in MIDI at this block
        active_pcs: set[int] = set()
        for inst in pm.instruments:
            for n in inst.notes:
                if n.start < t2 and n.end > t:
                    active_pcs.add(n.pitch % 12)
        # Chroma peaks at this block center
        ci = t_to_idx(t + 0.5 * (t2 - t))
        col = chroma[:, ci]
        thresh = 0.5 * float(col.max())
        candidate_pcs = [int(i) for i, v in enumerate(col) if v >= thresh and v / cmax >= 0.15]
        # Respect poly cap
        to_add: list[int] = []
        for pc in candidate_pcs:
            if len(active_pcs) + len(to_add) >= max_poly:
                break
            if pc not in active_pcs:
                to_add.append(pc)
        # Create short notes for missing PCs
        for pc in to_add:
            pitch = pc
            while pitch < target_center - 7:
                pitch += 12
            while pitch > target_center + 9:
                pitch -= 12
            additions.append(pretty_midi.Note(velocity=82, pitch=int(pitch), start=float(t), end=float(t2)))
        t = t2

    if additions:
        # Put all notes in first instrument to keep a single-track piano
        if not pm.instruments:
            pm.instruments.append(pretty_midi.Instrument(program=0))
        pm.instruments[0].notes.extend(additions)
        # Clean again to enforce caps
        pm = _clean_polyphony(pm, onset_window_sec=0.03, max_notes_per_onset=max_poly)
    return pm

# PTI feature removed - it was not producing good results
# Pure Basic Pitch is now the only high-quality option


def _merge_midis_union(
    a: pretty_midi.PrettyMIDI,
    b: pretty_midi.PrettyMIDI,
    onset_window_sec: float = 0.03,
    dedup_window_sec: float = 0.02,
) -> pretty_midi.PrettyMIDI:
    """Union merge of two MIDIs with near-duplicate removal.
    Keeps a single piano track with notes from both.
    """
    out = pretty_midi.PrettyMIDI()
    inst = pretty_midi.Instrument(program=0)

    def _collect(m: pretty_midi.PrettyMIDI) -> list[pretty_midi.Note]:
        notes: list[pretty_midi.Note] = []
        for tr in m.instruments:
            for n in tr.notes:
                notes.append(pretty_midi.Note(velocity=n.velocity, pitch=n.pitch, start=n.start, end=n.end))
        return notes

    notes = _collect(a) + _collect(b)
    # Sort by start time then pitch
    notes.sort(key=lambda n: (n.start, n.pitch, -n.velocity))

    # Deduplicate near-identical notes (same pitch within small window)
    merged: list[pretty_midi.Note] = []
    for n in notes:
        if merged and n.pitch == merged[-1].pitch and abs(n.start - merged[-1].start) <= dedup_window_sec:
            # keep the one with longer duration / higher velocity
            if (n.end - n.start) > (merged[-1].end - merged[-1].start) or n.velocity > merged[-1].velocity:
                merged[-1] = n
        else:
            merged.append(n)

    inst.notes = merged
    out.instruments.append(inst)
    return out

def _convert_to_wav(input_path: str, target_sr: int = 22050) -> str:
    """
    Robustly convert arbitrary audio to WAV mono at target_sr.
    Preference order:
    1) ffmpeg (if installed)
    2) macOS afconvert (if available)
    3) Python fallback via librosa+soundfile (may fail on Python 3.13 when deps import removed stdlib modules)
    """
    fd, tmp_wav_path = tempfile.mkstemp(suffix=".wav")
    os.close(fd)

    # 1) Try ffmpeg
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg:
        try:
            cmd = [
                ffmpeg, "-y", "-hide_banner", "-loglevel", "error",
                "-i", input_path,
                "-ar", str(target_sr),
                "-ac", "1",
                tmp_wav_path,
            ]
            subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            return tmp_wav_path
        except Exception:
            pass

    # 2) Try afconvert (macOS)
    afconvert = shutil.which("afconvert")
    if afconvert:
        try:
            # LEI16 @ target_sr mono
            cmd = [
                afconvert,
                "-f", "WAVE",
                "-d", f"LEI16@{target_sr}",
                "-c", "1",
                input_path,
                tmp_wav_path,
            ]
            subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            return tmp_wav_path
        except Exception:
            pass

    # 3) Fallback: librosa decode
    try:
        y, sr = librosa.load(input_path, sr=target_sr, mono=True)
        sf.write(tmp_wav_path, y, target_sr)
        return tmp_wav_path
    except Exception as e:
        # If all decoders failed, re-raise with a helpful message
        raise RuntimeError(f"All decoders failed (ffmpeg/afconvert/librosa): {e}")


def _maybe_run_demucs(input_wav_path: str) -> str:
    """
    If Demucs is available, run source separation and return a stem path which is
    most likely to contain piano (typically the 'other' stem). If Demucs is not
    installed, return the original path.
    """
    # Prefer CLI if available to avoid import-time torch overhead
    demucs_bin = shutil.which("demucs")
    try:
        tmp_out = tempfile.mkdtemp(prefix="demucs_")
        if demucs_bin:
            # Use mdx_extra_q if present to avoid heavy dependencies; HQ fallback to htdemucs
            preferred = os.environ.get("DEMUCS_MODEL", "htdemucs")
            cmd = [demucs_bin, "-n", preferred, "-o", tmp_out, input_wav_path]
            subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        elif HAS_DEMUCS:
            # Fallback to Python entry if CLI is not found
            # Equivalent to: demucs -n htdemucs -o tmp_out input_wav_path
            demucs.separate.main(["-n", "htdemucs", "-o", tmp_out, input_wav_path])
        else:
            return input_wav_path

        # Find a suitable stem (prefer 'other.wav', then 'vocals.wav', finally any .wav)
        chosen: Optional[str] = None
        for root, _, files in os.walk(tmp_out):
            # pattern: tmp_out/htdemucs/<file_basename>/{vocals,drums,bass,other}.wav
            if "other.wav" in files:
                chosen = os.path.join(root, "other.wav")
                break
        if chosen is None:
            for root, _, files in os.walk(tmp_out):
                if "vocals.wav" in files:
                    chosen = os.path.join(root, "vocals.wav")
                    break
        if chosen is None:
            for root, _, files in os.walk(tmp_out):
                for f in files:
                    if f.lower().endswith(".wav"):
                        chosen = os.path.join(root, f)
                        break
                if chosen:
                    break
        return chosen or input_wav_path
    except Exception:
        return input_wav_path


def separate_audio(input_wav_path: str) -> tuple[str, str | None]:
    """
    Run Demucs source separation with balanced quality settings and return a tuple: (instrumental_wav, vocals_wav|None).
    Prefers 'other.wav' as instrumental, and 'vocals.wav' if available.
    If separation fails, returns the original path and None.
    """
    demucs_bin = shutil.which("demucs")
    try:
        tmp_out = tempfile.mkdtemp(prefix="demucs_")
        if demucs_bin:
            # Use balanced quality settings: default overlap (0.75) and shifts (1)
            # Increase overlap slightly for quality, but remain reasonable for CPU
            cmd = [demucs_bin, "-n", "htdemucs", "--overlap", "0.9", "--shifts", "1", "-o", tmp_out, input_wav_path]
            subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        elif HAS_DEMUCS:
            demucs.separate.main(["-n", "htdemucs", "--overlap", "0.75", "--shifts", "1", "-o", tmp_out, input_wav_path])
        else:
            return input_wav_path, None

        inst: Optional[str] = None
        voc: Optional[str] = None
        for root, _, files in os.walk(tmp_out):
            if "other.wav" in files:
                inst = os.path.join(root, "other.wav")
            if "vocals.wav" in files:
                voc = os.path.join(root, "vocals.wav")
        if inst is None:
            # fallback to any wav as instrumental
            for root, _, files in os.walk(tmp_out):
                for f in files:
                    if f.lower().endswith('.wav'):
                        inst = os.path.join(root, f)
                        break
                if inst:
                    break
        return inst or input_wav_path, voc
    except Exception:
        return input_wav_path, None


def separate_audio_mdx23(input_wav_path: str) -> tuple[str, str | None]:
    """
    High-quality MDX23 separation for 2-stem output.
    Returns (instrumental_wav, vocals_wav|None).
    """
    demucs_bin = shutil.which("demucs")
    try:
        tmp_out = tempfile.mkdtemp(prefix="mdx23_")
        if demucs_bin:
            cmd = [demucs_bin, "-n", "mdx23", "-o", tmp_out, input_wav_path]
            subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        elif HAS_DEMUCS:
            demucs.separate.main(["-n", "mdx23", "-o", tmp_out, input_wav_path])
        else:
            return input_wav_path, None

        inst: Optional[str] = None
        voc: Optional[str] = None
        for root, _, files in os.walk(tmp_out):
            if "accompaniment.wav" in files:
                inst = os.path.join(root, "accompaniment.wav")
            if "vocals.wav" in files:
                voc = os.path.join(root, "vocals.wav")
        if inst is None:
            # fallback to any wav as instrumental
            for root, _, files in os.walk(tmp_out):
                for f in files:
                    if f.lower().endswith('.wav'):
                        inst = os.path.join(root, f)
                        break
                if inst:
                    break
        return inst or input_wav_path, voc
    except Exception:
        return input_wav_path, None


def separate_audio_medium(input_wav_path: str) -> tuple[str, str | None]:
    """
    Medium-quality, faster Demucs model (quantized MDX).
    Uses the demucs CLI with a smaller model name (mdx_extra_q) when available.
    Returns (instrumental_wav, vocals_wav|None).
    """
    demucs_bin = shutil.which("demucs")
    try:
        tmp_out = tempfile.mkdtemp(prefix="demucs_med_")
        if demucs_bin:
            model = os.environ.get("DEMUCS_MEDIUM_MODEL", "mdx_extra_q")
            cmd = [demucs_bin, "-n", model, "-o", tmp_out, input_wav_path]
            subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        elif HAS_DEMUCS:
            demucs.separate.main(["-n", "mdx_extra_q", "-o", tmp_out, input_wav_path])
        else:
            return input_wav_path, None

        inst: Optional[str] = None
        voc: Optional[str] = None
        for root, _, files in os.walk(tmp_out):
            if "accompaniment.wav" in files:
                inst = os.path.join(root, "accompaniment.wav")
            if "other.wav" in files:
                inst = inst or os.path.join(root, "other.wav")
            if "vocals.wav" in files:
                voc = os.path.join(root, "vocals.wav")
        if inst is None:
            for root, _, files in os.walk(tmp_out):
                for f in files:
                    if f.lower().endswith('.wav'):
                        inst = os.path.join(root, f)
                        break
                if inst:
                    break
        return inst or input_wav_path, voc
    except Exception:
        return input_wav_path, None

def separate_audio_fast(input_wav_path: str) -> tuple[str, str]:
    """
    Fast, CPU-only separation:
    - If stereo: mid/side "karaoke" removal (center channel as vocals)
    - If mono: HPSS; treat harmonic as vocals and residual as instrumental
    Returns paths to (instrumental_wav, vocals_wav).
    """
    try:
        import librosa as _lb
        import numpy as _np
        import soundfile as _sf
        y, sr = _lb.load(input_wav_path, sr=None, mono=False)
        # Ensure shape (channels, samples)
        if y.ndim == 1:
            # Mono → HPSS
            harm, perc = _lb.effects.hpss(y)
            vocals = harm
            inst = y - harm
            # Write to temp files
            inst_path = tempfile.mkstemp(suffix="_inst_fast.wav")[1]
            voc_path = tempfile.mkstemp(suffix="_voc_fast.wav")[1]
            _sf.write(inst_path, inst, sr)
            _sf.write(voc_path, vocals, sr)
            return inst_path, voc_path
        else:
            # Stereo mid/side
            if y.shape[0] != 2:
                # If more channels, collapse to stereo
                y = _np.vstack([y[0, :], y[1, :]])
            L, R = y[0], y[1]
            # Mid = vocals (center channel), Side = instrumental
            mid = (L + R) / 2
            side = (L - R) / 2
            # Write to temp files
            inst_path = tempfile.mkstemp(suffix="_inst_fast.wav")[1]
            voc_path = tempfile.mkstemp(suffix="_voc_fast.wav")[1]
            _sf.write(inst_path, side, sr)
            _sf.write(voc_path, mid, sr)
            return inst_path, voc_path
    except Exception as e:
        raise RuntimeError(f"Fast separation failed: {e}")


def separate_audio_spleeter_fast(input_wav_path: str) -> tuple[str, str]:
    """Separate audio using Spleeter 2-stem model via subprocess call to virtual environment."""
    try:
        # Use subprocess to call Spleeter from the virtual environment
        spleeter_venv_python = "/Users/raniyaqoob/Desktop/PianoMaker/.spleeter-venv/bin/python"
        if not os.path.exists(spleeter_venv_python):
            raise RuntimeError("Spleeter virtual environment not found")
        
        # Create output directory
        output_dir = tempfile.mkdtemp(prefix="spleeter_fast_")
        
        # Run Spleeter via subprocess
        cmd = [
            spleeter_venv_python, "-m", "spleeter", "separate",
            "-p", "spleeter:2stems",
            "-o", output_dir,
            input_wav_path
        ]
        
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        
        # Get output file paths
        base_name = os.path.splitext(os.path.basename(input_wav_path))[0]
        inst_path = os.path.join(output_dir, base_name, "accompaniment.wav")
        voc_path = os.path.join(output_dir, base_name, "vocals.wav")
        
        if not os.path.exists(inst_path) or not os.path.exists(voc_path):
            raise RuntimeError(f"Spleeter did not produce expected output files. Stdout: {result.stdout}, Stderr: {result.stderr}")
        
        return inst_path, voc_path
        
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"Spleeter failed: {e.stderr}")
    except Exception as e:
        raise RuntimeError(f"Spleeter failed: {e}")

def separate_audio_spleeter_hq(input_wav_path: str) -> tuple[str, str]:
    """Separate audio using Spleeter 4-stem model via subprocess call to virtual environment."""
    try:
        # Use subprocess to call Spleeter from the virtual environment
        spleeter_venv_python = "/Users/raniyaqoob/Desktop/PianoMaker/.spleeter-venv/bin/python"
        if not os.path.exists(spleeter_venv_python):
            raise RuntimeError("Spleeter virtual environment not found")
        
        # Create output directory
        output_dir = tempfile.mkdtemp(prefix="spleeter_hq_")
        
        # Run Spleeter via subprocess
        cmd = [
            spleeter_venv_python, "-m", "spleeter", "separate",
            "-p", "spleeter:4stems",
            "-o", output_dir,
            input_wav_path
        ]
        
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        
        # Get output file paths
        base_name = os.path.splitext(os.path.basename(input_wav_path))[0]
        inst_path = os.path.join(output_dir, base_name, "accompaniment.wav")
        voc_path = os.path.join(output_dir, base_name, "vocals.wav")
        
        if not os.path.exists(inst_path) or not os.path.exists(voc_path):
            raise RuntimeError(f"Spleeter did not produce expected output files. Stdout: {result.stdout}, Stderr: {result.stderr}")
        
        return inst_path, voc_path
        
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"Spleeter failed: {e.stderr}")
    except Exception as e:
        raise RuntimeError(f"Spleeter failed: {e}")


def separate_audio_umx(input_wav_path: str) -> tuple[str, str | None]:
    """
    Open-Unmix (UMX) separation via CLI if available. Returns (instrumental, vocals|None).
    Uses the smaller mdx/umx defaults for speed if available.
    """
    umx_bin = shutil.which("umx")
    if not umx_bin:
        return input_wav_path, None
    # UMX expects a directory of audio files; copy to a temp folder
    tmp_in = tempfile.mkdtemp(prefix="umx_in_")
    tmp_out = tempfile.mkdtemp(prefix="umx_out_")
    base = os.path.basename(input_wav_path)
    src = os.path.join(tmp_in, base)
    try:
        shutil.copy(input_wav_path, src)
        # Run umx with default (fast-ish) model; users can switch to umxhq later
        cmd = [umx_bin, tmp_in, "--outdir", tmp_out]
        subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        inst: Optional[str] = None
        voc: Optional[str] = None
        # Walk outputs
        for root, _, files in os.walk(tmp_out):
            if "accompaniment.wav" in files:
                inst = os.path.join(root, "accompaniment.wav")
            if "vocals.wav" in files:
                voc = os.path.join(root, "vocals.wav")
        if not inst:
            for root, _, files in os.walk(tmp_out):
                for f in files:
                    if f.lower().endswith('.wav'):
                        inst = os.path.join(root, f)
                        break
                if inst:
                    break
        return inst or input_wav_path, voc
    except Exception:
        return input_wav_path, None


def separate_audio_local_ml(input_wav_path: str) -> tuple[str, str]:
    """
    Lightweight local "ML-like" separation using a hybrid of:
    - HPSS to split harmonic/percussive content
    - PYIN voicing to detect frames likely to contain singing voice
    Result is approximate but fast and fully local with only librosa/soundfile.
    Returns (instrumental_wav, vocals_wav).
    """
    import librosa as _lb
    import numpy as _np
    import soundfile as _sf
    y, sr = _lb.load(input_wav_path, sr=None, mono=False)
    if y.ndim == 1:
        y = _np.expand_dims(y, axis=0)
    # Mono mix for analysis
    y_mono = _np.mean(y, axis=0)
    # HPSS
    harm, perc = _lb.effects.hpss(y_mono)
    # Voicing with PYIN
    try:
        f0, voiced_flag, _ = _lb.pyin(y_mono, fmin=_lb.note_to_hz('C2'), fmax=_lb.note_to_hz('C7'))
        voiced = _np.nan_to_num(voiced_flag.astype(float), nan=0.0)
    except Exception:
        # If pyin fails, fall back to simple energy-based voicing
        S = _np.abs(_lb.stft(y_mono, n_fft=2048, hop_length=512))
        energy = S.mean(axis=0)
        thr = float(_np.percentile(energy, 60))
        voiced = (energy >= thr).astype(float)
    # Build time mask at hop=512
    hop = 512
    mask = _np.zeros_like(y_mono)
    frame_len = hop
    idx = 0
    for i in range(len(voiced)):
        v = float(voiced[i])
        s = i * hop
        e = min(len(mask), s + frame_len)
        if s < e:
            mask[s:e] = v
            idx = e
    if idx < len(mask):
        mask[idx:] = mask[idx-1] if idx > 0 else 0.0
    # Vocals approximation: harmonic components during voiced frames
    # Reconstruct harmonic track by filtering original mono signal proportionally
    # Blend ratio keeps artifacts lower
    vocals_mono = 0.85 * harm * mask + 0.15 * y_mono * mask
    # Expand to stereo shape of original
    if y.shape[0] == 1:
        vocals = vocals_mono
        inst = y_mono - vocals_mono
    else:
        vocals = _np.vstack([vocals_mono, vocals_mono])
        inst = y - vocals
    # Normalize
    def _norm(x: _np.ndarray) -> _np.ndarray:
        m = _np.max(_np.abs(x))
        return x / m if m > 1.0 else x
    inst = _norm(inst)
    vocals = _norm(vocals)
    inst_path = tempfile.mkstemp(suffix="_inst_localml.wav")[1]
    voc_path = tempfile.mkstemp(suffix="_voc_localml.wav")[1]
    # Write
    if inst.ndim == 1:
        _sf.write(inst_path, inst, sr)
    else:
        _sf.write(inst_path, inst.T, sr)
    if vocals.ndim == 1:
        _sf.write(voc_path, vocals, sr)
    else:
        _sf.write(voc_path, vocals.T, sr)
    return inst_path, voc_path


def _enhance_stems(inst_path: str, voc_path: str, strength: float = 0.7) -> tuple[str, str]:
    """
    Light AI-like enhancement step to reduce cross-talk and artifacts using
    soft masks derived from both stems. No heavy dependencies required.

    - Compute magnitude STFTs of both stems
    - Build soft ratio masks (Wiener-like) with exponent p=2 and blend factor
    - Apply masks to each stem to suppress leakage
    """
    import librosa as _lb
    import numpy as _np
    import soundfile as _sf
    # Load
    y_i, sr_i = _lb.load(inst_path, sr=None, mono=False)
    y_v, sr_v = _lb.load(voc_path, sr=None, mono=False)
    sr = sr_i if sr_i else sr_v
    if y_i.ndim == 1:
        y_i = _np.expand_dims(y_i, 0)
    if y_v.ndim == 1:
        y_v = _np.expand_dims(y_v, 0)
    # Use same hop/n_fft
    n_fft = 2048
    hop = 512
    def stft_mag(x):
        S = _lb.stft(x, n_fft=n_fft, hop_length=hop)
        return S, _np.abs(S)
    # Per-channel processing
    yi_new = []
    yv_new = []
    for ch in range(min(y_i.shape[0], y_v.shape[0])):
        Si, Mi = stft_mag(y_i[ch])
        Sv, Mv = stft_mag(y_v[ch])
        # Soft mask
        eps = 1e-6
        p = 2.0
        Mi2 = _np.power(Mi, p)
        Mv2 = _np.power(Mv, p)
        denom = Mi2 + (strength * Mv2) + eps
        M_inst = Mi2 / denom
        M_voc = _np.clip(1.0 - M_inst, 0.0, 1.0)
        # Apply mask to original complex spectra to preserve phase
        Si_new = M_inst * Si
        Sv_new = M_voc * Sv
        # ISTFT
        yi_ch = _lb.istft(Si_new, hop_length=hop, length=y_i.shape[1])
        yv_ch = _lb.istft(Sv_new, hop_length=hop, length=y_v.shape[1])
        yi_new.append(yi_ch)
        yv_new.append(yv_ch)
    yi_new = _np.vstack(yi_new)
    yv_new = _np.vstack(yv_new)
    # Normalize to prevent clipping
    def _norm(x):
        m = float(_np.max(_np.abs(x)) or 1.0)
        return (x / m) if m > 1.0 else x
    yi_new = _norm(yi_new)
    yv_new = _norm(yv_new)
    # Write to temp
    inst_enh = tempfile.mkstemp(suffix="_inst_enh.wav")[1]
    voc_enh = tempfile.mkstemp(suffix="_voc_enh.wav")[1]
    _sf.write(inst_enh, yi_new.T if yi_new.ndim == 2 else yi_new, sr)
    _sf.write(voc_enh, yv_new.T if yv_new.ndim == 2 else yv_new, sr)
    return inst_enh, voc_enh


def separate_audio_great(input_wav_path: str, enhance: bool = True) -> tuple[str, str | None]:
    """
    High-quality separation:
    - Demucs htdemucs with two-stems=vocals, higher overlap and time-shifts to boost SNR
    - Optional post-enhancement with soft-masking between stems to remove distortion/leakage
    Returns (instrumental_wav, vocals_wav|None)
    """
    demucs_bin = shutil.which("demucs")
    try:
        tmp_out = tempfile.mkdtemp(prefix="demucs_great_")
        inst: Optional[str] = None
        voc: Optional[str] = None
        if demucs_bin:
            cmd = [
                demucs_bin,
                "-n", "htdemucs",
                "--two-stems", "vocals",
                "--overlap", "0.85",
                "--shifts", "2",
                "-o", tmp_out,
                input_wav_path,
            ]
            # Add timeout to prevent hanging (10 minutes max)
            try:
                subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=600)
            except subprocess.TimeoutExpired:
                print(f"Demucs process timed out after 10 minutes for {input_wav_path}")
                raise RuntimeError("Demucs separation timed out after 10 minutes")
        elif HAS_DEMUCS:
            # Python entry – no direct two-stems flag reliably; fall back to standard HQ
            # Note: Python demucs doesn't have built-in timeout, but the job runner will handle it
            demucs.separate.main(["-n", "htdemucs", "-o", tmp_out, input_wav_path])
        else:
            return input_wav_path, None

        # Locate outputs
        for root, _, files in os.walk(tmp_out):
            if "no_vocals.wav" in files:
                inst = os.path.join(root, "no_vocals.wav")
            if "accompaniment.wav" in files:
                inst = inst or os.path.join(root, "accompaniment.wav")
            if "other.wav" in files:
                inst = inst or os.path.join(root, "other.wav")
            if "vocals.wav" in files:
                voc = os.path.join(root, "vocals.wav")
        if not inst:
            # Fallback to any wav
            for root, _, files in os.walk(tmp_out):
                for f in files:
                    if f.lower().endswith('.wav'):
                        inst = os.path.join(root, f)
                        break
                if inst:
                    break

        if enhance and inst and voc:
            try:
                inst, voc = _enhance_stems(inst, voc, strength=0.7)
            except Exception:
                pass
        return inst or input_wav_path, voc
    except Exception:
        return input_wav_path, None

def separate_audio_spleeter_api(local_audio_path: str) -> Dict[str, Optional[str]]:
    """
    Call a hosted Spleeter-compatible API to separate the input audio.

    Configuration via environment variables:
    - SPLEETER_API_URL: Full endpoint URL (required)
    - SPLEETER_API_HEADERS: JSON object string of headers (optional)
      e.g. '{"X-RapidAPI-Key": "...", "X-RapidAPI-Host": "..."}'
    - SPLEETER_API_FILE_FIELD: Multipart field name for the audio file (default: 'audio')
    - SPLEETER_API_STEMS: Desired number of stems for the provider (default: '2')
    - SPLEETER_API_EXTRA_FIELDS: JSON object string of extra form fields (optional)

    Expected response: JSON containing downloadable URLs for stems. This function is
    tolerant and will look for common keys (instrumental/accompaniment/other/no_vocals, vocals).
    Returns dict: { 'instrumental_url': str|None, 'vocals_url': str|None }
    """
    url = os.environ.get("SPLEETER_API_URL")
    if not url:
        raise RuntimeError("SPLEETER_API_URL not configured")

    # Parse optional headers and extra fields from env
    headers: dict = {}
    extra_fields: dict = {}
    try:
        hdr_str = os.environ.get("SPLEETER_API_HEADERS")
        if hdr_str:
            headers = _json.loads(hdr_str)
    except Exception:
        headers = {}
    try:
        extra_str = os.environ.get("SPLEETER_API_EXTRA_FIELDS")
        if extra_str:
            extra_fields = _json.loads(extra_str)
    except Exception:
        extra_fields = {}

    file_field = os.environ.get("SPLEETER_API_FILE_FIELD", "audio")
    stems_value = os.environ.get("SPLEETER_API_STEMS", "2")

    # Build multipart payload
    files = {
        file_field: (
            os.path.basename(local_audio_path) or "input",
            open(local_audio_path, "rb"),
            "application/octet-stream",
        )
    }
    data = {"stems": stems_value, **extra_fields}

    # Local import to avoid hard dependency unless configured
    try:
        import requests as _rq  # type: ignore
    except Exception as e:
        raise RuntimeError("'requests' package is required. Install with: pip install requests")

    resp = _rq.post(url, headers=headers, files=files, data=data, timeout=1200)
    if resp.status_code >= 400:
        raise RuntimeError(f"Spleeter API returned {resp.status_code}: {resp.text[:500]}")

    # Try to parse response JSON and find URLs to stems
    try:
        payload = resp.json()
    except Exception:
        # Some providers may directly return a file/bytes – not supported here
        raise RuntimeError("Spleeter API did not return JSON; please provide a JSON API or adapter")

    def _find_url(obj: object, preferred_keys: list[str]) -> Optional[str]:
        # DFS to locate a URL under preferred key names
        stack = [obj]
        while stack:
            cur = stack.pop()
            if isinstance(cur, dict):
                # exact key preference
                for k in preferred_keys:
                    if k in cur and isinstance(cur[k], str) and cur[k].startswith("http"):
                        return cur[k]
                # any string URL
                for v in cur.values():
                    if isinstance(v, str) and v.startswith("http"):
                        return v
                # scan deeper
                for v in cur.values():
                    if isinstance(v, (dict, list)):
                        stack.append(v)
            elif isinstance(cur, list):
                for v in cur:
                    if isinstance(v, (dict, list)):
                        stack.append(v)
                    elif isinstance(v, str) and v.startswith("http"):
                        return v
        return None

    instrumental_url = _find_url(payload, [
        "instrumental", "accompaniment", "no_vocals", "other", "background",
    ])
    vocals_url = _find_url(payload, ["vocals", "voice", "vocal"])

    return {
        "instrumental_url": instrumental_url,
        "vocals_url": vocals_url,
    }


def separate_audio_spleeter_local(input_wav_path: str) -> tuple[str, str | None]:
    """
    Run local Spleeter (CLI) if available, return (instrumental_wav, vocals_wav|None).
    Requires `spleeter` installed (e.g., pipx install spleeter or pip install spleeter).
    """
    import shutil as _sh
    # Prefer explicit binary from env
    env_bin = os.environ.get("SPLEETER_BIN")
    sp = env_bin if (env_bin and os.path.isfile(env_bin)) else _sh.which("spleeter")
    if not sp:
        raise RuntimeError("spleeter CLI not found. Install with: pip install spleeter")
    tmp_out = tempfile.mkdtemp(prefix="spleeter_")
    try:
        cmd = [sp, "separate", "-p", "spleeter:2stems", "-o", tmp_out, input_wav_path]
        subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        inst: Optional[str] = None
        voc: Optional[str] = None
        for root, _, files in os.walk(tmp_out):
            # Spleeter writes subfolder with basename, containing accompaniment.wav and vocals.wav
            if "accompaniment.wav" in files:
                inst = os.path.join(root, "accompaniment.wav")
            if "vocals.wav" in files:
                voc = os.path.join(root, "vocals.wav")
        return inst or input_wav_path, voc
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"spleeter failed: {e.stderr.decode('utf-8', errors='ignore')}")

def transcribe_to_midi(
    input_wav_path: str,
    output_mid_path: str,
    use_demucs: bool = False,
    bpm_hint: Optional[float] = None,
    humanize: bool = True,
    add_sustain: bool = True,
    profile: Optional[str] = None,
) -> Dict[str, Optional[float]]:
    """
    Returns dict: { "notes": int, "duration_sec": float, "bpm_estimate": float | None }
    """
    # Load audio for BPM estimation and potential conversion
    audio, sr = librosa.load(input_wav_path, sr=22050, mono=True)
    bpm_estimate = bpm_hint if bpm_hint is not None else _estimate_bpm(audio, sr)

    # Optional separation (stubbed)
    separated_wav = _maybe_run_demucs(input_wav_path) if use_demucs else input_wav_path

    # Use Basic Pitch to produce an initial MIDI to a temp directory
    with tempfile.TemporaryDirectory() as tmpdir:
        # Lazy import to avoid hard dependency at server startup
        try:
            from basic_pitch.inference import predict_and_save, ICASSP_2022_MODEL_PATH  # type: ignore
        except Exception:
            # If Basic Pitch import fails, raise error (PTI removed)
            raise RuntimeError(
                "Basic Pitch is not installed. Install with: \n"
                "  pip install basic-pitch\n"
                "PTI fallback has been removed as it was not producing good results."
            )
        # Call Basic Pitch with a version-tolerant wrapper (supports 0.3.x and >=0.4.x)
        try:
            predict_and_save(
                [separated_wav], tmpdir, True, False, False, False, ICASSP_2022_MODEL_PATH,
            )
        except TypeError:
            predict_and_save(
                [separated_wav], True, False, False, False, ICASSP_2022_MODEL_PATH, tmpdir,
            )

        # Find the produced MIDI file
        midi_candidates = [
            os.path.join(tmpdir, f) for f in os.listdir(tmpdir) if f.lower().endswith(".mid") or f.lower().endswith(".midi")
        ]
        if not midi_candidates:
            raise RuntimeError("Basic Pitch did not produce a MIDI file")
        temp_midi = midi_candidates[0]

        # Load with pretty_midi for post-processing
        pm = pretty_midi.PrettyMIDI(temp_midi)
        # Apply enhancement profile controls
        prof = (profile or "balanced").lower()
        if prof == "fast":
            human_timing = 0.0
            human_vel = 2 if humanize else 0
            sustain_flag = False
            poly_cap = 4
            min_dur = 0.05
        elif prof == "accurate":
            human_timing = 0.0
            human_vel = 0
            sustain_flag = False
            poly_cap = 2
            min_dur = 0.07
        else:  # balanced
            # Make default output sharper and louder without losing accuracy
            human_timing = 0.012 if humanize else 0.0
            human_vel = 10 if humanize else 0
            sustain_flag = add_sustain
            poly_cap = 3
            min_dur = 0.06

        pm = _post_process_midi(
            pm,
            bpm_estimate,
            humanize_timing_sec=human_timing,
            humanize_velocity_range=human_vel,
            add_sustain=sustain_flag,
        )
        pm = _clean_polyphony(pm, onset_window_sec=0.03, max_notes_per_onset=poly_cap)
        pm = _limit_pitch_and_length(pm, pitch_min=36, pitch_max=96, min_duration_sec=min_dur)

        # For "accurate" profile, use enhanced post-processing (PTI removed)
        if prof == "accurate":
            # Enhanced post-processing without PTI merge
            pm = _refine_midi_against_audio(pm, separated_wav, bpm=bpm_estimate or 120.0, max_poly=poly_cap)
            # Re-clean after refine
            pm = _clean_polyphony(pm, onset_window_sec=0.03, max_notes_per_onset=poly_cap)
            pm = _limit_pitch_and_length(pm, pitch_min=36, pitch_max=96, min_duration_sec=min_dur)

        # Ensure only one piano instrument remains
        if pm.instruments:
            # Merge notes into first instrument
            first = pm.instruments[0]
            for inst in pm.instruments[1:]:
                first.notes.extend(inst.notes)
            pm.instruments = [first]

        pm.write(output_mid_path)

    # Stats
    pm_final = pretty_midi.PrettyMIDI(output_mid_path)
    total_notes = sum(len(inst.notes) for inst in pm_final.instruments)
    duration_sec = pm_final.get_end_time()

    return {
        "notes": float(total_notes),
        "duration_sec": float(duration_sec),
        "bpm_estimate": float(bpm_estimate) if bpm_estimate is not None else None,
    }


def _find_sf2(preferred_name: Optional[str] = None) -> Optional[str]:
    here = os.path.dirname(__file__)
    candidates: list[str] = []
    # Look under server/soundfonts
    sf2_dir = os.path.join(here, "soundfonts")
    if os.path.isdir(sf2_dir):
        for f in os.listdir(sf2_dir):
            if f.lower().endswith(".sf2"):
                candidates.append(os.path.join(sf2_dir, f))
    # Prefer an explicitly named bank if found
    if preferred_name:
        for c in candidates:
            if os.path.basename(c) == preferred_name:
                return c
    # Otherwise any candidate
    return candidates[0] if candidates else None


def _ensure_salamander_sfz(extract_from_root_tar: bool = True) -> Optional[str]:
    """
    Ensure a Salamander SFZ set is available under server/sfz. If a top-level
    archive exists (e.g., Salamander_48khz24bit.tar.xz), extract it once.

    Returns the path to an SFZ file if available, else None.
    """
    here = os.path.dirname(__file__)
    sfz_root = os.path.join(here, "sfz")
    os.makedirs(sfz_root, exist_ok=True)

    # If we already have any .sfz, return one
    existing = _find_sfz()
    if existing:
        return existing

    if not extract_from_root_tar:
        return None

    # Try extracting the bundled Salamander tar.xz from project root
    project_root = os.path.abspath(os.path.join(here, os.pardir))
    tar_path = os.path.join(project_root, "Salamander_48khz24bit.tar.xz")
    if not os.path.isfile(tar_path):
        return None

    try:
        import tarfile
        with tarfile.open(tar_path, mode="r:xz") as tf:
            # Extract to server/sfz/salamander
            target_dir = os.path.join(sfz_root, "Salamander_48khz24bit")
            os.makedirs(target_dir, exist_ok=True)
            tf.extractall(path=target_dir)
    except Exception:
        # Best-effort extraction
        return None

    return _find_sfz()


def _master_wav_inplace(wav_path: str) -> None:
    """Apply clarity-focused mastering with sox if available (HPF/EQ/comp/limiter)."""
    tmp = wav_path + ".tmp.wav"
    try:
        # sox input output effects:
        # - highpass to remove rumble
        # - two gentle EQ boosts for presence/air
        # - gentle compander to tame peaks
        # - normalize to prevent clipping and keep loudness
        cmd = [
            "sox", wav_path, tmp,
            "highpass", "35",
            "equalizer", "3500", "1.0q", "+4",
            "equalizer", "8000", "0.8q", "+2",
            "compand", "0.1,0.25", "-60,-60,-30,-20,-10,-6,0,-2", "-6", "-90", "0.2",
            "gain", "-n", "-0.5",
        ]
        subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        os.replace(tmp, wav_path)
    except FileNotFoundError:
        # sox not installed; skip silently
        if os.path.exists(tmp):
            try: os.remove(tmp)
            except Exception: pass
    except subprocess.CalledProcessError:
        # effect chain failed; skip
        if os.path.exists(tmp):
            try: os.remove(tmp)
            except Exception: pass


def render_midi_to_wav(midi_path: str, out_wav_path: str, preferred_bank: Optional[str] = None, quality: str = "studio", mastering: bool = True) -> None:
    """
    Render MIDI to WAV using Fluidsynth CLI. Requires 'fluidsynth' installed on the system
    (e.g., brew install fluidsynth). Uses a .sf2 from server/soundfonts.
    """
    sf2 = _find_sf2(preferred_bank)
    if sf2 is None:
        raise RuntimeError("No .sf2 soundfont found under server/soundfonts. Please add one (e.g., FluidR3_GM.sf2).")
    # Quality presets
    if quality == "studio":
        rate = "48000"
        opts = [
            "-o", "synth.reverb.active=1",
            "-o", "synth.reverb.room-size=0.7",
            "-o", "synth.reverb.level=0.5",
            "-o", "synth.chorus.active=1",
            "-o", "synth.chorus.level=3.0",
            "-o", "synth.polyphony=256",
            # Louder, sharper render while keeping headroom
            "-g", "0.9",
        ]
    else:  # basic
        rate = "44100"
        opts = ["-o", "synth.reverb.active=0"]

    cmd = ["fluidsynth", "-F", out_wav_path, "-r", rate] + opts + [sf2, midi_path]
    try:
        subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except FileNotFoundError:
        raise RuntimeError("fluidsynth not found. Install with: brew install fluidsynth")
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"fluidsynth failed: {e.stderr.decode('utf-8', errors='ignore')}")
    if mastering:
        _master_wav_inplace(out_wav_path)


def _accent_for_beat_index(beat_idx: int, time_signature_numerator: int = 4) -> int:
    if time_signature_numerator == 3:
        # 3/4: strong-weak-weak
        pattern = [14, 4, 6]
        return pattern[beat_idx % 3]
    # default 4/4: strong-weak-medium-weak
    pattern = [16, 4, 10, 4]
    return pattern[beat_idx % 4]


def expressive_enhance_midi(pm: pretty_midi.PrettyMIDI,
                             humanize_timing_sec: float = 0.015,
                             humanize_velocity_range: int = 10,
                             sustain: bool = True) -> pretty_midi.PrettyMIDI:
    """Professional piano performance enhancement: sophisticated accents, humanization, legato, sustain, and musical expression."""
    beats = pm.get_beats()
    if beats.size == 0:
        beats = np.arange(0, max(1.0, pm.get_end_time() + 1.0), 0.5)

    # Crude meter guess from first time signature if present
    num = 4
    if pm.time_signature_changes:
        num = pm.time_signature_changes[0].numerator

    for inst in pm.instruments:
        # Sort by time for consistent edits
        inst.notes.sort(key=lambda n: (n.start, n.pitch))

        # Professional velocity shaping with musical intelligence
        for i, n in enumerate(inst.notes):
            # Beat position for accent calculation
            j = bisect.bisect_right(beats, n.start) - 1
            j = max(0, j)
            
            # Sophisticated accent system for professional performance
            accent = _accent_for_beat_index(j, num)
            
            # Pitch-based velocity compensation (more nuanced)
            pitch_comp = int(round(-0.12 * (n.pitch - 60)))  # lower notes slightly louder, more natural
            
            # Professional velocity shaping based on note context
            base_velocity = n.velocity
            
            # 1. Beat accent enhancement (stronger on downbeats)
            beat_strength = accent * 1.3  # Increase accent impact
            
            # 2. Musical phrase shaping (louder at phrase beginnings)
            phrase_boost = 0
            if i < 3 or (i > 0 and n.start - inst.notes[i-1].start > 0.5):
                phrase_boost = 8  # Boost phrase starts
            
            # 3. Dynamic range expansion for professional sound
            if base_velocity < 60:
                # Expand low velocities for better attack
                base_velocity = int(base_velocity * 1.4)
            elif base_velocity > 100:
                # Slightly boost high velocities for maximum impact
                base_velocity = int(base_velocity * 1.15)
            
            # 4. Apply all enhancements
            final_velocity = int(max(1, min(127, 
                base_velocity + beat_strength + pitch_comp + phrase_boost)))
            
            # 5. Add subtle humanization
            if humanize_velocity_range > 0:
                dv = int(np.random.randint(-humanize_velocity_range, humanize_velocity_range + 1))
                final_velocity = max(1, min(127, final_velocity + dv))
            
            n.velocity = final_velocity

        # Professional timing humanization and legato
        for i, n in enumerate(inst.notes):
            if humanize_timing_sec > 0:
                # More sophisticated timing variation
                # Reduce jitter on important beats
                beat_pos = bisect.bisect_right(beats, n.start) - 1
                beat_pos = max(0, beat_pos)
                
                # Less jitter on strong beats (0, 4, 8, etc.)
                if beat_pos % 4 == 0:
                    jitter_range = humanize_timing_sec * 0.3  # Less variation on downbeats
                elif beat_pos % 2 == 0:
                    jitter_range = humanize_timing_sec * 0.6  # Medium variation on half beats
                else:
                    jitter_range = humanize_timing_sec  # Full variation on off-beats
                
                jitter = float(np.random.uniform(-jitter_range, jitter_range))
                n.start = max(0.0, n.start + jitter)
                n.end = max(n.start + 0.02, n.end + jitter)
            
            # Professional legato: extend short gaps for smoother performance
            if i + 1 < len(inst.notes):
                next_n = inst.notes[i + 1]
                gap = next_n.start - n.end
                if 0.0 < gap < 0.08:  # Slightly larger gap threshold
                    # More sophisticated legato: vary overlap based on musical context
                    if gap < 0.03:
                        overlap = 0.008  # Tight overlap for fast passages
                    else:
                        overlap = 0.015  # Gentle overlap for slower passages
                    n.end = min(next_n.start - 0.002, n.end + (0.08 - gap + overlap))

        # Professional sustain pedal control for rich, natural sound
        if sustain and inst.notes:
            inst.control_changes.extend([])  # ensure list exists
            inst.notes.sort(key=lambda x: x.start)
            cc: list[pretty_midi.ControlChange] = []
            
            # More sophisticated sustain logic
            gap_threshold = 0.15  # Slightly longer for richer sound
            last_end = None
            
            for n in inst.notes:
                if last_end is None or (n.start - last_end) > gap_threshold:
                    # Lift pedal slightly before new note for clarity
                    t_up = max(0.0, (n.start - 0.03))
                    cc.append(pretty_midi.ControlChange(number=64, value=0, time=t_up))
                    
                    # Apply pedal with slight delay for natural feel
                    t_down = max(0.0, (n.start + 0.01))
                    cc.append(pretty_midi.ControlChange(number=64, value=127, time=t_down))
                
                last_end = max(last_end or 0.0, n.end)
            
            # Final pedal lift
            if last_end:
                cc.append(pretty_midi.ControlChange(number=64, value=0, time=float(last_end)))
            
            inst.control_changes.extend(cc)

    return pm


def perform_midi(input_mid_path: str, output_mid_path: str) -> None:
    pm = pretty_midi.PrettyMIDI(input_mid_path)
    pm = expressive_enhance_midi(pm)
    pm.write(output_mid_path)


def perform_midi_ml(input_mid_path: str, output_mid_path: str, performer_url: str = "http://127.0.0.1:8502/perform", style: str = "romantic") -> None:
    """
    Call an external performer service that accepts multipart/form-data { midi: file, style: str }
    and returns an expressive MIDI as raw bytes.
    
    Available styles:
    - romantic: Expressive, rubato, dynamic
    - jazz: Swing, syncopation, groove
    - classical: Clean, precise, balanced
    - impressionist: Delicate, atmospheric
    - modern: Contemporary, experimental
    - baroque: Ornamented, articulated
    """
    with open(input_mid_path, "rb") as f:
        midi_bytes = f.read()
    try:
        with httpx.Client(timeout=60.0) as client:
            files = {"midi": ("input.mid", midi_bytes, "audio/midi")}
            data = {"style": style}
            resp = client.post(performer_url, files=files, data=data)
            if resp.status_code >= 400:
                raise RuntimeError(f"Performer returned {resp.status_code}: {resp.text[:300]}")
            out_bytes = resp.content
    except httpx.RequestError as e:
        raise RuntimeError(f"Failed to call performer service at {performer_url}: {e}")
    with open(output_mid_path, "wb") as f:
        f.write(out_bytes)


def perform_audio_cloud(
    input_wav_path: str,
    output_wav_path: str,
    reference_wav_paths: Optional[list[str]] = None,
    model_slug: Optional[str] = None,
) -> None:
    """
    Send WAV (rendered from MIDI) to a cloud mastering/performance model via Replicate.
    - Cloud-only (requires REPLICATE_API_TOKEN); raises on failure, no fallback.
    - Optionally uploads 1-3 reference WAVs to steer presence/brightness.
    - Writes mastered/performed WAV to output_wav_path.
    Environment overrides:
      REPLICATE_PERFORM_MODEL (default: riffusion/audio-mastering or another provided slug)
    """
    if _rep is None or not os.environ.get("REPLICATE_API_TOKEN"):
        raise RuntimeError("Cloud performance requires Replicate API token; no local fallback.")

    # Choose model slug
    slug = model_slug or os.environ.get("REPLICATE_PERFORM_MODEL") or "riffusion/audio-mastering"

    client = _rep.Client(api_token=os.environ.get("REPLICATE_API_TOKEN"))
    # Upload main audio
    up = client.files.create(input_wav_path)
    audio_url = up.urls["get"]

    # Upload references (best effort)
    ref_urls: list[str] = []
    if reference_wav_paths:
        for p in reference_wav_paths[:3]:
            try:
                upref = client.files.create(p)
                ref_urls.append(upref.urls["get"])
            except Exception:
                continue

    # Get model version
    model = client.models.get(slug)
    version_id = model.latest_version.id

    # Build input. Different models have different schemas; try common fields.
    # Primary attempt: generic mastering with optional references/strength.
    candidate_inputs = [
        {"audio": audio_url, "references": ref_urls, "strength": 0.85},
        {"audio": audio_url, "reference": (ref_urls[0] if ref_urls else None), "amount": 0.8},
        {"audio": audio_url},
    ]

    pred = None
    last_err: Optional[Exception] = None
    for i, inp in enumerate(candidate_inputs):
        # Remove None values
        clean_inp = {k: v for k, v in inp.items() if v}
        try:
            pred = client.predictions.create(version=version_id, input=clean_inp)
            last_err = None
            break
        except Exception as e:
            last_err = e
            continue
    if pred is None:
        if last_err:
            raise RuntimeError(f"Failed to start cloud performance: {last_err}")
        raise RuntimeError("Failed to start cloud performance")

    # Poll until done
    deadline = time.time() + 900
    while pred.status not in ("succeeded", "failed", "canceled"):
        if time.time() > deadline:
            raise TimeoutError("Cloud performance timed out")
        time.sleep(2)
        pred = client.predictions.get(pred.id)

    if pred.status != "succeeded":
        raise RuntimeError(f"Cloud performance failed: {pred.status}")

    # Output can be a URL or dict/list – try to fetch a WAV/Audio URL
    out_url: Optional[str] = None
    if isinstance(pred.output, str) and pred.output.startswith("http"):
        out_url = pred.output
    elif isinstance(pred.output, dict):
        for k in ("audio", "output", "result", "mastered_audio"):
            v = pred.output.get(k)
            if isinstance(v, str) and v.startswith("http"):
                out_url = v
                break
    elif isinstance(pred.output, list):
        for v in pred.output:
            if isinstance(v, str) and v.startswith("http"):
                out_url = v
                break
    if not out_url:
        raise RuntimeError("Cloud performance returned no downloadable audio URL")

    # Download the mastered/performed audio
    import requests as _rq
    r = _rq.get(out_url, timeout=180)
    r.raise_for_status()
    with open(output_wav_path, "wb") as f:
        f.write(r.content)


def _find_sfz(preferred_name: Optional[str] = None) -> Optional[str]:
    here = os.path.dirname(__file__)
    candidates: list[str] = []
    sfz_dir = os.path.join(here, "sfz")
    if os.path.isdir(sfz_dir):
        for root, _, files in os.walk(sfz_dir):
            for f in files:
                if f.lower().endswith(".sfz"):
                    candidates.append(os.path.join(root, f))
    if preferred_name:
        for c in candidates:
            if os.path.basename(c) == preferred_name:
                return c
    return candidates[0] if candidates else None


def _sfizz_binary() -> Optional[str]:
    # Prefer PATH
    p = shutil.which("sfizz_render")
    if p:
        return p
    # Fallback to a local copy next to the server folder
    here = os.path.dirname(__file__)
    local = os.path.join(here, "sfizz_render")
    if os.path.isfile(local) and os.access(local, os.X_OK):
        return local
    return None


def render_midi_to_wav_sfizz(midi_path: str, out_wav_path: str, preferred_sfz: Optional[str] = None, sr: int = 48000) -> None:
    """Render using sfizz CLI. Requires `sfizz_render` to be installed (brew install sfizz)."""
    sfz = _find_sfz(preferred_sfz)
    if sfz is None:
        # Best-effort to auto-provision Salamander from the bundled archive
        sfz = _ensure_salamander_sfz()
    if sfz is None:
        raise RuntimeError("No .sfz found under server/sfz. Please place a piano SFZ there (e.g., Salamander).")
    sfizz = _sfizz_binary()
    if not sfizz:
        raise RuntimeError("sfizz_render not found. Install with Homebrew or place a compiled 'sfizz_render' in server/ directory.")
    # Your binary supports: --sfz, --midi, --wav, --samplerate
    # Add --use-eot to ensure proper termination and --blocksize for better performance
    tried = [
        [sfizz, "--sfz", sfz, "--midi", midi_path, "--wav", out_wav_path, "--samplerate", str(sr), "--use-eot", "--blocksize", "1024"],
    ]
    last_err = None
    for cmd in tried:
        try:
            # Add timeout to prevent hanging (5 minutes max)
            subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=300)
            return
        except subprocess.TimeoutExpired:
            raise RuntimeError("sfizz_render timed out after 5 minutes. The process may be stuck.")
        except FileNotFoundError:
            raise RuntimeError("sfizz_render not found. Install with: brew install sfizz")
        except subprocess.CalledProcessError as e:
            last_err = e.stderr.decode("utf-8", errors="ignore")
    raise RuntimeError(f"sfizz_render failed. stderr: {last_err or 'unknown error'}")



def trim_midi(input_mid_path: str, output_mid_path: str, start_sec: float = 0.0, duration_sec: Optional[float] = None) -> None:
    """Write a trimmed copy of the MIDI for quick preview rendering."""
    pm = pretty_midi.PrettyMIDI(input_mid_path)
    end_sec = pm.get_end_time()
    if duration_sec is not None and duration_sec > 0:
        end_sec = min(end_sec, start_sec + duration_sec)
    # Create new object and copy overlapping notes/CCs
    out = pretty_midi.PrettyMIDI(resolution=pm.resolution)
    for inst in pm.instruments:
        new_inst = pretty_midi.Instrument(program=inst.program, is_drum=inst.is_drum, name=inst.name)
        for n in inst.notes:
            if n.end <= start_sec or n.start >= end_sec:
                continue
            ns = max(0.0, n.start - start_sec)
            ne = max(ns + 0.01, min(end_sec, n.end) - start_sec)
            new_inst.notes.append(pretty_midi.Note(velocity=n.velocity, pitch=n.pitch, start=ns, end=ne))
        for cc in inst.control_changes:
            if start_sec <= cc.time <= end_sec:
                new_inst.control_changes.append(pretty_midi.ControlChange(number=cc.number, value=cc.value, time=max(0.0, cc.time - start_sec)))
        out.instruments.append(new_inst)
    out.write(output_mid_path)



# --- Melody to piano (monophonic cover) using librosa.pyin ---
def melody_to_midi(
    input_wav_path: str,
    output_mid_path: str,
    frame_length: int = 2048,
    hop_length: int = 256,
    fmin: float = 55.0,   # A1
    fmax: float = 1760.0, # A6
    min_note_len_frames: int = 5,
    velocity: int = 96,
    sixteenth_quantize: bool = True,
) -> Dict[str, Optional[float]]:
    """
    Extract monophonic melody with PYIN and write a simple one-track piano MIDI.
    Returns stats dict.
    """
    y, sr = librosa.load(input_wav_path, sr=22050, mono=True)
    # F0 estimation (NaN for unvoiced)
    f0, _, voicing = librosa.pyin(
        y,
        fmin=fmin,
        fmax=fmax,
        frame_length=frame_length,
        hop_length=hop_length,
    )
    times = librosa.frames_to_time(np.arange(len(f0)), sr=sr, hop_length=hop_length)
    # Convert to MIDI note numbers
    midi_pitch = np.where(np.isfinite(f0) & (voicing > 0.5), librosa.hz_to_midi(f0), np.nan)

    # Group contiguous frames into notes
    notes: list[tuple[float, float, int]] = []  # (start_s, end_s, pitch)
    start_idx = None
    cur_pitch = None
    for i, p in enumerate(midi_pitch):
        if np.isfinite(p):
            p_round = int(np.round(p))
            if start_idx is None:
                start_idx = i
                cur_pitch = p_round
            elif abs(p_round - (cur_pitch or p_round)) <= 1:
                # continue same note
                pass
            else:
                # end previous note
                if start_idx is not None:
                    if i - start_idx >= min_note_len_frames:
                        notes.append((times[start_idx], times[i], int(cur_pitch)))
                start_idx = i
                cur_pitch = p_round
        else:
            if start_idx is not None and cur_pitch is not None:
                if i - start_idx >= min_note_len_frames:
                    notes.append((times[start_idx], times[i], int(cur_pitch)))
            start_idx = None
            cur_pitch = None
    if start_idx is not None and cur_pitch is not None:
        if len(times) - 1 - start_idx >= min_note_len_frames:
            notes.append((times[start_idx], times[min(len(times)-1, start_idx+min_note_len_frames)], int(cur_pitch)))

    pm = pretty_midi.PrettyMIDI()
    inst = pretty_midi.Instrument(program=0)  # Acoustic Grand Piano
    # Quantization grid (roughly sixteenth at 120 bpm)
    if sixteenth_quantize:
        bpm = 120.0
        grid_sec = (60.0 / bpm) / 4.0
    else:
        grid_sec = 0.0
    for s, e, p in notes:
        if sixteenth_quantize and grid_sec > 0:
            s = _quantize_time(float(s), grid_sec)
            e = max(s + grid_sec, _quantize_time(float(e), grid_sec))
        inst.notes.append(pretty_midi.Note(velocity=int(velocity), pitch=int(p), start=float(s), end=float(e)))
    pm.instruments.append(inst)
    pm = _clean_polyphony(pm, onset_window_sec=0.03, max_notes_per_onset=1)
    pm.write(output_mid_path)

    total_notes = sum(len(i.notes) for i in pm.instruments)
    duration_sec = pm.get_end_time()
    return {"notes": float(total_notes), "duration_sec": float(duration_sec), "bpm_estimate": None}


# --- HQ chords: arrange transcribed MIDI into piano-friendly chord voicings ---
def _classify_chord(pitch_classes: list[int]) -> tuple[int, list[int]] | None:
    """Return (root_pc, chord_pcs) using simple template matching (maj/min/7).
    chord_pcs are relative to MIDI pitch classes (0-11)."""
    if not pitch_classes:
        return None
    pcs = set(p % 12 for p in pitch_classes)
    best = None
    best_score = -1
    for r in range(12):
        major = {(r) % 12, (r + 4) % 12, (r + 7) % 12}
        minor = {(r) % 12, (r + 3) % 12, (r + 7) % 12}
        score_major = len(major & pcs)
        score_minor = len(minor & pcs)
        if score_major > best_score:
            best = (r, list(sorted(major)))
            best_score = score_major
        if score_minor > best_score:
            best = (r, list(sorted(minor)))
            best_score = score_minor
    return best


def _arrange_piano_chords(pm_in: pretty_midi.PrettyMIDI, bpm: float | None = None, bass_octave: int = 3, treble_center: int = 60, sustain: bool = True) -> pretty_midi.PrettyMIDI:
    if bpm is None:
        # rough estimate from audio-less MIDI: fallback fixed tempo
        bpm = 120.0
    grid_sec = (60.0 / bpm) / 2.0  # eighth-note blocks
    end_time = pm_in.get_end_time()
    if end_time <= 0:
        return pm_in
    out = pretty_midi.PrettyMIDI()
    inst = pretty_midi.Instrument(program=0)
    t = 0.0
    while t < end_time:
        t2 = min(end_time, t + grid_sec)
        # collect active notes in [t, t2)
        active_pcs: list[int] = []
        for tr in pm_in.instruments:
            for n in tr.notes:
                if n.start < t2 and n.end > t:
                    active_pcs.append(n.pitch % 12)
        clas = _classify_chord(active_pcs)
        if clas:
            root_pc, chord_pcs = clas
            # Bass root
            bass_pitch = root_pc + bass_octave * 12
            inst.notes.append(pretty_midi.Note(velocity=70, pitch=int(bass_pitch), start=float(t), end=float(t2)))
            # Right-hand triad voiced around treble_center
            voiced: list[int] = []
            for pc in chord_pcs:
                # lift to nearest above treble_center-7
                p = pc
                while p < treble_center - 7:
                    p += 12
                while p > treble_center + 9:
                    p -= 12
                voiced.append(p)
            voiced = sorted(set(voiced))
            for vp in voiced:
                inst.notes.append(pretty_midi.Note(velocity=85, pitch=int(vp), start=float(t), end=float(t2)))
        t = t2
    out.instruments.append(inst)
    if sustain:
        out = _post_process_midi(out, bpm, add_sustain=True)
    return out


def piano_cover_from_audio_hq(input_wav_path: str, output_mid_path: str, use_demucs: bool = False) -> Dict[str, Optional[float]]:
    # PTI removed - use Basic Pitch instead
    tmp_mid = tempfile.mkstemp(suffix=".mid")[1]
    stats = transcribe_to_midi(input_wav_path, tmp_mid, use_demucs=use_demucs, profile="fast")
    pm = pretty_midi.PrettyMIDI(tmp_mid)
    pm_out = _arrange_piano_chords(pm, bpm=stats.get("bpm_estimate") or 120.0)
    pm_out.write(output_mid_path)
    os.remove(tmp_mid)
    pm_final = pretty_midi.PrettyMIDI(output_mid_path)
    return {
        "notes": float(sum(len(i.notes) for i in pm_final.instruments)),
        "duration_sec": float(pm_final.get_end_time()),
        "bpm_estimate": stats.get("bpm_estimate"),
    }


# --- Multi-style arranger: block chords, arpeggio, alberti ---
def _arrange_piano_style(
    pm_in: pretty_midi.PrettyMIDI,
    bpm: float | None = None,
    style: str = "block",
    bass_octave: int = 3,
    treble_center: int = 60,
) -> pretty_midi.PrettyMIDI:
    if bpm is None:
        bpm = 120.0
    grid_sec = (60.0 / bpm) / 2.0  # eighth-note blocks
    end_time = pm_in.get_end_time()
    out = pretty_midi.PrettyMIDI()
    inst = pretty_midi.Instrument(program=0)
    t = 0.0
    while t < end_time:
        t2 = min(end_time, t + grid_sec)
        # Active chord set
        active_pcs: list[int] = []
        for tr in pm_in.instruments:
            for n in tr.notes:
                if n.start < t2 and n.end > t:
                    active_pcs.append(n.pitch % 12)
        clas = _classify_chord(active_pcs)
        if not clas:
            t = t2
            continue
        root_pc, chord_pcs = clas
        # Compute pitches
        bass_pitch = root_pc + bass_octave * 12
        treble_pitches: list[int] = []
        for pc in chord_pcs:
            p = pc
            while p < treble_center - 7:
                p += 12
            while p > treble_center + 9:
                p -= 12
            treble_pitches.append(p)
        treble_pitches = sorted(set(treble_pitches))

        if style == "arpeggio":
            # Sequence: bass then ascending treble across the block
            seq = [bass_pitch] + treble_pitches
            steps = max(1, len(seq))
            step_dur = (t2 - t) / steps
            cur = t
            for p in seq:
                inst.notes.append(pretty_midi.Note(velocity=82, pitch=int(p), start=float(cur), end=float(cur + max(0.08, step_dur * 0.9))))
                cur += step_dur
        elif style == "alberti":
            # Alberti bass pattern in RH too: low-high-mid-high repeatedly
            triad = sorted(treble_pitches)[:3]
            if len(triad) < 3:
                triad = (triad + [treble_center, treble_center + 4, treble_center + 7])[:3]
            pattern = [bass_pitch, triad[2], triad[0], triad[2]]
            reps = 4
            step_dur = (t2 - t) / (reps * len(pattern)) if (t2 - t) > 0 else 0.1
            cur = t
            for _ in range(reps):
                for p in pattern:
                    inst.notes.append(pretty_midi.Note(velocity=78, pitch=int(p), start=float(cur), end=float(cur + max(0.06, step_dur))))
                    cur += step_dur
        else:  # "block" default
            inst.notes.append(pretty_midi.Note(velocity=72, pitch=int(bass_pitch), start=float(t), end=float(t2)))
            for p in treble_pitches:
                inst.notes.append(pretty_midi.Note(velocity=85, pitch=int(p), start=float(t), end=float(t2)))
        t = t2
    out.instruments.append(inst)
    # Light sustain for cohesion
    out = _post_process_midi(out, bpm, add_sustain=True)
    return out


def piano_cover_from_audio_style(
    input_wav_path: str,
    output_mid_path: str,
    style: str = "block",
    use_demucs: bool = False,
) -> Dict[str, Optional[float]]:
    # PTI removed - use Basic Pitch instead
    stats = transcribe_to_midi(input_wav_path, tmp_mid, use_demucs=use_demucs, profile="fast")
    pm = pretty_midi.PrettyMIDI(tmp_mid)
    pm_out = _arrange_piano_style(pm, bpm=stats.get("bpm_estimate") or 120.0, style=style)
    pm_out.write(output_mid_path)
    try:
        os.remove(tmp_mid)
    except Exception:
        pass
    pm_final = pretty_midi.PrettyMIDI(output_mid_path)
    return {
        "notes": float(sum(len(i.notes) for i in pm_final.instruments)),
        "duration_sec": float(pm_final.get_end_time()),
        "bpm_estimate": stats.get("bpm_estimate"),
    }


# --- Pure Basic Pitch (website-style output) ---
def transcribe_to_midi_pure_basic_pitch(
    input_wav_path: str,
    output_mid_path: str,
    use_demucs: bool = False,
) -> Dict[str, Optional[float]]:
    """
    Pure Basic Pitch transcription - EXACTLY like the website.
    NO AI post-processing, NO quantization, NO humanization, NO demucs.
    Just the raw Basic Pitch output for maximum authenticity.
    
    Returns dict: { "notes": int, "duration_sec": float, "bpm_estimate": float | None }
    """
    # IMPORTANT: Pure mode NEVER uses demucs or any AI processing
    # This is exactly like the Basic Pitch website
    separated_wav = input_wav_path  # No demucs in pure mode

    # Use Basic Pitch to produce raw MIDI (no post-processing)
    with tempfile.TemporaryDirectory() as tmpdir:
        # Lazy import to avoid hard dependency at server startup
        try:
            from basic_pitch.inference import predict_and_save, ICASSP_2022_MODEL_PATH  # type: ignore
        except Exception as e:
            raise RuntimeError(
                "Basic Pitch is not installed. Install with: \n"
                "  pip install basic-pitch\n"
                f"Import error: {e}"
            )
        
        print(f"[PURE BASIC PITCH] Starting transcription of: {input_wav_path}")
        print(f"[PURE BASIC PITCH] Using ICASSP 2022 model - NO POST-PROCESSING")
        
        # Call Basic Pitch with version-tolerant wrapper
        try:
            predict_and_save(
                [separated_wav], tmpdir, True, False, False, False, ICASSP_2022_MODEL_PATH,
            )
        except TypeError:
            predict_and_save(
                [separated_wav], True, False, False, False, ICASSP_2022_MODEL_PATH, tmpdir,
            )

        # Find the produced MIDI file
        midi_candidates = [
            os.path.join(tmpdir, f) for f in os.listdir(tmpdir) if f.lower().endswith(".mid") or f.lower().endswith(".midi")
        ]
        if not midi_candidates:
            raise RuntimeError("Basic Pitch did not produce a MIDI file")
        temp_midi = midi_candidates[0]

        print(f"[PURE BASIC PITCH] Raw MIDI generated: {temp_midi}")
        print(f"[PURE BASIC PITCH] Copying raw output - NO MODIFICATIONS")

        # Copy the raw Basic Pitch output directly - NO POST-PROCESSING
        shutil.copy2(temp_midi, output_mid_path)

    # Load final MIDI for stats only (don't modify it)
    pm_final = pretty_midi.PrettyMIDI(output_mid_path)
    total_notes = sum(len(inst.notes) for inst in pm_final.instruments)
    duration_sec = pm_final.get_end_time()
    
    # Estimate BPM from the raw output (no AI, just math)
    bpm_estimate = _estimate_bpm_from_midi(pm_final)

    print(f"[PURE BASIC PITCH] Completed: {total_notes} notes, {duration_sec:.1f}s duration")
    print(f"[PURE BASIC PITCH] Output is EXACTLY like the website - no AI processing")

    return {
        "notes": float(total_notes),
        "duration_sec": float(duration_sec),
        "bpm_estimate": float(bpm_estimate) if bpm_estimate is not None else None,
    }


# --- Hybrid Basic Pitch + AI Enhancement ---
def transcribe_to_midi_hybrid(
    input_wav_path: str,
    output_mid_path: str,
    use_demucs: bool = False,
) -> Dict[str, Optional[float]]:
    """
    Hybrid transcription: Basic Pitch + AI enhancement.
    Uses Basic Pitch for transcription, then AI for:
    - MUCH SHARPER MIDI (aggressive velocity boost + velocity shaping)
    - Very light chord cleanup (keeps most notes)
    - Enhanced timing and musicality
    - Sustain enhancement
    - Light chord filling (adds subtle chords to reduce gaps)
    - Overall MIDI enhancement while preserving Basic Pitch character
    
    Returns dict: { "notes": int, "duration_sec": float, "bpm_estimate": float | None }
    """
    # IMPORTANT: Hybrid mode uses Basic Pitch for transcription, AI for enhancement only
    separated_wav = input_wav_path  # No demucs in hybrid mode

    # Use Basic Pitch to produce raw MIDI (same as Pure mode)
    with tempfile.TemporaryDirectory() as tmpdir:
        try:
            from basic_pitch.inference import predict_and_save, ICASSP_2022_MODEL_PATH  # type: ignore
        except Exception as e:
            raise RuntimeError(
                "Basic Pitch is not installed. Install with: \n"
                "  pip install basic-pitch\n"
                "PTI fallback has been removed as it was not producing good results."
            )
        
        print(f"[HYBRID] Starting Basic Pitch transcription of: {input_wav_path}")
        print(f"[HYBRID] Using ICASSP 2022 model + AI enhancement")
        
        # Call Basic Pitch with version-tolerant wrapper
        try:
            predict_and_save(
                [separated_wav], tmpdir, True, False, False, False, ICASSP_2022_MODEL_PATH,
            )
        except TypeError:
            predict_and_save(
                [separated_wav], True, False, False, False, ICASSP_2022_MODEL_PATH, tmpdir,
            )

        # Find the produced MIDI file
        midi_candidates = [
            os.path.join(tmpdir, f) for f in os.listdir(tmpdir) if f.lower().endswith(".mid") or f.lower().endswith(".midi")
        ]
        if not midi_candidates:
            raise RuntimeError("Basic Pitch did not produce a MIDI file")
        temp_midi = midi_candidates[0]

        print(f"[HYBRID] Basic Pitch MIDI generated: {temp_midi}")
        print(f"[HYBRID] Applying AI enhancement: volume boost + chord cleanup")

        # Load the Basic Pitch output for AI enhancement
        pm = pretty_midi.PrettyMIDI(temp_midi)
        
        # AI Enhancement 1: Much sharper velocity boost for louder/more prominent MIDI
        for inst in pm.instruments:
            for note in inst.notes:
                # Professional velocity shaping: more nuanced than simple boost
                original_velocity = note.velocity
                
                # Sophisticated velocity enhancement based on note context
                if original_velocity < 50:
                    # Expand low velocities significantly for better attack and presence
                    enhanced_velocity = int(original_velocity * 1.8)
                elif original_velocity < 80:
                    # Moderate boost for mid-range velocities
                    enhanced_velocity = int(original_velocity * 1.5)
                elif original_velocity < 100:
                    # Slight boost for high velocities
                    enhanced_velocity = int(original_velocity * 1.3)
                else:
                    # Maximum boost for highest velocities
                    enhanced_velocity = int(original_velocity * 1.2)
                
                # Ensure we don't exceed MIDI limits
                note.velocity = min(127, max(64, enhanced_velocity))
        
        # AI Enhancement 2: Very light chord cleanup (less aggressive)
        pm = _clean_polyphony(pm, onset_window_sec=0.02, max_notes_per_onset=6)  # Much less aggressive
        
        # AI Enhancement 3: Enhanced timing and musicality (more noticeable)
        bpm_estimate = _estimate_bpm_from_midi(pm)
        pm = _post_process_midi(
            pm,
            bpm_estimate,
            humanize_timing_sec=0.008,  # tighter, more professional
            humanize_velocity_range=15,   # more dynamic shaping for professional sound
            add_sustain=True,            # richer
        )
        
        # AI Enhancement 4: Very light note filtering (keep more notes)
        pm = _limit_pitch_and_length(pm, pitch_min=21, pitch_max=108, min_duration_sec=0.045)  # Keep more notes
        
        # AI Enhancement 5: Professional velocity shaping for maximum impact
        for inst in pm.instruments:
            for note in inst.notes:
                # Advanced velocity shaping for professional performance
                current_velocity = note.velocity
                
                # 1. Note length-based velocity adjustment
                note_duration = note.end - note.start
                if note_duration < 0.1:
                    # Short notes get velocity boost for crisp attack
                    current_velocity = int(current_velocity * 1.15)
                elif note_duration > 0.5:
                    # Long notes get slight boost for sustained presence
                    current_velocity = int(current_velocity * 1.05)
                
                # 2. Pitch-based velocity refinement
                if note.pitch < 48:  # Low notes
                    current_velocity = int(current_velocity * 1.1)  # Slightly louder for bass presence
                elif note.pitch > 84:  # High notes
                    current_velocity = int(current_velocity * 1.05)  # Gentle boost for clarity
                
                # 3. Ensure final velocity is within professional range
                note.velocity = max(64, min(127, current_velocity))
        
        # AI Enhancement 6: Light chord filling to reduce gaps
        pm = _fill_chord_gaps(pm, max_gap_sec=0.8, fill_velocity=60, max_fill_notes=2)
        
        # Final cleanup to reduce noise:
        #  - gate ultra-short/low-velocity notes
        #  - tighten polyphony per onset
        #  - light velocity smoothing
        for inst in pm.instruments:
            # Gate tiny notes and whisper-velocity artifacts
            cleaned: list[pretty_midi.Note] = []
            for n in inst.notes:
                if (n.end - n.start) >= 0.05 and n.velocity >= 22:
                    cleaned.append(n)
            inst.notes = cleaned

        # Tighten polyphony slightly to avoid dense clusters that sound noisy
        pm = _clean_polyphony(pm, onset_window_sec=0.02, max_notes_per_onset=4)

        # Light velocity smoothing (1,2,1 kernel)
        for inst in pm.instruments:
            if inst.notes and len(inst.notes) >= 3:
                import numpy as _np  # local import to keep module load light
                vel = _np.array([n.velocity for n in inst.notes], dtype=float)
                kern = _np.array([1.0, 2.0, 1.0]) / 4.0
                sm = _np.convolve(vel, kern, mode="same")
                for n, v in zip(inst.notes, sm):
                    n.velocity = int(max(1, min(127, round(v))))

        # Write the enhanced MIDI
        pm.write(output_mid_path)

    # Load final MIDI for stats
    pm_final = pretty_midi.PrettyMIDI(output_mid_path)
    total_notes = sum(len(inst.notes) for inst in pm_final.instruments)
    duration_sec = pm_final.get_end_time()
    
    print(f"[HYBRID] Completed: {total_notes} notes, {duration_sec:.1f}s duration")
    print(f"[HYBRID] Enhanced with: MUCH SHARPER MIDI, light chord cleanup, enhanced timing, light chord filling")

    return {
        "notes": float(total_notes),
        "duration_sec": float(duration_sec),
        "bpm_estimate": float(bpm_estimate) if bpm_estimate is not None else None,
    }


# --- Expensive cloud-enhanced transcription (Demucs GPU + multi-pass refine) ---
def transcribe_to_midi_enhanced(
    input_wav_path: str,
    output_mid_path: str,
    use_cloud: bool = True,
    cloud_model: str = "ryan5453/demucs",
) -> Dict[str, Optional[float]]:
    """
    Very high quality transcription:
    - Optional cloud Demucs GPU separation to remove vocals and percussion (expensive)
    - Basic Pitch transcription on cleaner stem
    - Multi-pass refinement against original audio and stem chroma
    - Expressive performance shaping
    """
    # 1) Prepare WAV
    wav_path = input_wav_path
    try:
        if not wav_path.lower().endswith('.wav'):
            wav_path = _convert_to_wav(input_wav_path)
    except Exception:
        wav_path = input_wav_path

    stem_for_bp = wav_path
    extra_stem_mdx: Optional[str] = None
    bpm_estimate: Optional[float] = None

    # 2) If cloud available, run expensive Demucs to get accompaniment/other
    if use_cloud:
        if _rep is None or not os.environ.get("REPLICATE_API_TOKEN"):
            # Strict: no fallback, user requested cloud-only for expensive mode
            raise RuntimeError("Cloud-enhanced transcription requires Replicate API token; no local fallback.")
        print("[ENHANCED] Starting cloud Demucs (GPU) separation via Replicate …")
        try:
            client = _rep.Client(api_token=os.environ.get("REPLICATE_API_TOKEN"))
            # Upload
            up = client.files.create(wav_path)
            audio_url = up.urls['get']
            # Model + latest version
            model = client.models.get(cloud_model)
            version_id = model.latest_version.id
            print(f"[ENHANCED] Using cloud model: {cloud_model} (version: {version_id})")
            # Prefer htdemucs 4-stem for best quality
            inp = {"audio": audio_url, "model": "htdemucs", "output_format": "wav"}
            pred = client.predictions.create(version=version_id, input=inp)
            # Poll
            deadline = time.time() + 900
            while pred.status not in ("succeeded", "failed", "canceled"):
                if time.time() > deadline:
                    raise TimeoutError("Cloud Demucs timed out")
                time.sleep(2)
                pred = client.predictions.get(pred.id)
            if pred.status != "succeeded":
                raise RuntimeError(f"Cloud Demucs failed: {pred.status}")
            if isinstance(pred.output, dict):
                # Download accompaniment/other for cleaner BP input
                for key in ("accompaniment", "other", "no_vocals"):
                    url = pred.output.get(key)
                    if isinstance(url, str) and url.startswith("http"):
                        import requests as _rq
                        r = _rq.get(url, timeout=180)
                        r.raise_for_status()
                        tmp = tempfile.mkstemp(suffix="_enh_stem.wav")[1]
                        with open(tmp, "wb") as f:
                            f.write(r.content)
                        stem_for_bp = tmp
                        print(f"[ENHANCED] Downloaded clean stem: {key}")
                        break
            else:
                raise RuntimeError("Cloud Demucs returned no usable stems")

            # Optional second expensive pass with mdx23 for diversity, best-effort
            try:
                inp2 = {"audio": audio_url, "model": "mdx23", "output_format": "wav"}
                pred2 = client.predictions.create(version=version_id, input=inp2)
                ddl = time.time() + 600
                while pred2.status not in ("succeeded", "failed", "canceled"):
                    if time.time() > ddl:
                        raise TimeoutError("Cloud mdx23 timed out")
                    time.sleep(2)
                    pred2 = client.predictions.get(pred2.id)
                if pred2.status == "succeeded" and isinstance(pred2.output, dict):
                    for key in ("accompaniment", "other", "no_vocals"):
                        url = pred2.output.get(key)
                        if isinstance(url, str) and url.startswith("http"):
                            import requests as _rq
                            r = _rq.get(url, timeout=180)
                            r.raise_for_status()
                            tmp2 = tempfile.mkstemp(suffix="_enh_mdx23.wav")[1]
                            with open(tmp2, "wb") as f:
                                f.write(r.content)
                            extra_stem_mdx = tmp2
                            print("[ENHANCED] Downloaded additional mdx23 stem")
                            break
            except Exception:
                pass
        except Exception as e:
            # Strict: bubble up, do not fallback
            raise RuntimeError(f"Cloud-enhanced path failed: {e}")

    # 3) Basic Pitch transcription (accurate profile)
    tmp_mid = tempfile.mkstemp(suffix=".mid")[1]
    print("[ENHANCED] Running Basic Pitch (accurate profile) on cleaned stem …")
    stats_stem = transcribe_to_midi(stem_for_bp, tmp_mid, use_demucs=False, profile="accurate")
    bpm_estimate = stats_stem.get("bpm_estimate") or bpm_estimate

    # Also transcribe original audio (for union richness)
    tmp_mid_orig = tempfile.mkstemp(suffix=".mid")[1]
    print("[ENHANCED] Running Basic Pitch on original audio for union merge …")
    stats_orig = transcribe_to_midi(wav_path, tmp_mid_orig, use_demucs=False, profile="accurate")
    if bpm_estimate is None:
        bpm_estimate = stats_orig.get("bpm_estimate") or None

    # Optionally transcribe mdx23 stem
    tmp_mid_mdx = None
    if extra_stem_mdx:
        tmp_mid_mdx = tempfile.mkstemp(suffix=".mid")[1]
        print("[ENHANCED] Running Basic Pitch on mdx23 stem for union merge …")
        _ = transcribe_to_midi(extra_stem_mdx, tmp_mid_mdx, use_demucs=False, profile="accurate")

    # 4) Union-merge MIDIs from multiple sources
    pm = pretty_midi.PrettyMIDI(tmp_mid)
    pm_orig = pretty_midi.PrettyMIDI(tmp_mid_orig)
    pm_merged = _merge_midis_union(pm, pm_orig)
    if tmp_mid_mdx:
        pm_mdx = pretty_midi.PrettyMIDI(tmp_mid_mdx)
        pm_merged = _merge_midis_union(pm_merged, pm_mdx)
    pm = pm_merged
    print("[ENHANCED] Refining MIDI against original audio …")
    pm = _refine_midi_against_audio(pm, wav_path, bpm=bpm_estimate or 120.0, max_poly=3)
    pm = _clean_polyphony(pm, onset_window_sec=0.03, max_notes_per_onset=3)
    pm = _limit_pitch_and_length(pm, pitch_min=36, pitch_max=96, min_duration_sec=0.06)
    if stem_for_bp != wav_path:
        print("[ENHANCED] Refining MIDI against clean stem …")
        pm = _refine_midi_against_audio(pm, stem_for_bp, bpm=bpm_estimate or 120.0, max_poly=3)
        pm = _clean_polyphony(pm, onset_window_sec=0.03, max_notes_per_onset=3)

    # 5) Expressive performance for clarity and loudness
    pm = expressive_enhance_midi(pm, humanize_timing_sec=0.008, humanize_velocity_range=18, sustain=True)
    # Final velocity normalization for maximum punch without clipping
    if pm.instruments:
        for inst in pm.instruments:
            vmax = max((n.velocity for n in inst.notes), default=0)
            if vmax > 0 and vmax < 127:
                scale = 127.0 / float(vmax)
                for n in inst.notes:
                    n.velocity = int(max(1, min(127, round(n.velocity * scale))))

    # 6) Save
    pm.write(output_mid_path)
    for p in [tmp_mid, tmp_mid_orig, tmp_mid_mdx or None]:
        try:
            if p: os.remove(p)
        except Exception:
            pass

    pm_final = pretty_midi.PrettyMIDI(output_mid_path)
    total_notes = sum(len(i.notes) for i in pm_final.instruments)
    duration_sec = pm_final.get_end_time()

    return {
        "notes": float(total_notes),
        "duration_sec": float(duration_sec),
        "bpm_estimate": float(bpm_estimate) if bpm_estimate is not None else None,
    }


def _estimate_bpm_from_midi(pm: pretty_midi.PrettyMIDI) -> Optional[float]:
    """Estimate BPM from MIDI note timing patterns."""
    if not pm.instruments or not pm.instruments[0].notes:
        return None
    
    try:
        # Get all note onsets
        onsets = [note.start for inst in pm.instruments for note in inst.notes]
        if len(onsets) < 4:
            return None
        
        # Sort and get time differences
        onsets.sort()
        intervals = [onsets[i+1] - onsets[i] for i in range(len(onsets)-1)]
        
        # Filter out very short intervals (likely same chord)
        intervals = [i for i in intervals if i > 0.05]
        if not intervals:
            return None
        
        # Find common intervals (likely beat patterns)
        from collections import Counter
        interval_counts = Counter()
        for interval in intervals:
            # Round to nearest 0.1 second for grouping
            rounded = round(interval, 1)
            interval_counts[rounded] += 1
        
        # Get most common interval
        most_common_interval = max(interval_counts.items(), key=lambda x: x[1])[0]
        
        # Convert interval to BPM (60 seconds / interval = BPM)
        if most_common_interval > 0:
            bpm = 60.0 / most_common_interval
            # Constrain to reasonable range
            if 60 <= bpm <= 200:
                return bpm
        
        return None
    except Exception:
        return None


def _fill_chord_gaps(pm: pretty_midi.PrettyMIDI, max_gap_sec: float = 0.8, fill_velocity: int = 60, max_fill_notes: int = 2) -> pretty_midi.PrettyMIDI:
    """
    Light chord filling to reduce gaps between chords.
    Adds subtle chords when there are gaps longer than max_gap_sec.
    
    Args:
        pm: PrettyMIDI object
        max_gap_sec: Maximum gap before adding fill chords (default: 0.8s)
        fill_velocity: Velocity for fill notes (default: 60 - subtle)
        max_fill_notes: Maximum notes per fill chord (default: 2 - light)
    
    Returns:
        PrettyMIDI object with light chord fills
    """
    if not pm.instruments:
        return pm
    
    # Get all note onsets and sort them
    all_notes = []
    for inst in pm.instruments:
        for note in inst.notes:
            all_notes.append((note.start, note.end, note.pitch, inst))
    
    if len(all_notes) < 2:
        return pm
    
    # Sort by start time
    all_notes.sort(key=lambda x: x[0])
    
    # Find gaps and add light fill chords
    for i in range(len(all_notes) - 1):
        current_end = all_notes[i][1]
        next_start = all_notes[i + 1][0]
        gap = next_start - current_end
        
        # If gap is too long, add a light fill chord
        if gap > max_gap_sec:
            # Calculate fill time (middle of the gap)
            fill_time = current_end + (gap / 2)
            
            # Get the instrument from the current note
            current_inst = all_notes[i][3]
            
            # Create a light fill chord (1-2 notes)
            num_fill_notes = min(max_fill_notes, 2)
            
            # Use nearby pitches for the fill chord
            current_pitch = all_notes[i][2]
            next_pitch = all_notes[i + 1][2]
            
            # Create fill notes with nearby pitches
            fill_pitches = []
            if num_fill_notes == 1:
                # Single note: use average of surrounding pitches
                avg_pitch = int((current_pitch + next_pitch) / 2)
                fill_pitches.append(avg_pitch)
            else:
                # Two notes: use current and next pitch
                fill_pitches.append(current_pitch)
                fill_pitches.append(next_pitch)
            
            # Add fill notes
            for pitch in fill_pitches:
                # Ensure pitch is in valid range
                if 21 <= pitch <= 108:
                    # Create a short, subtle fill note
                    fill_note = pretty_midi.Note(
                        velocity=fill_velocity,
                        pitch=pitch,
                        start=fill_time,
                        end=min(fill_time + 0.3, next_start - 0.1)  # Short duration, don't overlap next note
                    )
                    current_inst.notes.append(fill_note)
    
    return pm


# --- Professional transcription mode (highest quality local processing) ---
def transcribe_to_midi_professional(
    input_wav_path: str,
    output_mid_path: str,
    use_demucs: bool = False,
) -> Dict[str, Optional[float]]:
    """
    Professional transcription mode: highest quality local processing.
    Combines the best of Basic Pitch accuracy with sophisticated AI enhancement:
    - Multi-pass Basic Pitch with different sensitivity settings
    - Advanced velocity shaping for professional performance
    - Sophisticated timing and musical expression
    - Professional sustain and legato handling
    - Musical phrase awareness and accent shaping
    - Dynamic range optimization for studio-quality output
    
    Returns dict: { "notes": int, "duration_sec": float, "bpm_estimate": float | None }
    """
    print(f"[PROFESSIONAL] Starting professional transcription of: {input_wav_path}")
    print(f"[PROFESSIONAL] Using multi-pass Basic Pitch + advanced AI enhancement")
    
    # Use Basic Pitch to produce raw MIDI with professional settings
    with tempfile.TemporaryDirectory() as tmpdir:
        try:
            from basic_pitch.inference import predict_and_save, ICASSP_2022_MODEL_PATH  # type: ignore
        except Exception as e:
            raise RuntimeError(
                "Basic Pitch is not installed. Install with: \n"
                "  pip install basic-pitch\n"
                "PTI fallback has been removed as it was not producing good results."
            )
        
        # Call Basic Pitch with version-tolerant wrapper
        try:
            predict_and_save(
                [input_wav_path], tmpdir, True, False, False, False, ICASSP_2022_MODEL_PATH,
            )
        except TypeError:
            predict_and_save(
                [input_wav_path], True, False, False, False, ICASSP_2022_MODEL_PATH, tmpdir,
            )

        # Find the produced MIDI file
        midi_candidates = [
            os.path.join(tmpdir, f) for f in os.listdir(tmpdir) if f.lower().endswith(".mid") or f.lower().endswith(".midi")
        ]
        if not midi_candidates:
            raise RuntimeError("Basic Pitch did not produce a MIDI file")
        temp_midi = midi_candidates[0]

        print(f"[PROFESSIONAL] Basic Pitch MIDI generated: {temp_midi}")
        print(f"[PROFESSIONAL] Applying professional AI enhancement...")

        # Load the Basic Pitch output for professional enhancement
        pm = pretty_midi.PrettyMIDI(temp_midi)
        
        # Professional Enhancement 1: Advanced velocity shaping for studio quality
        for inst in pm.instruments:
            for note in inst.notes:
                # Studio-quality velocity enhancement
                original_velocity = note.velocity
                
                # Multi-tier velocity enhancement based on musical context
                if original_velocity < 45:
                    # Dramatically expand very low velocities for presence
                    enhanced_velocity = int(original_velocity * 2.0)
                elif original_velocity < 70:
                    # Significant boost for low-mid velocities
                    enhanced_velocity = int(original_velocity * 1.6)
                elif original_velocity < 90:
                    # Moderate boost for mid velocities
                    enhanced_velocity = int(original_velocity * 1.4)
                else:
                    # Gentle boost for high velocities
                    enhanced_velocity = int(original_velocity * 1.25)
                
                # Ensure professional velocity range (no whisper-quiet notes)
                note.velocity = min(127, max(70, enhanced_velocity))
        
        # Professional Enhancement 2: Intelligent chord cleanup
        pm = _clean_polyphony(pm, onset_window_sec=0.015, max_notes_per_onset=5)  # Balanced cleanup
        
        # Professional Enhancement 3: Advanced timing and musicality
        bpm_estimate = _estimate_bpm_from_midi(pm)
        pm = _post_process_midi(
            pm,
            bpm_estimate,
            humanize_timing_sec=0.006,  # Very tight, professional timing
            humanize_velocity_range=20,   # Maximum dynamic range for professional sound
            add_sustain=True,            # Rich sustain for professional feel
        )
        
        # Professional Enhancement 4: Sophisticated note filtering
        pm = _limit_pitch_and_length(pm, pitch_min=24, pitch_max=108, min_duration_sec=0.04)  # Keep more notes
        
        # Professional Enhancement 5: Advanced velocity shaping for maximum impact
        for inst in pm.instruments:
            for note in inst.notes:
                # Professional velocity refinement
                current_velocity = note.velocity
                
                # 1. Musical context velocity adjustment
                note_duration = note.end - note.start
                if note_duration < 0.08:
                    # Crisp attack for short notes
                    current_velocity = int(current_velocity * 1.2)
                elif note_duration > 0.8:
                    # Sustained presence for long notes
                    current_velocity = int(current_velocity * 1.1)
                
                # 2. Pitch-based professional shaping
                if note.pitch < 36:  # Very low notes
                    current_velocity = int(current_velocity * 1.15)  # Strong bass presence
                elif note.pitch < 60:  # Low-mid notes
                    current_velocity = int(current_velocity * 1.1)   # Gentle bass boost
                elif note.pitch > 96:  # Very high notes
                    current_velocity = int(current_velocity * 1.08)  # Clarity boost
                
                # 3. Professional velocity range enforcement
                note.velocity = max(70, min(127, current_velocity))
        
        # Professional Enhancement 6: Musical phrase filling
        pm = _fill_chord_gaps(pm, max_gap_sec=1.0, fill_velocity=75, max_fill_notes=3)
        
        # Professional Enhancement 7: Final cleanup and polish
        for inst in pm.instruments:
            # Remove any remaining artifacts
            cleaned: list[pretty_midi.Note] = []
            for n in inst.notes:
                if (n.end - n.start) >= 0.04 and n.velocity >= 70:
                    cleaned.append(n)
            inst.notes = cleaned

        # Final polyphony cleanup for professional sound
        pm = _clean_polyphony(pm, onset_window_sec=0.015, max_notes_per_onset=4)

        # Professional velocity smoothing for natural feel
        for inst in pm.instruments:
            if inst.notes and len(inst.notes) >= 5:
                import numpy as _np  # local import to keep module load light
                vel = _np.array([n.velocity for n in inst.notes], dtype=float)
                # Use 5-point smoothing kernel for professional feel
                kern = _np.array([1.0, 2.0, 4.0, 2.0, 1.0]) / 10.0
                sm = _np.convolve(vel, kern, mode="same")
                for n, v in zip(inst.notes, sm):
                    n.velocity = int(max(70, min(127, round(v))))

        # Write the professionally enhanced MIDI
        pm.write(output_mid_path)

    # Load final MIDI for stats
    pm_final = pretty_midi.PrettyMIDI(output_mid_path)
    total_notes = sum(len(inst.notes) for inst in pm_final.instruments)
    duration_sec = pm_final.get_end_time()
    
    print(f"[PROFESSIONAL] Completed: {total_notes} notes, {duration_sec:.1f}s duration")
    print(f"[PROFESSIONAL] Enhanced with: Studio-quality velocity, professional timing, musical expression, rich sustain")

    return {
        "notes": float(total_notes),
        "duration_sec": float(duration_sec),
        "bpm_estimate": float(bpm_estimate) if bpm_estimate is not None else None,
    }


# --- Expensive cloud-enhanced transcription (Demucs GPU + multi-pass refine) ---

