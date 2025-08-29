import io
import json
from typing import Optional, Dict, Any, List
from fastapi import FastAPI, UploadFile, File, HTTPException, Form
from fastapi.responses import Response
import pretty_midi
import numpy as np
from enum import Enum

app = FastAPI(title="Enhanced ML Performer")

class PerformanceStyle(str, Enum):
    ROMANTIC = "romantic"      # Expressive, rubato, dynamic
    JAZZ = "jazz"              # Swing, syncopation, groove
    CLASSICAL = "classical"     # Clean, precise, balanced
    IMPRESSIONIST = "impressionist"  # Delicate, atmospheric
    MODERN = "modern"          # Contemporary, experimental
    BAROQUE = "baroque"        # Ornamented, articulated

class PerformanceConfig:
    def __init__(self, style: PerformanceStyle):
        self.style = style
        # Style-specific parameters
        self.params = self._get_style_params()
    
    def _get_style_params(self) -> Dict[str, Any]:
        base_params = {
            "velocity_range": (40, 100),
            "timing_jitter": 0.01,  # Reduced from 0.02
            "sustain_pedal": False,
            "rubato_strength": 0.0,
            "swing_amount": 0.0,
            "accent_pattern": "none"
        }
        
        if self.style == PerformanceStyle.ROMANTIC:
            base_params.update({
                "velocity_range": (45, 105),  # Reduced range from (30, 110)
                "timing_jitter": 0.02,        # Reduced from 0.05
                "sustain_pedal": True,
                "rubato_strength": 0.08,      # Reduced from 0.15
                "accent_pattern": "phrasing"
            })
        elif self.style == PerformanceStyle.JAZZ:
            base_params.update({
                "velocity_range": (55, 105),  # Reduced range from (50, 120)
                "timing_jitter": 0.015,       # Reduced from 0.03
                "swing_amount": 0.15,         # Reduced from 0.3
                "accent_pattern": "syncopation"
            })
        elif self.style == PerformanceStyle.CLASSICAL:
            base_params.update({
                "velocity_range": (48, 92),   # Reduced range from (45, 95)
                "timing_jitter": 0.005,       # Reduced from 0.01
                "accent_pattern": "downbeats"
            })
        elif self.style == PerformanceStyle.IMPRESSIONIST:
            base_params.update({
                "velocity_range": (42, 88),   # Reduced range from (35, 85)
                "timing_jitter": 0.02,        # Reduced from 0.04
                "sustain_pedal": True,
                "accent_pattern": "delicate"
            })
        elif self.style == PerformanceStyle.MODERN:
            base_params.update({
                "velocity_range": (65, 105),  # Reduced range from (60, 115)
                "timing_jitter": 0.025,       # Reduced from 0.06
                "accent_pattern": "rhythmic"
            })
        elif self.style == PerformanceStyle.BAROQUE:
            base_params.update({
                "velocity_range": (45, 85),   # Reduced range from (40, 90)
                "timing_jitter": 0.008,       # Reduced from 0.015
                "accent_pattern": "ornamented"
            })
        
        return base_params

def analyze_musical_structure(pm: pretty_midi.PrettyMIDI) -> Dict[str, Any]:
    """Analyze MIDI to understand musical structure for intelligent performance."""
    analysis = {
        "tempo": 120.0,
        "key": "C",
        "time_signature": "4/4",
        "phrases": [],
        "dynamics": [],
        "rhythm_patterns": []
    }
    
    # Extract tempo
    if hasattr(pm, 'estimate_tempo') and callable(getattr(pm, 'estimate_tempo', None)):
        analysis["tempo"] = pm.estimate_tempo()
    elif hasattr(pm, 'tempo_changes') and pm.tempo_changes:
        analysis["tempo"] = pm.tempo_changes[0].tempo
    else:
        analysis["tempo"] = 120.0  # Default tempo
    
    # Analyze note density and dynamics
    if pm.instruments:
        notes = pm.instruments[0].notes
        if notes:
            velocities = [n.velocity for n in notes]
            analysis["dynamics"] = {
                "min_velocity": min(velocities),
                "max_velocity": max(velocities),
                "avg_velocity": np.mean(velocities),
                "velocity_std": np.std(velocities)
            }
            
            # Analyze rhythm patterns
            note_starts = [n.start for n in notes]
            note_durations = [n.end - n.start for n in notes]
            analysis["rhythm_patterns"] = {
                "avg_duration": np.mean(note_durations),
                "duration_variety": np.std(note_durations),
                "note_density": len(notes) / max(1.0, pm.get_end_time())
            }
    
    return analysis

