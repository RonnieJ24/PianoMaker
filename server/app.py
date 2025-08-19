import os
import uuid
import shutil
import json
import threading
import time
from typing import Optional

from fastapi import FastAPI, UploadFile, File, Form, HTTPException, Request
from fastapi.responses import StreamingResponse
from dotenv import load_dotenv
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware

try:
    from server.inference import OUTPUTS_DIR, transcribe_to_midi, _convert_to_wav, render_midi_to_wav, perform_midi, perform_midi_ml, render_midi_to_wav_sfizz, trim_midi, transcribe_to_midi_pti, separate_audio, separate_audio_fast, separate_audio_spleeter_api, melody_to_midi, piano_cover_from_audio_hq, piano_cover_from_audio_style, separate_audio_spleeter_local, separate_audio_medium, separate_audio_umx, separate_audio_local_ml, separate_audio_great
except Exception:
    from inference import OUTPUTS_DIR, transcribe_to_midi, _convert_to_wav, render_midi_to_wav, perform_midi, perform_midi_ml, render_midi_to_wav_sfizz, trim_midi, transcribe_to_midi_pti, separate_audio, separate_audio_fast, separate_audio_spleeter_api, melody_to_midi, piano_cover_from_audio_hq, piano_cover_from_audio_style, separate_audio_spleeter_local, separate_audio_medium, separate_audio_umx, separate_audio_local_ml, separate_audio_great
import os as _os
try:
    import replicate as _rep  # optional; only used if REPLICATE_API_TOKEN is set
except Exception:
    _rep = None


load_dotenv()
# Force Demucs HQ model for robust separation
os.environ.setdefault("DEMUCS_MODEL", "htdemucs")
app = FastAPI(title="PianoMaker API", version="0.1.0")
# Allow simulator/device to connect
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
@app.get("/ping")
async def ping():
    return {"status": "ok"}

@app.get("/health")
async def health():
    # Simple check plus number of jobs folders
    try:
        jobs = [d for d in os.listdir(OUTPUTS_DIR) if os.path.isdir(os.path.join(OUTPUTS_DIR, d))]
        return {"status": "ok", "jobs": len(jobs)}
    except Exception:
        return {"status": "ok"}

