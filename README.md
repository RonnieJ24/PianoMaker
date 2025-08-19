# PianoMaker Monorepo

Folders:

- ios/ (Xcode project and SwiftUI app live in `PianoMaker/`)
- server/ (FastAPI backend)

Backend quickstart:

```bash
cd server
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app:app --host 0.0.0.0 --port 8000 --reload
```

API:

- POST `/transcribe` multipart: `file`, optional form `use_demucs` (bool). Returns `{ status, midi_url, duration_sec, notes, job_id }` synchronously for MVP.
- GET `/status/{job_id}`: returns `{ status }` or `{ status: "done", midi_url }`.

iOS:

- Open `PianoMaker.xcodeproj`. Run on Simulator. Update `Config.serverBaseURL` to your LAN IP for device testing.

Notes:

- The app includes a placeholder SoundFont at `PianoMaker/Resources/SoundFonts/AcousticPiano.sf2`. Replace with a real GM piano SF2 for best quality.
- Outputs are served statically from `/outputs` so the app can download MIDI.



