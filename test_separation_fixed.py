#!/usr/bin/env python3
"""
Test script for the fixed Great Quality separation system
"""

import requests
import time
import os

def test_separation():
    """Test the separation endpoint"""
    print("🧪 Testing Fixed Great Quality Separation")
    print("=" * 45)

    # Test file
    test_file = "01 - Dreamlover - Mariah Carey.mp3"

    if not os.path.exists(test_file):
        print(f"❌ Test file {test_file} not found")
        return

    print(f"✅ Using test file: {test_file}")

    # Test the separation endpoint
    url = "http://localhost:8010/separate_start"

    try:
        with open(test_file, 'rb') as f:
            files = {'file': (test_file, f, 'audio/mpeg')}
            response = requests.post(url, files=files)

        if response.status_code == 200:
            result = response.json()
            job_id = result.get('job_id')
            print(f"✅ Separation job started. Job ID: {job_id}")

            # Check job status multiple times
            for i in range(10):
                time.sleep(3)
                print(f"⏳ Check {i+1}/10...")
                
                status_url = f"http://localhost:8010/job/{job_id}"
                try:
                    status_response = requests.get(status_url)
                    if status_response.status_code == 200:
                        status_data = status_response.json()
                        status = status_data.get('status')
                        progress = status_data.get('progress', 0)
                        
                        print(f"   Status: {status}, Progress: {progress:.1%}")
                        
                        # Check for separation files
                        if status_data.get('instrumental_url'):
                            print(f"   ✅ Instrumental: {status_data.get('instrumental_url')}")
                        if status_data.get('vocals_url'):
                            print(f"   ✅ Vocals: {status_data.get('vocals_url')}")
                        if status_data.get('backend'):
                            print(f"   Backend: {status_data.get('backend')}")
                        
                        if status == 'done':
                            print("✅ Separation completed!")
                            return
                        elif status == 'error':
                            print(f"❌ Separation failed: {status_data.get('error', 'Unknown error')}")
                            return
                    else:
                        print(f"⚠️  Status check failed: {status_response.status_code}")

                except Exception as e:
                    print(f"⚠️  Error checking status: {e}")

            print("⏰ Checked 10 times, separation still in progress")

        else:
            print(f"❌ Failed to start separation: {response.status_code}")
            print(f"   Response: {response.text}")

    except Exception as e:
        print(f"❌ Error: {e}")

if __name__ == "__main__":
    test_separation()