def apply_romantic_style(pm: pretty_midi.PrettyMIDI, config: PerformanceConfig) -> pretty_midi.PrettyMIDI:
    """Apply romantic performance style with rubato and expressive dynamics."""
    analysis = analyze_musical_structure(pm)
    
    for inst in pm.instruments:
        if not inst.notes:
            continue
            
        # Sort notes for processing
        inst.notes.sort(key=lambda n: (n.start, n.pitch))
        
        # Apply rubato (tempo flexibility)
        rubato_strength = config.params["rubato_strength"]
        if rubato_strength > 0:
            for note in inst.notes:
                # Create natural rubato curve
                phrase_position = note.start / max(1.0, pm.get_end_time())
                rubato_curve = np.sin(phrase_position * 2 * np.pi * 2) * 0.5 + 0.5
                rubato_offset = (rubato_curve - 0.5) * rubato_strength * 0.1
                note.start += rubato_offset
                note.end += rubato_offset
        
        # Apply expressive dynamics
        for note in inst.notes:
            # Phrase-based dynamics
            phrase_position = note.start / max(1.0, pm.get_end_time())
            phrase_dynamic = np.sin(phrase_position * 2 * np.pi * 3) * 0.3 + 0.7
            
            # Melodic contour following
            pitch_factor = (note.pitch - 60) / 48.0  # Relative to middle C
            pitch_dynamic = 1.0 + pitch_factor * 0.2
            
            # Combine factors
            dynamic_multiplier = phrase_dynamic * pitch_dynamic
            new_velocity = int(note.velocity * dynamic_multiplier)
            note.velocity = max(30, min(110, new_velocity))
            
            # Add subtle timing variations
            timing_jitter = np.random.normal(0, config.params["timing_jitter"])
            note.start = max(0.0, note.start + timing_jitter)
            note.end = max(note.start + 0.02, note.end + timing_jitter)
    
    return pm

def apply_jazz_style(pm: pretty_midi.PrettyMIDI, config: PerformanceConfig) -> pretty_midi.PrettyMIDI:
    """Apply jazz performance style with swing and syncopation."""
    analysis = analyze_musical_structure(pm)
    
    for inst in pm.instruments:
        if not inst.notes:
            continue
            
        inst.notes.sort(key=lambda n: (n.start, n.pitch))
        
        # Apply swing feel
        swing_amount = config.params["swing_amount"]
        if swing_amount > 0:
            for note in inst.notes:
                # Swing every other eighth note
                beat_position = (note.start * analysis["tempo"] / 60.0) % 1.0
                if 0.5 <= beat_position < 1.0:  # Off-beat
                    swing_offset = swing_amount * 0.1
                    note.start += swing_offset
                    note.end += swing_offset
        
        # Apply syncopation accents
        for note in inst.notes:
            beat_position = (note.start * analysis["tempo"] / 60.0) % 1.0
            if 0.4 <= beat_position < 0.6:  # Syncopated position
                note.velocity = min(127, note.velocity + 15)
            
            # Add groove variations
            groove_factor = np.sin(note.start * 2 * np.pi * 2) * 0.2 + 1.0
            note.velocity = int(note.velocity * groove_factor)
            note.velocity = max(50, min(120, note.velocity))
    
    return pm