# Ensure outputs directory exists and mount it for static serving
os.makedirs(OUTPUTS_DIR, exist_ok=True)
app.mount("/outputs", StaticFiles(directory=OUTPUTS_DIR), name="outputs")
@app.post("/separate")
async def separate(request: Request, file: UploadFile = File(...), mode: Optional[str] = Form(None), enhance: Optional[bool] = Form(False)):
    if file is None:
        raise HTTPException(status_code=400, detail="No file uploaded")

    job_id = uuid.uuid4().hex[:8]
    job_dir = os.path.join(OUTPUTS_DIR, job_id)
    os.makedirs(job_dir, exist_ok=True)

    # Save uploaded file
    original_ext = os.path.splitext(file.filename or "input")[1].lower()
    original_name = f"input{original_ext if original_ext else '.bin'}"
    original_path = os.path.join(job_dir, original_name)
    with open(original_path, "wb") as f:
        shutil.copyfileobj(file.file, f)

    # Convert to WAV if needed
    try:
        if original_ext not in [".wav", ".wave"]:
            wav_path = _convert_to_wav(original_path)
        else:
            wav_path = original_path
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Failed to decode audio: {e}")

    backend = None
    fallback_from = None
    inst_path = None
    voc_path = None

    def _copy_to_job(src: Optional[str], dst_name: str) -> Optional[str]:
        if not src:
            return None
        out = os.path.join(job_dir, dst_name)
        try:
            shutil.copy(src, out)
            return out
        except Exception:
            return None

    # Choose strategy
    try:
        m = (mode or "").lower() if mode else None
        if m == "fast":
            inst, voc = separate_audio_fast(wav_path)
            backend = "fast_local"
        elif m == "medium":
            inst, voc = separate_audio_medium(wav_path)
            backend = "demucs_medium"
        elif m == "great":
            inst, voc = separate_audio_great(wav_path, enhance=bool(enhance))
            backend = "demucs_great" + ("+enh" if enhance else "")
        elif m == "umx":
            inst, voc = separate_audio_umx(wav_path)
            backend = "umx"
        elif m == "local_ml":
            inst, voc = separate_audio_local_ml(wav_path)
            backend = "local_ml"
        else:
            # Robust default: Demucs hq → medium → local_ml → fast
            try:
                inst, voc = separate_audio(wav_path)
                backend = "demucs_hq"
            except Exception:
                fallback_from = "demucs_hq"
                try:
                    inst, voc = separate_audio_medium(wav_path)
                    backend = "demucs_medium"
                except Exception:
                    if not fallback_from:
                        fallback_from = backend or "demucs"
                    try:
                        inst, voc = separate_audio_local_ml(wav_path)
                        backend = "local_ml"
                    except Exception:
                        if not fallback_from:
                            fallback_from = backend or "local_ml"
                        inst, voc = separate_audio_fast(wav_path)
                        backend = "fast_local"

        inst_path = _copy_to_job(inst, "instrumental.wav")
        voc_path = _copy_to_job(voc, "vocals.wav") if voc else None
        # Fallback: if vocals missing but instrumental exists, derive vocals = original - instrumental
        if voc_path is None and inst_path and os.path.isfile(inst_path):
            try:
                import soundfile as _sf
                import numpy as _np
                import librosa as _lb
                y, sr = _lb.load(wav_path, sr=None, mono=False)
                i, sr2 = _sf.read(inst_path, dtype='float32')
                if sr2 != sr:
                    # Simple resample via librosa if needed
                    if i.ndim == 1:
                        i = _lb.resample(i, orig_sr=sr2, target_sr=sr)
                    else:
                        i = _np.vstack([_lb.resample(i[:,0], orig_sr=sr2, target_sr=sr), _lb.resample(i[:,1], orig_sr=sr2, target_sr=sr)]).T
                # Ensure shapes and channels align
                if y.ndim == 1:
                    y = _np.expand_dims(y, axis=0)
                if i.ndim == 1:
                    i = _np.expand_dims(i, axis=0)
                if y.shape[-1] != i.shape[0] and i.ndim == 2 and y.ndim == 2:
                    i = i.T
                n = min(y.shape[-1], i.shape[-1])
                y = y[..., :n]
                i = i[..., :n]
                voc = y - i
                out_v = os.path.join(job_dir, "vocals.wav")
                _sf.write(out_v, voc.T if voc.ndim == 2 else voc, sr)
                voc_path = out_v
            except Exception:
                pass
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Separation failed: {e}")

    base_url = str(request.base_url).rstrip("/")
    inst_url = f"{base_url}/outputs/{job_id}/instrumental.wav" if inst_path and os.path.isfile(inst_path) else None
    voc_url = f"{base_url}/outputs/{job_id}/vocals.wav" if voc_path and os.path.isfile(voc_path) else None

    return JSONResponse(content={
        "status": "done",
        "job_id": job_id,
        "instrumental_url": inst_url,
        "vocals_url": voc_url,
        "backend": backend,
        "fallback_from": fallback_from,
    })


@app.post("/separate_api")
async def separate_api(request: Request, file: UploadFile = File(...), model_version: Optional[str] = Form(None), force: Optional[bool] = Form(False), target: Optional[str] = Form(None), local: Optional[bool] = Form(False)):
    if file is None:
        raise HTTPException(status_code=400, detail="No file uploaded")

    job_id = uuid.uuid4().hex[:8]
    job_dir = os.path.join(OUTPUTS_DIR, job_id)
    os.makedirs(job_dir, exist_ok=True)

    original_ext = os.path.splitext(file.filename or "input")[1].lower()
    original_name = f"input{original_ext if original_ext else '.bin'}"
    original_path = os.path.join(job_dir, original_name)
    with open(original_path, "wb") as f:
        shutil.copyfileobj(file.file, f)

    try:
        wav_path = _convert_to_wav(original_path) if original_ext not in [".wav", ".wave"] else original_path
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Failed to decode audio: {e}")

    base_url = str(request.base_url).rstrip("/")
    backend = None
    fallback_from = None

    def _copy(src: Optional[str], name: str) -> Optional[str]:
        if not src:
            return None
        out = os.path.join(job_dir, name)
        try:
            shutil.copy(src, out)
            return f"{base_url}/outputs/{job_id}/{name}"
        except Exception:
            return None

    instrumental_url = None
    vocals_url = None

    try:
        if local:
            inst, voc = separate_audio_spleeter_local(wav_path)
            backend = "spleeter_local"
            instrumental_url = _copy(inst, "instrumental.wav")
            vocals_url = _copy(voc, "vocals.wav") if voc else None
        else:
            # Hosted API route
            try:
                res = separate_audio_spleeter_api(wav_path)
                backend = "spleeter_api"
                instrumental_url = res.get("instrumental_url")
                vocals_url = res.get("vocals_url")
                if not instrumental_url and not vocals_url:
                    raise RuntimeError("Hosted API returned no URLs")
            except Exception as e:
                if force:
                    raise
                # Fallback locally for robustness
                fallback_from = "spleeter_api"
                try:
                    inst, voc = separate_audio(wav_path)
                    backend = "demucs_hq"
                except Exception:
                    inst, voc = separate_audio_fast(wav_path)
                    backend = "fast_local"
                instrumental_url = _copy(inst, "instrumental.wav")
                vocals_url = _copy(voc, "vocals.wav") if voc else None
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Separation(API) failed: {e}")

    return JSONResponse(content={
        "status": "done",
        "job_id": job_id,
        "instrumental_url": instrumental_url,
        "vocals_url": vocals_url,
        "backend": backend,
        "fallback_from": fallback_from,
    })



