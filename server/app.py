import os
import uuid
import shutil
import json
import threading
import time
import subprocess
from typing import Optional

from fastapi import FastAPI, UploadFile, File, Form, HTTPException, Request
from fastapi.responses import StreamingResponse
from dotenv import load_dotenv
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware

try:
    from server.inference import OUTPUTS_DIR, transcribe_to_midi, transcribe_to_midi_pure_basic_pitch, transcribe_to_midi_hybrid, _convert_to_wav, render_midi_to_wav, perform_midi, perform_midi_ml, render_midi_to_wav_sfizz, trim_midi, melody_to_midi, piano_cover_from_audio_hq, piano_cover_from_audio_style, perform_audio_cloud
except Exception:
    from inference import OUTPUTS_DIR, transcribe_to_midi, transcribe_to_midi_pure_basic_pitch, transcribe_to_midi_hybrid, _convert_to_wav, render_midi_to_wav, perform_midi, perform_midi_ml, render_midi_to_wav_sfizz, trim_midi, melody_to_midi, piano_cover_from_audio_hq, piano_cover_from_audio_style, perform_audio_cloud
import os as _os
import sys
try:
    import replicate as _rep  # optional; only used if REPLICATE_API_TOKEN is set
except Exception:
    _rep = None

load_dotenv()

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

@app.get("/capabilities")
async def capabilities():
    """Report optional backend capabilities so the client can adapt UI."""
    ffmpeg_available = shutil.which("ffmpeg") is not None

    return JSONResponse(content={
        "status": "ok",
        "ffmpeg_available": bool(ffmpeg_available),
    })

# Ensure outputs directory exists and mount it for static serving
os.makedirs(OUTPUTS_DIR, exist_ok=True)
app.mount("/outputs", StaticFiles(directory=OUTPUTS_DIR), name="outputs")

@app.post("/process_audio")
async def process_audio(
    request: Request,
    file: UploadFile = File(...),
    output_format: Optional[str] = Form("wav")
):
    """
    Simple, reliable audio processing endpoint.
    Converts audio to WAV format and returns the processed file.
    No separation - just clean conversion.
    """
    if file is None:
        raise HTTPException(status_code=400, detail="No file uploaded")

    # Generate unique job ID
    job_id = str(uuid.uuid4())
    job_dir = os.path.join(OUTPUTS_DIR, job_id)
    os.makedirs(job_dir, exist_ok=True)

    try:
        # Save uploaded file
        input_path = os.path.join(job_dir, f"input{os.path.splitext(file.filename)[1]}")
        with open(input_path, "wb") as f:
            shutil.copyfileobj(file.file, f)

        # Convert to WAV using ffmpeg (reliable)
        output_path = os.path.join(job_dir, "processed.wav")
        
        if shutil.which("ffmpeg"):
            cmd = [
                "ffmpeg", "-i", input_path,
                "-acodec", "pcm_s16le",
                "-ar", "44100",
                "-ac", "2",
                "-y",  # Overwrite output
                output_path
            ]
            
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
            
            if result.returncode != 0:
                raise RuntimeError(f"FFmpeg conversion failed: {result.stderr}")
        else:
            # Fallback: just copy the file if ffmpeg not available
            shutil.copy2(input_path, output_path)

        # Verify output exists
        if not os.path.exists(output_path):
            raise RuntimeError("Output file was not created")

        # Return success response
        return {
            "status": "success",
            "job_id": job_id,
            "message": f"Audio processed successfully. Output format: {output_format.upper()}",
            "output_url": f"/outputs/{job_id}/processed.wav",
            "file_size": os.path.getsize(output_path)
        }

    except Exception as e:
        # Clean up on error
        if os.path.exists(job_dir):
            shutil.rmtree(job_dir)
        raise HTTPException(status_code=500, detail=f"Audio processing failed: {str(e)}")

@app.post("/process_audio_job")
async def process_audio_job(
    request: Request,
    file: UploadFile = File(...),
    output_format: Optional[str] = Form("wav")
):
    """
    Asynchronous audio processing with job status tracking.
    More reliable than the old separation system.
    """
    if file is None:
        raise HTTPException(status_code=400, detail="No file uploaded")

    # Generate unique job ID
    job_id = str(uuid.uuid4())
    job_dir = os.path.join(OUTPUTS_DIR, job_id)
    os.makedirs(job_dir, exist_ok=True)

    try:
        # Save uploaded file
        input_path = os.path.join(job_dir, f"input{os.path.splitext(file.filename)[1]}")
        with open(input_path, "wb") as f:
            shutil.copyfileobj(file.file, f)

        # Start processing in background thread
        t = threading.Thread(target=_process_audio_job_runner, args=(job_id, job_dir, input_path))
        t.daemon = True
        t.start()

        return {
            "status": "started",
            "job_id": job_id,
            "message": "Audio processing started"
        }

    except Exception as e:
        # Clean up on error
        if os.path.exists(job_dir):
            shutil.rmtree(job_dir)
        raise HTTPException(status_code=500, detail=f"Failed to start audio processing: {str(e)}")

