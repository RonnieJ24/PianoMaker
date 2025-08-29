#!/usr/bin/env python3
"""
Simple test script to test separation functions directly
"""

import sys
import os
sys.path.append('server')

from inference import separate_audio, separate_audio_pro, separate_audio_fast_overlap

def test_separation_functions():
    """Test the separation functions directly"""
    print("🧪 Testing separation functions directly...")
    
    # Test file
    test_file = "01 - Dreamlover - Mariah Carey.mp3"
    
    if not os.path.exists(test_file):
        print(f"❌ Test file {test_file} not found")
        return
    
    print(f"✅ Using test file: {test_file}")
    
    try:
        print("\n1️⃣ Testing Standard Mode...")
        inst, voc = separate_audio(test_file)
        print(f"   Instrumental: {inst}")
        print(f"   Vocals: {voc}")
        
        print("\n2️⃣ Testing Pro Mode...")
        inst_pro, voc_pro = separate_audio_pro(test_file)
        print(f"   Instrumental: {inst_pro}")
        print(f"   Vocals: {voc_pro}")
        
        print("\n3️⃣ Testing Speed Mode...")
        inst_speed, voc_speed = separate_audio_fast_overlap(test_file)
        print(f"   Instrumental: {inst_speed}")
        print(f"   Vocals: {voc_speed}")
        
        print("\n✅ All functions executed successfully!")
        
    except Exception as e:
        print(f"❌ Error: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    test_separation_functions()


