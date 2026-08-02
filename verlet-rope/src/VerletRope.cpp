#include "VerletRope.hpp"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/physics_direct_space_state3d.hpp>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/world3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cmath>

using namespace godot;

namespace Xenu
{

namespace
{
// Once every particle has been near-still for SLEEP_FRAMES ticks the rope
// sleeps: the whole sim and the re-mesh are skipped until an anchor moves.
constexpr int SLEEP_FRAMES = 30;
constexpr double SLEEP_POINT_EPS_SQ = 0.0015 * 0.0015;

// Second, slower way to be finished: the rope is oscillating rather than
// stopping. A segment resting near the reach of the rest-info sphere drops in
// and out of detection between throttled passes, so its cached plane vanishes,
// the segment falls for an interval, is re-detected and is pushed back — a
// stable cycle whose per-tick motion never drops under SLEEP_POINT_EPS_SQ. Its
// signature is that it goes nowhere, so track the furthest any particle strays
// from a reference pose and sleep when a whole window fits in a small envelope.
constexpr int SLEEP_REF_FRAMES = 90;
constexpr double SLEEP_EXCURSION_EPS_SQ = 0.012 * 0.012;

constexpr double WAKE_ANCHOR_EPS_SQ = 0.0005 * 0.0005;
// Tighter than the wake threshold: this only costs a tube rebuild, whereas
// waking costs a full solve, so it can afford to notice smaller motion.
constexpr double RENDER_FOLLOW_EPS_SQ = 0.0001 * 0.0001;

constexpr const char *CABLE_SHADER_PATH = "res://Shaders/cable.gdshader";
} // namespace

// ── Binding ─────────────────────────────────────────────────────────────────

#define XENU_BIND_PROP(name, getter, setter, variant_type)                     \
    ClassDB::bind_method(D_METHOD(setter, "value"), &VerletRope::Set##name);   \
    ClassDB::bind_method(D_METHOD(getter), &VerletRope::Get##name);            \
    ADD_PROPERTY(PropertyInfo(variant_type, #name), setter, getter);

void VerletRope::_bind_methods()
{
    // Property names deliberately match the GDScript ones exactly — the two
    // cable scenes and every caller in Scripts/ already use them.
    ClassDB::bind_method(D_METHOD("set_segment_count", "value"), &VerletRope::SetSegmentCount);
    ClassDB::bind_method(D_METHOD("get_segment_count"), &VerletRope::GetSegmentCount);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "segment_count"), "set_segment_count", "get_segment_count");

    ClassDB::bind_method(D_METHOD("set_segment_length", "value"), &VerletRope::SetSegmentLength);
    ClassDB::bind_method(D_METHOD("get_segment_length"), &VerletRope::GetSegmentLength);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "segment_length"), "set_segment_length", "get_segment_length");

    ClassDB::bind_method(D_METHOD("set_gravity", "value"), &VerletRope::SetGravity);
    ClassDB::bind_method(D_METHOD("get_gravity"), &VerletRope::GetGravity);
    ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "gravity"), "set_gravity", "get_gravity");

    ClassDB::bind_method(D_METHOD("set_damping", "value"), &VerletRope::SetDamping);
    ClassDB::bind_method(D_METHOD("get_damping"), &VerletRope::GetDamping);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "damping", PROPERTY_HINT_RANGE, "0.0,1.0"),
                 "set_damping", "get_damping");

    ClassDB::bind_method(D_METHOD("set_constraint_iterations", "value"), &VerletRope::SetConstraintIterations);
    ClassDB::bind_method(D_METHOD("get_constraint_iterations"), &VerletRope::GetConstraintIterations);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "constraint_iterations"),
                 "set_constraint_iterations", "get_constraint_iterations");

    ADD_GROUP("Stiffness", "");
    ClassDB::bind_method(D_METHOD("set_stretch_stiffness", "value"), &VerletRope::SetStretchStiffness);
    ClassDB::bind_method(D_METHOD("get_stretch_stiffness"), &VerletRope::GetStretchStiffness);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "stretch_stiffness", PROPERTY_HINT_RANGE, "0.0,1.0"),
                 "set_stretch_stiffness", "get_stretch_stiffness");

    ClassDB::bind_method(D_METHOD("set_bend_stiffness", "value"), &VerletRope::SetBendStiffness);
    ClassDB::bind_method(D_METHOD("get_bend_stiffness"), &VerletRope::GetBendStiffness);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "bend_stiffness", PROPERTY_HINT_RANGE, "0.0,1.0"),
                 "set_bend_stiffness", "get_bend_stiffness");

    ClassDB::bind_method(D_METHOD("set_max_bend_degrees", "value"), &VerletRope::SetMaxBendDegrees);
    ClassDB::bind_method(D_METHOD("get_max_bend_degrees"), &VerletRope::GetMaxBendDegrees);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_bend_degrees", PROPERTY_HINT_RANGE, "0.0,180.0"),
                 "set_max_bend_degrees", "get_max_bend_degrees");

    ADD_GROUP("Rendering", "");
    ClassDB::bind_method(D_METHOD("set_tube_radius", "value"), &VerletRope::SetTubeRadius);
    ClassDB::bind_method(D_METHOD("get_tube_radius"), &VerletRope::GetTubeRadius);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "tube_radius"), "set_tube_radius", "get_tube_radius");

    ClassDB::bind_method(D_METHOD("set_tube_sides", "value"), &VerletRope::SetTubeSides);
    ClassDB::bind_method(D_METHOD("get_tube_sides"), &VerletRope::GetTubeSides);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "tube_sides"), "set_tube_sides", "get_tube_sides");

    ClassDB::bind_method(D_METHOD("set_smoothing", "value"), &VerletRope::SetSmoothing);
    ClassDB::bind_method(D_METHOD("get_smoothing"), &VerletRope::GetSmoothing);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "smoothing", PROPERTY_HINT_RANGE, "0,3"),
                 "set_smoothing", "get_smoothing");

    ClassDB::bind_method(D_METHOD("set_rope_color", "value"), &VerletRope::SetRopeColor);
    ClassDB::bind_method(D_METHOD("get_rope_color"), &VerletRope::GetRopeColor);
    ADD_PROPERTY(PropertyInfo(Variant::COLOR, "rope_color"), "set_rope_color", "get_rope_color");

    ADD_GROUP("Collision", "");
    ClassDB::bind_method(D_METHOD("set_surface_collision_mask", "value"), &VerletRope::SetSurfaceCollisionMask);
    ClassDB::bind_method(D_METHOD("get_surface_collision_mask"), &VerletRope::GetSurfaceCollisionMask);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "surface_collision_mask", PROPERTY_HINT_LAYERS_3D_PHYSICS),
                 "set_surface_collision_mask", "get_surface_collision_mask");

    ClassDB::bind_method(D_METHOD("set_collision_radius", "value"), &VerletRope::SetCollisionRadius);
    ClassDB::bind_method(D_METHOD("get_collision_radius"), &VerletRope::GetCollisionRadius);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "collision_radius"), "set_collision_radius", "get_collision_radius");

    ClassDB::bind_method(D_METHOD("set_surface_friction", "value"), &VerletRope::SetSurfaceFriction);
    ClassDB::bind_method(D_METHOD("get_surface_friction"), &VerletRope::GetSurfaceFriction);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "surface_friction", PROPERTY_HINT_RANGE, "0.0,1.0"),
                 "set_surface_friction", "get_surface_friction");

    ClassDB::bind_method(D_METHOD("set_raycast_interval", "value"), &VerletRope::SetRaycastInterval);
    ClassDB::bind_method(D_METHOD("get_raycast_interval"), &VerletRope::GetRaycastInterval);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "raycast_interval"), "set_raycast_interval", "get_raycast_interval");

    ClassDB::bind_method(D_METHOD("set_self_collision", "value"), &VerletRope::SetSelfCollision);
    ClassDB::bind_method(D_METHOD("get_self_collision"), &VerletRope::GetSelfCollision);
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "self_collision"), "set_self_collision", "get_self_collision");

    ADD_GROUP("Coupling", "");
    ClassDB::bind_method(D_METHOD("set_anchor_pull", "value"), &VerletRope::SetAnchorPull);
    ClassDB::bind_method(D_METHOD("get_anchor_pull"), &VerletRope::GetAnchorPull);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "anchor_pull"), "set_anchor_pull", "get_anchor_pull");

    ADD_GROUP("End alignment", "");
    ClassDB::bind_method(D_METHOD("set_end_align_stiffness", "value"), &VerletRope::SetEndAlignStiffness);
    ClassDB::bind_method(D_METHOD("get_end_align_stiffness"), &VerletRope::GetEndAlignStiffness);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "end_align_stiffness", PROPERTY_HINT_RANGE, "0.0,1.0"),
                 "set_end_align_stiffness", "get_end_align_stiffness");

    ClassDB::bind_method(D_METHOD("set_plug_exit_axis", "value"), &VerletRope::SetPlugExitAxis);
    ClassDB::bind_method(D_METHOD("get_plug_exit_axis"), &VerletRope::GetPlugExitAxis);
    ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "plug_exit_axis"), "set_plug_exit_axis", "get_plug_exit_axis");

    ClassDB::bind_method(D_METHOD("set_start_anchor_offset", "value"), &VerletRope::SetStartAnchorOffset);
    ClassDB::bind_method(D_METHOD("get_start_anchor_offset"), &VerletRope::GetStartAnchorOffset);
    ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "start_anchor_offset"),
                 "set_start_anchor_offset", "get_start_anchor_offset");

    ClassDB::bind_method(D_METHOD("set_end_anchor_offset", "value"), &VerletRope::SetEndAnchorOffset);
    ClassDB::bind_method(D_METHOD("get_end_anchor_offset"), &VerletRope::GetEndAnchorOffset);
    ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "end_anchor_offset"),
                 "set_end_anchor_offset", "get_end_anchor_offset");

    ClassDB::bind_method(D_METHOD("set_end_stiffness", "value"), &VerletRope::SetEndStiffness);
    ClassDB::bind_method(D_METHOD("get_end_stiffness"), &VerletRope::GetEndStiffness);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "end_stiffness", PROPERTY_HINT_RANGE, "0.0,1.0"),
                 "set_end_stiffness", "get_end_stiffness");

    ClassDB::bind_method(D_METHOD("set_end_stiff_segments", "value"), &VerletRope::SetEndStiffSegments);
    ClassDB::bind_method(D_METHOD("get_end_stiff_segments"), &VerletRope::GetEndStiffSegments);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "end_stiff_segments", PROPERTY_HINT_RANGE, "0,8"),
                 "set_end_stiff_segments", "get_end_stiff_segments");

    // Anchors — plain properties, assigned from GDScript after instancing.
    ClassDB::bind_method(D_METHOD("set_start_node", "node"), &VerletRope::SetStartNode);
    ClassDB::bind_method(D_METHOD("get_start_node"), &VerletRope::GetStartNode);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "start_node", PROPERTY_HINT_NODE_TYPE, "Node3D",
                              PROPERTY_USAGE_NONE),
                 "set_start_node", "get_start_node");

    ClassDB::bind_method(D_METHOD("set_end_node", "node"), &VerletRope::SetEndNode);
    ClassDB::bind_method(D_METHOD("get_end_node"), &VerletRope::GetEndNode);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "end_node", PROPERTY_HINT_NODE_TYPE, "Node3D",
                              PROPERTY_USAGE_NONE),
                 "set_end_node", "get_end_node");

    // Methods. _init_points keeps its GDScript name (leading underscore and
    // all) because every caller in Scripts/ already spells it that way.
    ClassDB::bind_method(D_METHOD("_init_points"), &VerletRope::InitPoints);
    ClassDB::bind_method(D_METHOD("wake"), &VerletRope::Wake);
    ClassDB::bind_method(D_METHOD("rest_length"), &VerletRope::RestLength);
    ClassDB::bind_method(D_METHOD("get_points"), &VerletRope::GetPoints);
    ClassDB::bind_method(D_METHOD("nudge_point", "index", "delta"), &VerletRope::NudgePoint);
    ClassDB::bind_method(D_METHOD("set_rope_length", "length"), &VerletRope::SetRopeLength);
    ClassDB::bind_method(D_METHOD("step", "delta"), &VerletRope::Step);
    ClassDB::bind_method(D_METHOD("remesh"), &VerletRope::Remesh);
    ClassDB::bind_method(D_METHOD("is_sleeping"), &VerletRope::IsSleeping);
}

