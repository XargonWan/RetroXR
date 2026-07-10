# Plan: Self-describing persistence (kill the per-type registration table)

## Context

Adding a spawnable object today requires touching THREE registration points in
`RetroVR/Scripts/Data/scene_persistence.gd` — a `const *_SCENE` preload, an
`elif node is X:` branch in `_serialize_node`, and a `"type"` case in
`_deserialize_object` — a file unrelated to the object being added. Forgetting
is **silent**: `_serialize_node` returns `{}` and the object simply vanishes
from saves. Because `NetObjectSync` uses the same serializer as its wire
format, a forgotten type is ALSO invisible to multiplayer snapshots and spawn
replication (empty serialization → `_register_host` returns false → skipped).

This bit us for real: trash cans were silently dropped from scene saves and
netplay snapshots until 885b3da. That's a *category* of bug — this plan
deletes the category.

## Design — objects describe themselves

Godot stamps every instantiated scene with `node.scene_file_path`. Use it as
the identity; state moves into optional duck-typed hooks on the object itself.

### Wire/save format (new entries)

```gdscript
{
  "id": 7,
  "scene": "res://Scenes/Objects/trash_can.tscn",   # node.scene_file_path
  "position": [x, y, z],
  "rotation": [x, y, z],
  "state": { ... }        # optional: node.persist_state(), omitted when absent
}
```

### Generic serialize (replaces the elif chain)

```gdscript
func _serialize_node(node: Node, id: int, node_to_id: Dictionary) -> Dictionary:
    if node.scene_file_path.is_empty() \
            or not node.scene_file_path.begins_with(SPAWNABLE_PREFIX):
        return {}   # side-effect nodes (cables, plugs) keep serializing empty
    var entry := { "id": id, "scene": node.scene_file_path,
        "position": [...], "rotation": [...] }
    if node.has_method("persist_state"):
        entry["state"] = node.persist_state()
    return entry
```

### Generic deserialize

```gdscript
const SPAWNABLE_PREFIX := "res://Scenes/Objects/"   # whitelist — a tampered
# save file must not be able to instantiate arbitrary scenes.

func _deserialize_object(data: Dictionary) -> Node3D:
    var scene_path := str(data.get("scene", LEGACY_TYPES.get(data.get("type"), "")))
    if not scene_path.begins_with(SPAWNABLE_PREFIX):
        return null
    var obj := (load(scene_path) as PackedScene).instantiate() as Node3D
    if obj and obj.has_method("apply_persist_state"):
        obj.apply_persist_state(data.get("state", {}))
    return obj
```

### Per-object hooks (state lives NEXT to the state it saves)

```gdscript
# cartridge.gd — replaces the central rom_path/game_label/save_id/systemid branch
func persist_state() -> Dictionary:
    return {"rom_path": rom_path, "game_label": game_label,
            "save_id": save_id, "systemid": systemid}

func apply_persist_state(s: Dictionary) -> void:
    rom_path = str(s.get("rom_path", ""))
    game_label = str(s.get("game_label", ""))
    save_id = str(s.get("save_id", ""))
    systemid = str(s.get("systemid", ""))
```

Objects needing hooks (mine their current serialize branches for the fields):
RetroSystem (systemid, power is handled separately), RetroTV (crt_enabled,
scale_factor), RetroCartridge (+ RetroDisc inherits the hooks — the
disc-before-cartridge branch-order trap DISAPPEARS), MemoryCard (card_id,
card_label), PDFBook (pdf_path, size_scale, half_pages, page_state/leaf),
VCRPlayer, VCRTape. Stateless (no hooks needed): TVRemote, TrashCan, RayGun,
RetroController (its port link is wiring, below).

## What stays in the persistence layer (unchanged)

These are RELATIONSHIPS between entries, not per-object state — they don't
grow when new object types are added:

- Cross-object wiring pass 2: `snapped_cartridge_id`, TV↔system cable
  connections, controller plugs → ports, memory card seating
  (`scene_persistence.gd` restore pass around :263, system entry fields).
- Power-off-before-save sweep (`:142`).
- `NetObjectSync._file_desc` / `_augment_file_fields` / `_resolve_file_fields`
  (rom/pdf/video md5 resolution) — keyed by class, stable. Could later become
  a `persist_file_desc()` hook too, but NOT in this pass (verify-only ROM
  policy code is netplay-sensitive).

## Compatibility

- **Old saves**: keep a `LEGACY_TYPES: Dictionary` (type string → scene path,
  one line per historical type: system/tv/tv_remote/cartridge/disc/
  memory_card/book/retro_controller/ray_gun/vcr_player/vcr_tape/trash_can) on
  the READ path only. Write the new `"scene"` format going forward. Bump
  `VERSION` to 2 (loader accepts both).
- **Netplay wire format**: both peers must run the same build (already true —
  PROTOCOL_VERSION gate in NetworkManager). The snapshot/spawn entries change
  shape identically on both ends since they flow through `_serialize_node`.
  Consider bumping PROTOCOL_VERSION to be explicit.

## The permanent guard

Promote the throwaway round-trip probe (see 885b3da's verification) into a
kept test: `Tools/persistence_roundtrip_probe.gd` iterating EVERY .tscn under
`res://Scenes/Objects/` that is in the "spawned" group after instantiation —
serialize → assert non-empty → deserialize → assert same scene + state
round-trips. Run headless in the compile-check step. A new spawnable that
somehow can't round-trip fails LOUDLY at probe time instead of silently
losing objects.

## Steps

1. Add hooks (`persist_state`/`apply_persist_state`) to the 7 stateful object
   scripts, mirroring their current central branches exactly.
2. Rewrite `_serialize_node` generic path + `SPAWNABLE_PREFIX` whitelist;
   keep wiring/power passes untouched.
3. Rewrite `_deserialize_object` with `LEGACY_TYPES` fallback; VERSION 2.
4. Delete the per-type consts/branches; run the round-trip probe (all types,
   old-format entries too).
5. Netplay smoke: host+client snapshot with a mixed room (each object type),
   verify identical world on the client. Bump PROTOCOL_VERSION.
6. Load a REAL pre-change save file from disk and verify every object returns.

## Risks

- Missed field in a hook migration → object loads with defaults. Mitigate by
  diffing each hook against the old branch field-by-field (step 1 is
  mechanical) and step 6's real-save load.
- `scene_file_path` is empty for nodes built in code (not scene instances) —
  everything the spawn menu creates is a scene instance, so fine; the probe
  catches violations.
- Saves become path-coupled: renaming/moving a .tscn breaks old saves unless
  LEGACY_TYPES (or a rename map) covers it. Convention: don't move scenes
  under Scenes/Objects/, or add the old path to the map when you must.
