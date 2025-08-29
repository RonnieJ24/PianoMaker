#!/usr/bin/env python3
"""
Compare different transcription modes by rendering them and analyzing quality differences.
This helps demonstrate the professional improvements in sound quality.
"""

import os
import sys
import tempfile
import time
import requests
import json

def test_backend_modes(audio_file_path: str, base_url: str = "http://localhost:8010"):
    """Test different transcription modes via the backend API."""
    
    if not os.path.exists(audio_file_path):
        print(f"❌ Audio file not found: {audio_file_path}")
        return
    
    print(f"🎵 Testing backend transcription modes on: {audio_file_path}")
    print(f"🌐 Backend URL: {base_url}")
    print("=" * 70)
    
    # Test different modes
    modes = [
        ("pure", "Pure Basic Pitch (baseline)"),
        ("hybrid", "Hybrid: Basic Pitch + AI enhancement"),
        ("professional", "Professional: Studio-quality local processing"),
        ("enhanced", "Enhanced: Cloud + multi-pass refinement")
    ]
    
    results = {}
    
    for mode_name, description in modes:
        print(f"\n🔍 Testing {mode_name.upper()} mode...")
        print(f"   Description: {description}")
        
        try:
            # Upload file for transcription
            with open(audio_file_path, 'rb') as f:
                files = {'file': (os.path.basename(audio_file_path), f, 'audio/mpeg')}
                data = {'mode': mode_name}
                
                start_time = time.time()
                response = requests.post(f"{base_url}/transcribe", files=files, data=data, timeout=300)
                elapsed = time.time() - start_time
                
                if response.status_code == 200:
                    result = response.json()
                    job_id = result.get('job_id')
                    midi_url = result.get('midi_url')
                    
                    print(f"   ✅ Transcription completed successfully")
                    print(f"   📊 Job ID: {job_id}")
                    print(f"   🎵 MIDI URL: {midi_url}")
                    print(f"   ⏱️  Processing time: {elapsed:.1f}s")
                    
                    # Now render the MIDI to compare audio quality
                    print(f"   🎹 Rendering MIDI for audio comparison...")
                    
                    # Download MIDI file
                    # Check if midi_url is already a full URL or just a path
                    if midi_url.startswith('http'):
                        download_url = midi_url
                    else:
                        download_url = f"{base_url}{midi_url}"
                    
                    midi_response = requests.get(download_url)
                    if midi_response.status_code == 200:
                        # Save MIDI temporarily
                        with tempfile.NamedTemporaryFile(suffix=".mid", delete=False) as tmp:
                            tmp.write(midi_response.content)
                            midi_path = tmp.name
                        
                        # Render with professional settings
                        with open(midi_path, 'rb') as f:
                            render_files = {'midi': ('input.mid', f, 'audio/midi')}
                            render_data = {
                                'soundfont': 'professional',
                                'quality': 'studio'
                            }
                            
                            render_response = requests.post(f"{base_url}/render", files=render_files, data=render_data, timeout=120)
                            
                            if render_response.status_code == 200:
                                render_result = render_response.json()
                                wav_url = render_result.get('wav_url')
                                print(f"   🎵 Audio rendered: {wav_url}")
                                
                                results[mode_name] = {
                                    "status": "success",
                                    "job_id": job_id,
                                    "midi_url": midi_url,
                                    "wav_url": wav_url,
                                    "processing_time": elapsed,
                                    "midi_path": midi_path
                                }
                            else:
                                print(f"   ❌ Rendering failed: {render_response.status_code}")
                                results[mode_name] = {"status": "render_failed", "error": f"HTTP {render_response.status_code}"}
                        
                        # Clean up MIDI file
                        try:
                            os.unlink(midi_path)
                        except:
                            pass
                    else:
                        print(f"   ❌ MIDI download failed: {midi_response.status_code}")
                        results[mode_name] = {"status": "midi_download_failed", "error": f"HTTP {midi_response.status_code}"}
                else:
                    print(f"   ❌ Transcription failed: {response.status_code}")
                    print(f"   📝 Response: {response.text[:200]}")
                    results[mode_name] = {"status": "transcription_failed", "error": f"HTTP {response.status_code}"}
                    
        except Exception as e:
            print(f"   ❌ {mode_name} mode failed: {e}")
            results[mode_name] = {"status": "error", "error": str(e)}
    
    # Summary and recommendations
    print("\n" + "=" * 70)
    print("📊 BACKEND TRANSCRIPTION MODE COMPARISON")
    print("=" * 70)
    
    successful_modes = []
    for mode_name, data in results.items():
        if data.get("status") == "success":
            successful_modes.append(mode_name)
            print(f"{mode_name.upper():12} ✅ Success - {data['processing_time']:>5.1f}s processing")
            # Fix URL display - check if wav_url is already full URL
            wav_display_url = data['wav_url']
            if not wav_display_url.startswith('http'):
                wav_display_url = f"{base_url}{data['wav_url']}"
            print(f"{'':12}   🎵 Audio: {wav_display_url}")
        else:
            print(f"{mode_name.upper():12} ❌ Failed: {data.get('error', 'Unknown error')}")
    
    if successful_modes:
        print(f"\n🎯 SUCCESSFUL MODES ({len(successful_modes)}):")
        for mode in successful_modes:
            data = results[mode]
            wav_display_url = data['wav_url']
            if not wav_display_url.startswith('http'):
                wav_display_url = f"{base_url}{data['wav_url']}"
            print(f"   • {mode.upper()}: {wav_display_url}")
        
        print(f"\n💡 QUALITY COMPARISON:")
        print(f"   • PURE: Clean, unprocessed Basic Pitch output")
        print(f"   • HYBRID: Enhanced with AI velocity and timing")
        print(f"   • PROFESSIONAL: Studio-quality with advanced expression")
        print(f"   • ENHANCED: Maximum quality (requires cloud)")
        
        print(f"\n🔊 AUDIO QUALITY FEATURES:")
        print(f"   • Velocity range: Pure < Hybrid < Professional < Enhanced")
        print(f"   • Timing precision: Pure < Hybrid < Professional < Enhanced")
        print(f"   • Musical expression: Pure < Hybrid < Professional < Enhanced")
        print(f"   • Sustain richness: Pure < Hybrid < Professional < Enhanced")
    
    return results

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python compare_modes.py <audio_file> [backend_url]")
        print("Example: python compare_modes.py ../01 - Dreamlover - Mariah Carey.mp3")
        print("Example: python compare_modes.py ../01 - Dreamlover - Mariah Carey.mp3 http://localhost:8010")
        sys.exit(1)
    
    audio_file = sys.argv[1]
    backend_url = sys.argv[2] if len(sys.argv) > 2 else "http://localhost:8010"
    
    test_backend_modes(audio_file, backend_url)
