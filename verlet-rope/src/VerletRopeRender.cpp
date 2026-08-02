// VerletRope — tube meshing and render-time interpolation. Split from
// VerletRope.cpp to keep the files readable.
//
// The tube cannot use ARRAY_NORMAL: positions are re-uploaded every frame
// through surface_update_vertex_region, and normals share that same vertex
// buffer, so adding them means rebuilding the whole surface each frame — a GPU
// buffer reallocation per rope per frame, which is exactly what this avoids.
// Custom attributes live in the ATTRIBUTE buffer instead, which has its own
// region-update call, so the normal rides along for one extra bulk upload.

#include "VerletRope.hpp"

#include <godot_cpp/classes/engine.hpp>

#include <cmath>

using namespace godot;

namespace Xenu
{

namespace
{
constexpr double RENDER_FOLLOW_EPS_SQ = 0.0001 * 0.0001;
} // namespace

void VerletRope::BuildTrigTables()
{
    m_cos_table.resize(m_tube_sides);
    m_sin_table.resize(m_tube_sides);
    for (int j = 0; j < m_tube_sides; ++j)
    {
        const double angle = Math_TAU * static_cast<double>(j) / static_cast<double>(m_tube_sides);
        m_cos_table[j] = static_cast<float>(std::cos(angle));
        m_sin_table[j] = static_cast<float>(std::sin(angle));
    }
}

void VerletRope::BuildMeshTopology()
{
    const int sub = Subdiv();
    const int ring_count = m_segment_count * sub + 1;
    const int seg_rings = ring_count - 1;

    m_ring_points.assign(ring_count, Vector3());
    m_ring_side.assign(ring_count, Vector3());
    m_ring_up.assign(ring_count, Vector3());

    const int vertex_count = ring_count * m_tube_sides;
    PackedVector3Array vertex_array;
    vertex_array.resize(vertex_count);
    PackedFloat32Array normal_array;
    normal_array.resize(vertex_count * 4);

    // Index buffer — topology never changes, built once.
    PackedInt32Array index_array;
    index_array.resize(seg_rings * m_tube_sides * 6);
    {
        int32_t *idx_w = index_array.ptrw();
        int idx = 0;
        for (int i = 0; i < seg_rings; ++i)
        {
            for (int j = 0; j < m_tube_sides; ++j)
            {
                const int a = i * m_tube_sides + j;
                const int b = i * m_tube_sides + (j + 1) % m_tube_sides;
                const int c = (i + 1) * m_tube_sides + j;
                const int d = (i + 1) * m_tube_sides + (j + 1) % m_tube_sides;
                idx_w[idx] = a;
                idx_w[idx + 1] = b;
                idx_w[idx + 2] = c;
                idx_w[idx + 3] = b;
                idx_w[idx + 4] = d;
                idx_w[idx + 5] = c;
                idx += 6;
            }
        }
    }

    Array arrays;
    arrays.resize(Mesh::ARRAY_MAX);
    arrays[Mesh::ARRAY_VERTEX] = vertex_array;
    arrays[Mesh::ARRAY_INDEX] = index_array;
    // PackedFloat32Array, NOT bytes: the *_FLOAT custom formats are validated as
    // PACKED_FLOAT32_ARRAY here and the surface silently fails to build
    // otherwise. (The region updates below do want bytes.)
    arrays[Mesh::ARRAY_CUSTOM0] = normal_array;

    Ref<ArrayMesh> am;
    am.instantiate();
    const uint64_t fmt = static_cast<uint64_t>(Mesh::ARRAY_CUSTOM_RGBA_FLOAT)
                         << Mesh::ARRAY_FORMAT_CUSTOM0_SHIFT;
    am->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays, TypedArray<Array>(),
                                Dictionary(), fmt);
    am->surface_set_material(0, m_material);
    set_mesh(am);

    // Staging buffers for the per-frame region uploads, sized once.
    m_vertex_bytes.resize(vertex_count * static_cast<int>(sizeof(float)) * 3);
    m_normal_bytes.resize(vertex_count * static_cast<int>(sizeof(float)) * 4);
}

