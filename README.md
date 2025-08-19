# PianoMaker

SwiftUI app + FastAPI backends for audio → MIDI transcription, separation, and rendering.

## Folders
- `PianoMaker/`: iOS app (open `PianoMaker.xcodeproj` in Xcode)
- `local-backend/`: minimal FastAPI mock on port 8000 (fast dev path)
- `server/`: full FastAPI backend with separation, rendering, covers, etc.

## Prerequisites
- macOS (Apple Silicon recommended)
- Xcode 15+
- Python 3.11+ (`/usr/bin/python3` is fine)
- Homebrew packages (for full features):
  - `ffmpeg`
  - `fluid-synth` (fluidsynth)

Install via Homebrew:
```bash
brew install ffmpeg fluid-synth
```

Optional (for HQ separation/arrangers):
- Demucs CLI models: `pip install demucs`
- An SFZ renderer (`sfizz_render`) if you want the SFZ route. Not required for basic use.

## Quick start (recommended)
1) Start the full backend (port 8010):
```bash
cd server
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app:app --host 0.0.0.0 --port 8010
```

2) Run the iOS app in Simulator:
- Open `PianoMaker.xcodeproj` in Xcode and Run.
- The app auto-discovers backends in this order: `8010` (full), `8001` (legacy), `8000` (local mock).
- You can also set it manually from the ⋯ menu:
  - “Use Full Server (127.0.0.1:8010)” or
  - “Use Local Server (127.0.0.1:8000)”

## Lightweight backend (mock, port 8000)
This is a tiny backend that always succeeds quickly (useful for UI/dev).
```bash
cd local-backend
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn main:app --host 0.0.0.0 --port 8000
```

## Key endpoints (full backend)
- `POST /transcribe_start` → returns `{ status:"queued", job_id }` then `GET /status/{job_id}` → `{ status, midi_url? }`
- `POST /transcribe` (blocking)
- `POST /separate_start` → `GET /job/{job_id}` for progress and `instrumental_url`/`vocals_url`
- `POST /render` (MIDI→WAV via fluidsynth)
- `POST /render_sfizz_start` + `GET /job/{job_id}` for SFZ rendering
- `POST /ddsp_melody_to_piano`, `POST /piano_cover_hq`, `POST /piano_cover_style`

Artifacts are served from `/outputs/<job_id>/...`.

## SoundFonts / assets
- The iOS app ships with lightweight `.sf2` files under `PianoMaker/Resources/SoundFonts/` for on-device MIDI playback.
- The server expects an `.sf2` in `server/soundfonts/` (ignored by git). Put one there (e.g. `FluidR3_GM.sf2`) for `/render`.
- Large assets (SF2/SFZ, model files) are ignored by git to keep the repo small.

## Troubleshooting
- App keeps “spinning” / no results:
  - Ensure the backend is running (`curl http://127.0.0.1:8010/health` should return 200).
  - In the app’s ⋯ menu, set the server explicitly to `http://127.0.0.1:8010`.
  - If uploads time out on large files, try the “PTI” option (slower but robust) or use the mock backend on 8000 to validate UI.
- Separation returns original audio only:
  - Demucs not installed or models missing; install `pip install demucs` or use the “Fast (Local)” option which is CPU-only.
  - Check `server/outputs/<job_id>/` for generated files and any `error.txt`.
- SFZ render fails:
  - Ensure `sfizz_render` exists or stick to `/render` (fluidsynth + `.sf2`).

## Git workflow
Changes are not auto-synced to GitHub. Commit and push:
```bash
git status
git add -A
git commit -m "Describe change"
git push
```

Undo examples:
```bash
git restore path/to/file                  # drop unstaged edits
git restore --staged path/to/file         # unstage but keep edits
git reset --soft HEAD~1                   # undo last commit, keep work
git reset --hard HEAD~1                   # drop last commit and its work
git revert <SHA>                          # make an "undo" commit for a pushed change
```

## Notes
- When running on a physical device, point the app to your Mac’s LAN IP (e.g. `http://192.168.x.x:8010`).
- Large model files and soundfonts are ignored by `.gitignore`. Add them locally as needed.