// ── Anchors ─────────────────────────────────────────────────────────────────

void VerletRope::SetStartNode(Node3D *p_node)
{
    m_start_node_id = p_node ? p_node->get_instance_id() : 0;
    m_start_cached = p_node;
}

Node3D *VerletRope::GetStartNode() const
{
    if (m_start_node_id == 0)
        return nullptr;
    return Object::cast_to<Node3D>(ObjectDB::get_instance(m_start_node_id));
}

void VerletRope::SetEndNode(Node3D *p_node)
{
    m_end_node_id = p_node ? p_node->get_instance_id() : 0;
    m_end_cached = p_node;
}

Node3D *VerletRope::GetEndNode() const
{
    if (m_end_node_id == 0)
        return nullptr;
    return Object::cast_to<Node3D>(ObjectDB::get_instance(m_end_node_id));
}

void VerletRope::CacheAnchors()
{
    m_start_cached = GetStartNode();
    m_end_cached = GetEndNode();
}

Vector3 VerletRope::AnchorPoint(Node3D *node, const Vector3 &offset, const Vector3 &fallback) const
{
    return node ? (node->get_global_transform().xform(offset)) : fallback;
}

// ── Lifecycle ───────────────────────────────────────────────────────────────

void VerletRope::_ready()
{
    // Lit PVC jacket — cable.gdshader derives its normal from a CUSTOM0
    // attribute, because the tube has no normal array (positions are re-uploaded
    // every frame through surface_update_vertex_region, and normals would share
    // that buffer).
    Ref<Shader> shader = ResourceLoader::get_singleton()->load(CABLE_SHADER_PATH);
    m_material.instantiate();
    m_material->set_shader(shader);
    m_material->set_shader_parameter("cable_color", m_rope_color);
    set_as_top_level(true);
    set_global_transform(Transform3D());

    BuildTrigTables();
    BuildMeshTopology();
    InitPoints();

    if (m_surface_collision_mask != 0)
    {
        m_ray_query.instantiate();
        m_ray_query->set_collision_mask(m_surface_collision_mask);
        m_ray_query->set_hit_back_faces(false);
        m_sphere.instantiate();
        // Query slightly beyond the contact distance so a particle RESTING at
        // exactly collision_radius keeps reporting.
        m_sphere->set_radius(m_collision_radius * 1.3);
        m_shape_query.instantiate();
        m_shape_query->set_shape(m_sphere);
        m_shape_query->set_collision_mask(m_surface_collision_mask);
        RefreshExclusions();
    }
}