def apply_classical_style(pm: pretty_midi.PrettyMIDI, config: PerformanceConfig) -> pretty_midi.PrettyMIDI:
    """Apply classical performance style with precision and balance."""
    analysis = analyze_musical_structure(pm)
    
    for inst in pm.instruments:
        if not inst.notes:
            continue
            
        inst.notes.sort(key=lambda n: (n.start, n.pitch))
        
        # Apply downbeat accents
        for note in inst.notes:
            beat_position = (note.start * analysis["tempo"] / 60.0) % 4.0
            if beat_position < 0.1:  # On downbeat
                note.velocity = min(127, note.velocity + 10)
            elif 1.0 <= beat_position < 1.1:  # On beat 2
                note.velocity = min(127, note.velocity + 5)
            elif 2.0 <= beat_position < 2.1:  # On beat 3
                note.velocity = min(127, note.velocity + 5)
            elif 3.0 <= beat_position < 3.1:  # On beat 4
                note.velocity = min(127, note.velocity + 3)
        
        # Balance dynamics across the piece
        velocities = [n.velocity for n in inst.notes]
        if velocities:
            target_mean = 80
            current_mean = np.mean(velocities)
            if abs(current_mean - target_mean) > 5:
                adjustment = (target_mean - current_mean) * 0.3
                for note in inst.notes:
                    note.velocity = max(45, min(95, int(note.velocity + adjustment)))
    
    return pm

def apply_impressionist_style(pm: pretty_midi.PrettyMIDI, config: PerformanceConfig) -> pretty_midi.PrettyMIDI:
    """Apply impressionist performance style with delicate, atmospheric qualities."""
    analysis = analyze_musical_structure(pm)
    
    for inst in pm.instruments:
        if not inst.notes:
            continue
            
        inst.notes.sort(key=lambda n: (n.start, n.pitch))
        
        # Apply delicate, atmospheric dynamics
        for note in inst.notes:
            # Soft, ethereal quality
            base_velocity = note.velocity * 0.8  # Generally softer
            
            # Add atmospheric variations
            time_factor = np.sin(note.start * 2 * np.pi * 0.5) * 0.3 + 0.7
            pitch_factor = np.cos((note.pitch - 60) * np.pi / 24.0) * 0.2 + 0.8
            
            new_velocity = int(base_velocity * time_factor * pitch_factor)
            note.velocity = max(35, min(85, new_velocity))
            
            # Gentle timing variations
            timing_jitter = np.random.normal(0, config.params["timing_jitter"] * 0.5)
            note.start = max(0.0, note.start + timing_jitter)
            note.end = max(note.start + 0.02, note.end + timing_jitter)
    
    return pm

def apply_modern_style(pm: pretty_midi.PrettyMIDI, config: PerformanceConfig) -> pretty_midi.PrettyMIDI:
    """Apply modern performance style with contemporary, experimental qualities."""
    analysis = analyze_musical_structure(pm)
    
    for inst in pm.instruments:
        if not inst.notes:
            continue
            
        inst.notes.sort(key=lambda n: (n.start, n.pitch))
        
        # Apply rhythmic emphasis and contemporary dynamics
        for note in inst.notes:
            # Rhythmic accenting
            beat_position = (note.start * analysis["tempo"] / 60.0) % 1.0
            if 0.25 <= beat_position < 0.35:  # Off-beat emphasis
                note.velocity = min(127, note.velocity + 20)
            elif 0.75 <= beat_position < 0.85:  # Off-beat emphasis
                note.velocity = min(127, note.velocity + 20)
            
            # Contemporary velocity shaping
            pitch_factor = (note.pitch - 60) / 48.0
            pitch_dynamic = 1.0 + pitch_factor * 0.3
            
            new_velocity = int(note.velocity * pitch_dynamic)
            note.velocity = max(60, min(115, new_velocity))
            
            # Experimental timing
            timing_jitter = np.random.normal(0, config.params["timing_jitter"])
            note.start = max(0.0, note.start + timing_jitter)
            note.end = max(note.start + 0.02, note.end + timing_jitter)
    
    return pm

