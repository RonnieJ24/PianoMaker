import asyncio
import os
import uuid
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, File, Form, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles


BASE_DIR = Path(__file__).parent
STATIC_DIR = BASE_DIR / "static"
STATIC_DIR.mkdir(parents=True, exist_ok=True)


def absolute_url(path: str) -> str:
    # The iOS app points to http://127.0.0.1:8000
    return f"http://127.0.0.1:8000{path}"


def write_minimal_midi(path: Path) -> None:
    # Minimal SMF Type-0 MIDI file: header + a short track with tempo and EOT
    # Header: 'MThd' + length 6 + format 0 + ntrks 1 + division 96
    header = b"MThd" + bytes([0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x01, 0x00, 0x60])
    # Track data: set tempo 120bpm, program change, end of track
    track_data = bytes.fromhex("00 FF 51 03 07 A1 20 00 C0 00 00 FF 2F 00")
    track_len = len(track_data)
    track = b"MTrk" + track_len.to_bytes(4, byteorder="big") + track_data
    path.write_bytes(header + track)


def write_silence_wav(path: Path, seconds: float = 1.0, sample_rate: int = 44100) -> None:
    import wave
    import struct

    num_channels = 1
    sampwidth = 2  # 16-bit
    num_frames = int(seconds * sample_rate)
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(num_channels)
        wf.setsampwidth(sampwidth)
        wf.setframerate(sample_rate)
        silence_frame = struct.pack("<h", 0)
        for _ in range(num_frames):
            wf.writeframes(silence_frame)


# In-memory job storage
jobs: dict[str, dict] = {}


app = FastAPI(title="PianoMaker Local Backend", version="0.1.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")


@app.get("/health")
async def health():
    return {"ok": True}


async def complete_job(job_id: str, payload: dict, delay: float = 0.2) -> None:
    await asyncio.sleep(delay)
    job = jobs.get(job_id)
    if not job:
        return
    job.update(payload)
    job["status"] = "done"


# --- Transcription ---
@app.post("/transcribe_start")
async def transcribe_start(
    file: UploadFile = File(...),
    use_demucs: Optional[str] = Form(None),
    profile: Optional[str] = Form(None),
):
    job_id = str(uuid.uuid4())
    midi_name = f"{job_id}.mid"
    midi_path = STATIC_DIR / midi_name
    write_minimal_midi(midi_path)
    jobs[job_id] = {"status": "processing", "kind": "transcribe"}
    # Populate result shortly after
    asyncio.create_task(
        complete_job(
            job_id,
            {
                "midi_url": absolute_url(f"/static/{midi_name}"),
                "duration_sec": 12.3,
                "notes": 42,
                "job_id": job_id,
            },
        )
    )
    return {"status": "processing", "job_id": job_id}


@app.get("/status/{job_id}")
async def transcription_status(job_id: str):
    job = jobs.get(job_id)
    if not job:
        return JSONResponse(status_code=404, content={"detail": "Job not found"})
    if job.get("status") != "done":
        return {"status": "processing", "job_id": job_id}
    return {
        "status": "done",
        "midi_url": job.get("midi_url"),
        "duration_sec": job.get("duration_sec", 60.0),
        "notes": job.get("notes", 60),
        "job_id": job_id,
    }


@app.post("/transcribe")
async def transcribe(
    file: UploadFile = File(...),
    use_demucs: Optional[str] = Form(None),
):
    midi_name = f"direct_{uuid.uuid4().hex}.mid"
    midi_path = STATIC_DIR / midi_name
    write_minimal_midi(midi_path)
    return {
        "status": "done",
        "midi_url": absolute_url(f"/static/{midi_name}"),
        "duration_sec": 15.0,
        "notes": 50,
    }


# --- Rendering ---
@app.post("/render")
async def render(midi: UploadFile = File(...), quality: Optional[str] = Form(None)):
    wav_name = f"render_{uuid.uuid4().hex}.wav"
    wav_path = STATIC_DIR / wav_name
    write_silence_wav(wav_path, seconds=1.0)
    return {"wav_url": absolute_url(f"/static/{wav_name}")}


@app.post("/render_sfizz")
async def render_sfizz(midi: UploadFile = File(...), sr: Optional[str] = Form(None), preview: Optional[str] = Form(None)):
    wav_name = f"sfizz_{uuid.uuid4().hex}.wav"
    wav_path = STATIC_DIR / wav_name
    write_silence_wav(wav_path, seconds=1.0)
    return {"wav_url": absolute_url(f"/static/{wav_name}")}


@app.post("/render_sfizz_start")
async def render_sfizz_start(midi: UploadFile = File(...), sr: Optional[str] = Form(None), preview: Optional[str] = Form(None)):
    job_id = str(uuid.uuid4())
    wav_name = f"sfizz_job_{job_id}.wav"
    wav_path = STATIC_DIR / wav_name
    write_silence_wav(wav_path, seconds=1.0)
    jobs[job_id] = {"status": "processing", "kind": "render", "wav_url": absolute_url(f"/static/{wav_name}")}
    asyncio.create_task(complete_job(job_id, {}))
    return {"status": "processing", "job_id": job_id}


