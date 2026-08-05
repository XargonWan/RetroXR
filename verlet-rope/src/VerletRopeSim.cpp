// VerletRope — the per-tick simulation. Split from VerletRope.cpp, which holds
// the bindings and lifecycle, purely to keep both files readable.
//
// Ported from verlet_rope.gd. Constraint order, contact caching and sleep rules
// all match it; where the GDScript had constraints hand-inlined into the solver
// loop to dodge interpreter call overhead, they are ordinary inline functions
// again here.

#include "VerletRope.hpp"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/physics_direct_space_state3d.hpp>
#include <godot_cpp/classes/world3d.hpp>

#include <cmath>

using namespace godot;

namespace Xenu
{

namespace
{
constexpr int SLEEP_FRAMES = 30;
constexpr double SLEEP_POINT_EPS_SQ = 0.0015 * 0.0015;
constexpr int SLEEP_REF_FRAMES = 90;
constexpr double SLEEP_EXCURSION_EPS_SQ = 0.012 * 0.012;
constexpr double WAKE_ANCHOR_EPS_SQ = 0.0005 * 0.0005;
} // namespace

// ── Constraint primitives ───────────────────────────────────────────────────

// Positional constraint between points a/b toward rest distance, split by
// inverse mass.
inline void VerletRope::SolvePair(int a, int b, double rest, double k)
{
    const float w_a = m_inv_mass[a];
    const float w_b = m_inv_mass[b];
    const float w_sum = w_a + w_b;
    if (w_sum == 0.0f)
        return;
    const Vector3 diff = m_points[b] - m_points[a];
    const double dist = diff.length();
    if (dist < 0.0001)
        return;
    const Vector3 correction = diff * ((dist - rest) / dist) * k;
    m_points[a] += correction * (w_a / w_sum);
    m_points[b] -= correction * (w_b / w_sum);
}

// Angular bend constraint: pull particle b toward the midpoint of its
// neighbours at +/-spacing (momentum-balanced), ignoring deviation below
// allowed_dev.
inline void VerletRope::SolveBend(int b, int spacing, double allowed_dev, double k)
{
    const int a = b - spacing;
    const int c = b + spacing;
    const float w_a = m_inv_mass[a];
    const float w_b = m_inv_mass[b];
    const float w_c = m_inv_mass[c];
    const float w_total = w_b + 0.5f * (w_a + w_c);
    if (w_total == 0.0f)
        return;
    const Vector3 delta = (m_points[a] + m_points[c]) * 0.5f - m_points[b];
    const double dev_sq = delta.length_squared();
    // The degenerate case has to be dropped rather than scaled: nudging an
    // already-straight triple by a fraction of a micrometre is what used to stop
    // a settled rope going to sleep.
    if (dev_sq < 1e-8)
        return;
    Vector3 v;
    if (allowed_dev > 0.0)
    {
        if (dev_sq <= allowed_dev * allowed_dev)
            return;
        const double dev = std::sqrt(dev_sq);
        v = delta * ((dev - allowed_dev) / dev * k);
    }
    else
    {
        // No free-bend allowance makes the (dev - allowed) / dev scale exactly
        // 1, so the correction is delta * k and the length is never needed. This
        // is the default path: max_bend_degrees is 0 unless a rope opts in, and
        // the strain-relief stub always passes 0.
        v = delta * k;
    }
    m_points[b] += v * (w_b / w_total);
    m_points[a] -= v * (0.5f * w_a / w_total);
    m_points[c] -= v * (0.5f * w_c / w_total);
}

// Keep segment s's midpoint outside its cached contact plane, splitting the
// correction so the midpoint clears fully. The distance cap guards against stale
// planes (refreshed only every raycast_interval frames, and infinite in extent).
inline void VerletRope::SolveMidContact(int s)
{
    const int ia = m_seg_a[s];
    const int ib = m_seg_b[s];
    const float w_a = m_inv_mass[ia];
    const float w_b = m_inv_mass[ib];
    const float w_sum = w_a + w_b;
    if (w_sum == 0.0f)
        return;
    const Vector3 mid = (m_points[ia] + m_points[ib]) * 0.5f;
    const double rest = m_seg_rest[s];
    if (mid.distance_squared_to(m_mid_contact_point[s]) > rest * rest * 4.0)
        return;
    const Vector3 n = m_mid_contact_normal[s];
    const double d = (mid - m_mid_contact_point[s]).dot(n);
    if (d >= m_collision_radius)
        return;
    const Vector3 push = n * (m_collision_radius - d);
    m_points[ia] += push * (2.0f * w_a / w_sum);
    m_points[ib] += push * (2.0f * w_b / w_sum);
}

// Keep particle i at least collision_radius outside the cached plane.
inline void VerletRope::ProjectPlane(int i, const Vector3 &cp, const Vector3 &n)
{
    const double d = (m_points[i] - cp).dot(n);
    if (d < m_collision_radius)
        m_points[i] += n * (m_collision_radius - d);
}

inline void VerletRope::PinAnchors()
{
    if (m_start_cached)
    {
        m_points[0] = AnchorPoint(m_start_cached, m_start_anchor_offset, m_points[0]);
        m_prev_points[0] = m_points[0];
    }
    if (m_end_cached)
    {
        const int last = TrunkCount() - 1;
        m_points[last] = AnchorPoint(m_end_cached, m_end_anchor_offset, m_points[last]);
        m_prev_points[last] = m_points[last];
    }
    for (const FrayChain &fc : m_fray)
    {
        if (fc.cached == nullptr)
            continue;
        const int last = fc.first + fc.count - 1;
        m_points[last] = AnchorPoint(fc.cached, fc.offset, m_points[last]);
        m_prev_points[last] = m_points[last];
    }
}

// Snap point i to just outside a surface and convert its velocity into a
// friction-damped slide along the surface (no bounce).
inline void VerletRope::ResolveContact(int i, const Vector3 &contact, const Vector3 &normal)
{
    const Vector3 vel = m_points[i] - m_prev_points[i];
    const Vector3 tangential = vel - normal * vel.dot(normal);
    m_points[i] = contact + normal * m_collision_radius;
    m_prev_points[i] = m_points[i] - tangential * (1.0 - m_surface_friction);
}

// Stub stiffness at the k-th particle from an end (k = 1 nearest), over n stub
// particles. Full strength at the plug, easing to nothing at the far end — a
// constant strength across the stub made the cable look like sausage links,
// because a rigid run met a floppy run at a hard boundary.
double VerletRope::StubWeight(double base, int k, int n) const
{
    if (n <= 1)
        return base;
    return base * (1.0 - static_cast<double>(k - 1) / static_cast<double>(n));
}

// Whether a cached contact plane is still plausible for particle i: the particle
// hasn't slid far from the contact and still sits near the plane.
bool VerletRope::PlaneValid(int i, const Vector3 &cp, const Vector3 &n) const
{
    const Vector3 p = m_points[i];
    if (p.distance_squared_to(cp) > m_segment_length * m_segment_length * 4.0)
        return false;
    return std::abs((p - cp).dot(n)) < m_collision_radius * 3.0;
}

// ── Plug orientation ────────────────────────────────────────────────────────

// True when this anchor's orientation is externally fixed, so the cable should
// leave it stiffly along its exit axis rather than hanging freely. That covers a
// host attach point (a plain Node3D bolted to a device) and a plug that's held
// or socketed. A free-dangling plug is NOT fixed — it follows the rope instead.
bool VerletRope::PlugIsFixed(Node3D *node) const
{
    if (node == nullptr)
        return false;
    RigidBody3D *rb = Object::cast_to<RigidBody3D>(node);
    if (rb == nullptr)
        return true; // host attach point — rigidly mounted to its device
    if (rb->is_freeze_enabled())
        return true;
    if (rb->has_method("is_picked_up"))
        return static_cast<bool>(rb->call("is_picked_up"));
    return false;
}

Vector3 VerletRope::PlugExitDir(Node3D *node) const
{
    if (node == nullptr)
        return Vector3();
    return (node->get_global_transform().basis.orthonormalized().xform(m_plug_exit_axis)).normalized();
}

// Rotate a free plug rigidbody so its cable-exit axis points along the rope's
// tangent, easing by k per frame. Rotating the plug doesn't move its anchor
// point, so this never perturbs the sim.
void VerletRope::AlignAnchorPlug(Node3D *node, const Vector3 &target_dir_in, double k)
{
    RigidBody3D *rb = Object::cast_to<RigidBody3D>(node);
    if (rb == nullptr || rb->is_freeze_enabled())
        return;
    if (rb->has_method("is_picked_up") && static_cast<bool>(rb->call("is_picked_up")))
        return;
    if (target_dir_in.length_squared() < 1e-8)
        return;
    const Vector3 target_dir = target_dir_in.normalized();
    // We own this plug's rotation while it dangles free — kill any residual spin
    // so the physics engine doesn't drift it between our frames.
    rb->set_angular_velocity(Vector3());
    const Basis basis = rb->get_global_transform().basis.orthonormalized();
    const Vector3 cur_axis = basis.xform(m_plug_exit_axis).normalized();
    if (cur_axis.length_squared() < 1e-8)
        return;
    const double dot = CLAMP(cur_axis.dot(target_dir), -1.0, 1.0);
    if (dot > 0.9999)
        return; // already aligned
    Quaternion arc;
    if (dot < -0.9999)
    {
        // Opposite directions — pick any perpendicular for the 180 degree flip.
        Vector3 perp = cur_axis.cross(Vector3(0, 1, 0));
        if (perp.length_squared() < 1e-6)
            perp = cur_axis.cross(Vector3(1, 0, 0));
        arc = Quaternion(perp.normalized(), Math_PI);
    }
    else
    {
        arc = Quaternion(cur_axis, target_dir);
    }
    const Quaternion cur_q = basis.get_rotation_quaternion();
    const Quaternion target_q = (arc * cur_q).normalized();
    const Quaternion new_q = cur_q.slerp(target_q, CLAMP(k, 0.0, 1.0));
    Transform3D xf = rb->get_global_transform();
    xf.basis = Basis(new_q);
    rb->set_global_transform(xf);
}

// ── Tick ────────────────────────────────────────────────────────────────────

void VerletRope::_physics_process(double p_delta)
{
    Step(p_delta);
}

void VerletRope::Step(double p_delta)
{
    if (m_points.empty())
        return;

    CacheAnchors();

    if (m_asleep)
    {
        if (AnchorsMoved())
            Wake();
        else
        {
            // Nothing moved, so there is nothing to interpolate between; leaving
            // this true would re-mesh a settled cable every frame forever.
            m_interpolating = false;
            return;
        }
    }
    m_mesh_dirty = true;

    Integrate(p_delta);

    // End orientation authority: a plug whose orientation is externally fixed
    // drives the ROPE. A free plug is the complement — it follows the rope (see
    // AlignAnchorPlug after the solve).
    const bool start_fixed = PlugIsFixed(m_start_cached);
    const bool end_fixed = PlugIsFixed(m_end_cached);
    const Vector3 start_exit = start_fixed ? PlugExitDir(m_start_cached) : Vector3();
    const Vector3 end_exit = end_fixed ? PlugExitDir(m_end_cached) : Vector3();

    SolveConstraints(start_fixed, end_fixed, start_exit, end_exit);
    ApplyContactFriction();

    // Cadence shared by the two heavy passes below.
    m_raycast_frame += 1;
    const bool do_rest = m_raycast_frame >= m_raycast_interval;
    if (do_rest)
        m_raycast_frame = 0;

    // Runs every tick, not on the cadence above, despite being the only O(n^2)
    // pass here. Tried at raycast_interval and a slack cable settles visibly
    // differently: with the pushout applied on one tick in three, gravity and
    // the stretch constraints close the coils unopposed in between, and a cord
    // that should drape off a table collapses into a flat pile on it.
    if (m_self_collision)
        SolveSelfCollision();

    if (m_surface_collision_mask != 0 && m_ray_query.is_valid())
        SolveSurfaceCollision(do_rest);

    ApplyAnchorCoupling();

    // Plug end-direction alignment, FREE ends only.
    const int count = TrunkCount();
    if (m_end_align_stiffness > 0.0 && count >= 2)
    {
        if (!start_fixed)
            AlignAnchorPlug(m_start_cached, m_points[1] - m_points[0], m_end_align_stiffness);
        if (!end_fixed)
            AlignAnchorPlug(m_end_cached, m_points[count - 2] - m_points[count - 1], m_end_align_stiffness);
        for (const FrayChain &fc : m_fray)
        {
            if (fc.cached == nullptr || fc.count < 2 || PlugIsFixed(fc.cached))
                continue;
            const int last = fc.first + fc.count - 1;
            AlignAnchorPlug(fc.cached, m_points[last - 1] - m_points[last], m_end_align_stiffness);
        }
    }

    UpdateSleepState();
    // Last thing in the tick, after the anchors are pinned: roll the render
    // history forward so _process has two states to interpolate between.
    SnapshotRenderState();
}

void VerletRope::Integrate(double p_delta)
{
    const int count = static_cast<int>(m_points.size());
    const Vector3 grav_step = m_gravity * (p_delta * p_delta);
    const double retain = 1.0 - m_damping;
    for (int i = 0; i < count; ++i)
    {
        if (m_inv_mass[i] == 0.0f)
            continue;
        const Vector3 current = m_points[i];
        const Vector3 velocity = (current - m_prev_points[i]) * retain;
        m_prev_points[i] = current;
        m_points[i] = current + velocity + grav_step;
    }
    PinAnchors();
}

void VerletRope::SolveConstraints(bool p_start_fixed, bool p_end_fixed,
                                  const Vector3 &p_start_exit, const Vector3 &p_end_exit)
{
    // The trunk's own particle range. Without a fray this is every particle, so
    // all the loops below are exactly what they were.
    const int count = TrunkCount();
    const int seg_count = static_cast<int>(m_seg_a.size());
    const int iters = m_constraint_iterations > 1 ? m_constraint_iterations : 1;

    // Stretch stiffness is remapped so extensibility is independent of the
    // iteration count (k' = 1-(1-k)^(1/n)); 1.0 stays fully rigid.
    const double k_stretch = 1.0 - std::pow(1.0 - CLAMP(m_stretch_stiffness, 0.0, 1.0), 1.0 / iters);
    // Bend stiffness is applied directly per iteration — remapping it the same
    // way crushes mid-range values into "floppy" at typical iteration counts.
    const double k_bend = CLAMP(m_bend_stiffness, 0.0, 1.0);
    // A bend of angle B deviates the particle L*sin(B/2) from the midpoint;
    // bends up to max_bend_degrees are free.
    const double allowed_dev = m_segment_length * std::sin(Math::deg_to_rad(m_max_bend_degrees) * 0.5);

    // Contact flags are only rewritten by the throttled rest pass, never inside
    // the solve, so gather the active planes once instead of re-testing every
    // particle on all eight iterations.
    m_active_mid.clear();
    for (int s = 0; s < seg_count; ++s)
        if (m_mid_contact[s] != 0)
            m_active_mid.push_back(s);
    m_active_contact.clear();
    for (int i = 0, n = static_cast<int>(m_points.size()); i < n; ++i)
        if (m_inv_mass[i] != 0.0f && m_c_flags[i] != 0)
            m_active_contact.push_back(i);

    for (int iter_i = 0; iter_i < iters; ++iter_i)
    {
        // Stretch runs off the segment table, so a branch's link back to the
        // junction is solved with the rest, at the branch's own rest length.
        for (int s = 0; s < seg_count; ++s)
            SolvePair(m_seg_a[s], m_seg_b[s], m_seg_rest[s], k_stretch);

        // Bend, hierarchical: besides adjacent triples (spacing 1), also
        // constrain toward midpoints at spacing 2/4/8… Plain PBD bending
        // saturates with chain length, so long ropes stay droopy no matter the
        // stiffness; the long-range constraints fix that in O(log n) passes. The
        // hierarchy depth scales with stiffness. Sweep direction alternates per
        // iteration. The free-bend allowance grows ~s^2 with spacing.
        if (k_bend > 0.0)
        {
            int levels = 1 + static_cast<int>(std::lround(k_bend * 3.0));
            int s = 1;
            while (s * 2 <= count - 1 && levels > 0)
            {
                const double allowed = allowed_dev * static_cast<double>(s * s);
                if (iter_i % 2 == 0)
                    for (int i = s; i < count - s; ++i)
                        SolveBend(i, s, allowed, k_bend);
                else
                    for (int i = count - s - 1; i >= s; --i)
                        SolveBend(i, s, allowed, k_bend);
                s *= 2;
                levels -= 1;
            }
        }

        // End stiffness (strain-relief boot): hold the first/last few segments
        // perfectly straight with a strong direct stiffness, so the cable
        // emerges rigid from each plug and only bends past the stub. Applied
        // after the general bend so it wins near the ends.
        if (m_end_stiffness > 0.0 && m_end_stiff_segments > 0)
        {
            const double ke = CLAMP(m_end_stiffness, 0.0, 1.0);
            const int n_end = std::min(m_end_stiff_segments, (count - 1) / 2);
            if (iter_i % 2 == 0)
            {
                for (int i = 1; i <= n_end; ++i)
                    SolveBend(i, 1, 0.0, StubWeight(ke, i, n_end));
                for (int i = count - 2; i > count - 2 - n_end; --i)
                    SolveBend(i, 1, 0.0, StubWeight(ke, count - 1 - i, n_end));
            }
            else
            {
                for (int i = n_end; i >= 1; --i)
                    SolveBend(i, 1, 0.0, StubWeight(ke, i, n_end));
                for (int i = count - 1 - n_end; i < count - 1; ++i)
                    SolveBend(i, 1, 0.0, StubWeight(ke, count - 1 - i, n_end));
            }
        }

        // Directional stub for a FIXED end: pull the first/last few particles
        // onto the line leaving the plug along its exit axis, so a held or
        // socketed cable emerges stiffly in the direction it plugs in.
        if (m_end_stiffness > 0.0 && m_end_stiff_segments > 0 && (p_start_fixed || p_end_fixed))
        {
            const double ked = CLAMP(m_end_stiffness, 0.0, 1.0);
            const int nd = std::min(m_end_stiff_segments, (count - 1) / 2);
            if (p_end_fixed)
            {
                const Vector3 base_e = m_points[count - 1];
                for (int j = 1; j <= nd; ++j)
                {
                    const int idx = count - 1 - j;
                    if (m_inv_mass[idx] != 0.0f)
                        m_points[idx] = m_points[idx].lerp(
                            base_e + p_end_exit * (m_segment_length * j), StubWeight(ked, j, nd));
                }
            }
            if (p_start_fixed)
            {
                const Vector3 base_s = m_points[0];
                for (int j = 1; j <= nd; ++j)
                {
                    if (m_inv_mass[j] != 0.0f)
                        m_points[j] = m_points[j].lerp(
                            base_s + p_start_exit * (m_segment_length * j), StubWeight(ked, j, nd));
                }
            }
        }

        if (!m_fray.empty())
            SolveFrayConstraints(iter_i, k_stretch, k_bend, allowed_dev);

        // Cached contact planes, solved together with the other constraints so
        // contacts — including edge wraps — are part of the equilibrium instead
        // of oscillating.
        for (int s : m_active_mid)
            SolveMidContact(s);
        for (int i : m_active_contact)
        {
            const uint8_t flags = m_c_flags[i];
            if (flags & 1)
                ProjectPlane(i, m_c_p1[i], m_c_n1[i]);
            if (flags & 2)
                ProjectPlane(i, m_c_p2[i], m_c_n2[i]);
        }
        PinAnchors();
    }
}

// Bend and stub constraints for the frayed branches. Stretch is not here — it
// comes off the shared segment table with the trunk's.
//
// Nothing spans the junction: a branch's bend starts one particle in, so the
// breakout is a free hinge. That is what a real fray is, and constraining across
// it would need a "which branch" choice the geometry doesn't offer.
void VerletRope::SolveFrayConstraints(int p_iter, double, double p_k_bend, double p_allowed_dev)
{
    const double seg_len = FraySegLength();
    for (const FrayChain &fc : m_fray)
    {
        const int first = fc.first;
        const int last = fc.first + fc.count - 1;
        if (fc.count < 3)
            continue;

        if (p_k_bend > 0.0)
        {
            int levels = 1 + static_cast<int>(std::lround(p_k_bend * 3.0));
            int s = 1;
            while (s * 2 <= fc.count - 1 && levels > 0)
            {
                const double allowed = p_allowed_dev * static_cast<double>(s * s);
                if (p_iter % 2 == 0)
                    for (int i = first + s; i <= last - s; ++i)
                        SolveBend(i, s, allowed, p_k_bend);
                else
                    for (int i = last - s; i >= first + s; --i)
                        SolveBend(i, s, allowed, p_k_bend);
                s *= 2;
                levels -= 1;
            }
        }

        // Strain-relief boot at the plug, the same taper the trunk's ends get.
        if (m_end_stiffness > 0.0 && m_end_stiff_segments > 0)
        {
            const double ke = CLAMP(m_end_stiffness, 0.0, 1.0);
            const int n_end = std::min(m_end_stiff_segments, fc.count - 2);
            for (int j = 1; j <= n_end; ++j)
                SolveBend(last - j, 1, 0.0, StubWeight(ke, j, n_end));

            // Directional stub: a branch whose plug is held or socketed leaves
            // it along the plug's exit axis rather than hanging off it.
            if (PlugIsFixed(fc.cached))
            {
                const Vector3 exit = PlugExitDir(fc.cached);
                const Vector3 base = m_points[last];
                for (int j = 1; j <= n_end; ++j)
                {
                    const int idx = last - j;
                    if (m_inv_mass[idx] != 0.0f)
                        m_points[idx] = m_points[idx].lerp(base + exit * (seg_len * j),
                                                           StubWeight(ke, j, n_end));
                }
            }
        }
    }
}

// Friction for cached resting contacts (once per frame, not per iteration): damp
// the tangential velocity of every particle a contact plane is holding.
void VerletRope::ApplyContactFriction()
{
    const int count = static_cast<int>(m_points.size());
    for (int i = 0; i < count; ++i)
    {
        if (m_inv_mass[i] == 0.0f || m_c_flags[i] == 0)
            continue;
        for (int slot = 0; slot < 2; ++slot)
        {
            if ((m_c_flags[i] & (1 << slot)) == 0)
                continue;
            const Vector3 n = slot == 0 ? m_c_n1[i] : m_c_n2[i];
            const Vector3 cp = slot == 0 ? m_c_p1[i] : m_c_p2[i];
            if ((m_points[i] - cp).dot(n) > m_collision_radius * 1.05)
                continue;
            const Vector3 vel = m_points[i] - m_prev_points[i];
            const Vector3 tangential = vel - n * vel.dot(n);
            m_prev_points[i] = m_points[i] - tangential * (1.0 - m_surface_friction);
        }
    }
}

void VerletRope::SolveSelfCollision()
{
    const int count = static_cast<int>(m_points.size());
    const double min_d = m_collision_radius * 2.0;
    const double min_d_sq = min_d * min_d;
    for (int i = 0; i < count; ++i)
    {
        const float w_i = m_inv_mass[i];
        const uint8_t g_i = m_self_group[i];
        Vector3 p_i = m_points[i];
        // j >= i+2 exempts chain neighbours by ARRAY distance, which stops being
        // chain distance once branches are appended: a branch's head and the
        // trunk's end are coincident but far apart in the array, as are the
        // heads of two branches. m_self_group re-states that by construction.
        for (int j = i + 2; j < count; ++j)
        {
            const float w_j = m_inv_mass[j];
            const float w_sum = w_i + w_j;
            if (w_sum == 0.0f)
                continue;
            if (g_i != 0 && g_i == m_self_group[j])
                continue;
            const Vector3 diff = m_points[j] - p_i;
            const double d_sq = diff.length_squared();
            if (d_sq >= min_d_sq || d_sq < 1e-8)
                continue;
            const double dist = std::sqrt(d_sq);
            const Vector3 push = diff * ((dist - min_d) / dist);
            p_i += push * (w_i / w_sum);
            m_points[j] -= push * (w_j / w_sum);
        }
        m_points[i] = p_i;
    }
}

void VerletRope::SolveSurfaceCollision(bool p_do_rest)
{
    const int count = static_cast<int>(m_points.size());
    Ref<World3D> world = get_world_3d();
    if (world.is_null())
        return;
    PhysicsDirectSpaceState3D *space_state = world->get_direct_space_state();
    if (space_state == nullptr)
        return;

    for (int i = 0; i < count; ++i)
    {
        if (m_inv_mass[i] == 0.0f)
            continue;
        // Sweep this frame's motion so a point can't tunnel through thin
        // geometry, even between rest-query frames.
        const Vector3 from = m_prev_points[i];
        const Vector3 to = m_points[i];
        const Vector3 motion = to - from;
        if (motion.length_squared() > 0.000001)
        {
            m_ray_query->set_from(from);
            m_ray_query->set_to(to + motion.normalized() * m_collision_radius);
            Dictionary hit = space_state->intersect_ray(m_ray_query);
            if (!hit.is_empty())
            {
                const Vector3 hit_normal = hit["normal"];
                if (hit_normal != Vector3())
                {
                    ResolveContact(i, hit["position"], hit_normal);
                    continue;
                }
            }
        }
        // Resting contact (throttled — heavier query): refresh the particle's
        // cached contact-plane manifold. The planes are enforced every frame
        // INSIDE the constraint loop, so contacts are part of the solver's
        // equilibrium; snapping the particle here instead fights the other
        // constraints and jitters edge wraps. The query only reports the deepest
        // plane (which alternates at a corner), so a still-valid previous plane
        // with a different normal is kept as a second slot.
        if (p_do_rest)
        {
            m_shape_query->set_transform(Transform3D(Basis(), m_points[i]));
            Dictionary rest = space_state->get_rest_info(m_shape_query);
            bool keep1 = (m_c_flags[i] & 1) != 0 && PlaneValid(i, m_c_p1[i], m_c_n1[i]);
            bool keep2 = (m_c_flags[i] & 2) != 0 && PlaneValid(i, m_c_p2[i], m_c_n2[i]);
            // Deep-penetration guard: if the particle centre is BEHIND the
            // reported plane it has passed the surface, and ejecting along this
            // normal can pop it out the FAR side of a slab. Don't cache — the
            // wrong-side recovery below walks it back instead.
            if (!rest.is_empty())
            {
                const Vector3 nn = rest["normal"];
                const Vector3 np = rest["point"];
                if (nn != Vector3() && (m_points[i] - np).dot(nn) >= 0.0)
                {
                    if (keep1 && nn.dot(m_c_n1[i]) > 0.9)
                    {
                        m_c_p1[i] = np;
                        m_c_n1[i] = nn;
                    }
                    else if (keep2 && nn.dot(m_c_n2[i]) > 0.9)
                    {
                        m_c_p2[i] = np;
                        m_c_n2[i] = nn;
                    }
                    else if (!keep1)
                    {
                        m_c_p1[i] = np;
                        m_c_n1[i] = nn;
                        keep1 = true;
                    }
                    else
                    {
                        m_c_p2[i] = np;
                        m_c_n2[i] = nn;
                        keep2 = true;
                    }
                }
            }
            m_c_flags[i] = static_cast<uint8_t>((keep1 ? 1 : 0) | (keep2 ? 2 : 0));
        }
    }

    if (!p_do_rest)
        return;

    // Segment-midpoint contact CACHE refresh: particle collision alone lets the
    // straight span BETWEEN two particles cut through a convex corner. We only
    // query here — the cached plane is enforced every frame inside the
    // constraint loop, so the corner contact is part of the solver's
    // equilibrium. Pushing directly from this throttled pass instead makes an
    // edge-wrapped rope visibly oscillate.
    const int seg_count = static_cast<int>(m_seg_a.size());
    for (int s = 0; s < seg_count; ++s)
    {
        const int ia = m_seg_a[s];
        const int ib = m_seg_b[s];
        m_mid_contact[s] = 0;
        if (m_inv_mass[ia] + m_inv_mass[ib] == 0.0f)
            continue;
        const Vector3 mid = (m_points[ia] + m_points[ib]) * 0.5f;
        m_shape_query->set_transform(Transform3D(Basis(), mid));
        Dictionary rest = space_state->get_rest_info(m_shape_query);
        if (rest.is_empty())
            continue;
        const Vector3 n = rest["normal"];
        if (n == Vector3())
            continue;
        // Deep-penetration guard, but bounded. A midpoint behind the reported
        // plane must not be ejected along this normal when it has genuinely
        // passed through a slab — that pops it out the far side. A chord
        // cutting a convex CORNER puts the midpoint slightly behind the surface
        // too, though, and that is the exact case this cache exists to fix. An
        // unconditional reject therefore drops the contact whenever the segment
        // needs it most: between throttled passes the segment sinks into the
        // corner, the refresh refuses to cache it, it sinks further, and the
        // stretch constraints eventually snap it back out — a limit cycle with
        // a period locked to raycast_interval, and the visible jitter wherever
        // a cable bends over an edge. Only a penetration deeper than a corner
        // cut can produce is treated as a tunnel.
        const double behind = -(mid - rest["point"].operator Vector3()).dot(n);
        if (behind > m_collision_radius * 3.0)
            continue;
        m_mid_contact[s] = 1;
        m_mid_contact_point[s] = rest["point"];
        m_mid_contact_normal[s] = n;
    }

    // Wrong-side recovery: a particle that tunnelled through a slab gets locked
    // on the far side — every time the stretch constraints pull it back, the
    // motion sweep hits the slab's far face front-on and re-strands it, so the
    // state is self-sustaining. Local contact info can't detect this;
    // CONNECTIVITY can: cast the segment ray BOTH ways. A segment genuinely
    // passing through a slab enters one face and exits through an opposing face
    // (normals antiparallel), while a legit drape over an edge crosses roughly
    // perpendicular faces. Require the state on two consecutive rest passes,
    // then teleport the particle back to the entry face.
    for (int s = 0; s < seg_count; ++s)
    {
        const int prev = m_seg_a[s];
        const int i = m_seg_b[s];
        if (m_inv_mass[i] == 0.0f)
            continue;
        const Vector3 seg_vec = m_points[i] - m_points[prev];
        const double seg_len = seg_vec.length();
        if (seg_len < 0.0001)
        {
            m_stuck_passes[i] = 0;
            continue;
        }
        m_ray_query->set_from(m_points[prev]);
        m_ray_query->set_to(m_points[i] + seg_vec * (m_collision_radius / seg_len));
        Dictionary entry = space_state->intersect_ray(m_ray_query);
        const Vector3 entry_n = entry.is_empty() ? Vector3() : entry["normal"].operator Vector3();
        // Must be meaningfully behind the entered face (not a corner graze)…
        if (entry_n == Vector3() ||
            (m_points[i] - entry["position"].operator Vector3()).dot(entry_n) > -m_collision_radius)
        {
            m_stuck_passes[i] = 0;
            continue;
        }
        // …and the reverse ray must exit through an opposing face.
        m_ray_query->set_from(m_points[i]);
        m_ray_query->set_to(m_points[prev]);
        Dictionary exit = space_state->intersect_ray(m_ray_query);
        if (exit.is_empty() || entry_n.dot(exit["normal"].operator Vector3()) > -0.7)
        {
            m_stuck_passes[i] = 0;
            continue;
        }
        m_stuck_passes[i] += 1;
        if (m_stuck_passes[i] < 2)
            continue;
        m_stuck_passes[i] = 0;
        m_points[i] = entry["position"].operator Vector3() + entry_n * m_collision_radius;
        m_prev_points[i] = m_points[i];
        m_c_flags[i] = 0;
        m_mid_contact[s] = 0;
        if (m_next_seg[i] >= 0)
            m_mid_contact[m_next_seg[i]] = 0;
    }
}

// Pull back on an anchor's rigidbody when the cable it holds is stretched past
// its rest length. This is the ONLY path by which the rope moves a plug: a
// pinned particle has inverse mass 0, so the plug drives the rope and never the
// other way about.
void VerletRope::ApplyAnchorCoupling()
{
    if (m_anchor_pull <= 0.0)
        return;

    // Trunk, between its own two anchors. Needs both: with a fray there is no
    // trunk anchor at all and the branches below do the work instead.
    if (m_start_cached && m_end_cached)
    {
        const Vector3 ps = AnchorPoint(m_start_cached, m_start_anchor_offset, Vector3());
        const Vector3 pe = AnchorPoint(m_end_cached, m_end_anchor_offset, Vector3());
        const double excess = ps.distance_to(pe) - RestLength();
        if (excess > 0.0)
        {
            const double force = excess * m_anchor_pull;
            if (m_start_body)
                m_start_body->apply_force((pe - ps).normalized() * force,
                                          ps - m_start_body->get_global_position());
            if (m_end_body)
                m_end_body->apply_force((ps - pe).normalized() * force,
                                        pe - m_end_body->get_global_position());
        }
    }

    // Each branch, between its plug and the breakout it hangs off. Without this
    // a lead frayed at both ends has no coupling whatsoever — pick up one plug of
    // a composite lead, walk away, and the other five sit exactly where they are
    // while the cable stretches without limit.
    for (const FrayChain &fc : m_fray)
    {
        if (fc.body == nullptr)
            continue;
        const Vector3 plug = AnchorPoint(fc.cached, fc.offset, Vector3());
        const Vector3 junction = m_points[fc.head];
        const double excess = plug.distance_to(junction) - fc.count * FraySegLength();
        if (excess <= 0.0)
            continue;
        fc.body->apply_force((junction - plug).normalized() * (excess * m_anchor_pull),
                             plug - fc.body->get_global_position());
    }
}

void VerletRope::UpdateSleepState()
{
    const int count = static_cast<int>(m_points.size());
    if (static_cast<int>(m_sleep_ref.size()) != count)
        OpenExcursionWindow();

    bool still = true;
    for (int i = 0; i < count; ++i)
    {
        if (m_points[i].distance_squared_to(m_prev_points[i]) > SLEEP_POINT_EPS_SQ)
            still = false;
        const double e = m_points[i].distance_squared_to(m_sleep_ref[i]);
        if (e > m_max_excursion_sq)
            m_max_excursion_sq = e;
    }

    const Vector3 a_start = AnchorPoint(m_start_cached, m_start_anchor_offset, m_sleep_anchor_start);
    const Vector3 a_end = AnchorPoint(m_end_cached, m_end_anchor_offset, m_sleep_anchor_end);
    bool anchors_still =
        a_start.distance_squared_to(m_sleep_anchor_start) <= WAKE_ANCHOR_EPS_SQ &&
        a_end.distance_squared_to(m_sleep_anchor_end) <= WAKE_ANCHOR_EPS_SQ;
    m_sleep_anchor_start = a_start;
    m_sleep_anchor_end = a_end;
    for (FrayChain &fc : m_fray)
    {
        const Vector3 a = AnchorPoint(fc.cached, fc.offset, fc.sleep_pos);
        if (a.distance_squared_to(fc.sleep_pos) > WAKE_ANCHOR_EPS_SQ)
            anchors_still = false;
        fc.sleep_pos = a;
    }
    if (!anchors_still)
        still = false;

    if (still)
    {
        m_still_frames += 1;
        if (m_still_frames >= SLEEP_FRAMES)
            SleepNow();
    }
    else
    {
        m_still_frames = 0;
    }

    m_ref_frames += 1;
    if (m_ref_frames >= SLEEP_REF_FRAMES)
    {
        if (anchors_still && m_max_excursion_sq < SLEEP_EXCURSION_EPS_SQ)
            SleepNow();
        else
            OpenExcursionWindow();
    }
}

} // namespace Xenu