def apply_baroque_style(pm: pretty_midi.PrettyMIDI, config: PerformanceConfig) -> pretty_midi.PrettyMIDI:
    """Apply baroque performance style with ornamentation and articulation."""
    analysis = analyze_musical_structure(pm)
    
    for inst in pm.instruments:
        if not inst.notes:
            continue
            
        inst.notes.sort(key=lambda n: (n.start, n.pitch))
        
        # Apply baroque ornamentation and articulation
        for note in inst.notes:
            # Ornamented accents
            beat_position = (note.start * analysis["tempo"] / 60.0) % 1.0
            if beat_position < 0.1:  # On beat
                note.velocity = min(127, note.velocity + 12)
            
            # Articulation variations
            note_duration = note.end - note.start
            if note_duration < 0.2:  # Short notes get articulation
                note.velocity = min(127, note.velocity + 8)
            
            # Baroque dynamic balance
            pitch_factor = (note.pitch - 60) / 48.0
            pitch_dynamic = 1.0 + pitch_factor * 0.15
            
            new_velocity = int(note.velocity * pitch_dynamic)
            note.velocity = max(40, min(90, new_velocity))
    
    return pm

def enhance_midi_performance(pm: pretty_midi.PrettyMIDI, style: PerformanceStyle) -> pretty_midi.PrettyMIDI:
    """
    Main function to enhance MIDI performance based on style.
    Uses intelligent learning from basic pitch to make human-like enhancements.
    """
    config = PerformanceConfig(style)
    
    # First, analyze the original MIDI to understand its character
    analysis = analyze_musical_structure(pm)
    
    # Learn from the basic pitch patterns and apply intelligent modifications
    if pm.instruments:
        for inst in pm.instruments:
            if inst.notes:
                # Learn from original note patterns
                original_notes = inst.notes.copy()
                
                # Apply style-specific intelligent enhancements
                if style == PerformanceStyle.ROMANTIC:
                    inst.notes = apply_romantic_style_intelligent(original_notes, analysis, config)
                elif style == PerformanceStyle.JAZZ:
                    inst.notes = apply_jazz_style_intelligent(original_notes, analysis, config)
                elif style == PerformanceStyle.CLASSICAL:
                    inst.notes = apply_classical_style_intelligent(original_notes, analysis, config)
                elif style == PerformanceStyle.IMPRESSIONIST:
                    inst.notes = apply_impressionist_style_intelligent(original_notes, analysis, config)
                elif style == PerformanceStyle.MODERN:
                    inst.notes = apply_modern_style_intelligent(original_notes, analysis, config)
                elif style == PerformanceStyle.BAROQUE:
                    inst.notes = apply_baroque_style_intelligent(original_notes, analysis, config)
                
                # Human-like cleanup: limit polyphony to max 6 notes (realistic for human hands)
                inst.notes = limit_polyphony_human_like(inst.notes, max_notes=6)
                
                # Add intelligent sustain pedal based on learned patterns
                if config.params["sustain_pedal"]:
                    add_intelligent_sustain_pedal(inst, analysis)
    
    return pm

@app.post("/perform")
async def perform(
    midi: UploadFile = File(...),
    style: Optional[PerformanceStyle] = Form(PerformanceStyle.ROMANTIC)
):
    """Enhanced MIDI performance with multiple styles."""
    try:
        data = await midi.read()
        bio = io.BytesIO(data)
        pm = pretty_midi.PrettyMIDI(bio)
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Invalid MIDI: {e}")

    # Enhance the performance
    enhanced_pm = enhance_midi_performance(pm, style)
    
    # Output the enhanced MIDI
    out = io.BytesIO()
    enhanced_pm.write(out)
    out.seek(0)
    
    return Response(
        content=out.read(), 
        media_type="audio/midi",
        headers={"X-Performance-Style": style.value}
    )