@app.post("/transcribe")
async def transcribe(request: Request, file: UploadFile = File(...), use_demucs: bool = Form(False), profile: Optional[str] = Form(None)):
    if file is None:
        raise HTTPException(status_code=400, detail="No file uploaded")

    job_id = uuid.uuid4().hex[:8]
    job_dir = os.path.join(OUTPUTS_DIR, job_id)
    os.makedirs(job_dir, exist_ok=True)

    # Save uploaded file
    original_ext = os.path.splitext(file.filename or "input")[1].lower()
    original_name = f"input{original_ext if original_ext else '.bin'}"
    original_path = os.path.join(job_dir, original_name)
    with open(original_path, "wb") as f:
        shutil.copyfileobj(file.file, f)

    # Convert to WAV if needed
    try:
        if original_ext not in [".wav", ".wave"]:
            wav_path = _convert_to_wav(original_path)
        else:
            wav_path = original_path
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Failed to decode audio: {e}")

    midi_path = os.path.join(job_dir, "output.mid")

    # Run transcription: prefer Basic Pitch, fall back to PTI automatically
    try:
        stats = transcribe_to_midi(wav_path, midi_path, use_demucs=use_demucs, profile=profile)
    except Exception as e:
        # Fallback to PTI for broader compatibility
        try:
            stats = transcribe_to_midi_pti(wav_path, midi_path, use_demucs=use_demucs)
        except Exception as e2:
            raise HTTPException(status_code=500, detail=f"Transcription failed: {e}")

    base_url = str(request.base_url).rstrip("/")
    midi_url = f"{base_url}/outputs/{os.path.basename(job_dir)}/output.mid"

    return JSONResponse(
        content={
            "status": "done",
            "midi_url": midi_url,
            "duration_sec": stats.get("duration_sec"),
            "notes": int(stats.get("notes", 0)),
            "job_id": job_id,
        }
    )


@app.get("/status/{job_id}")
async def status(request: Request, job_id: str):
    job_dir = os.path.join(OUTPUTS_DIR, job_id)
    midi_path = os.path.join(job_dir, "output.mid")
    if os.path.exists(midi_path):
        base_url = str(request.base_url).rstrip("/")
        midi_url = f"{base_url}/outputs/{job_id}/output.mid"
        return {"status": "done", "midi_url": midi_url}
    elif os.path.isdir(job_dir):
        # Include any error file content if present
        err_path = os.path.join(job_dir, "error.txt")
        if os.path.isfile(err_path):
            try:
                with open(err_path, "r") as f:
                    return {"status": "error", "error": f.read()[:2000]}
            except Exception:
                pass
        return {"status": "processing"}
    else:
        raise HTTPException(status_code=404, detail="job_id not found")