// Fill m_ring_points from the sim points — straight copy, or Catmull-Rom
// subdivision when smoothing > 0.
void VerletRope::FillRingPoints()
{
    const int count = static_cast<int>(m_render_points.size());
    const int sub = Subdiv();
    if (sub == 1)
    {
        for (int i = 0; i < count; ++i)
            m_ring_points[i] = m_render_points[i];
        return;
    }
    int r = 0;
    for (int i = 0; i < count - 1; ++i)
    {
        const Vector3 p0 = m_render_points[i - 1 > 0 ? i - 1 : 0];
        const Vector3 p1 = m_render_points[i];
        const Vector3 p2 = m_render_points[i + 1];
        const Vector3 p3 = m_render_points[i + 2 < count - 1 ? i + 2 : count - 1];
        for (int s = 0; s < sub; ++s)
        {
            const double t = static_cast<double>(s) / static_cast<double>(sub);
            const double t2 = t * t;
            const double t3 = t2 * t;
            m_ring_points[r] = 0.5 * ((2.0 * p1) + (-p0 + p2) * t +
                                      (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 +
                                      (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3);
            r += 1;
        }
    }
    m_ring_points[r] = m_render_points[count - 1];
}

void VerletRope::RenderTube()
{
    FillRingPoints();
    const int count = static_cast<int>(m_ring_points.size());

    // Parallel-transport (rotation-minimizing) frames: build the first ring's
    // basis from any perpendicular, then carry it along the tube by projecting
    // the previous side vector onto each new tangent plane. Computing frames
    // independently from a fixed reference vector twists neighbouring rings
    // against each other whenever the tangent nears that reference, which
    // pinches the tube like sausage links.
    Vector3 prev_side;
    Vector3 prev_tangent(0, 1, 0);
    for (int i = 0; i < count; ++i)
    {
        Vector3 tangent;
        if (i == 0)
            tangent = m_ring_points[1] - m_ring_points[0];
        else if (i == count - 1)
            tangent = m_ring_points[i] - m_ring_points[i - 1];
        else
            tangent = m_ring_points[i + 1] - m_ring_points[i - 1];
        // Degeneracy guard, deliberately far below the ring spacing. At 0.0001
        // it meant 10 mm and fired on both END rings every frame: their tangent
        // is one-sided, and Catmull-Rom compresses the first and last sub-step.
        // The ring then got built around UP, putting its plane ALONG the cable
        // instead of across it, and the tube ended in a flat sliver at every
        // plug. Falling back to the previous tangent also beats a fixed axis: a
        // real degeneracy is two coincident points, where carrying the frame
        // forward is what the parallel transport wants anyway.
        if (tangent.length_squared() < 1e-12)
            tangent = prev_tangent;
        else
            tangent = tangent.normalized();
        prev_tangent = tangent;

        Vector3 side = prev_side - tangent * prev_side.dot(tangent);
        if (side.length_squared() < 0.000001)
        {
            const Vector3 ref = std::abs(tangent.dot(Vector3(0, 1, 0))) < 0.99 ? Vector3(0, 1, 0)
                                                                              : Vector3(1, 0, 0);
            side = tangent.cross(ref);
        }
        side = side.normalized();
        prev_side = side;
        m_ring_side[i] = side;
        m_ring_up[i] = side.cross(tangent).normalized();
    }

    // Fill the staging buffers directly — these go straight to the GPU.
    float *vw = reinterpret_cast<float *>(m_vertex_bytes.ptrw());
    float *nw = reinterpret_cast<float *>(m_normal_bytes.ptrw());
    for (int i = 0; i < count; ++i)
    {
        const int base = i * m_tube_sides;
        const Vector3 side = m_ring_side[i];
        const Vector3 up = m_ring_up[i];
        const Vector3 centre = m_ring_points[i];
        for (int j = 0; j < m_tube_sides; ++j)
        {
            const Vector3 radial = side * m_cos_table[j] + up * m_sin_table[j];
            const Vector3 v = centre + radial * m_tube_radius;
            const int v3 = (base + j) * 3;
            vw[v3] = v.x;
            vw[v3 + 1] = v.y;
            vw[v3 + 2] = v.z;
            const int n4 = (base + j) * 4;
            nw[n4] = radial.x;
            nw[n4 + 1] = radial.y;
            nw[n4 + 2] = radial.z;
            nw[n4 + 3] = 0.0f;
        }
    }

    Ref<ArrayMesh> am = get_mesh();
    if (am.is_null())
        return;
    am->surface_update_vertex_region(0, 0, m_vertex_bytes);
    am->surface_update_attribute_region(0, 0, m_normal_bytes);

    // Keep culling bounds in sync — surface_update_vertex_region does NOT
    // recompute the mesh AABB (it stays a zero-size box at the origin), and this
    // node is top_level at the world origin, so without this the rope gets
    // frustum-culled whenever the origin is off-screen.
    AABB aabb(m_render_points[0], Vector3());
    for (size_t i = 1; i < m_render_points.size(); ++i)
        aabb = aabb.expand(m_render_points[i]);
    set_custom_aabb(aabb.grow(m_collision_radius * 2.0));
}

// Roll the render history forward one physics tick. Called at the end of every
// simulated tick, after the anchors are pinned.
void VerletRope::SnapshotRenderState()
{
    const size_t n = m_points.size();
    if (m_curr_render.size() != n)
    {
        m_prev_render = m_points;
        m_curr_render = m_points;
        m_render_points = m_points;
        m_interpolating = false;
        return;
    }
    bool moved = false;
    for (size_t i = 0; i < n; ++i)
    {
        m_prev_render[i] = m_curr_render[i];
        m_curr_render[i] = m_points[i];
        m_render_points[i] = m_points[i];
        if (!moved && m_prev_render[i].distance_squared_to(m_curr_render[i]) > RENDER_FOLLOW_EPS_SQ)
            moved = true;
    }
    m_interpolating = moved;
}

void VerletRope::_process(double)
{
    Remesh();
}

void VerletRope::Remesh()
{
    if (m_points.size() < 2)
        return;
    // The whole rope has to be interpolated, not just its ends. Overriding only
    // the two end points put them on render time while every interior point
    // stayed on physics time, and that discontinuity pulsed the final segment
    // every frame — which read as the cord jittering, and pinched the tube
    // whenever the last two rings closed up enough for the tangent to collapse.
    // This is the same fraction Godot uses to draw the plug, so the cord end and
    // the plug agree by construction.
    if (m_interpolating && m_render_points.size() == m_curr_render.size())
    {
        const double f = CLAMP(Engine::get_singleton()->get_physics_interpolation_fraction(), 0.0, 1.0);
        for (size_t i = 0; i < m_render_points.size(); ++i)
            m_render_points[i] = m_prev_render[i].lerp(m_curr_render[i], f);
        m_mesh_dirty = true;
    }
    if (m_mesh_dirty)
    {
        RenderTube();
        m_mesh_dirty = false;
    }
}

} // namespace Xenu