def _process_audio_job_runner(job_id: str, job_dir: str, input_path: str):
    """
    Reliable audio processing job runner.
    Simple conversion to WAV format with timeout protection.
    """
    try:
        # Update progress to starting
        _write_progress(job_dir, "processing", 0.1)
        
        # Convert to WAV using ffmpeg
        output_path = os.path.join(job_dir, "processed.wav")
        
        if shutil.which("ffmpeg"):
            _write_progress(job_dir, "processing", 0.3)
            
            cmd = [
                "ffmpeg", "-i", input_path,
                "-acodec", "pcm_s16le",
                "-ar", "44100",
                "-ac", "2",
                "-y",
                output_path
            ]
            
            # Add timeout to prevent hanging (2 minutes max)
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
            
            if result.returncode != 0:
                raise RuntimeError(f"FFmpeg conversion failed: {result.stderr}")
        else:
            # Fallback: just copy the file
            shutil.copy2(input_path, output_path)

        _write_progress(job_dir, "processing", 0.8)
        
        # Verify output exists
        if not os.path.exists(output_path):
            raise RuntimeError("Output file was not created")
            
        print(f"Audio processing completed successfully. Output: {output_path}")
        
        # Signal done
        _write_progress(job_dir, "done", 1.0)
        
        # Save metadata
        try:
            with open(os.path.join(job_dir, "meta.json"), "w") as f:
                json.dump({
                    "backend": "ffmpeg" if shutil.which("ffmpeg") else "copy",
                    "message": "Audio processed successfully"
                }, f)
        except Exception:
            pass

    except Exception as e:
        print(f"Audio processing job failed: {e}")
        _write_progress(job_dir, "error", 1.0, str(e))

def _write_progress(job_dir: str, status: str, progress: float, error: str = None):
    """Write progress to JSON file."""
    try:
        progress_data = {
            "status": status,
            "progress": progress,
            "timestamp": time.time()
        }
        if error:
            progress_data["error"] = error
            
        with open(os.path.join(job_dir, "progress.json"), "w") as f:
            json.dump(progress_data, f)
    except Exception as e:
        print(f"Failed to write progress: {e}")

@app.get("/job/{job_id}")
async def job_status(request: Request, job_id: str):
    """Get job status and results."""
    job_dir = os.path.join(OUTPUTS_DIR, job_id)
    
    if not os.path.exists(job_dir):
        raise HTTPException(status_code=404, detail="Job not found")
    
    # Read progress file
    progress_file = os.path.join(job_dir, "progress.json")
    if os.path.exists(progress_file):
        try:
            with open(progress_file, "r") as f:
                progress_data = json.load(f)
        except Exception:
            progress_data = {"status": "unknown", "progress": 0.0}
    else:
        progress_data = {"status": "unknown", "progress": 0.0}
    
    # Build response
    base_url = str(request.base_url).rstrip("/")
    response = {
        "job_id": job_id,
        "status": progress_data.get("status", "unknown"),
        "progress": progress_data.get("progress", 0.0),
        "timestamp": progress_data.get("timestamp", time.time())
    }
    
    if "error" in progress_data:
        response["error"] = progress_data["error"]
    
    # Include meta if present (cloud/local indicator)
    meta_path = os.path.join(job_dir, "meta.json")
    if os.path.isfile(meta_path):
        try:
            with open(meta_path, "r") as f:
                meta = json.load(f)
            # expose a compact indicator
            if isinstance(meta, dict):
                response["source"] = meta.get("separation_source") or meta.get("backend")
                if meta.get("cloud_model"):
                    response["cloud_model"] = meta.get("cloud_model")
        except Exception:
            pass

    # Check for output files (audio processing)
    output_path = os.path.join(job_dir, "processed.wav")
    if os.path.isfile(output_path):
        response["output_url"] = f"{base_url}/outputs/{job_id}/processed.wav"
        response["file_size"] = os.path.getsize(output_path)
        
        # If we have output but status isn't done, mark it as done
        if response["status"] not in ["done", "error"]:
            response["status"] = "done"
            response["progress"] = 1.0
    
    # Check for separation output files
    instrumental_path = os.path.join(job_dir, "instrumental.wav")
    vocals_path = os.path.join(job_dir, "vocals.wav")

    instrumental_exists = os.path.isfile(instrumental_path)
    vocals_exists = os.path.isfile(vocals_path)

    if instrumental_exists:
        response["instrumental_url"] = f"{base_url}/outputs/{job_id}/instrumental.wav"

    if vocals_exists:
        response["vocals_url"] = f"{base_url}/outputs/{job_id}/vocals.wav"

    # Only auto-mark separation as done when BOTH stems are present.
    # This prevents clients from stopping early with vocals-only.
    if (instrumental_exists and vocals_exists) and response["status"] not in ["done", "error"]:
        response["status"] = "done"
        response["progress"] = 1.0
    
    # Transcription output (MIDI)
    midi_path = os.path.join(job_dir, "transcribed.mid")
    if os.path.isfile(midi_path):
        response["midi_url"] = f"{base_url}/outputs/{job_id}/transcribed.mid"
        if response["status"] not in ["done", "error"]:
            response["status"] = "done"
            response["progress"] = 1.0

    return response