@app.post("/render")
async def render(request: Request, midi: UploadFile = File(...), sf2_name: Optional[str] = Form(None), quality: str = Form("studio")):
    if midi is None:
        raise HTTPException(status_code=400, detail="No MIDI uploaded")

    job_id = uuid.uuid4().hex[:8]
    job_dir = os.path.join(OUTPUTS_DIR, job_id)
    os.makedirs(job_dir, exist_ok=True)

    midi_path = os.path.join(job_dir, "input.mid")
    with open(midi_path, "wb") as f:
        shutil.copyfileobj(midi.file, f)

    wav_path = os.path.join(job_dir, "render.wav")
    try:
        render_midi_to_wav(midi_path, wav_path, preferred_bank=sf2_name, quality=quality)
    except RuntimeError as e:
        raise HTTPException(status_code=500, detail=str(e))

    base_url = str(request.base_url).rstrip("/")
    wav_url = f"{base_url}/outputs/{job_id}/render.wav"
    return JSONResponse(content={"status": "done", "wav_url": wav_url, "job_id": job_id})

@app.post("/render_sfizz")
async def render_sfizz(request: Request, midi: UploadFile = File(...), sfz_name: Optional[str] = Form(None), sr: Optional[int] = Form(None)):
    if midi is None:
        raise HTTPException(status_code=400, detail="No MIDI uploaded")

    job_id = uuid.uuid4().hex[:8]
    job_dir = os.path.join(OUTPUTS_DIR, job_id)
    os.makedirs(job_dir, exist_ok=True)

    in_mid = os.path.join(job_dir, "input.mid")
    with open(in_mid, "wb") as f:
        shutil.copyfileobj(midi.file, f)

    wav_path = os.path.join(job_dir, "render_sfizz.wav")
    try:
        print(f"[render_sfizz] start job={job_id} midi={in_mid}")
        render_midi_to_wav_sfizz(in_mid, wav_path, preferred_sfz=sfz_name, sr=sr or 48000)
    except Exception as e:
        print(f"[render_sfizz] ERROR job={job_id}: {e}")
        raise HTTPException(status_code=500, detail=str(e))

    base_url = str(request.base_url).rstrip("/")
    wav_url = f"{base_url}/outputs/{job_id}/render_sfizz.wav"
    print(f"[render_sfizz] done job={job_id} wav={wav_url}")
    return JSONResponse(content={"status": "done", "wav_url": wav_url, "job_id": job_id})


# --- Async job-based SFZ render with progress ---
def _write_progress(job_dir: str, status: str, progress: float, error: Optional[str] = None):
    meta_path = os.path.join(job_dir, "progress.json")
    payload = {"status": status, "progress": float(progress)}
    if error:
        payload["error"] = error
    try:
        with open(meta_path, "w") as f:
            json.dump(payload, f)
    except Exception:
        pass


def _sfizz_job_runner(job_id: str, job_dir: str, in_mid: str, wav_path: str, sr: int, sfz_name: Optional[str]):
    base_progress = 0.1
    _write_progress(job_dir, "starting", base_progress)
    try:
        # Rendering step
        _write_progress(job_dir, "rendering", 0.2)
        render_midi_to_wav_sfizz(in_mid, wav_path, preferred_sfz=sfz_name, sr=sr)
        # Finished
        _write_progress(job_dir, "done", 1.0)
    except Exception as e:
        _write_progress(job_dir, "error", 1.0, str(e))


@app.post("/render_sfizz_start")
async def render_sfizz_start(request: Request, midi: UploadFile = File(...), sfz_name: Optional[str] = Form(None), sr: Optional[int] = Form(None), preview: Optional[bool] = Form(None)):
    if midi is None:
        raise HTTPException(status_code=400, detail="No MIDI uploaded")

    job_id = uuid.uuid4().hex[:8]
    job_dir = os.path.join(OUTPUTS_DIR, job_id)
    os.makedirs(job_dir, exist_ok=True)

    in_mid = os.path.join(job_dir, "input.mid")
    with open(in_mid, "wb") as f:
        shutil.copyfileobj(midi.file, f)

    # Optionally trim for a fast preview
    if preview:
        trimmed = os.path.join(job_dir, "input_trimmed.mid")
        try:
            trim_midi(in_mid, trimmed, start_sec=0.0, duration_sec=30.0)
            in_mid = trimmed
        except Exception as e:
            print(f"[preview] trim failed, continuing full render: {e}")

    wav_path = os.path.join(job_dir, "render_sfizz.wav")
    _write_progress(job_dir, "queued", 0.0)

    t = threading.Thread(target=_sfizz_job_runner, args=(job_id, job_dir, in_mid, wav_path, sr or 44100, sfz_name), daemon=True)
    t.start()

    return JSONResponse(content={"status": "queued", "job_id": job_id})