# --- Separation ---
@app.post("/separate_start")
async def separate_start(
    file: UploadFile = File(...),
    mode: Optional[str] = Form(None),
    enhance: Optional[str] = Form(None),
):
    job_id = str(uuid.uuid4())
    inst_name = f"inst_{job_id}.wav"
    voc_name = f"voc_{job_id}.wav"
    write_silence_wav(STATIC_DIR / inst_name, seconds=1.0)
    write_silence_wav(STATIC_DIR / voc_name, seconds=1.0)
    jobs[job_id] = {
        "status": "processing",
        "kind": "separate",
        "instrumental_url": absolute_url(f"/static/{inst_name}"),
        "vocals_url": absolute_url(f"/static/{voc_name}"),
        "backend": "demucs",
        "fallback_from": None,
    }
    asyncio.create_task(complete_job(job_id, {}))
    return {"status": "processing", "job_id": job_id}


@app.post("/separate_api")
async def separate_api(
    file: UploadFile = File(...),
    force: Optional[str] = Form(None),
    target: Optional[str] = Form(None),
    local: Optional[str] = Form(None),
):
    # Immediate response variant
    inst_name = f"inst_{uuid.uuid4().hex}.wav"
    voc_name = f"voc_{uuid.uuid4().hex}.wav"
    write_silence_wav(STATIC_DIR / inst_name, seconds=1.0)
    write_silence_wav(STATIC_DIR / voc_name, seconds=1.0)
    return {
        "status": "done",
        "job_id": uuid.uuid4().hex,
        "instrumental_url": absolute_url(f"/static/{inst_name}"),
        "vocals_url": absolute_url(f"/static/{voc_name}"),
        "backend": "spleeter_api",
        "fallback_from": None,
    }


@app.get("/job/{job_id}")
async def job_status(job_id: str):
    job = jobs.get(job_id)
    if not job:
        return JSONResponse(status_code=404, content={"detail": "Job not found"})
    resp: dict = {"status": job.get("status", "processing"), "progress": 1.0 if job.get("status") == "done" else 0.5}
    if "wav_url" in job:
        resp["wav_url"] = job["wav_url"]
    if "instrumental_url" in job or "vocals_url" in job:
        resp["instrumental_url"] = job.get("instrumental_url")
        resp["vocals_url"] = job.get("vocals_url")
        resp["backend"] = job.get("backend")
        resp["fallback_from"] = job.get("fallback_from")
    return resp


# --- DDSP / Covers ---
@app.post("/ddsp_melody_to_piano")
async def ddsp_melody_to_piano(file: UploadFile = File(...), render: Optional[str] = Form(None)):
    midi_name = f"ddsp_{uuid.uuid4().hex}.mid"
    wav_name = f"ddsp_{uuid.uuid4().hex}.wav"
    write_minimal_midi(STATIC_DIR / midi_name)
    write_silence_wav(STATIC_DIR / wav_name, seconds=1.0)
    return {
        "status": "done",
        "midi_url": absolute_url(f"/static/{midi_name}"),
        "wav_url": absolute_url(f"/static/{wav_name}"),
    }


@app.post("/piano_cover_hq")
async def piano_cover_hq(file: UploadFile = File(...), use_demucs: Optional[str] = Form(None), render: Optional[str] = Form(None)):
    midi_name = f"cover_hq_{uuid.uuid4().hex}.mid"
    wav_name = f"cover_hq_{uuid.uuid4().hex}.wav"
    write_minimal_midi(STATIC_DIR / midi_name)
    write_silence_wav(STATIC_DIR / wav_name, seconds=1.0)
    return {
        "status": "done",
        "midi_url": absolute_url(f"/static/{midi_name}"),
        "wav_url": absolute_url(f"/static/{wav_name}"),
    }


@app.post("/piano_cover_style")
async def piano_cover_style(file: UploadFile = File(...), style: str = Form(...), use_demucs: Optional[str] = Form(None), render: Optional[str] = Form(None)):
    midi_name = f"cover_style_{uuid.uuid4().hex}.mid"
    wav_name = f"cover_style_{uuid.uuid4().hex}.wav"
    write_minimal_midi(STATIC_DIR / midi_name)
    write_silence_wav(STATIC_DIR / wav_name, seconds=1.0)
    return {
        "status": "done",
        "midi_url": absolute_url(f"/static/{midi_name}"),
        "wav_url": absolute_url(f"/static/{wav_name}"),
    }


# --- Performance enhancers ---
@app.post("/perform")
async def perform(midi: UploadFile = File(...)):
    midi_name = f"performed_{uuid.uuid4().hex}.mid"
    write_minimal_midi(STATIC_DIR / midi_name)
    return {"midi_url": absolute_url(f"/static/{midi_name}")}


@app.post("/perform_ml")
async def perform_ml(midi: UploadFile = File(...)):
    midi_name = f"performed_ml_{uuid.uuid4().hex}.mid"
    write_minimal_midi(STATIC_DIR / midi_name)
    return {"midi_url": absolute_url(f"/static/{midi_name}")}


