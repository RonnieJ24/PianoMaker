# PianoMaker - Simplified Setup

## 🎯 **What Changed**
- ❌ **Removed**: Mock backend (port 8000) and complex server discovery
- ✅ **Simplified**: Single, reliable backend on port 8010
- 🧹 **Cleaned**: Removed fallback logic and confusing options

## 🚀 **Quick Start**

### 1. Start the Backend
```bash
./start_backend.sh
```
The backend will be available at: `http://10.0.0.231:8010`

### 2. Run the iOS App
- Open `PianoMaker.xcodeproj` in Xcode
- Run on iOS Simulator
- App will automatically connect to the backend

## 🔧 **What You Get**
- **Real transcription** with actual notes from your songs
- **High-quality audio separation** using Demucs
- **MIDI rendering** with FluidSynth and soundfonts
- **Piano covers** and style-based arrangements
- **All advanced features** working correctly

## 📱 **iOS App**
- **Server**: Always connects to `http://10.0.0.231:8010`
- **No more confusion**: Single, reliable connection
- **Simple menu**: Just "Select Audio", "Refresh Status", "Clear Errors"

## 🎵 **Test It**
1. Upload an audio file (e.g., "04. Snow On The Beach.mp3")
2. Tap "Convert" 
3. Get real transcription with actual notes and duration
4. Use vocal separation, piano covers, and other features

## 🛠 **Troubleshooting**
- **Backend not responding**: Run `./start_backend.sh`
- **iOS app won't connect**: Check that backend is running on port 8010
- **Need to change server**: Edit `PianoMaker/Config.swift`

## 📁 **Project Structure**
```
PianoMaker/
├── PianoMaker/          # iOS app (Xcode project)
├── server/              # Full backend with all features
├── start_backend.sh     # Easy backend startup script
└── README_SIMPLE.md     # This file
```

**No more mock backends, no more confusion - just one reliable server!** 🎹