@app.post("/transcribe_pti")
async def transcribe_pti(request: Request, file: UploadFile = File(...), use_demucs: bool = Form(False), profile: Optional[str] = Form(None)):
    if file is None:
        raise HTTPException(status_code=400, detail="No file uploaded")

    job_id = uuid.uuid4().hex[:8]
    job_dir = os.path.join(OUTPUTS_DIR, job_id)
    os.makedirs(job_dir, exist_ok=True)

    original_ext = os.path.splitext(file.filename or "input")[1].lower()
    original_name = f"input{original_ext if original_ext else '.bin'}"
    original_path = os.path.join(job_dir, original_name)
    with open(original_path, "wb") as f:
        shutil.copyfileobj(file.file, f)

    try:
        if original_ext not in [".wav", ".wave"]:
            wav_path = _convert_to_wav(original_path)
        else:
            wav_path = original_path
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Failed to decode audio: {e}")

    midi_path = os.path.join(job_dir, "output.mid")
    try:
        stats = transcribe_to_midi_pti(wav_path, midi_path, use_demucs=use_demucs)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"PTI transcription failed: {e}")

    base_url = str(request.base_url).rstrip("/")
    midi_url = f"{base_url}/outputs/{os.path.basename(job_dir)}/output.mid"

    return JSONResponse(
        content={
            "status": "done",
            "midi_url": midi_url,
            "duration_sec": stats.get("duration_sec"),
            "notes": int(stats.get("notes", 0)),
            "job_id": job_id,
        }
    )


@app.get("/job/{job_id}")
async def job_status(request: Request, job_id: str):
    job_dir = os.path.join(OUTPUTS_DIR, job_id)
    meta_path = os.path.join(job_dir, "progress.json")
    if not os.path.isdir(job_dir):
        raise HTTPException(status_code=404, detail="job_id not found")
    status = "processing"
    progress = 0.0
    error = None
    if os.path.isfile(meta_path):
        try:
            with open(meta_path, "r") as f:
                d = json.load(f)
                status = d.get("status", status)
                progress = float(d.get("progress", progress))
                error = d.get("error")
        except Exception:
            pass
    response = {"status": status, "progress": progress}
    base_url = str(request.base_url).rstrip("/")
    # Render job artifact
    wav_path = os.path.join(job_dir, "render_sfizz.wav")
    if status == "done" and os.path.isfile(wav_path):
        response["wav_url"] = f"{base_url}/outputs/{job_id}/render_sfizz.wav"
    # Separation artifacts
    inst_path = os.path.join(job_dir, "instrumental.wav")
    voc_path = os.path.join(job_dir, "vocals.wav")
    if os.path.isfile(inst_path):
        response["instrumental_url"] = f"{base_url}/outputs/{job_id}/instrumental.wav"
    if os.path.isfile(voc_path):
        response["vocals_url"] = f"{base_url}/outputs/{job_id}/vocals.wav"
    meta_mode = os.path.join(job_dir, "sep_meta.json")
    try:
        if os.path.isfile(meta_mode):
            with open(meta_mode, "r") as f:
                d = json.load(f)
                if d.get("backend"):
                    response["backend"] = d.get("backend")
                if d.get("fallback_from"):
                    response["fallback_from"] = d.get("fallback_from")
    except Exception:
        pass
    if status == "error" and error:
        response["error"] = error
    return JSONResponse(content=response)


def _transcribe_job_runner(job_id: str, job_dir: str, input_path: str, use_demucs: bool):
    midi_path = os.path.join(job_dir, "output.mid")
    try:
        # Convert to WAV inside the background job to avoid long request times
        original_ext = os.path.splitext(input_path)[1].lower()
        try:
            wav_path = _convert_to_wav(input_path) if original_ext not in [".wav", ".wave"] else input_path
        except Exception as e:
            raise RuntimeError(f"Failed to decode audio: {e}")

        try:
            # Load profile hint if present
            profile = None
            meta_path = os.path.join(job_dir, "profile.json")
            try:
                with open(meta_path, "r") as f:
                    d = json.load(f)
                    profile = d.get("profile")
            except Exception:
                pass
            transcribe_to_midi(wav_path, midi_path, use_demucs=use_demucs, profile=profile)
        except Exception:
            transcribe_to_midi_pti(wav_path, midi_path, use_demucs=use_demucs)
    except Exception as e:
        try:
            with open(os.path.join(job_dir, "error.txt"), "w") as f:
                f.write(str(e))
        except Exception:
            pass


