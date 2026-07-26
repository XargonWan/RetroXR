# Multiplayer — Player 2/3/4 Support

## Goal
Allow additional players to join a hosted session and share the arcade room. Port assignment is determined by join order: first to join is player 2, second is player 3, etc. Each player plugs their own physical controller into a system's numbered ports.

## Prerequisite
**Ray-Gun Support / Controller Port System must be implemented first.** This plan assumes:
- Systems already have 4 physical controller port snap zones (labeled 1-4) on the front
- Regular controllers and light guns already use the plug-into-port mechanic
- `SetJoypadState(port, ...)` and lightgun methods already exposed on the Libretro node
- Port-to-device type assignment already handled by `system.gd`

Multiplayer builds on top of this — it does NOT re-implement the port system.

## Port Assignment Model
- Player 1 = the host (port 0, leftmost slot "1")
- Player 2 = first to join (port 1, slot "2")
- Player 3 = second to join (port 2, slot "3")
- Player 4 = third to join (port 3, slot "4")

When a remote player joins, the system highlights their assigned port slot (glow effect) to show them which plug goes where. The remote player then physically picks up a controller in their own space and plugs it in.

## Current State
- **No networking code** exists (only `web_file_server.gd` for ROM HTTP serving)
- **InputHandler C++ supports multiple ports** — already used by the controller port system (from ray-gun plan)
- **Godot has built-in multiplayer** via `MultiplayerAPI`, `ENetMultiplayerPeer`, WebSocket, etc.
- **Scene objects** are already persistable via `scene_persistence.gd`

## Implementation Plan

### Phase 1: Networking Foundation
1. **Create `network_manager.gd`**:
   - Host: Creates `ENetMultiplayerPeer` server on a configurable port (default 7777)
   - Join: Connects to host IP
   - Assigns player IDs by join order: `peer_id → player_index` (1=host, 2=first join, etc.)
   - Handles connect/disconnect events — free `remote_player` node on disconnect
   - Emits `player_joined(player_index)`, `player_left(player_index)` signals
2. **Add multiplayer UI to spawn menu**:
   - "Host Game" button → shows local IP + port
   - "Join Game" field → enter host IP
   - Player list: shows connected players with their assigned port numbers

### Phase 2: Player Representation
1. **Create `remote_player.gd`**:
   - Spawned by host for each remote peer
   - Syncs head transform + both hand transforms via `MultiplayerSynchronizer`
   - Visual: floating head mesh + hand meshes (ghostly appearance, no body)
   - Labeled with "P2", "P3", etc. via Label3D above head
2. **Scene replication**:
   - Spawned objects (systems, TVs, cartridges, controllers) sync via `MultiplayerSpawner`
   - Object ownership: whoever grabs an object owns it for that frame's transform authority
   - Cable connections and port snaps sync as RPCs

### Phase 3: Port Highlighting for Remote Players
1. **When player joins**, their assigned port slot on all systems glows:
   - Host calls RPC: `highlight_port(player_index)` on all clients
   - Each system's port snap zone for that player_index lights up (e.g., green for P2)
   - Glow stays until that player plugs in a controller
2. **Controller plug-in is local for each player**:
   - Each remote player spawns and plugs in a controller in their own local scene
   - The plug action is replicated (RPC) to the host
   - Host's `system.gd._on_port_snapped(port_index, controller)` runs authoritatively

### Phase 4: Input Routing for Remote Players
1. **Remote player sends input to host as RPC** (not via Godot Input actions):
   - Remote `retro_controller.gd` reads VR input locally
   - Sends `rpc("send_input", port_index, button_mask, ax, ay, rx, ry)` to host each physics frame
   - Host calls `libretro_node.SetJoypadState(port_index, ...)` with received data
2. **Light gun remote input**:
   - Remote gun computes lightgun XY locally (it can see the replicated TV mesh transform)
   - Sends `rpc("send_lightgun", port_index, x, y, offscreen, buttons)` to host
   - Host calls `libretro_node.SetLightgunPosition(...)` etc.
3. **Latency note**: Input lag from network latency is unavoidable without netplay rollback — acceptable for local network play, documented limitation for online

### Phase 5: Video/Audio for Remote Players
1. **Video**: Host runs Libretro and renders to the screen mesh — remote players see it via replicated scene
   - The physical arcade metaphor (Option C) means everyone is looking at the same virtual TV: no streaming needed
   - Remote players' `MultiplayerSynchronizer` receives the TV node transform; they see it in their own space at the same position
2. **Audio**: Spatial audio from the TV node — remote players hear it spatially based on their head position relative to the TV

## Key Files to Modify
- `RetroVR/Scripts/Objects/system.gd` — Port highlight RPC, authoritative port-snap handling
- `RetroVR/Scripts/Objects/retro_controller.gd` — Send input RPC when remote player
- `RetroVR/Scripts/Objects/ray_gun.gd` — Send lightgun RPC when remote player
- `RetroVR/Scripts/UI/spawn_menu_controller.gd` — Multiplayer UI tab
- `RetroVR/project.godot` — Network config, multiplayer spawner setup

## New Files
- `RetroVR/Scripts/Net/network_manager.gd` — Host/join, player ID assignment
- `RetroVR/Scripts/Net/remote_player.gd` — Remote player avatar + sync
- `RetroVR/Scenes/Net/remote_player.tscn` — Floating head + hands scene

## Risks
- Latency: RPC input adds lag; fine for local network, noticeable online
- Scene sync grows complex with many interactive objects — start with minimal replication
- VR multiplayer requires all players to have Quest headsets
- Port ordering assumes players don't disconnect/reconnect mid-game — handle gracefully

## Verification
1. Host on one Quest, join from second Quest → see each other's avatars
2. First player to join gets port 2 highlighted on all systems
3. Remote player picks up controller in their space, plugs into their port slot → host's Libretro receives input on port 1
4. Remote player plugs in a ray gun → host registers lightgun on that port
5. Both players see the game on the shared TV; audio is spatial
6. Remote player disconnects → avatar removed, port slot dims
