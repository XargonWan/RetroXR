#pragma once

// Verlet rope — PBD rope simulation between two 3D anchor points. Ported from
// Scripts/Objects/cables/verlet_rope.gd, which this replaces; the GDScript
// version was the single largest CPU item in a scene full of cables (~460 us
// per rope per physics tick plus ~157 us per rendered frame to re-mesh the
// tube), and essentially all of that was interpreter overhead in the solver's
// inner loops rather than real work.
//
// The behaviour is meant to be indistinguishable from the GDScript original —
// same constraints in the same order, same contact caching, same sleep rules.
// Tools/rope_bench.tscn A/Bs the cost and renders a settled cable for
// comparison; a settled cable must look the same as it did before.
//
// Constraints, in solve order, all iteration-count-independent:
//   - Stretch: distance constraints between neighbours (stretch_stiffness).
//   - Bend: hierarchical, toward the midpoint of neighbours at spacing 1/2/4…,
//     with a max_bend_degrees free allowance.
//   - End stiffness: a strain-relief stub holding the first/last few segments
//     straight, plus a directional stub for an end whose plug orientation is
//     externally fixed.
//   - Cached contact planes, per particle and per segment midpoint.

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/physics_ray_query_parameters3d.hpp>
#include <godot_cpp/classes/physics_shape_query_parameters3d.hpp>
#include <godot_cpp/classes/rigid_body3d.hpp>
#include <godot_cpp/classes/shader.hpp>
#include <godot_cpp/classes/shader_material.hpp>
#include <godot_cpp/classes/sphere_shape3d.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include <vector>

namespace Xenu
{

class VerletRope : public godot::MeshInstance3D
{
    GDCLASS(VerletRope, godot::MeshInstance3D)

public:
    VerletRope() = default;
    ~VerletRope() override = default;

    void _ready() override;
    void _process(double p_delta) override;
    void _physics_process(double p_delta) override;

    // One simulation tick. Bound so a bench can drive the rope off the engine's
    // callback and time it directly; _physics_process is just this plus the
    // engine's cadence.
    void Step(double p_delta);
    // Render-time interpolation plus the tube rebuild — the body of _process,
    // bound for the same reason as Step.
    void Remesh();
    bool IsSleeping() const { return m_asleep; }

    // ── Public API used from GDScript ────────────────────────────────────────
    void InitPoints();
    void Wake();
    double RestLength() const;
    godot::PackedVector3Array GetPoints() const;
    void NudgePoint(int p_index, const godot::Vector3 &p_delta);
    void SetRopeLength(double p_length);

    // Anchors. Held as ObjectIDs rather than raw pointers: a plug or a host
    // machine can be freed while the rope still exists, and a stale Node3D* here
    // is a crash rather than a missing cable.
    void SetStartNode(godot::Node3D *p_node);
    godot::Node3D *GetStartNode() const;
    void SetEndNode(godot::Node3D *p_node);
    godot::Node3D *GetEndNode() const;

    // ── Exported properties ──────────────────────────────────────────────────
#define XENU_ROPE_PROP(type, name, member)                                     \
    void Set##name(type v) { member = v; }                                     \
    type Get##name() const { return member; }

    XENU_ROPE_PROP(int, SegmentCount, m_segment_count)
    XENU_ROPE_PROP(double, SegmentLength, m_segment_length)
    XENU_ROPE_PROP(godot::Vector3, Gravity, m_gravity)
    XENU_ROPE_PROP(double, Damping, m_damping)
    XENU_ROPE_PROP(int, ConstraintIterations, m_constraint_iterations)
    XENU_ROPE_PROP(double, StretchStiffness, m_stretch_stiffness)
    XENU_ROPE_PROP(double, BendStiffness, m_bend_stiffness)
    XENU_ROPE_PROP(double, MaxBendDegrees, m_max_bend_degrees)
    XENU_ROPE_PROP(double, TubeRadius, m_tube_radius)
    XENU_ROPE_PROP(int, TubeSides, m_tube_sides)
    XENU_ROPE_PROP(int, Smoothing, m_smoothing)
    XENU_ROPE_PROP(int, SurfaceCollisionMask, m_surface_collision_mask)
    XENU_ROPE_PROP(double, CollisionRadius, m_collision_radius)
    XENU_ROPE_PROP(double, SurfaceFriction, m_surface_friction)
    XENU_ROPE_PROP(int, RaycastInterval, m_raycast_interval)
    XENU_ROPE_PROP(bool, SelfCollision, m_self_collision)
    XENU_ROPE_PROP(double, AnchorPull, m_anchor_pull)
    XENU_ROPE_PROP(double, EndAlignStiffness, m_end_align_stiffness)
    XENU_ROPE_PROP(godot::Vector3, PlugExitAxis, m_plug_exit_axis)
    XENU_ROPE_PROP(godot::Vector3, StartAnchorOffset, m_start_anchor_offset)
    XENU_ROPE_PROP(godot::Vector3, EndAnchorOffset, m_end_anchor_offset)
    XENU_ROPE_PROP(double, EndStiffness, m_end_stiffness)
    XENU_ROPE_PROP(int, EndStiffSegments, m_end_stiff_segments)
#undef XENU_ROPE_PROP

    void SetRopeColor(const godot::Color &p_color);
    godot::Color GetRopeColor() const { return m_rope_color; }

protected:
    static void _bind_methods();

private:
    // ── Simulation ───────────────────────────────────────────────────────────
    void Integrate(double p_delta);
    void SolveConstraints(bool p_start_fixed, bool p_end_fixed,
                          const godot::Vector3 &p_start_exit,
                          const godot::Vector3 &p_end_exit);
    void ApplyContactFriction();
    void SolveSelfCollision();
    void SolveSurfaceCollision(bool p_do_rest);
    void ApplyAnchorCoupling();
    void UpdateSleepState();