@app.get("/styles")
async def get_available_styles():
    """Get available performance styles."""
    return {
        "styles": [
            {
                "id": style.value,
                "name": style.value.title(),
                "description": get_style_description(style)
            }
            for style in PerformanceStyle
        ]
    }

def get_style_description(style: PerformanceStyle) -> str:
    """Get human-readable description of each style."""
    descriptions = {
        PerformanceStyle.ROMANTIC: "Expressive, rubato, dynamic - perfect for emotional pieces",
        PerformanceStyle.JAZZ: "Swing, syncopation, groove - ideal for jazz and contemporary music",
        PerformanceStyle.CLASSICAL: "Clean, precise, balanced - traditional classical performance",
        PerformanceStyle.IMPRESSIONIST: "Delicate, atmospheric - great for Debussy-style pieces",
        PerformanceStyle.MODERN: "Contemporary, experimental - modern performance techniques",
        PerformanceStyle.BAROQUE: "Ornamented, articulated - authentic baroque performance"
    }
    return descriptions.get(style, "Enhanced performance style")

@app.get("/health")
async def health():
    """Health check endpoint."""
    return {"status": "healthy", "service": "Enhanced ML Performer"}

# Placeholder functions for style-specific intelligent enhancements
def apply_romantic_style_intelligent(notes: List[pretty_midi.Note], analysis: dict, config: PerformanceConfig) -> List[pretty_midi.Note]:
    """Apply romantic style enhancements intelligently."""
    # Placeholder - in real implementation, would analyze and enhance notes
    return notes

def apply_jazz_style_intelligent(notes: List[pretty_midi.Note], analysis: dict, config: PerformanceConfig) -> List[pretty_midi.Note]:
    """Apply jazz style enhancements intelligently."""
    # Placeholder - in real implementation, would analyze and enhance notes
    return notes

def apply_classical_style_intelligent(notes: List[pretty_midi.Note], analysis: dict, config: PerformanceConfig) -> List[pretty_midi.Note]:
    """Apply classical style enhancements intelligently."""
    # Placeholder - in real implementation, would analyze and enhance notes
    return notes

def apply_impressionist_style_intelligent(notes: List[pretty_midi.Note], analysis: dict, config: PerformanceConfig) -> List[pretty_midi.Note]:
    """Apply impressionist style enhancements intelligently."""
    # Placeholder - in real implementation, would analyze and enhance notes
    return notes

def apply_modern_style_intelligent(notes: List[pretty_midi.Note], analysis: dict, config: PerformanceConfig) -> List[pretty_midi.Note]:
    """Apply modern style enhancements intelligently."""
    # Placeholder - in real implementation, would analyze and enhance notes
    return notes

def apply_baroque_style_intelligent(notes: List[pretty_midi.Note], analysis: dict, config: PerformanceConfig) -> List[pretty_midi.Note]:
    """Apply baroque style enhancements intelligently."""
    # Placeholder - in real implementation, would analyze and enhance notes
    return notes

def limit_polyphony_human_like(notes: List[pretty_midi.Note], max_notes: int = 6) -> List[pretty_midi.Note]:
    """
    Limit polyphony to realistic human hand limits.
    Prioritizes melody notes and removes overlapping notes intelligently.
    """
    if len(notes) <= max_notes:
        return notes
    
    # Sort notes by importance (velocity, duration, and position)
    def note_importance(note):
        # Higher velocity = more important
        # Longer duration = more important  
        # Higher pitch = more important (melody)
        return (note.velocity * 0.4 + 
                (note.end - note.start) * 0.3 + 
                note.note * 0.3)
    
    # Sort by importance and keep top notes
    sorted_notes = sorted(notes, key=note_importance, reverse=True)
    return sorted_notes[:max_notes]

def add_intelligent_sustain_pedal(inst: pretty_midi.Instrument, analysis: dict):
    """Add intelligent sustain pedal based on musical analysis."""
    # Placeholder - in real implementation, would add sustain pedal events
    pass






































