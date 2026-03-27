# Multiplayer — Player 2/3/4 Support

## Goal
Allow additional players to join a hosted session and act as player 2/3/4 for libretro emulation, sharing the same arcade room.

## Current State
- **No networking code** exists (only `web_file_server.gd` for ROM HTTP serving)
- **InputHandler C++ already supports multiple ports** (0-3):
  - `SetJoypadButtonStates(port, states)` — port parameter exists
  - `SetAnalogLeft(port, x, y)` — per-port analog
  - All getter/state callbacks route by port
- **Only port 0 is used** — hardcoded in `Wrapper._process()` and `_input()`
- **Godot has built-in multiplayer** via `MultiplayerAPI`, `ENetMultiplayerPeer`, WebSocket, etc.
- **VRInputMapper** attaches to one system at a time, routes to global `Input` actions

## Implementation Plan

### Phase 1: Local Multi-Port Input (No Networking)
Before networking, enable multiple input sources hitting different libretro ports:

1. **Extend `Wrapper.cpp` `_process()`** to poll input for ports 1-3:
   - Define additional input action sets: `RETRO_P2_JOYPAD_A`, `RETRO_P2_JOYPAD_B`, etc.
   - Or: use Godot's `Input.get_joy_axis()` / `Input.is_joy_button_pressed()` for physical gamepads
   - Map physical gamepad 0 → port 0, gamepad 1 → port 1, etc.
2. **Expose `SetInputPort(port)` to GDScript** on Libretro node:
   - VRInputMapper can set which port its input routes to
   - Default: port 0

### Phase 2: Networking Foundation
1. **Create `network_manager.gd`**:
   - Host: Creates `ENetMultiplayerPeer` server on a configurable port
   - Join: Connects to host IP:port
   - Assigns player IDs (host = player 1, first join = player 2, etc.)
   - Handles connect/disconnect events
2. **Add multiplayer UI to spawn menu**:
   - "Host Game" button (starts server, shows IP/code)
   - "Join Game" field (enter host IP or code)
   - Player list showing connected players

### Phase 3: Player Representation
1. **Create `remote_player.gd`**:
   - Represents another player in the scene
   - Syncs head + hand positions (XRCamera3D + 2x XRController3D transforms)
   - Visual: Floating head + hands (no body needed, common VR multiplayer pattern)
   - Uses `MultiplayerSynchronizer` for transform replication
2. **Scene replication**:
   - Spawned objects (systems, TVs, cartridges) sync via `MultiplayerSpawner`
   - Object pickups: ownership transfers to the grabbing player
   - Cable connections sync as RPCs

### Phase 4: Input Routing for Remote Players
1. **Remote player input → libretro port mapping**:
   - Host runs the emulation (Libretro node is authoritative)
   - Remote players send their input state as RPCs to the host
   - Host feeds remote input into port 1/2/3 via `InputHandler.SetJoypadButtonStates(port, states)`
2. **Modify `VRInputMapper`**:
   - When attached to a system, send input as RPC if not host
   - Host receives RPC, maps to correct port based on player ID
3. **Port assignment**:
   - When a player attaches to a system, assign them the next available port
   - Display port number on the "CONTROLLED" label (e.g., "P2 CONTROLLED")

### Phase 5: Video/Audio Sync for Remote Players
1. **Video**: Host already renders to screen mesh texture — remote players see it via scene sync
   - If using `MultiplayerSynchronizer`, the texture updates happen locally since the mesh is replicated
   - **Challenge**: Libretro runs on host only, so remote players need texture data
   - **Option A**: Stream compressed frames via RPC (high bandwidth)
   - **Option B**: Each client runs their own Libretro instance with synced input (netplay-style)
   - **Option C**: Only the host's TV displays the game; remote players physically look at the same TV in VR (simplest, most immersive)
   - **Recommended**: Option C — it's a shared arcade room, everyone looks at the same TV
2. **Audio**: Host's audio plays spatially from the TV — remote players hear it via spatial audio (no extra sync needed if in same virtual room)

## Key Files to Modify
- `libretro-godot/src/Wrapper.cpp` — Multi-port input polling
- `libretro-godot/src/Libretro.hpp/.cpp` — Expose port control to GDScript
- `RetroVR/Scripts/vr_input_mapper.gd` — Port selection, RPC input sending
- `RetroVR/project.godot` — Add multiplayer input actions, network config
- `RetroVR/Scripts/UI/spawn_menu_controller.gd` — Multiplayer UI tab

## New Files
- `RetroVR/Scripts/Net/network_manager.gd` — Host/join, player management
- `RetroVR/Scripts/Net/remote_player.gd` — Remote player avatar + sync
- `RetroVR/Scenes/Net/remote_player.tscn` — Remote player scene (head + hands)

## Complexity Warning (from wish list)
This is the most complex feature. Recommended approach:
1. **Start with Phase 1** (local multi-gamepad) — useful on its own
2. **Phase 2-3** (networking + avatars) — significant effort but well-documented in Godot
3. **Phase 4-5** (input routing + display) — the VR arcade metaphor (Option C) greatly simplifies this

## Risks
- Latency: Input sent over network adds lag to emulation
- Godot's multiplayer API works well for transforms but custom data (input states) needs careful RPC design
- VR multiplayer requires both players to have Quest headsets
- Scene sync complexity grows with number of interactive objects

## Verification
1. **Phase 1**: Connect two physical gamepads, both control different players in a 2-player game
2. **Phase 2-3**: Two Quest headsets on same network, one hosts, one joins — see each other's avatars
3. **Phase 4**: Player 2 attaches to same system as player 1, controls map to port 1
4. **Phase 5**: Both players see the game on the same TV, audio is spatial