    inline void SolvePair(int a, int b, double rest, double k);
    inline void SolveBend(int b, int spacing, double allowed_dev, double k);
    inline void SolveMidContact(int i);
    inline void ProjectPlane(int i, const godot::Vector3 &cp, const godot::Vector3 &n);
    inline void PinAnchors();
    inline void ResolveContact(int i, const godot::Vector3 &contact, const godot::Vector3 &normal);
    double StubWeight(double base, int k, int n) const;
    bool PlaneValid(int i, const godot::Vector3 &cp, const godot::Vector3 &n) const;

    // ── Anchors ──────────────────────────────────────────────────────────────
    godot::Vector3 AnchorPoint(godot::Node3D *node, const godot::Vector3 &offset,
                               const godot::Vector3 &fallback) const;
    bool AnchorsMoved() const;
    bool PlugIsFixed(godot::Node3D *node) const;
    godot::Vector3 PlugExitDir(godot::Node3D *node) const;
    void AlignAnchorPlug(godot::Node3D *node, const godot::Vector3 &target_dir, double k);
    void RefreshExclusions();
    // Resolved once per tick so the hot paths don't repeat the ObjectDB lookup.
    void CacheAnchors();

    // ── Rendering ────────────────────────────────────────────────────────────
    void BuildTrigTables();
    void BuildMeshTopology();
    void FillRingPoints();
    void RenderTube();
    void SnapshotRenderState();
    int Subdiv() const { return m_smoothing + 1; }
    void SleepNow();
    void OpenExcursionWindow();

    // ── State ────────────────────────────────────────────────────────────────
    std::vector<godot::Vector3> m_points;
    std::vector<godot::Vector3> m_prev_points;
    std::vector<float> m_inv_mass;

    std::vector<uint8_t> m_mid_contact;
    std::vector<godot::Vector3> m_mid_contact_point;
    std::vector<godot::Vector3> m_mid_contact_normal;

    std::vector<uint8_t> m_c_flags;
    std::vector<godot::Vector3> m_c_p1;
    std::vector<godot::Vector3> m_c_n1;
    std::vector<godot::Vector3> m_c_p2;
    std::vector<godot::Vector3> m_c_n2;
    std::vector<uint8_t> m_stuck_passes;

    std::vector<int> m_active_mid;
    std::vector<int> m_active_contact;

    std::vector<godot::Vector3> m_render_points;
    std::vector<godot::Vector3> m_prev_render;
    std::vector<godot::Vector3> m_curr_render;
    std::vector<godot::Vector3> m_sleep_ref;

    std::vector<float> m_cos_table;
    std::vector<float> m_sin_table;
    std::vector<godot::Vector3> m_ring_points;
    std::vector<godot::Vector3> m_ring_side;
    std::vector<godot::Vector3> m_ring_up;

    // Vertex/attribute staging buffers, reused every frame — the region upload
    // wants bytes, so the sim writes straight into these.
    godot::PackedByteArray m_vertex_bytes;
    godot::PackedByteArray m_normal_bytes;

    godot::Ref<godot::ShaderMaterial> m_material;
    godot::Ref<godot::PhysicsRayQueryParameters3D> m_ray_query;
    godot::Ref<godot::PhysicsShapeQueryParameters3D> m_shape_query;
    godot::Ref<godot::SphereShape3D> m_sphere;

    uint64_t m_start_node_id = 0;
    uint64_t m_end_node_id = 0;
    godot::Node3D *m_start_cached = nullptr;
    godot::Node3D *m_end_cached = nullptr;
    godot::RigidBody3D *m_start_body = nullptr;
    godot::RigidBody3D *m_end_body = nullptr;

    int m_raycast_frame = 0;
    bool m_asleep = false;
    int m_still_frames = 0;
    int m_ref_frames = 0;
    double m_max_excursion_sq = 0.0;
    godot::Vector3 m_sleep_anchor_start;
    godot::Vector3 m_sleep_anchor_end;
    bool m_mesh_dirty = true;
    bool m_interpolating = false;

    // ── Exported values ──────────────────────────────────────────────────────
    int m_segment_count = 15;
    double m_segment_length = 0.06;
    godot::Vector3 m_gravity = godot::Vector3(0, -9.8, 0);
    double m_damping = 0.01;
    int m_constraint_iterations = 5;
    double m_stretch_stiffness = 1.0;
    double m_bend_stiffness = 0.0;
    double m_max_bend_degrees = 0.0;
    double m_tube_radius = 0.005;
    int m_tube_sides = 8;
    int m_smoothing = 0;
    godot::Color m_rope_color = godot::Color(0.15f, 0.15f, 0.15f, 1.0f);
    int m_surface_collision_mask = 7;
    double m_collision_radius = 0.008;
    double m_surface_friction = 0.4;
    int m_raycast_interval = 3;
    bool m_self_collision = false;
    double m_anchor_pull = 0.0;
    double m_end_align_stiffness = 0.0;
    godot::Vector3 m_plug_exit_axis = godot::Vector3(0, 0, -1);
    godot::Vector3 m_start_anchor_offset;
    godot::Vector3 m_end_anchor_offset;
    double m_end_stiffness = 0.0;
    int m_end_stiff_segments = 3;
};

} // namespace Xenu