@app.post("/transcribe")
async def transcribe(request: Request, file: UploadFile = File(...), use_demucs: bool = Form(False), mode: str = Form("pure")):
    """
    Transcription endpoint with three quality modes:
    
    - mode="pure" (default): Pure Basic Pitch (exactly like the website)
    - mode="hybrid": Basic Pitch + AI enhancement (louder/sharp + chord cleanup)
    - mode="enhanced": Full AI-enhanced Basic Pitch with post-processing, quantization, humanization
    """
    if file is None:
        raise HTTPException(status_code=400, detail="No file uploaded")

    job_id = uuid.uuid4().hex[:8]
    job_dir = os.path.join(OUTPUTS_DIR, job_id)
    os.makedirs(job_dir, exist_ok=True)

    # Save upload
    original_ext = os.path.splitext(file.filename or "input")[1].lower()
    original_name = f"input{original_ext if original_ext else '.bin'}"
    original_path = os.path.join(job_dir, original_name)
    with open(original_path, "wb") as f:
        shutil.copyfileobj(file.file, f)

    # Convert to wav if needed
    try:
        wav_path = _convert_to_wav(original_path) if original_ext not in [".wav", ".wave"] else original_path
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Failed to decode audio: {e}")

    # Run transcription based on mode (functions write directly to output path)
    job_midi = os.path.join(job_dir, "transcribed.mid")
    try:
        if mode == "pure":
            _ = transcribe_to_midi_pure_basic_pitch(wav_path, job_midi)
        elif mode == "hybrid":
            _ = transcribe_to_midi_hybrid(wav_path, job_midi)
        elif mode == "enhanced":
            # Cloud-expensive enhanced path (uses Replicate if configured)
            from inference import transcribe_to_midi_enhanced
            _ = transcribe_to_midi_enhanced(wav_path, job_midi, use_cloud=True)
            # After MIDI is created, render neutral WAV and send to cloud performer (no fallback)
            neutral_wav = os.path.join(job_dir, "neutral.wav")
            try:
                render_midi_to_wav(job_midi, neutral_wav, preferred_bank=None, quality="studio", mastering=False)
            except Exception as e:
                raise HTTPException(status_code=500, detail=f"Neutral render failed: {e}")

            # Choose default reference tracks from project root to bias presence/brightness
            default_refs = [
                os.path.abspath(os.path.join(os.path.dirname(__file__), os.pardir, "05 - Holiday - Madonna.mp3")),
                os.path.abspath(os.path.join(os.path.dirname(__file__), os.pardir, "02 - Hero - Mariah Carey.mp3")),
            ]
            ref_paths: list[str] = []
            for rp in default_refs:
                try:
                    if os.path.isfile(rp):
                        # Convert to wav best-effort
                        cw = _convert_to_wav(rp)
                        ref_paths.append(cw)
                except Exception:
                    pass

            # Require performer model to be set to avoid accidental fallback
            model_slug = os.environ.get("REPLICATE_PERFORM_MODEL")
            if not model_slug:
                raise HTTPException(status_code=503, detail="Set REPLICATE_PERFORM_MODEL to a valid Replicate mastering/performance model slug. Cloud-only, no fallback.")
            performed_wav = os.path.join(job_dir, "performed.wav")
            try:
                perform_audio_cloud(neutral_wav, performed_wav, reference_wav_paths=ref_paths, model_slug=model_slug)
            except Exception as e:
                raise HTTPException(status_code=500, detail=f"Cloud performance failed: {e}")
        else:
            raise HTTPException(status_code=400, detail=f"Unknown mode: {mode}")
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Transcription failed: {e}")

    # Return results
    base_url = str(request.base_url).rstrip("/")
    midi_url = f"{base_url}/outputs/{job_id}/transcribed.mid"
    resp = {
        "status": "done",
        "job_id": job_id,
        "midi_url": midi_url,
        "mode": mode
    }
    # If enhanced, include performed WAV URL if present
    perf_path = os.path.join(job_dir, "performed.wav")
    if os.path.isfile(perf_path):
        resp["performed_wav_url"] = f"{base_url}/outputs/{job_id}/performed.wav"
    return JSONResponse(content=resp)

@app.post("/transcribe_start")
async def transcribe_start(request: Request, file: UploadFile = File(...), mode: str = Form("pure")):
    """Start async transcription and return a job id; poll /job/{id} for midi_url."""
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

    t = threading.Thread(target=_transcribe_job_runner_mode, args=(job_id, job_dir, original_path, mode), daemon=True)
    t.start()
    return JSONResponse(content={"status": "queued", "job_id": job_id})

@app.post("/transcribe_job")
async def transcribe_job(request: Request, file: UploadFile = File(...), use_demucs: bool = Form(False), mode: str = Form("pure")):
    """
    Asynchronous transcription endpoint.
    """
    if file is None:
        raise HTTPException(status_code=400, detail="No file uploaded")

    job_id = uuid.uuid4().hex[:8]
    job_dir = os.path.join(OUTPUTS_DIR, job_id)
    os.makedirs(job_dir, exist_ok=True)

    # Save upload
    original_ext = os.path.splitext(file.filename or "input")[1].lower()
    original_name = f"input{original_ext if original_ext else '.bin'}"
    original_path = os.path.join(job_dir, original_name)
    with open(original_path, "wb") as f:
        shutil.copyfileobj(file.file, f)

    # Start transcription in background thread
    t = threading.Thread(target=_transcribe_job_runner, args=(job_id, job_dir, original_path, bool(use_demucs)), daemon=True)
    t.start()
    return JSONResponse(content={"status": "queued", "job_id": job_id})