void VerletRope::SetRopeColor(const Color &p_color)
{
    m_rope_color = p_color;
    if (m_material.is_valid())
        m_material->set_shader_parameter("cable_color", p_color);
}

double VerletRope::RestLength() const
{
    return m_segment_count * m_segment_length;
}

PackedVector3Array VerletRope::GetPoints() const
{
    PackedVector3Array out;
    out.resize(static_cast<int64_t>(m_points.size()));
    Vector3 *w = out.ptrw();
    for (size_t i = 0; i < m_points.size(); ++i)
        w[i] = m_points[i];
    return out;
}

void VerletRope::NudgePoint(int p_index, const Vector3 &p_delta)
{
    if (p_index < 0 || p_index >= static_cast<int>(m_points.size()) || m_inv_mass[p_index] == 0.0f)
        return;
    m_points[p_index] += p_delta;
    Wake();
}

void VerletRope::SetRopeLength(double p_length)
{
    m_segment_length = std::fmax(p_length, 0.01) / static_cast<double>(m_segment_count);
    Wake();
}

void VerletRope::Wake()
{
    m_asleep = false;
    m_still_frames = 0;
    OpenExcursionWindow();
}

void VerletRope::OpenExcursionWindow()
{
    m_sleep_ref = m_points;
    m_ref_frames = 0;
    m_max_excursion_sq = 0.0;
}

