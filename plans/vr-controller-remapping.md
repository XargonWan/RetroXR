# VR Controller Button Remapping

## Goal
Allow users to remap Quest controller buttons to libretro joypad inputs, with persistence (save/load bindings). Support per-system or global profiles.

## Current State
- **Hardcoded mappings** in `vr_input_mapper.gd` (lines 291-321):
  ```
  Right A → RETRO_JOYPAD_A
  Right B → RETRO_JOYPAD_B
  Left X  → RETRO_JOYPAD_X
  Left Y  → RETRO_JOYPAD_Y
  (etc.)
  ```
- **No remapping UI** or persistence
- **Input flows through Godot Input actions** (`Input.action_press("RETRO_JOYPAD_A")`)
- **Wrapper._process()** polls these actions and maps to libretro button bitmask
- **Scene persistence** (`scene_persistence.gd`) handles object save/load but not input config

## Implementation Plan

### Phase 1: Data-Driven Mapping
1. **Replace hardcoded mappings with a dictionary** in `vr_input_mapper.gd`:
   ```gdscript
   var button_map: Dictionary = {
       "ax_button": "RETRO_JOYPAD_A",      # Right A
       "bx_button": "RETRO_JOYPAD_B",      # Right B
       "by_button": "RETRO_JOYPAD_X",      # Left X
       "ay_button": "RETRO_JOYPAD_Y",      # Left Y
       "trigger_right": "RETRO_JOYPAD_R2",
       "trigger_left": "RETRO_JOYPAD_L2",
       "grip_right": "RETRO_JOYPAD_R",
       "grip_left": "RETRO_JOYPAD_L",
       "primary_click_right": "RETRO_JOYPAD_START",
       "primary_click_left": "RETRO_JOYPAD_SELECT",
   }
   ```
2. **Refactor `_map_inputs()`** to iterate over `button_map` instead of hardcoded if/else chain
3. **Stick mappings** (d-pad, analog) remain fixed (no good reason to remap sticks)

### Phase 2: Persistence
1. **Save/load to JSON file**:
   - Path: `user://controller_bindings.json`
   - Structure:
     ```json
     {
       "global": { "ax_button": "RETRO_JOYPAD_A", ... },
       "per_system": {
         "nes": { "ax_button": "RETRO_JOYPAD_B", ... },
         "snes": { ... }
       }
     }
     ```
2. **Create `controller_bindings.gd`** (static helper):
   - `load_bindings() → Dictionary`
   - `save_bindings(bindings: Dictionary)`
   - `get_bindings_for_system(systemid: String) → Dictionary` — returns per-system if exists, else global
3. **Load on attach**: When VRInputMapper attaches to a system, load bindings for that system's `systemid`
4. **Fallback chain**: Per-system → Global → Default (hardcoded)

### Phase 3: Remapping UI
1. **Add "Controls" section to spawn menu Options tab**:
   - List of VR buttons (left column) → mapped libretro action (right column)
   - Tap a row to enter "listen mode" → press desired VR button → assigns mapping
   - "Reset to Default" button
   - "Save as Global" / "Save for [System Name]" toggle
2. **UI implementation**:
   - Reuse existing spawn menu SubViewport pattern
   - Grid of `Button` nodes or `ItemList`
   - Each row: `[VR Button Label] → [Libretro Action Dropdown]`
3. **Visual feedback**: When in listen mode, highlight the active row, show "Press a button..."

### Phase 4: Profile Management
1. **Default profiles** for common systems:
   - NES: A=A, B=B (simple)
   - SNES: A=A, B=B, X=X, Y=Y, L=L, R=R
   - N64: Complex mapping (Z-trigger, C-buttons) — provide a sensible default
   - PlayStation: Cross=B, Circle=A, Square=Y, Triangle=X (Japanese layout)
2. **Export/import profiles** (optional): Copy JSON to clipboard or share file

## Key Files to Modify
- `RetroVR/Scripts/vr_input_mapper.gd` — Data-driven mapping, load bindings on attach
- `RetroVR/Scripts/UI/spawn_menu.gd` — Add Controls section to Options tab
- `RetroVR/Scripts/Objects/system.gd` — Pass `systemid` to input mapper on attach

## New Files
- `RetroVR/Scripts/Data/controller_bindings.gd` — Load/save/query binding profiles
- `RetroVR/Scripts/UI/controls_remap_panel.gd` — Remapping UI logic

## Verification
1. Open spawn menu → Options → Controls
2. See current button mappings listed
3. Tap "Right A" row → press Right B on controller → mapping changes to B
4. Save as global → close menu → attach to system → verify new mapping works
5. Save as per-system for NES → switch to SNES system → verify SNES uses global (not NES override)
6. Restart game → verify bindings persist from JSON file
7. "Reset to Default" restores original hardcoded mappings