def _transcribe_job_runner(job_id: str, job_dir: str, original_path: str, use_demucs: bool):
    """Transcription job runner."""
    try:
        _write_progress(job_dir, "processing", 0.1)
        
        # Convert to wav if needed
        original_ext = os.path.splitext(original_path)[1].lower()
        wav_path = _convert_to_wav(original_path) if original_ext not in [".wav", ".wave"] else original_path
        
        _write_progress(job_dir, "processing", 0.3)
        
        # Run transcription (enhanced/balanced profile)
        job_midi = os.path.join(job_dir, "transcribed.mid")
        _ = transcribe_to_midi(wav_path, job_midi)
        
        _write_progress(job_dir, "processing", 0.8)
        
        _write_progress(job_dir, "done", 1.0)
        
    except Exception as e:
        print(f"Transcription job failed: {e}")
        _write_progress(job_dir, "error", 1.0, str(e))

def _transcribe_job_runner_mode(job_id: str, job_dir: str, original_path: str, mode: str):
    """Transcription runner that honors the 'mode' string like the sync endpoint."""
    try:
        _write_progress(job_dir, "processing", 0.1)
        # Convert
        original_ext = os.path.splitext(original_path)[1].lower()
        wav_path = _convert_to_wav(original_path) if original_ext not in [".wav", ".wave"] else original_path
        _write_progress(job_dir, "processing", 0.3)

        job_midi = os.path.join(job_dir, "transcribed.mid")
        if mode == "pure":
            _ = transcribe_to_midi_pure_basic_pitch(wav_path, job_midi)
        elif mode == "hybrid":
            _ = transcribe_to_midi_hybrid(wav_path, job_midi)
        elif mode == "enhanced":
            _ = transcribe_to_midi(wav_path, job_midi)
        else:
            _ = transcribe_to_midi_pure_basic_pitch(wav_path, job_midi)

        _write_progress(job_dir, "processing", 0.8)
        _write_progress(job_dir, "done", 1.0)
    except Exception as e:
        print(f"Transcription job (mode) failed: {e}")
        _write_progress(job_dir, "error", 1.0, str(e))

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

    out_mid = os.path.join(job_dir, "performed.mid")
    try:
        perform_midi_ml(in_mid, out_mid, performer_url)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"ML performance enhancement failed: {e}")

    base_url = str(request.base_url).rstrip("/")
    midi_url = f"{base_url}/outputs/{job_id}/performed.mid"
    return JSONResponse(content={"status": "done", "midi_url": midi_url, "job_id": job_id})

@app.post("/render")
async def render(request: Request, midi: UploadFile = File(...), soundfont: Optional[str] = Form("default")):
    if midi is None:
        raise HTTPException(status_code=400, detail="No MIDI uploaded")

    job_id = uuid.uuid4().hex[:8]
    job_dir = os.path.join(OUTPUTS_DIR, job_id)
    os.makedirs(job_dir, exist_ok=True)

    in_mid = os.path.join(job_dir, "input.mid")
    with open(in_mid, "wb") as f:
        shutil.copyfileobj(midi.file, f)

    out_wav = os.path.join(job_dir, "rendered.wav")
    try:
        if soundfont == "sfizz":
            render_midi_to_wav_sfizz(in_mid, out_wav)
        else:
            render_midi_to_wav(in_mid, out_wav)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"MIDI rendering failed: {e}")

    base_url = str(request.base_url).rstrip("/")
    wav_url = f"{base_url}/outputs/{job_id}/rendered.wav"
    return JSONResponse(content={"status": "done", "wav_url": wav_url, "job_id": job_id})


@app.post("/perform_cloud")
async def perform_cloud(
    request: Request,
    midi: UploadFile = File(...),
    model_slug: Optional[str] = Form(None),
    reference1: UploadFile | None = File(None),
    reference2: UploadFile | None = File(None),
    reference3: UploadFile | None = File(None),
):
    """
    Cloud-only performance/mastering:
    1) Render MIDI to neutral WAV locally
    2) Send WAV (and optional reference WAVs) to Replicate model for mastering/performance
    3) Return mastered WAV URL
    """
    if midi is None:
        raise HTTPException(status_code=400, detail="No MIDI uploaded")

    job_id = uuid.uuid4().hex[:8]
    job_dir = os.path.join(OUTPUTS_DIR, job_id)
    os.makedirs(job_dir, exist_ok=True)

    # Save MIDI
    in_mid = os.path.join(job_dir, "input.mid")
    with open(in_mid, "wb") as f:
        shutil.copyfileobj(midi.file, f)

    # 1) Render to neutral WAV
    neutral_wav = os.path.join(job_dir, "neutral.wav")
    try:
        render_midi_to_wav(in_mid, neutral_wav, preferred_bank=None, quality="studio", mastering=False)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Neutral render failed: {e}")

    # Collect optional references
    refs: list[str] = []
    for idx, ref in enumerate([reference1, reference2, reference3], start=1):
        if ref is not None:
            rp = os.path.join(job_dir, f"reference{idx}.wav")
            try:
                # Accept any audio; ensure WAV
                tmp = os.path.join(job_dir, f"ref{idx}_raw")
                with open(tmp, "wb") as rf:
                    shutil.copyfileobj(ref.file, rf)
                # Convert to wav
                rp = _convert_to_wav(tmp)
                refs.append(rp)
            except Exception:
                # Ignore bad refs silently
                pass

    # 2) Cloud performance via Replicate (no fallback)
    mastered_wav = os.path.join(job_dir, "performed.wav")
    try:
        perform_audio_cloud(neutral_wav, mastered_wav, reference_wav_paths=refs, model_slug=model_slug)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Cloud performance failed: {e}")

    # 3) Serve result
    base_url = str(request.base_url).rstrip("/")
    wav_url = f"{base_url}/outputs/{job_id}/performed.wav"
    return JSONResponse(content={
        "status": "done",
        "job_id": job_id,
        "performed_wav_url": wav_url,
        "model": model_slug or os.environ.get("REPLICATE_PERFORM_MODEL") or "riffusion/audio-mastering",
    })