void VerletRope::SleepNow()
{
    m_asleep = true;
    // Zero implied velocities so waking doesn't inherit stale motion — and so a
    // rope stopped mid-oscillation doesn't resume it.
    m_prev_points = m_points;
}

void VerletRope::InitPoints()
{
    const int count = m_segment_count + 1;
    m_points.assign(count, Vector3());
    m_prev_points.assign(count, Vector3());
    m_inv_mass.assign(count, 1.0f);
    m_mid_contact.assign(m_segment_count, 0);
    m_mid_contact_point.assign(m_segment_count, Vector3());
    m_mid_contact_normal.assign(m_segment_count, Vector3());
    m_c_flags.assign(count, 0);
    m_c_p1.assign(count, Vector3());
    m_c_n1.assign(count, Vector3());
    m_c_p2.assign(count, Vector3());
    m_c_n2.assign(count, Vector3());
    m_stuck_passes.assign(count, 0);
    m_active_mid.reserve(m_segment_count);
    m_active_contact.reserve(count);

    CacheAnchors();
    const Vector3 start_pos = AnchorPoint(m_start_cached, m_start_anchor_offset, get_global_position());
    const Vector3 end_pos = AnchorPoint(
        m_end_cached, m_end_anchor_offset,
        start_pos + Vector3(0, -m_segment_count * m_segment_length, 0));

    for (int i = 0; i < count; ++i)
    {
        const double t = count > 1 ? static_cast<double>(i) / static_cast<double>(count - 1) : 0.0;
        m_points[i] = start_pos.lerp(end_pos, t);
        m_prev_points[i] = m_points[i];
    }
    m_inv_mass[0] = 0.0f;
    if (m_end_cached)
        m_inv_mass[count - 1] = 0.0f;

    Wake();
    m_sleep_anchor_start = AnchorPoint(m_start_cached, m_start_anchor_offset, start_pos);
    m_sleep_anchor_end = AnchorPoint(m_end_cached, m_end_anchor_offset, end_pos);
    RefreshExclusions();
    // Resize-and-seed: SnapshotRenderState detects the length change and fills
    // both history buffers from the fresh points.
    m_curr_render.clear();
    SnapshotRenderState();
}

