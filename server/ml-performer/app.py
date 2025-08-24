import io
from fastapi import FastAPI, UploadFile, File, HTTPException
from fastapi.responses import Response
import pretty_midi
import numpy as np

app = FastAPI(title="Local ML Performer (stub)")


def simple_ml_style(pm: pretty_midi.PrettyMIDI) -> pretty_midi.PrettyMIDI:
    # Placeholder: accent on downbeats, humanize, light sustain. Replace with real Magenta later.
    beats = pm.get_beats()
    if beats.size == 0:
        beats = np.arange(0, max(1.0, pm.get_end_time() + 1.0), 0.5)

    for inst in pm.instruments:
        inst.notes.sort(key=lambda n: (n.start, n.pitch))
        for i, n in enumerate(inst.notes):
            # Downbeat accent every 4 beats
            j = np.searchsorted(beats, n.start) - 1
            accent = 10 if (j % 4) == 0 else 0
            dv = int(np.random.randint(-5, 6))
            n.velocity = int(max(1, min(127, n.velocity + accent + dv)))
            # Tiny timing jitter
            jitter = float(np.random.uniform(-0.01, 0.01))
            n.start = max(0.0, n.start + jitter)
            n.end = max(n.start + 0.02, n.end + jitter)
    return pm


@app.post("/perform")
async def perform(midi: UploadFile = File(...)):
    try:
        data = await midi.read()
        bio = io.BytesIO(data)
        pm = pretty_midi.PrettyMIDI(bio)
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Invalid MIDI: {e}")

    pm_out = simple_ml_style(pm)
    out = io.BytesIO()
    pm_out.write(out)
    out.seek(0)
    return Response(content=out.read(), media_type="audio/midi")
































