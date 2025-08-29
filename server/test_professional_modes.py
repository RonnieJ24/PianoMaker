#!/usr/bin/env python3
"""
Test script to demonstrate different transcription modes and their quality differences.
This helps compare the sound quality between pure, hybrid, professional, and enhanced modes.
"""

import os
import sys
import tempfile
import time

# Add current directory to path for imports
sys.path.insert(0, os.path.dirname(__file__))

from inference import (
    transcribe_to_midi_pure_basic_pitch,
    transcribe_to_midi_hybrid,
    transcribe_to_midi_professional,
    transcribe_to_midi_enhanced
)

def test_transcription_modes(audio_file_path: str):
    """Test all transcription modes on the same audio file."""
    
    if not os.path.exists(audio_file_path):
        print(f"❌ Audio file not found: {audio_file_path}")
        return
    
    print(f"🎵 Testing transcription modes on: {audio_file_path}")
    print("=" * 60)
    
    modes = [
        ("pure", transcribe_to_midi_pure_basic_pitch, "Pure Basic Pitch (baseline)"),
        ("hybrid", transcribe_to_midi_hybrid, "Hybrid: Basic Pitch + AI enhancement"),
        ("professional", transcribe_to_midi_professional, "Professional: Studio-quality local processing"),
        ("enhanced", transcribe_to_midi_enhanced, "Enhanced: Cloud + multi-pass refinement")
    ]
    
    results = {}
    
    for mode_name, mode_func, description in modes:
        print(f"\n🔍 Testing {mode_name.upper()} mode...")
        print(f"   Description: {description}")
        
        # Create temporary output file
        with tempfile.NamedTemporaryFile(suffix=".mid", delete=False) as tmp:
            output_path = tmp.name
        
        try:
            start_time = time.time()
            
            if mode_name == "enhanced":
                # Enhanced mode requires cloud setup
                try:
                    result = mode_func(audio_file_path, output_path, use_cloud=True)
                    print(f"   ✅ Enhanced mode completed successfully")
                except Exception as e:
                    print(f"   ⚠️  Enhanced mode failed (cloud not configured): {e}")
                    result = {"notes": 0, "duration_sec": 0, "bpm_estimate": None}
            else:
                result = mode_func(audio_file_path, output_path)
            
            elapsed = time.time() - start_time
            
            # Get file size
            file_size = os.path.getsize(output_path) if os.path.exists(output_path) else 0
            
            results[mode_name] = {
                "result": result,
                "elapsed": elapsed,
                "file_size": file_size,
                "output_path": output_path
            }
            
            print(f"   📊 Notes: {result.get('notes', 0)}")
            print(f"   ⏱️  Duration: {result.get('duration_sec', 0):.1f}s")
            print(f"   🎯 BPM: {result.get('bpm_estimate', 'N/A')}")
            print(f"   💾 File size: {file_size / 1024:.1f} KB")
            print(f"   ⏱️  Processing time: {elapsed:.1f}s")
            
        except Exception as e:
            print(f"   ❌ {mode_name} mode failed: {e}")
            results[mode_name] = {"error": str(e)}
    
    # Summary comparison
    print("\n" + "=" * 60)
    print("📊 TRANSCRIPTION MODE COMPARISON")
    print("=" * 60)
    
    for mode_name, data in results.items():
        if "error" in data:
            print(f"{mode_name.upper():12} ❌ Failed: {data['error']}")
        else:
            result = data["result"]
            print(f"{mode_name.upper():12} ✅ {result.get('notes', 0):>4} notes, "
                  f"{result.get('duration_sec', 0):>5.1f}s, "
                  f"{data['elapsed']:>5.1f}s processing")
    
    print("\n💡 RECOMMENDATIONS:")
    print("• PURE: Best for learning/analysis, minimal processing")
    print("• HYBRID: Good balance of accuracy and enhancement")
    print("• PROFESSIONAL: Best local quality, studio-ready output")
    print("• ENHANCED: Maximum quality (requires cloud setup)")
    
    # Clean up temporary files
    for mode_name, data in results.items():
        if "output_path" in data and os.path.exists(data["output_path"]):
            try:
                os.unlink(data["output_path"])
            except:
                pass

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python test_professional_modes.py <audio_file>")
        print("Example: python test_professional_modes.py ../01 - Dreamlover - Mariah Carey.mp3")
        sys.exit(1)
    
    audio_file = sys.argv[1]
    test_transcription_modes(audio_file)



