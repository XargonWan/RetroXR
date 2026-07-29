#include "MetaXRAudioServer.hpp"
#include "MetaXRAudioStream.hpp"

#include <godot_cpp/classes/audio_server.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/scene_tree.hpp>
#include <godot_cpp/classes/window.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cstring>

using namespace godot;
using namespace MetaXRAudio;

namespace Xenu
{

MetaXRAudioServer* MetaXRAudioServer::s_singleton = nullptr;

namespace
{
/// Where the vendored native library sits once exported. res:// is inside the
/// pck in an exported build, so the library has to be resolved through
/// ProjectSettings::globalize_path, which yields a real filesystem path for
/// files excluded from the pck (Windows) or unpacked into the APK's lib dir
/// (Android, where the loader finds it by soname alone).
String NativeLibraryPath()
{
#if defined(_WIN32)
    return ProjectSettings::get_singleton()->globalize_path("res://metaxr-audio/MetaXRAudioUnity.dll");
#elif defined(__ANDROID__)
    // Packed into the APK's lib/arm64-v8a by the [dependencies] block in the
    // .gdextension, so the dynamic loader resolves it by name.
    return String("libMetaXRAudioUnity.so");
#else
    return ProjectSettings::get_singleton()->globalize_path("res://metaxr-audio/libMetaXRAudioUnity.so");
#endif
}
} // namespace

MetaXRAudioServer::MetaXRAudioServer()
{
    s_singleton = this;
    m_block.assign(kBlockFrames * 2, 0.0f);
    m_scratch_mono.assign(kBlockFrames, 0.0f);
    m_scratch_out.assign(kBlockFrames * 2, 0.0f);

    for (int i = 0; i < kMaxVoices; ++i)
        m_voices[i] = std::make_unique<Voice>();

    m_listener.forward[2] = -1.0f;
    m_listener.up[1]      =  1.0f;
    // No Initialise() here on purpose -- see IsAvailable().
}

void MetaXRAudioServer::EnsureInitialised()
{
    if (m_init_done)
        return;
    m_init_done = true;
    m_available = Initialise();
}

bool MetaXRAudioServer::IsAvailable()
{
    EnsureInitialised();
    return m_available;
}

godot::String MetaXRAudioServer::GetVersion()
{
    EnsureInitialised();
    return m_version;
}

godot::String MetaXRAudioServer::GetLastError()
{
    EnsureInitialised();
    return m_last_error;
}

MetaXRAudioServer::~MetaXRAudioServer()
{
    Shutdown();
    if (s_singleton == this)
        s_singleton = nullptr;
}

bool MetaXRAudioServer::Initialise()
{
    const String path = NativeLibraryPath();
    if (!Load(m_abi, path.utf8().get_data()))
    {
        m_last_error = "could not load " + path;
        UtilityFunctions::print("[MetaXRAudio] unavailable: ", m_last_error, " (falling back to AudioStreamPlayer3D)");
        return false;
    }

    int32_t maj = 0, min = 0, pat = 0;
    if (m_abi.get_version)
        m_abi.get_version(&maj, &min, &pat);
    m_version = vformat("%d.%d.%d", maj, min, pat);

    AudioServer* audio = AudioServer::get_singleton();
    if (audio == nullptr)
    {
        m_last_error = "AudioServer not available yet";
        Unload(m_abi);
        return false;
    }

    mxra_context_params params{};
    params.size            = sizeof(params);
    params.max_num_sources = kMaxVoices;
    params.sample_rate     = static_cast<uint32_t>(audio->get_mix_rate());
    params.buffer_length   = kBlockFrames;

    // The SDK only accepts 16000..48000. Godot's mix rate is configurable, so a
    // project set outside that range must fall back rather than run silent.
    if (params.sample_rate < 16000 || params.sample_rate > 48000)
    {
        m_last_error = vformat("mix rate %d outside the SDK's 16000-48000 range", params.sample_rate);
        UtilityFunctions::print("[MetaXRAudio] unavailable: ", m_last_error);
        Unload(m_abi);
        return false;
    }

    const mxra_result r = m_abi.context_create(&m_ctx, &params);
    if (r != MXRA_SUCCESS || m_ctx == nullptr)
    {
        // The SDK writes a non-null context even when it fails (issue 2 in
        // meta-xr-audio-known-issues.md), so the result code is the only
        // trustworthy signal here.
        m_last_error = vformat("mxra_context_create failed (%d)", static_cast<int>(r));
        UtilityFunctions::print("[MetaXRAudio] unavailable: ", m_last_error);
        m_ctx = nullptr;
        Unload(m_abi);
        return false;
    }

    UtilityFunctions::print("[MetaXRAudio] ready — SDK ", m_version,
                            ", ", params.sample_rate, " Hz, ", kMaxVoices, " voices");
    return true;
}

void MetaXRAudioServer::Shutdown()
{
    if (m_player && m_player->is_inside_tree())
    {
        m_player->stop();
        m_player->queue_free();
    }
    m_player = nullptr;
    m_stream.unref();

    if (m_ctx)
    {
        m_abi.context_shutdown(m_ctx);
        m_abi.context_destroy(m_ctx);
        m_ctx = nullptr;
    }
    if (m_abi.handle)
        Unload(m_abi);
    m_available = false;
}

void MetaXRAudioServer::EnsurePlayer()
{
    if (!m_available || m_player != nullptr)
        return;

    SceneTree* tree = Object::cast_to<SceneTree>(Engine::get_singleton()->get_main_loop());
    if (tree == nullptr || tree->get_root() == nullptr)
        return;

    m_stream.instantiate();
    m_player = memnew(AudioStreamPlayer);
    m_player->set_name("MetaXRAudioMixer");
    m_player->set_stream(m_stream);
    tree->get_root()->add_child(m_player);
    m_player->play();
}

// ---------------------------------------------------------------------------
// Main-thread API
// ---------------------------------------------------------------------------

void MetaXRAudioServer::SetListenerTransform(const Transform3D& xform)
{
    if (!m_available)
        return;

    const Vector3 origin  = xform.origin;
    // Godot cameras look down -Z; the SDK wants a +forward vector.
    const Vector3 forward = -xform.basis.get_column(2);
    const Vector3 up      =  xform.basis.get_column(1);

    const uint32_t seq = m_listener_seq.load(std::memory_order_relaxed);
    m_listener_seq.store(seq + 1, std::memory_order_release);   // odd: write in progress
    m_listener.position[0] = static_cast<float>(origin.x);
    m_listener.position[1] = static_cast<float>(origin.y);
    m_listener.position[2] = static_cast<float>(origin.z);
    m_listener.forward[0]  = static_cast<float>(forward.x);
    m_listener.forward[1]  = static_cast<float>(forward.y);
    m_listener.forward[2]  = static_cast<float>(forward.z);
    m_listener.up[0]       = static_cast<float>(up.x);
    m_listener.up[1]       = static_cast<float>(up.y);
    m_listener.up[2]       = static_cast<float>(up.z);
    m_listener_seq.store(seq + 2, std::memory_order_release);   // even: settled
}

void MetaXRAudioServer::SetRoom(const Vector3& size, const Vector3& centre, float reflectivity, float clutter)
{
    EnsureInitialised();
    if (!m_available || m_ctx == nullptr || !m_abi.shoebox_set_params)
        return;

    if (!m_room_enabled)
    {
        m_abi.context_set_feature(m_ctx, MXRA_FEATURE_SIMPLE_ROOM_MODELING, 1);
        m_abi.context_set_feature(m_ctx, MXRA_FEATURE_LATE_REVERBERATION, 1);
        m_room_enabled = true;
    }

    mxra_shoebox_params p{};
    p.size   = sizeof(p);
    p.width  = static_cast<float>(size.x > 0.1 ? size.x : 0.1);
    p.height = static_cast<float>(size.y > 0.1 ? size.y : 0.1);
    p.depth  = static_cast<float>(size.z > 0.1 ? size.z : 0.1);
    p.position[0] = static_cast<float>(centre.x);
    p.position[1] = static_cast<float>(centre.y);
    p.position[2] = static_cast<float>(centre.z);

    const float r = reflectivity < 0.0f ? 0.0f : (reflectivity > 1.0f ? 1.0f : reflectivity);
    for (int i = 0; i < 24; ++i)
        p.materials[i] = r;
    const float c = clutter < 0.0f ? 0.0f : (clutter > 1.0f ? 1.0f : clutter);
    for (int i = 0; i < 4; ++i)
        p.clutter[i] = c;

    m_abi.shoebox_set_params(m_ctx, &p);
}

void MetaXRAudioServer::ClearRoom()
{
    EnsureInitialised();
    if (!m_available || m_ctx == nullptr || !m_room_enabled)
        return;
    m_abi.context_set_feature(m_ctx, MXRA_FEATURE_LATE_REVERBERATION, 0);
    m_abi.context_set_feature(m_ctx, MXRA_FEATURE_SIMPLE_ROOM_MODELING, 0);
    m_room_enabled = false;
}

int MetaXRAudioServer::CreateVoice()
{
    EnsureInitialised();
    if (!m_available)
        return -1;

    EnsurePlayer();

    for (int i = 0; i < kMaxVoices; ++i)
    {
        Voice& v = *m_voices[i];
        bool expected = false;
        if (!v.active.compare_exchange_strong(expected, true, std::memory_order_acq_rel))
            continue;

        v.read_pos.store(0, std::memory_order_relaxed);
        v.write_pos.store(0, std::memory_order_relaxed);
        v.retiring.store(false, std::memory_order_relaxed);
        v.gain.store(1.0f, std::memory_order_relaxed);
        v.ever_sent = false;
        v.last_sent[0] = v.last_sent[1] = v.last_sent[2] = 1e30f;
        if (m_abi.source_reset)
            m_abi.source_reset(m_ctx, i);
        return i;
    }
    return -1;
}

void MetaXRAudioServer::DestroyVoice(int id)
{
    if (!m_available || id < 0 || id >= kMaxVoices)
        return;
    // Flagged rather than freed: the mixer may be mid-block on this voice. It
    // clears `active` itself once it has drained what is left.
    m_voices[id]->retiring.store(true, std::memory_order_release);
}

void MetaXRAudioServer::SetVoicePosition(int id, const Vector3& pos)
{
    if (!m_available || id < 0 || id >= kMaxVoices)
        return;
    Voice& v = *m_voices[id];

    const uint32_t seq = v.pose_seq.load(std::memory_order_relaxed);
    v.pose_seq.store(seq + 1, std::memory_order_release);
    v.pose[0] = static_cast<float>(pos.x);
    v.pose[1] = static_cast<float>(pos.y);
    v.pose[2] = static_cast<float>(pos.z);
    v.pose_seq.store(seq + 2, std::memory_order_release);
}

void MetaXRAudioServer::SetVoiceGain(int id, float gain)
{
    if (!m_available || id < 0 || id >= kMaxVoices)
        return;
    m_voices[id]->gain.store(gain, std::memory_order_relaxed);
}

int MetaXRAudioServer::VoiceFramesAvailable(int id) const
{
    if (!m_available || id < 0 || id >= kMaxVoices)
        return 0;
    return static_cast<int>(m_voices[id]->Available());
}

int MetaXRAudioServer::VoiceSpace(int id) const
{
    if (!m_available || id < 0 || id >= kMaxVoices)
        return 0;
    return static_cast<int>(m_voices[id]->Space());
}

int MetaXRAudioServer::VoiceFramesWanted(int id) const
{
    if (!m_available || id < 0 || id >= kMaxVoices)
        return 0;
    const Voice& v = *m_voices[id];
    const uint32_t target = m_target_fill.load(std::memory_order_relaxed);
    const uint32_t queued = v.Available();
    if (queued >= target)
        return 0;
    const uint32_t want  = target - queued;
    const uint32_t space = v.Space();
    return static_cast<int>(want < space ? want : space);
}

void MetaXRAudioServer::PushVoiceFrames(int id, const PackedFloat32Array& frames)
{
    if (!m_available || id < 0 || id >= kMaxVoices)
        return;
    Voice& v = *m_voices[id];
    if (!v.active.load(std::memory_order_acquire))
        return;

    const int n = static_cast<int>(frames.size());
    const uint32_t space = v.Space();
    const int count = static_cast<int>(n < static_cast<int>(space) ? n : space);
    uint32_t w = v.write_pos.load(std::memory_order_relaxed);
    const float* src = frames.ptr();
    for (int i = 0; i < count; ++i)
        v.ring[(w + i) & (Voice::kRingFrames - 1)] = src[i];
    v.write_pos.store(w + count, std::memory_order_release);
}

void MetaXRAudioServer::PushStereoFrames(int left_id, int right_id, const PackedVector2Array& frames)
{
    if (!m_available)
        return;
    const int n = static_cast<int>(frames.size());
    if (n <= 0)
        return;
    const Vector2* src = frames.ptr();

    // mode: 0 = left channel, 1 = right channel, 2 = downmix both to mono.
    auto push_channel = [&](int id, int mode)
    {
        if (id < 0 || id >= kMaxVoices)
            return;
        Voice& v = *m_voices[id];
        if (!v.active.load(std::memory_order_acquire))
            return;
        const uint32_t space = v.Space();
        const int count = static_cast<int>(n < static_cast<int>(space) ? n : space);
        uint32_t w = v.write_pos.load(std::memory_order_relaxed);
        for (int i = 0; i < count; ++i)
        {
            const float sample = (mode == 0) ? src[i].x
                               : (mode == 1) ? src[i].y
                                             : (src[i].x + src[i].y) * 0.5f;
            v.ring[(w + i) & (Voice::kRingFrames - 1)] = sample;
        }
        v.write_pos.store(w + count, std::memory_order_release);
    };

    // right_id < 0 means "single voice": downmix here rather than making the
    // caller run a per-sample loop in GDScript, which is far too slow to keep a
    // 48 kHz ring fed and simply starves the voice.
    if (right_id < 0)
    {
        push_channel(left_id, 2);
        return;
    }
    push_channel(left_id, 0);
    push_channel(right_id, 1);
}

void MetaXRAudioServer::SetTargetLatencyMs(float ms)
{
    AudioServer* audio = AudioServer::get_singleton();
    if (audio == nullptr)
        return;
    const double rate = audio->get_mix_rate();
    double frames = (ms / 1000.0) * rate;
    // Below one block the producer cannot keep up with the mixer at all; above
    // half the ring there is no headroom left to absorb a burst.
    const double lo = static_cast<double>(kBlockFrames * 2);
    const double hi = static_cast<double>(Voice::kRingFrames / 2);
    if (frames < lo) frames = lo;
    if (frames > hi) frames = hi;
    m_target_fill.store(static_cast<uint32_t>(frames), std::memory_order_relaxed);
}

float MetaXRAudioServer::GetTargetLatencyMs() const
{
    AudioServer* audio = AudioServer::get_singleton();
    if (audio == nullptr)
        return 0.0f;
    return static_cast<float>(m_target_fill.load(std::memory_order_relaxed) * 1000.0 / audio->get_mix_rate());
}

int MetaXRAudioServer::GetUnderrunCount() const
{
    return static_cast<int>(m_underruns.load(std::memory_order_relaxed));
}

void MetaXRAudioServer::ResetUnderrunCount()
{
    m_underruns.store(0, std::memory_order_relaxed);
    m_mix_calls.store(0, std::memory_order_relaxed);
    m_mix_frames.store(0, std::memory_order_relaxed);
    m_blocks.store(0, std::memory_order_relaxed);
    m_proc_ok.store(0, std::memory_order_relaxed);
    m_proc_fail.store(0, std::memory_order_relaxed);
}

Dictionary MetaXRAudioServer::GetMixStats() const
{
    Dictionary d;
    d["mix_calls"]  = (int64_t)m_mix_calls.load(std::memory_order_relaxed);
    d["mix_frames"] = (int64_t)m_mix_frames.load(std::memory_order_relaxed);
    d["blocks"]     = (int64_t)m_blocks.load(std::memory_order_relaxed);
    d["proc_ok"]    = (int64_t)m_proc_ok.load(std::memory_order_relaxed);
    d["proc_fail"]  = (int64_t)m_proc_fail.load(std::memory_order_relaxed);
    return d;
}

void MetaXRAudioServer::FlushVoice(int id)
{
    if (!m_available || id < 0 || id >= kMaxVoices)
        return;
    // Drop whatever is queued so a device that stops and later restarts does
    // not replay a stale tail. Moving the read cursor is safe from this side:
    // the mixer only ever advances it, and reading a slightly stale write_pos
    // just means one extra block drains.
    Voice& v = *m_voices[id];
    v.read_pos.store(v.write_pos.load(std::memory_order_acquire), std::memory_order_release);
}

int MetaXRAudioServer::GetActiveVoiceCount() const
{
    int n = 0;
    for (int i = 0; i < kMaxVoices; ++i)
        if (m_voices[i]->active.load(std::memory_order_relaxed))
            ++n;
    return n;
}

PackedVector2Array MetaXRAudioServer::RenderOffline(int frames)
{
    PackedVector2Array out;
    if (!m_available || frames <= 0)
        return out;
    out.resize(frames);
    std::vector<float> tmp(static_cast<size_t>(frames) * 2, 0.0f);
    MixInto(tmp.data(), frames);
    Vector2* dst = out.ptrw();
    for (int i = 0; i < frames; ++i)
        dst[i] = Vector2(tmp[i * 2], tmp[i * 2 + 1]);
    return out;
}

// ---------------------------------------------------------------------------
// Audio thread
// ---------------------------------------------------------------------------

void MetaXRAudioServer::ProcessBlock(float* out_interleaved)
{
    m_blocks.fetch_add(1, std::memory_order_relaxed);
    std::memset(out_interleaved, 0, sizeof(float) * kBlockFrames * 2);
    if (!m_available || m_ctx == nullptr)
        return;

    // Listener pose: retry until the seqlock reads even and unchanged.
    mxra_pose listener;
    for (;;)
    {
        const uint32_t s0 = m_listener_seq.load(std::memory_order_acquire);
        if (s0 & 1u) continue;
        listener = m_listener;
        if (m_listener_seq.load(std::memory_order_acquire) == s0)
            break;
    }
    m_abi.listener_set_pose(m_ctx, &listener);

    for (int i = 0; i < kMaxVoices; ++i)
    {
        Voice& v = *m_voices[i];
        if (!v.active.load(std::memory_order_acquire))
            continue;

        const uint32_t avail = v.Available();
        if (avail == 0)
        {
            if (!v.retiring.load(std::memory_order_relaxed))
                m_underruns.fetch_add(1, std::memory_order_relaxed);
            // A retiring voice with nothing left is safe to release. Doing it
            // here rather than in DestroyVoice means the slot is never reused
            // while the mixer is still reading it.
            if (v.retiring.load(std::memory_order_acquire))
                v.active.store(false, std::memory_order_release);
            continue;
        }

        const uint32_t take = avail < kBlockFrames ? avail : kBlockFrames;
        if (take < kBlockFrames)
            m_underruns.fetch_add(1, std::memory_order_relaxed);
        uint32_t r = v.read_pos.load(std::memory_order_relaxed);
        const float g = v.gain.load(std::memory_order_relaxed);
        for (uint32_t f = 0; f < take; ++f)
            m_scratch_mono[f] = v.ring[(r + f) & (Voice::kRingFrames - 1)] * g;
        for (uint32_t f = take; f < kBlockFrames; ++f)
            m_scratch_mono[f] = 0.0f;      // underrun: pad rather than stall
        v.read_pos.store(r + take, std::memory_order_release);

        float pos[3];
        for (;;)
        {
            const uint32_t s0 = v.pose_seq.load(std::memory_order_acquire);
            if (s0 & 1u) continue;
            pos[0] = v.pose[0]; pos[1] = v.pose[1]; pos[2] = v.pose[2];
            if (v.pose_seq.load(std::memory_order_acquire) == s0)
                break;
        }

        // Only touch the SDK when the position actually moved — see the comment
        // on Voice::last_sent.
        if (!v.ever_sent || pos[0] != v.last_sent[0] || pos[1] != v.last_sent[1] || pos[2] != v.last_sent[2])
        {
            m_abi.source_set_position(m_ctx, i, pos);
            v.last_sent[0] = pos[0]; v.last_sent[1] = pos[1]; v.last_sent[2] = pos[2];
            v.ever_sent = true;
        }

        uint32_t status = 0;
        const mxra_result pr = m_abi.source_process(m_ctx, i, &status, m_scratch_mono.data(),
                                 m_scratch_out.data(), MXRA_OUTPUT_INTERLEAVED);
        if (pr == MXRA_SUCCESS)
        {
            m_proc_ok.fetch_add(1, std::memory_order_relaxed);
            for (uint32_t f = 0; f < kBlockFrames * 2; ++f)
                out_interleaved[f] += m_scratch_out[f];
        }
        else
        {
            m_proc_fail.fetch_add(1, std::memory_order_relaxed);
        }
    }
}

void MetaXRAudioServer::MixInto(float* out, int frames)
{
    m_mix_calls.fetch_add(1, std::memory_order_relaxed);
    m_mix_frames.fetch_add((uint64_t)frames, std::memory_order_relaxed);
    int written = 0;
    while (written < frames)
    {
        if (m_block_used >= kBlockFrames)
        {
            ProcessBlock(m_block.data());
            m_block_used = 0;
        }
        const uint32_t left = kBlockFrames - m_block_used;
        const uint32_t want = static_cast<uint32_t>(frames - written);
        const uint32_t take = left < want ? left : want;
        std::memcpy(out + written * 2,
                    m_block.data() + m_block_used * 2,
                    sizeof(float) * take * 2);
        m_block_used += take;
        written += static_cast<int>(take);
    }
}

// ---------------------------------------------------------------------------

void MetaXRAudioServer::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("is_available"), &MetaXRAudioServer::IsAvailable);
    ClassDB::bind_method(D_METHOD("get_version"), &MetaXRAudioServer::GetVersion);
    ClassDB::bind_method(D_METHOD("get_last_error"), &MetaXRAudioServer::GetLastError);
    ClassDB::bind_method(D_METHOD("set_listener_transform", "transform"), &MetaXRAudioServer::SetListenerTransform);
    ClassDB::bind_method(D_METHOD("set_room", "size", "centre", "reflectivity", "clutter"), &MetaXRAudioServer::SetRoom);
    ClassDB::bind_method(D_METHOD("clear_room"), &MetaXRAudioServer::ClearRoom);
    ClassDB::bind_method(D_METHOD("create_voice"), &MetaXRAudioServer::CreateVoice);
    ClassDB::bind_method(D_METHOD("destroy_voice", "id"), &MetaXRAudioServer::DestroyVoice);
    ClassDB::bind_method(D_METHOD("set_voice_position", "id", "position"), &MetaXRAudioServer::SetVoicePosition);
    ClassDB::bind_method(D_METHOD("set_voice_gain", "id", "gain"), &MetaXRAudioServer::SetVoiceGain);
    ClassDB::bind_method(D_METHOD("voice_frames_available", "id"), &MetaXRAudioServer::VoiceFramesAvailable);
    ClassDB::bind_method(D_METHOD("voice_space", "id"), &MetaXRAudioServer::VoiceSpace);
    ClassDB::bind_method(D_METHOD("voice_frames_wanted", "id"), &MetaXRAudioServer::VoiceFramesWanted);
    ClassDB::bind_method(D_METHOD("push_voice_frames", "id", "frames"), &MetaXRAudioServer::PushVoiceFrames);
    ClassDB::bind_method(D_METHOD("push_stereo_frames", "left_id", "right_id", "frames"), &MetaXRAudioServer::PushStereoFrames);
    ClassDB::bind_method(D_METHOD("set_target_latency_ms", "ms"), &MetaXRAudioServer::SetTargetLatencyMs);
    ClassDB::bind_method(D_METHOD("get_target_latency_ms"), &MetaXRAudioServer::GetTargetLatencyMs);
    ClassDB::bind_method(D_METHOD("get_mix_stats"), &MetaXRAudioServer::GetMixStats);
    ClassDB::bind_method(D_METHOD("get_underrun_count"), &MetaXRAudioServer::GetUnderrunCount);
    ClassDB::bind_method(D_METHOD("reset_underrun_count"), &MetaXRAudioServer::ResetUnderrunCount);
    ClassDB::bind_method(D_METHOD("flush_voice", "id"), &MetaXRAudioServer::FlushVoice);
    ClassDB::bind_method(D_METHOD("get_active_voice_count"), &MetaXRAudioServer::GetActiveVoiceCount);
    ClassDB::bind_method(D_METHOD("render_offline", "frames"), &MetaXRAudioServer::RenderOffline);
}

} // namespace Xenu
