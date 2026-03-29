# VR Controller Button Remapping

## Goal
Allow users to remap Quest controller buttons, d-pad, and analog sticks to libretro inputs, with persistence. Support per-system or global profiles.

## Current State
- **Hardcoded mappings** in `vr_input_mapper.gd` (lines 291-321):
  ```
  Right A → RETRO_JOYPAD_A
  Right B → RETRO_JOYPAD_B
  Left X  → RETRO_JOYPAD_X
  Left Y  → RETRO_JOYPAD_Y
  Left stick → d-pad (fixed)
  Right stick → RETRO_ANALOG_RIGHT (fixed)
  (etc.)
  ```
- **No remapping UI** or persistence
- **Input flows through Godot Input actions** (`Input.action_press("RETRO_JOYPAD_A")`)
- **Wrapper._process()** polls these actions and maps to libretro button bitmask

## Remappable Inputs

### Buttons (can remap to any libretro joypad button)
| VR Source | Default Target |
|-----------|---------------|
| Right A | RETRO_JOYPAD_A |
| Right B | RETRO_JOYPAD_B |
| Left X | RETRO_JOYPAD_X |
| Left Y | RETRO_JOYPAD_Y |
| Right trigger | RETRO_JOYPAD_R2 |
| Left trigger | RETRO_JOYPAD_L2 |
| Right grip | RETRO_JOYPAD_R |
| Left grip | RETRO_JOYPAD_L |
| Right stick click | RETRO_JOYPAD_START |
| Left stick click | RETRO_JOYPAD_SELECT |

### Sticks (can only remap to libretro analog axes — not buttons)
| VR Source | Default Target | Remappable To |
|-----------|---------------|---------------|
| Left stick | RETRO_ANALOG_LEFT | Any analog axis (LEFT or RIGHT, X or Y) |
| Right stick | RETRO_ANALOG_RIGHT | Any analog axis (LEFT or RIGHT, X or Y) |

### D-pad (can only remap to libretro analog axes — not buttons)
| VR Source | Default Target | Remappable To |
|-----------|---------------|---------------|
| Left stick (thresholded) | RETRO_JOYPAD_UP/DOWN/LEFT/RIGHT | Any analog axis (LEFT or RIGHT, X or Y) |

**Constraint**: Sticks and d-pad are only remappable between analog axes. This prevents nonsensical mappings (e.g., "right stick = START button"). The d-pad is currently derived from the left stick with a threshold; remapping the left stick to a different analog axis also moves the d-pad source.

## Implementation Plan

### Phase 1: Data-Driven Mapping
1. **Replace hardcoded mappings with two dictionaries** in `vr_input_mapper.gd`:
   ```gdscript
   # Button bindings: VR input name → RETRO_JOYPAD_* action string
   var button_map: Dictionary = {
       "ax_button": "RETRO_JOYPAD_A",
       "bx_button": "RETRO_JOYPAD_B",
       "by_button": "RETRO_JOYPAD_X",
       "ay_button": "RETRO_JOYPAD_Y",
       "trigger_right": "RETRO_JOYPAD_R2",
       "trigger_left": "RETRO_JOYPAD_L2",
       "grip_right": "RETRO_JOYPAD_R",
       "grip_left": "RETRO_JOYPAD_L",
       "primary_click_right": "RETRO_JOYPAD_START",
       "primary_click_left": "RETRO_JOYPAD_SELECT",
   }

   # Analog stick bindings: VR stick name → RETRO_ANALOG_* target
   # Values: "left", "right" (which libretro analog slot to drive)
   var stick_map: Dictionary = {
       "stick_left": "left",   # also drives d-pad threshold
       "stick_right": "right",
   }
   ```
2. **Refactor `_map_inputs()`** to iterate over both dictionaries
3. **D-pad derives from the stick mapped to "left"** by default; if stick_left is remapped to "right", d-pad follows it

### Phase 2: Persistence
1. **Save/load to JSON file**:
   - Path: `user://controller_bindings.json`
   - Structure:
     ```json
     {
       "global": {
         "buttons": { "ax_button": "RETRO_JOYPAD_A", ... },
         "sticks": { "stick_left": "left", "stick_right": "right" }
       },
       "per_system": {
         "nes": {
           "buttons": { "ax_button": "RETRO_JOYPAD_B", ... },
           "sticks": { "stick_left": "left", "stick_right": "right" }
         }
       }
     }
     ```
2. **Create `controller_bindings.gd`** (static helper):
   - `load_bindings() → Dictionary`
   - `save_bindings(bindings: Dictionary)`
   - `get_bindings_for_system(systemid: String) → Dictionary`
3. **Load on attach**: When controller plugs into a system port, load bindings for that system's `systemid`
4. **Fallback chain**: Per-system → Global → Default (hardcoded)

### Phase 3: Remapping UI
1. **Add "Controls" section to spawn menu Options tab**:
   - **Buttons section**: List of VR button sources → dropdown of RETRO_JOYPAD_* targets
     - Tap a row → "listen mode" → press a VR button → assigns that button as the new target
   - **Sticks section**: Left stick and Right stick → dropdown of analog targets (LEFT, RIGHT only)
     - Simple 2-row section, no listen mode needed (just pick from dropdown)
   - **Reset to Default** button
   - **Save as Global** / **Save for [System Name]** toggle
2. **Visual feedback**: Listen mode highlights the active row, shows "Press a button..."
3. **Validation**: Sticks dropdowns only show analog options — buttons section only shows joypad button options

### Phase 4: Profile Management
1. **Default profiles** for common systems:
   - NES: A=A, B=B, sticks=default
   - SNES: A=A, B=B, X=X, Y=Y, L=L, R=R
   - N64: Complex (Z-trigger, C-buttons via right stick) — documented sensible default
   - PlayStation: Cross=B, Circle=A, Square=Y, Triangle=X (Japanese layout convention)
2. **Export/import**: Optional, copy JSON to clipboard

## Key Files to Modify
- `RetroVR/Scripts/vr_input_mapper.gd` — Two-dictionary data-driven mapping, load bindings on port-plug
- `RetroVR/Scripts/UI/spawn_menu.gd` — Add Controls section to Options tab
- `RetroVR/Scripts/Objects/system.gd` — Pass `systemid` to controller on port snap

## New Files
- `RetroVR/Scripts/Data/controller_bindings.gd` — Load/save/query binding profiles
- `RetroVR/Scripts/UI/controls_remap_panel.gd` — Remapping UI logic

## Verification
1. Open spawn menu → Options → Controls
2. See buttons section and sticks section listed separately
3. Tap "Right A" row → press Right B on controller → mapping changes to B
4. Sticks section: change Left stick to drive RIGHT analog → left stick now controls right analog in-game
5. Sticks dropdown does NOT offer button targets (joypad buttons not listed)
6. Save as global → plug controller into system → verify new mapping works
7. Save as per-system for NES → switch to SNES system → SNES uses global (not NES override)
8. Restart → bindings persist from JSON file
9. "Reset to Default" restores original hardcoded mappings
