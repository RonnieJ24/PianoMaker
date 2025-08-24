#!/usr/bin/env python3
"""
Test script for the new Separation Mode feature
Tests all three modes: standard, pro, and speed
"""

import requests
import json
import time

BASE_URL = "http://localhost:8010"

def test_separation_mode(mode, test_file="01 - Dreamlover - Mariah Carey.mp3"):
    """Test a specific separation mode"""
    print(f"\n🧪 Testing {mode.upper()} mode...")
    
    # Test the separate_start endpoint
    url = f"{BASE_URL}/separate_start"
    
    try:
        with open(test_file, "rb") as f:
            files = {"file": (test_file, f, "audio/wav")}
            data = {"separation_mode": mode}
            
            response = requests.post(url, files=files, data=data)
            
            if response.status_code == 200:
                result = response.json()
                job_id = result.get("job_id")
                print(f"✅ {mode} mode started successfully. Job ID: {job_id}")
                
                # Poll for completion
                print(f"⏳ Waiting for {mode} mode to complete...")
                for i in range(30):  # Wait up to 30 seconds
                    time.sleep(1)
                    status_url = f"{BASE_URL}/job/{job_id}"
                    status_response = requests.get(status_url)
                    
                    if status_response.status_code == 200:
                        status_data = status_response.json()
                        if status_data.get("status") == "done":
                            # Check the metadata file for mode information
                            try:
                                meta_url = f"{BASE_URL}/outputs/{job_id}/sep_meta.json"
                                meta_response = requests.get(meta_url)
                                if meta_response.status_code == 200:
                                    meta_data = meta_response.json()
                                    print(f"✅ {mode} mode completed successfully!")
                                    print(f"   Backend: {meta_data.get('backend', 'unknown')}")
                                    print(f"   Mode: {meta_data.get('mode', 'unknown')}")
                                    print(f"   Message: {meta_data.get('message', 'No message')}")
                                else:
                                    print(f"✅ {mode} mode completed successfully!")
                                    print(f"   Backend: {status_data.get('backend', 'unknown')}")
                                    print(f"   Mode: {mode}")
                            except Exception as e:
                                print(f"✅ {mode} mode completed successfully!")
                                print(f"   Backend: {status_data.get('backend', 'unknown')}")
                                print(f"   Mode: {mode}")
                            return True
                        elif status_data.get("status") == "error":
                            print(f"❌ {mode} mode failed: {status_data.get('error', 'Unknown error')}")
                            return False
                
                print(f"⏰ {mode} mode timed out")
                return False
                
            else:
                print(f"❌ {mode} mode failed to start: HTTP {response.status_code}")
                print(f"   Response: {response.text}")
                return False
                
    except Exception as e:
        print(f"❌ Error testing {mode} mode: {e}")
        return False

def main():
    """Test all separation modes"""
    print("🎵 Testing PianoMaker Separation Mode Feature")
    print("=" * 50)
    
    # Test all three modes
    modes = ["standard", "pro", "speed"]
    results = {}
    
    for mode in modes:
        results[mode] = test_separation_mode(mode)
    
    # Summary
    print("\n📊 Test Results Summary")
    print("=" * 30)
    for mode, success in results.items():
        status = "✅ PASS" if success else "❌ FAIL"
        print(f"{mode.upper():<10}: {status}")
    
    # Overall result
    all_passed = all(results.values())
    if all_passed:
        print("\n🎉 All separation modes tested successfully!")
    else:
        print("\n⚠️  Some separation modes failed. Check the logs above.")
    
    return all_passed

if __name__ == "__main__":
    main()