@app.post("/trim")
async def trim(request: Request, midi: UploadFile = File(...), start_time: float = Form(0.0), end_time: Optional[float] = Form(None)):
    if midi is None:
        raise HTTPException(status_code=400, detail="No MIDI uploaded")

    job_id = uuid.uuid4().hex[:8]
    job_dir = os.path.join(OUTPUTS_DIR, job_id)
    os.makedirs(job_dir, exist_ok=True)

    in_mid = os.path.join(job_dir, "input.mid")
    with open(in_mid, "wb") as f:
        shutil.copyfileobj(midi.file, f)

    out_mid = os.path.join(job_dir, "trimmed.mid")
    try:
        trim_midi(in_mid, out_mid, start_time, end_time)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"MIDI trimming failed: {e}")

    base_url = str(request.base_url).rstrip("/")
    midi_url = f"{base_url}/outputs/{job_id}/trimmed.mid"
    return JSONResponse(content={"status": "done", "midi_url": midi_url, "job_id": job_id})

@app.post("/melody_to_midi")
async def melody_to_midi_endpoint(request: Request, file: UploadFile = File(...)):
    if file is None:
        raise HTTPException(status_code=400, detail="No file uploaded")

    job_id = uuid.uuid4().hex[:8]
    job_dir = os.path.join(OUTPUTS_DIR, job_id)
    os.makedirs(job_dir, exist_ok=True)

    input_path = os.path.join(job_dir, f"input{os.path.splitext(file.filename)[1]}")
    with open(input_path, "wb") as f:
        shutil.copyfileobj(file.file, f)

    out_mid = os.path.join(job_dir, "melody.mid")
    try:
        melody_to_midi(input_path, out_mid)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Melody extraction failed: {e}")

    base_url = str(request.base_url).rstrip("/")
    midi_url = f"{base_url}/outputs/{job_id}/melody.mid"
    return JSONResponse(content={"status": "done", "midi_url": midi_url, "job_id": job_id})

@app.post("/separate_audio")
async def separate_audio(request: Request, file: UploadFile = File(...), mode: str = Form("mdx23"), cloud: Optional[bool] = Form(False), cloud_model: Optional[str] = Form(None)):
    """
    Start audio separation job. Returns job ID immediately.
    Use /job/{job_id} to check status and get results.
    
    - mode="mdx23" (default): Good quality, faster Demucs model
    - mode="htdemucs"/"great": Highest quality (longer)
    - mode="spleeter": Alternative 2/4 stems
    - mode="fast": CPU-only quick preview
    """
    if file is None:
        raise HTTPException(status_code=400, detail="No file uploaded")

    job_id = uuid.uuid4().hex[:8]
    job_dir = os.path.join(OUTPUTS_DIR, job_id)
    os.makedirs(job_dir, exist_ok=True)

    # Save uploaded file
    input_path = os.path.join(job_dir, f"input{os.path.splitext(file.filename)[1]}")
    with open(input_path, "wb") as f:
        shutil.copyfileobj(file.file, f)

    # Initialize job meta so /job shows intent immediately
    try:
        with open(os.path.join(job_dir, "meta.json"), "w") as f:
            json.dump({
                "backend": "cloud_only",
                "separation_source": "cloud_forced",
                "cloud_model": cloud_model or os.environ.get("REPLICATE_MODEL"),
                "mode": mode
            }, f)
    except Exception:
        pass

    # Start separation in background thread
    # FORCE CLOUD ONLY - no local fallback ever
    if _rep is not None and os.environ.get("REPLICATE_API_TOKEN"):
        t = threading.Thread(target=_separate_audio_job_runner_cloud, args=(job_id, job_dir, input_path, mode, cloud_model))
        print(f"🔒 FORCED CLOUD: Starting cloud separation job {job_id}")
    else:
        # Only if cloud is completely unavailable
        raise HTTPException(status_code=503, detail="Cloud processing required but not available. Please configure Replicate API token.")
    t.daemon = True
    t.start()

    return JSONResponse(content={
        "status": "started",
        "job_id": job_id,
        "message": f"Audio separation started with mode: {mode}",
        "cloud": bool(cloud),
        "cloud_model": cloud_model or os.environ.get("REPLICATE_MODEL")
    })

