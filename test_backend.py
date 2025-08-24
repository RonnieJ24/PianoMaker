#!/usr/bin/env python3
"""
Test script to verify the PianoMaker backend is working correctly
"""

import requests
import time
import json

def test_backend():
    base_url = "http://10.0.0.231:8010"
    
    print("🎵 Testing PianoMaker Backend...")
    print(f"📍 Server: {base_url}")
    
    # Test 1: Health check
    print("\n1️⃣ Testing health endpoint...")
    try:
        response = requests.get(f"{base_url}/health", timeout=10)
        if response.status_code == 200:
            print("✅ Health check passed")
            print(f"   Response: {response.json()}")
        else:
            print(f"❌ Health check failed: {response.status_code}")
            return False
    except Exception as e:
        print(f"❌ Health check error: {e}")
        return False
    
    # Test 2: Transcription
    print("\n2️⃣ Testing transcription endpoint...")
    try:
        with open("tiny.wav", "rb") as f:
            files = {"file": ("tiny.wav", f, "audio/wav")}
            data = {"use_demucs": "false", "profile": "default"}
            
            response = requests.post(
                f"{base_url}/transcribe_start",
                files=files,
                data=data,
                timeout=30
            )
            
        if response.status_code == 200:
            result = response.json()
            print("✅ Transcription started successfully")
            print(f"   Job ID: {result.get('job_id')}")
            print(f"   Status: {result.get('status')}")
            
            job_id = result.get('job_id')
            
            # Test 3: Poll job status
            print(f"\n3️⃣ Polling job {job_id}...")
            max_attempts = 30
            for attempt in range(max_attempts):
                time.sleep(2)
                
                job_response = requests.get(f"{base_url}/job/{job_id}", timeout=10)
                if job_response.status_code == 200:
                    job_status = job_response.json()
                    print(f"   Attempt {attempt + 1}: {job_status.get('status')} (progress: {job_status.get('progress', 0)})")
                    
                    if job_status.get('status') == 'done':
                        print("✅ Transcription completed!")
                        print(f"   MIDI URL: {job_status.get('midi_url')}")
                        print(f"   Duration: {job_status.get('duration_sec')}s")
                        print(f"   Notes: {job_status.get('notes')}")
                        
                        # Test 4: Download MIDI file
                        if job_status.get('midi_url'):
                            print(f"\n4️⃣ Testing MIDI download...")
                            midi_response = requests.get(job_status['midi_url'], timeout=10)
                            if midi_response.status_code == 200:
                                print(f"✅ MIDI file downloaded successfully ({len(midi_response.content)} bytes)")
                            else:
                                print(f"❌ MIDI download failed: {midi_response.status_code}")
                        
                        return True
                    elif job_status.get('status') == 'error':
                        print(f"❌ Transcription failed: {job_status.get('error')}")
                        return False
                else:
                    print(f"   Attempt {attempt + 1}: Failed to get job status ({job_response.status_code})")
            
            print(f"❌ Transcription timed out after {max_attempts * 2} seconds")
            return False
            
        else:
            print(f"❌ Transcription failed: {response.status_code}")
            print(f"   Response: {response.text}")
            return False
            
    except Exception as e:
        print(f"❌ Transcription error: {e}")
        return False

if __name__ == "__main__":
    success = test_backend()
    if success:
        print("\n🎉 All tests passed! Backend is working correctly.")
    else:
        print("\n💥 Some tests failed. Check the backend logs.")