@app.post("/transcribe_start")
async def transcribe_start(file: UploadFile = File(...), use_demucs: bool = Form(False), profile: Optional[str] = Form(None)):
    if file is None:
        raise HTTPException(status_code=400, detail="No file uploaded")
    job_id = uuid.uuid4().hex[:8]
    job_dir = os.path.join(OUTPUTS_DIR, job_id)
    os.makedirs(job_dir, exist_ok=True)

    original_ext = os.path.splitext(file.filename or "input")[1].lower()
    original_name = f"input{original_ext if original_ext else '.bin'}"
    original_path = os.path.join(job_dir, original_name)
    with open(original_path, "wb") as f:
        shutil.copyfileobj(file.file, f)

    # Stash profile hint for the worker via a sidecar json
    try:
        with open(os.path.join(job_dir, "profile.json"), "w") as f:
            json.dump({"profile": profile}, f)
    except Exception:
        pass
    t = threading.Thread(target=_transcribe_job_runner, args=(job_id, job_dir, original_path, bool(use_demucs)), daemon=True)
    t.start()
    return JSONResponse(content={"status": "queued", "job_id": job_id})


# --- Async separation job ---
def _separate_job_runner(job_id: str, job_dir: str, wav_path: str, mode: Optional[str], enhance: bool):
    backend = None
    fallback_from = None
    try:
        # Use same strategy as /separate endpoint
        m = (mode or "").lower() if mode else None
        if m == "fast":
            inst, voc = separate_audio_fast(wav_path)
            backend = "fast_local"
        elif m == "medium":
            inst, voc = separate_audio_medium(wav_path)
            backend = "demucs_medium"
        elif m == "great":
            inst, voc = separate_audio_great(wav_path, enhance=bool(enhance))
            backend = "demucs_great" + ("+enh" if enhance else "")
        elif m == "umx":
            inst, voc = separate_audio_umx(wav_path)
            backend = "umx"
        elif m == "local_ml":
            inst, voc = separate_audio_local_ml(wav_path)
            backend = "local_ml"
        else:
            try:
                inst, voc = separate_audio(wav_path)
                backend = "demucs_hq"
            except Exception:
                fallback_from = "demucs_hq"
                try:
                    inst, voc = separate_audio_medium(wav_path)
                    backend = "demucs_medium"
                except Exception:
                    try:
                        inst, voc = separate_audio_local_ml(wav_path)
                        backend = "local_ml"
                    except Exception:
                        inst, voc = separate_audio_fast(wav_path)
                        backend = "fast_local"

        # Persist outputs in job dir
        def _copy(src: Optional[str], name: str) -> Optional[str]:
            if not src:
                return None
            dst = os.path.join(job_dir, name)
            try:
                shutil.copy(src, dst)
                return dst
            except Exception:
                return None
        inst_path = _copy(inst, "instrumental.wav")
        voc_path = _copy(voc, "vocals.wav")
        # Signal done
        _write_progress(job_dir, "done", 1.0)
        try:
            with open(os.path.join(job_dir, "sep_meta.json"), "w") as f:
                json.dump({"backend": backend, "fallback_from": fallback_from}, f)
        except Exception:
            pass
    except Exception as e:
        _write_progress(job_dir, "error", 1.0, str(e))


@app.post("/separate_start")
async def separate_start(file: UploadFile = File(...), mode: Optional[str] = Form(None), enhance: Optional[bool] = Form(False)):
    if file is None:
        raise HTTPException(status_code=400, detail="No file uploaded")
    job_id = uuid.uuid4().hex[:8]
    job_dir = os.path.join(OUTPUTS_DIR, job_id)
    os.makedirs(job_dir, exist_ok=True)

    # Save upload
    original_ext = os.path.splitext(file.filename or "input")[1].lower()
    original_path = os.path.join(job_dir, f"input{original_ext if original_ext else '.bin'}")
    with open(original_path, "wb") as f:
        shutil.copyfileobj(file.file, f)

    # Convert to wav
    try:
        wav_path = _convert_to_wav(original_path) if original_ext not in [".wav", ".wave"] else original_path
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Failed to decode audio: {e}")

    _write_progress(job_dir, "queued", 0.0)
    t = threading.Thread(target=_separate_job_runner, args=(job_id, job_dir, wav_path, mode, bool(enhance))),
    # The comma created a tuple; fix by retrieving the thread object
    t = t[0]
    t.daemon = True
    t.start()
    return JSONResponse(content={"status": "queued", "job_id": job_id})