def _separate_audio_job_runner(job_id: str, job_dir: str, input_path: str, mode: str):
    """Background audio separation job runner."""
    try:
        # Update progress to starting
        _write_progress(job_dir, "processing", 0.1)
        
        # Convert to WAV if needed
        wav_path = _convert_to_wav(input_path) if not input_path.endswith('.wav') else input_path
        
        _write_progress(job_dir, "processing", 0.25)
        
        print(f"Starting separation job {job_id} with mode {mode}")

        # Call robust separation with fallbacks
        inst_path: str | None = None
        voc_path: str | None = None

        try:
            if mode in ("htdemucs", "hq", "great"):
                # Highest quality available in repo
                try:
                    from inference import separate_audio_great
                    inst_path, voc_path = separate_audio_great(wav_path, enhance=True)
                except Exception:
                    from inference import separate_audio
                    inst_path, voc_path = separate_audio(wav_path)
            elif mode == "mdx23":
                from inference import separate_audio_mdx23
                inst_path, voc_path = separate_audio_mdx23(wav_path)
            elif mode == "medium":
                from inference import separate_audio_medium
                inst_path, voc_path = separate_audio_medium(wav_path)
            elif mode == "fast":
                from inference import separate_audio_fast
                inst_path, voc_path = separate_audio_fast(wav_path)
            elif mode == "spleeter":
                from inference import separate_audio_spleeter_hq
                inst_path, voc_path = separate_audio_spleeter_hq(wav_path)
            else:
                from inference import separate_audio
                inst_path, voc_path = separate_audio(wav_path)
        except Exception as e:
            print(f"Primary separation ({mode}) failed: {e}")
            # Fallback chain: Demucs medium -> Spleeter HQ -> Fast CPU mid/side/HPSS
            try:
                from inference import separate_audio_medium
                inst_path, voc_path = separate_audio_medium(wav_path)
            except Exception as e2:
                print(f"Fallback Demucs medium failed: {e2}")
                try:
                    from inference import separate_audio_spleeter_hq
                    inst_path, voc_path = separate_audio_spleeter_hq(wav_path)
                except Exception as e3:
                    print(f"Fallback Spleeter HQ failed: {e3}")
                    from inference import separate_audio_fast
                    inst_path, voc_path = separate_audio_fast(wav_path)

        _write_progress(job_dir, "processing", 0.7)
        
        # Persist outputs into the job directory and normalize loudness
        instrumental_filename = "instrumental.wav"
        vocals_filename = "vocals.wav"

        # Ensure paths exist, otherwise copy input as last resort
        src_inst = inst_path if inst_path and os.path.exists(inst_path) else wav_path
        job_instrumental = os.path.join(job_dir, instrumental_filename)
        shutil.copy2(src_inst, job_instrumental)

        if voc_path and os.path.exists(voc_path):
            job_vocals = os.path.join(job_dir, vocals_filename)
            shutil.copy2(voc_path, job_vocals)
        else:
            # Create a basic vocal estimate using the fast method if none provided
            try:
                from inference import separate_audio_fast
                _, fast_voc = separate_audio_fast(wav_path)
                if fast_voc and os.path.exists(fast_voc):
                    job_vocals = os.path.join(job_dir, vocals_filename)
                    shutil.copy2(fast_voc, job_vocals)
            except Exception:
                pass

        # Loudness normalization via ffmpeg if available (target around -14 LUFS)
        try:
            if shutil.which("ffmpeg"):
                def _norm(inp: str):
                    tmp = inp + ".tmp.wav"
                    cmd = [
                        "ffmpeg", "-y", "-i", inp,
                        "-af", "loudnorm=I=-14:TP=-1.5:LRA=11",
                        "-ar", "44100", "-ac", "2",
                        tmp
                    ]
                    subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    os.replace(tmp, inp)
                _norm(job_instrumental)
                vpath = os.path.join(job_dir, vocals_filename)
                if os.path.exists(vpath):
                    _norm(vpath)
        except Exception as e:
            print(f"Normalization skipped/failed: {e}")

        _write_progress(job_dir, "processing", 0.95)
        
        # Update progress to done
        _write_progress(job_dir, "done", 1.0)
        # Write meta indicating local source
        try:
            with open(os.path.join(job_dir, "meta.json"), "w") as f:
                json.dump({
                    "backend": "local",
                    "separation_source": "local",
                    "mode": mode
                }, f)
        except Exception:
            pass
        print(f"Audio separation completed successfully. Job: {job_id}")
        
    except Exception as e:
        print(f"Audio separation job failed: {e}")
        _write_progress(job_dir, "error", 1.0, str(e))

