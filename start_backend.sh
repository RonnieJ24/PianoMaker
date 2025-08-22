#!/bin/bash

echo "🎵 Starting PianoMaker Backend..."
echo "📍 Server will be available at: http://10.0.0.231:8010"
echo ""

cd "$(dirname "$0")/server"
source .venv/bin/activate

echo "🚀 Starting backend on port 8010..."
python -m uvicorn app:app --host 0.0.0.0 --port 8010 --reload

echo ""
echo "✅ Backend stopped."
