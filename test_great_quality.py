#!/usr/bin/env python3
"""
Test script for the new Great Quality separation system
"""

import requests
import time
import os

def test_great_quality_separation():
    """Test the Great Quality separation endpoint"""
    print("🧪 Testing Great Quality Separation System")
    print("=" * 50)
    
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
            print(f"✅ Separation job started successfully. Job ID: {job_id}")
            
            # Poll for completion
            print("⏳ Waiting for separation to complete...")
            max_wait = 300  # 5 minutes
            start_time = time.time()
            
            while time.time() - start_time < max_wait:
                time.sleep(2)
                
                # Check job status
                status_url = f"http://localhost:8010/job/{job_id}"
                try:
                    status_response = requests.get(status_url)
                    if status_response.status_code == 200:
                        status_data = status_response.json()
                        status = status_data.get('status')
                        
                        if status == 'done':
                            print("✅ Separation completed successfully!")
                            print(f"   Instrumental: {status_data.get('instrumental_url', 'N/A')}")
                            print(f"   Vocals: {status_data.get('vocals_url', 'N/A')}")
                            print(f"   Backend: {status_data.get('backend', 'N/A')}")
                            return
                        elif status == 'error':
                            print(f"❌ Separation failed: {status_data.get('error', 'Unknown error')}")
                            return
                        else:
                            progress = status_data.get('progress', 0)
                            print(f"   Progress: {progress:.1%}")
                    else:
                        print(f"⚠️  Status check failed: {status_response.status_code}")
                        
                except Exception as e:
                    print(f"⚠️  Error checking status: {e}")
                    
            print("⏰ Separation timed out")
            
        else:
            print(f"❌ Failed to start separation: {response.status_code}")
            print(f"   Response: {response.text}")
            
    except Exception as e:
        print(f"❌ Error: {e}")

if __name__ == "__main__":
    test_great_quality_separation()