def _separate_audio_job_runner_cloud(job_id: str, job_dir: str, input_path: str, mode: str, cloud_model: Optional[str] = None):
    """Cloud separation with Replicate (GPU). NO LOCAL FALLBACK - cloud only."""
    try:
        _write_progress(job_dir, "processing", 0.05)
        wav_path = _convert_to_wav(input_path) if not input_path.endswith('.wav') else input_path
        _write_progress(job_dir, "processing", 0.15)

        if _rep is None or not os.environ.get("REPLICATE_API_TOKEN"):
            raise RuntimeError("Replicate not configured")

        print(f"Starting cloud separation job {job_id} with mode {mode}")

        # Choose a known-good model slug; allow override via request/env
        # Default: UVR deployment (fast & robust on GPU). You can change this slug later.
        model_slug = (cloud_model or os.environ.get("REPLICATE_MODEL") or "ryan5453/demucs")
        
        # Create Replicate client first
        client = _rep.Client(api_token=os.environ.get("REPLICATE_API_TOKEN"))
        
        # Get the model and its latest version ID
        print(f"🔍 Getting model info for: {model_slug}")
        try:
            model = client.models.get(model_slug)
            version_id = model.latest_version.id
            print(f"✅ Model version ID: {version_id}")
        except Exception as e:
            raise RuntimeError(f"Failed to get model info: {e}")
        
        # Upload audio file to Replicate first
        print(f"Uploading audio file to Replicate...")
        try:
            upload_response = client.files.create(wav_path)
            audio_url = upload_response.urls['get']
            print(f"✅ Audio uploaded: {audio_url}")
        except Exception as e:
            raise RuntimeError(f"Failed to upload audio file: {e}")

        # Different UVR wrappers on Replicate accept slightly different keys; try a couple of common schemas
        candidate_inputs = [
            # Demucs inputs - audio as URL, model for separation type
            {"audio": audio_url, "model": "htdemucs", "output_format": "wav"},
            {"audio": audio_url, "model": "mdx23", "output_format": "wav"},
            {"audio": audio_url, "output_format": "wav"},
        ]

        # Upload and run
        print(f"🔍 Using model: {model_slug}")
        print(f"🔍 Input format: {candidate_inputs[0]}")
        
        prediction = None
        last_err: Optional[Exception] = None
        for i, inp in enumerate(candidate_inputs):
            try:
                print(f"🔍 Trying input {i+1}: {inp}")
                prediction = client.predictions.create(version=version_id, input=inp)
                print(f"✅ Prediction created successfully with input {i+1}")
                last_err = None
                break
            except Exception as e:
                print(f"❌ Input {i+1} failed: {e}")
                last_err = e
                continue
        if prediction is None:
            if last_err:
                raise last_err
            raise RuntimeError("Failed to start cloud prediction")

        # Poll until done (with timeout)
        deadline = time.time() + 600  # 10 minutes max
        while prediction.status not in ("succeeded", "failed", "canceled"):
            if time.time() > deadline:
                raise TimeoutError("Cloud separation timed out")
            time.sleep(2)
            prediction = client.predictions.get(prediction.id)
            # Convert status to progress heuristically
            _write_progress(job_dir, "processing", min(0.8, 0.15 + 0.6 * (time.time() % 30) / 30.0))

        if prediction.status != "succeeded":
            raise RuntimeError(f"Cloud separation failed: {prediction.status}")

        # Expect output to be URLs (zip or separate files). Handle common UVR outputs.
        # Try to download instrumental and vocals.
        outputs = prediction.output
        print(f"🔍 Model outputs: {outputs}")
        
        # Handle Demucs-style output (dict with specific keys)
        inst_path = None
        voc_path = None
        
        if isinstance(outputs, dict):
            print(f"🔍 Processing dict output with keys: {list(outputs.keys())}")
            
            # Download vocals (vocals track)
            if "vocals" in outputs and isinstance(outputs["vocals"], str) and outputs["vocals"].startswith("http"):
                try:
                    vocals_url = outputs["vocals"]
                    print(f"🔍 Downloading vocals from: {vocals_url}")
                    voc_path = os.path.join(job_dir, "vocals.wav")
                    
                    import requests
                    r = requests.get(vocals_url, timeout=120)
                    r.raise_for_status()
                    with open(voc_path, "wb") as f:
                        f.write(r.content)
                    print(f"✅ Vocals downloaded: {voc_path}")
                except Exception as e:
                    print(f"❌ Vocals download failed: {e}")
            
            # Download instrumental (combine bass + drums + other)
            if any(key in outputs for key in ["bass", "drums", "other"]):
                try:
                    # Download all instrumental tracks
                    instrumental_tracks = []
                    for track_type in ["bass", "drums", "other"]:
                        if track_type in outputs and isinstance(outputs[track_type], str) and outputs[track_type].startswith("http"):
                            track_url = outputs[track_type]
                            print(f"🔍 Downloading {track_type} from: {track_url}")
                            
                            track_path = os.path.join(job_dir, f"{track_type}.wav")
                            r = requests.get(track_url, timeout=120)
                            r.raise_for_status()
                            with open(track_path, "wb") as f:
                                f.write(r.content)
                            instrumental_tracks.append(track_path)
                            print(f"✅ {track_type} downloaded: {track_path}")
                    
                    if instrumental_tracks:
                        # Combine instrumental tracks into one file
                        inst_path = os.path.join(job_dir, "instrumental.wav")
                        print(f"🔍 Combining instrumental tracks: {instrumental_tracks}")
                        
                        # Use ffmpeg to mix the tracks
                        if shutil.which("ffmpeg"):
                            cmd = ["ffmpeg", "-y"]
                            for track in instrumental_tracks:
                                cmd.extend(["-i", track])
                            cmd.extend(["-filter_complex", "amix=inputs=" + str(len(instrumental_tracks)) + ":duration=longest", inst_path])
                            
                            result = subprocess.run(cmd, capture_output=True, text=True)
                            if result.returncode == 0:
                                print(f"✅ Instrumental combined: {inst_path}")
                            else:
                                print(f"❌ FFmpeg mixing failed: {result.stderr}")
                                # Fallback: just copy the first track
                                shutil.copy2(instrumental_tracks[0], inst_path)
                        else:
                            # No ffmpeg: just copy the first track
                            shutil.copy2(instrumental_tracks[0], inst_path)
                            print(f"✅ Instrumental copied (no mixing): {inst_path}")
                            
                except Exception as e:
                    print(f"❌ Instrumental download/combination failed: {e}")
        
        # Fallback: handle list output (old format)
        elif isinstance(outputs, list):
            print(f"🔍 Processing list output with {len(outputs)} items")
            urls = [u for u in outputs if isinstance(u, str) and u.startswith("http")]
            
            for u in urls:
                local = os.path.join(job_dir, os.path.basename(u.split("?")[0]))
                try:
                    import requests
                    r = requests.get(u, timeout=120)
                    r.raise_for_status()
                    with open(local, "wb") as f:
                        f.write(r.content)
                    name_lower = os.path.basename(local).lower()
                    if "instrumental" in name_lower or "no_vocals" in name_lower or "karaoke" in name_lower:
                        inst_path = inst_path or local
                    elif "vocals" in name_lower or "voice" in name_lower or "acapella" in name_lower:
                        voc_path = voc_path or local
                except Exception as de:
                    print(f"Download error: {de}")

        # If zip provided, try to extract
        if (inst_path is None or voc_path is None) and any(u.endswith('.zip') for u in urls):
            try:
                import zipfile
                for u in urls:
                    if u.endswith('.zip'):
                        local_zip = os.path.join(job_dir, os.path.basename(u))
                        if not os.path.exists(local_zip):
                            import requests
                            r = requests.get(u, timeout=120)
                            r.raise_for_status()
                            with open(local_zip, 'wb') as f:
                                f.write(r.content)
                        with zipfile.ZipFile(local_zip, 'r') as z:
                            z.extractall(job_dir)
                        # search for extracted wavs
                        for root, _, files in os.walk(job_dir):
                            for fn in files:
                                if fn.lower().endswith('.wav'):
                                    p = os.path.join(root, fn)
                                    lf = fn.lower()
                                    if ("instrumental" in lf) or ("no_vocals" in lf) or ("karaoke" in lf):
                                        inst_path = inst_path or p
                                    if ("vocals" in lf) or ("acapella" in lf) or ("voice" in lf):
                                        voc_path = voc_path or p
            except Exception as e:
                print(f"Zip extraction failed: {e}")

        # If still missing, fail (no local fallback)
        if inst_path is None and voc_path is None:
            raise RuntimeError("Cloud outputs not detected from provider")

        # Normalize and place outputs in job dir
        job_instrumental = os.path.join(job_dir, "instrumental.wav")
        if inst_path and os.path.exists(inst_path) and inst_path != job_instrumental:
            shutil.copy2(inst_path, job_instrumental)
        elif inst_path and os.path.exists(inst_path):
            # File is already in the right place, just rename if needed
            pass
        else:
            # Fallback: copy original file
            shutil.copy2(wav_path, job_instrumental)

        vpath = None
        if voc_path and os.path.exists(voc_path):
            vpath = os.path.join(job_dir, "vocals.wav")
            if voc_path != vpath:
                shutil.copy2(voc_path, vpath)

        # Normalize loudness if ffmpeg exists
        try:
            if shutil.which("ffmpeg"):
                def _norm(inp: str):
                    tmp = inp + ".tmp.wav"
                    cmd = [
                        "ffmpeg", "-y", "-i", inp,
                        "-af", "loudnorm=I=-14:TP=-1.5:LRA=11",
                        "-ar", "44100", "-ac", "2",
                        tmp
                    ]
                    subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    os.replace(tmp, inp)
                _norm(job_instrumental)
                if vpath and os.path.exists(vpath):
                    _norm(vpath)
        except Exception as e:
            print(f"Normalization skipped/failed (cloud outputs): {e}")

        _write_progress(job_dir, "done", 1.0)
        print(f"Cloud audio separation completed successfully. Job: {job_id}")
        # Write meta indicating cloud source
        try:
            with open(os.path.join(job_dir, "meta.json"), "w") as f:
                json.dump({
                    "backend": "replicate",
                    "separation_source": "cloud",
                    "cloud_model": model_slug,
                    "mode": mode
                }, f)
        except Exception:
            pass

    except Exception as e:
        print(f"Cloud separation failed: {e}. NO LOCAL FALLBACK - job fails.")
        _write_progress(job_dir, "error", 1.0, f"Cloud separation failed: {e}. No local fallback available.")

@app.post("/piano_cover")
async def piano_cover(request: Request, file: UploadFile = File(...), style: str = Form("hq")):
    if file is None:
        raise HTTPException(status_code=400, detail="No file uploaded")

    job_id = uuid.uuid4().hex[:8]
    job_dir = os.path.join(OUTPUTS_DIR, job_id)
    os.makedirs(job_dir, exist_ok=True)

    input_path = os.path.join(job_dir, f"input{os.path.splitext(file.filename)[1]}")
    with open(input_path, "wb") as f:
        shutil.copyfileobj(file.file, f)

    out_mid = os.path.join(job_dir, "piano_cover.mid")
    try:
        if style == "hq":
            piano_cover_from_audio_hq(input_path, out_mid)
        else:
            piano_cover_from_audio_style(input_path, out_mid, style)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Piano cover generation failed: {e}")

    base_url = str(request.base_url).rstrip("/")
    midi_url = f"{base_url}/outputs/{job_id}/piano_cover.mid"
    return JSONResponse(content={"status": "done", "midi_url": midi_url, "job_id": job_id})

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8010)