@app.post("/perform")
async def perform(request: Request, midi: UploadFile = File(...)):
    if midi is None:
        raise HTTPException(status_code=400, detail="No MIDI uploaded")

    job_id = uuid.uuid4().hex[:8]
    job_dir = os.path.join(OUTPUTS_DIR, job_id)
    os.makedirs(job_dir, exist_ok=True)

    in_mid = os.path.join(job_dir, "input.mid")
    with open(in_mid, "wb") as f:
        shutil.copyfileobj(midi.file, f)

    out_mid = os.path.join(job_dir, "performed.mid")
    try:
        perform_midi(in_mid, out_mid)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Performance enhancement failed: {e}")

    base_url = str(request.base_url).rstrip("/")
    midi_url = f"{base_url}/outputs/{job_id}/performed.mid"
    return JSONResponse(content={"status": "done", "midi_url": midi_url, "job_id": job_id})

@app.post("/perform_ml")
async def perform_ml(request: Request, midi: UploadFile = File(...), performer_url: Optional[str] = Form(None)):
    if midi is None:
        raise HTTPException(status_code=400, detail="No MIDI uploaded")

    job_id = uuid.uuid4().hex[:8]
    job_dir = os.path.join(OUTPUTS_DIR, job_id)
    os.makedirs(job_dir, exist_ok=True)

    in_mid = os.path.join(job_dir, "input.mid")
    with open(in_mid, "wb") as f:
        shutil.copyfileobj(midi.file, f)

    out_mid = os.path.join(job_dir, "performed_ml.mid")
    try:
        perform_midi_ml(in_mid, out_mid, performer_url or "http://127.0.0.1:8502/perform")
    except Exception as e:
        # Graceful fallback to algorithmic performer if ML is unavailable
        try:
            perform_midi(in_mid, out_mid)
        except Exception:
            raise HTTPException(status_code=500, detail=f"ML performance failed: {e}")

    base_url = str(request.base_url).rstrip("/")
    midi_url = f"{base_url}/outputs/{job_id}/performed_ml.mid"
    return JSONResponse(content={"status": "done", "midi_url": midi_url, "job_id": job_id})


@app.post("/ddsp_melody_to_piano")
async def ddsp_melody_to_piano(request: Request, file: UploadFile = File(...), render: Optional[bool] = Form(True)):
    if file is None:
        raise HTTPException(status_code=400, detail="No file uploaded")
    job_id = uuid.uuid4().hex[:8]
    job_dir = os.path.join(OUTPUTS_DIR, job_id)
    os.makedirs(job_dir, exist_ok=True)
    original_ext = os.path.splitext(file.filename or "input")[1].lower()
    original_name = f"input{original_ext if original_ext else '.bin'}"
    original_path = os.path.join(job_dir, original_name)
    with open(original_path, "wb") as f:
        shutil.copyfileobj(file.file, f)

    try:
        wav_path = _convert_to_wav(original_path) if original_ext not in [".wav", ".wave"] else original_path
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Failed to decode audio: {e}")

    midi_path = os.path.join(job_dir, "melody.mid")
    try:
        stats = melody_to_midi(wav_path, midi_path)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Melody extraction failed: {e}")

    base_url = str(request.base_url).rstrip("/")
    midi_url = f"{base_url}/outputs/{job_id}/melody.mid"
    if render:
        wav_out = os.path.join(job_dir, "melody.wav")
        try:
            render_midi_to_wav(midi_path, wav_out, preferred_bank=None, quality="basic")
        except Exception as e:
            # still return midi if render fails
            return JSONResponse(content={"status": "done", "midi_url": midi_url, "notes": int(stats.get("notes", 0)), "duration_sec": stats.get("duration_sec")})
        wav_url = f"{base_url}/outputs/{job_id}/melody.wav"
        return JSONResponse(content={"status": "done", "midi_url": midi_url, "wav_url": wav_url, "notes": int(stats.get("notes", 0)), "duration_sec": stats.get("duration_sec")})
    return JSONResponse(content={"status": "done", "midi_url": midi_url, "notes": int(stats.get("notes", 0)), "duration_sec": stats.get("duration_sec")})