// Exclude the plug body and the host machine's body from rope collision — the
// anchor points sit at/inside those colliders and would jitter forever. Also
// caches the anchors' RigidBody3D ancestors for two-way coupling.
void VerletRope::RefreshExclusions()
{
    TypedArray<RID> rids;
    m_start_body = nullptr;
    m_end_body = nullptr;
    Node3D *anchors[2] = {GetStartNode(), GetEndNode()};
    for (int a_idx = 0; a_idx < 2; ++a_idx)
    {
        Node *n = anchors[a_idx];
        while (n != nullptr)
        {
            CollisionObject3D *co = Object::cast_to<CollisionObject3D>(n);
            if (co != nullptr)
            {
                rids.push_back(co->get_rid());
                RigidBody3D *rb = Object::cast_to<RigidBody3D>(n);
                if (rb != nullptr)
                {
                    if (a_idx == 0)
                        m_start_body = rb;
                    else
                        m_end_body = rb;
                }
                break;
            }
            n = n->get_parent();
        }
    }
    if (m_ray_query.is_valid())
        m_ray_query->set_exclude(rids);
    if (m_shape_query.is_valid())
        m_shape_query->set_exclude(rids);
}

bool VerletRope::AnchorsMoved() const
{
    if (AnchorPoint(m_start_cached, m_start_anchor_offset, m_sleep_anchor_start)
            .distance_squared_to(m_sleep_anchor_start) > WAKE_ANCHOR_EPS_SQ)
        return true;
    return AnchorPoint(m_end_cached, m_end_anchor_offset, m_sleep_anchor_end)
               .distance_squared_to(m_sleep_anchor_end) > WAKE_ANCHOR_EPS_SQ;
}

} // namespace Xenu