@app.post("/piano_cover_hq")
async def piano_cover_hq(request: Request, file: UploadFile = File(...), use_demucs: Optional[bool] = Form(False), render: Optional[bool] = Form(True)):
    if file is None:
        raise HTTPException(status_code=400, detail="No file uploaded")
    job_id = uuid.uuid4().hex[:8]
    job_dir = os.path.join(OUTPUTS_DIR, job_id)
    os.makedirs(job_dir, exist_ok=True)
    original_ext = os.path.splitext(file.filename or "input")[1].lower()
    original_name = f"input{original_ext if original_ext else '.bin'}"
    original_path = os.path.join(job_dir, original_name)
    with open(original_path, "wb") as f:
        shutil.copyfileobj(file.file, f)

    try:
        wav_path = _convert_to_wav(original_path) if original_ext not in [".wav", ".wave"] else original_path
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Failed to decode audio: {e}")

    midi_path = os.path.join(job_dir, "cover_hq.mid")
    try:
        stats = piano_cover_from_audio_hq(wav_path, midi_path, use_demucs=bool(use_demucs))
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"HQ cover failed: {e}")

    base_url = str(request.base_url).rstrip("/")
    midi_url = f"{base_url}/outputs/{job_id}/cover_hq.mid"
    if render:
        wav_out = os.path.join(job_dir, "cover_hq.wav")
        try:
            render_midi_to_wav(midi_path, wav_out, preferred_bank=None, quality="basic")
            wav_url = f"{base_url}/outputs/{job_id}/cover_hq.wav"
            return JSONResponse(content={"status": "done", "midi_url": midi_url, "wav_url": wav_url, "notes": int(stats.get("notes", 0)), "duration_sec": stats.get("duration_sec")})
        except Exception:
            pass
    return JSONResponse(content={"status": "done", "midi_url": midi_url, "notes": int(stats.get("notes", 0)), "duration_sec": stats.get("duration_sec")})


@app.post("/piano_cover_style")
async def piano_cover_style(request: Request, file: UploadFile = File(...), style: Optional[str] = Form("block"), use_demucs: Optional[bool] = Form(False), render: Optional[bool] = Form(True)):
    if file is None:
        raise HTTPException(status_code=400, detail="No file uploaded")
    job_id = uuid.uuid4().hex[:8]
    job_dir = os.path.join(OUTPUTS_DIR, job_id)
    os.makedirs(job_dir, exist_ok=True)
    original_ext = os.path.splitext(file.filename or "input")[1].lower()
    original_name = f"input{original_ext if original_ext else '.bin'}"
    original_path = os.path.join(job_dir, original_name)
    with open(original_path, "wb") as f:
        shutil.copyfileobj(file.file, f)

    try:
        wav_path = _convert_to_wav(original_path) if original_ext not in [".wav", ".wave"] else original_path
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Failed to decode audio: {e}")

    midi_path = os.path.join(job_dir, "cover_style.mid")
    try:
        s = (style or "block").lower()
        if s not in ("block", "arpeggio", "alberti"):
            s = "block"
        stats = piano_cover_from_audio_style(wav_path, midi_path, style=s, use_demucs=bool(use_demucs))
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Cover(style) failed: {e}")

    base_url = str(request.base_url).rstrip("/")
    midi_url = f"{base_url}/outputs/{job_id}/cover_style.mid"
    if render:
        wav_out = os.path.join(job_dir, "cover_style.wav")
        try:
            render_midi_to_wav(midi_path, wav_out, preferred_bank=None, quality="basic")
            wav_url = f"{base_url}/outputs/{job_id}/cover_style.wav"
            return JSONResponse(content={"status": "done", "midi_url": midi_url, "wav_url": wav_url, "notes": int(stats.get("notes", 0)), "duration_sec": stats.get("duration_sec")})
        except Exception:
            pass
    return JSONResponse(content={"status": "done", "midi_url": midi_url, "notes": int(stats.get("notes", 0)), "duration_sec": stats.get("duration_sec")})
