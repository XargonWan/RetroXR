#include "VlcPlayer.hpp"

#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include <vlc/vlc.h>

#include <algorithm>
#include <cstdlib>
#include <cstring>

using namespace godot;

namespace SK
{

static void set_plugin_path_env(const char *path)
{
#ifdef _WIN32
    _putenv_s("VLC_PLUGIN_PATH", path);
#else
    setenv("VLC_PLUGIN_PATH", path, 1);
#endif
}

VlcPlayer::VlcPlayer()
{
    // ~2 seconds of stereo headroom so brief main-thread stalls don't underrun.
    m_audio_ring.assign((size_t)m_audio_rate * m_audio_channels * 2, 0);
}

VlcPlayer::~VlcPlayer()
{
    release_player();
    if (m_vlc)
    {
        libvlc_release(static_cast<libvlc_instance_t *>(m_vlc));
        m_vlc = nullptr;
    }
}

void VlcPlayer::ensure_instance()
{
    if (m_vlc)
        return;
    // Point libVLC at the plugin tree we ship next to the extension.
    String plugins = ProjectSettings::get_singleton()->globalize_path("res://vlc-godot/plugins");
    set_plugin_path_env(plugins.utf8().get_data());

    const char *args[] = {
        "--no-video-title-show",
        "--no-snapshot-preview",
        "--quiet",
    };
    m_vlc = libvlc_new(sizeof(args) / sizeof(args[0]), args);
    if (!m_vlc)
        UtilityFunctions::push_error("VlcPlayer: libvlc_new failed (check VLC_PLUGIN_PATH: ", plugins, ")");
}

void VlcPlayer::release_player()
{
    if (m_mp)
    {
        libvlc_media_player_stop(static_cast<libvlc_media_player_t *>(m_mp));
        libvlc_media_player_release(static_cast<libvlc_media_player_t *>(m_mp));
        m_mp = nullptr;
    }
}

bool VlcPlayer::open(const String &path, bool is_dvd)
{
    ensure_instance();
    if (!m_vlc)
        return false;
    release_player();

    libvlc_instance_t *inst = static_cast<libvlc_instance_t *>(m_vlc);
    String p = path.replace("\\", "/");
    // Build an MRL. dvd:// for a DVD image (VIDEO_TS folder / .iso, dvdnav menus);
    // file:// for a plain media file (more robust on Windows than new_path).
    String mrl = is_dvd ? (String("dvd:///") + p) : (String("file:///") + p);
    libvlc_media_t *media = libvlc_media_new_location(inst, mrl.utf8().get_data());
    if (!media)
    {
        const char *err = libvlc_errmsg();
        UtilityFunctions::push_error("VlcPlayer: could not create media for ", mrl,
                                     " — ", err ? err : "(no libvlc error)");
        return false;
    }

    libvlc_media_player_t *mp = libvlc_media_player_new_from_media(media);
    libvlc_media_release(media);
    if (!mp)
        return false;
    m_mp = mp;

    libvlc_video_set_callbacks(mp, cb_lock, cb_unlock, cb_display, this);
    libvlc_video_set_format_callbacks(mp, cb_format, cb_cleanup);

    // Route audio to Godot: decode to interleaved S16 stereo @48k into our ring
    // buffer; the owner drains it into an AudioStreamGenerator on a 3D player.
    libvlc_audio_set_format(mp, "S16N", m_audio_rate, m_audio_channels);
    libvlc_audio_set_callbacks(mp, cb_audio_play, nullptr, nullptr, cb_audio_flush, nullptr, this);

    attach_events();
    return true;
}

void VlcPlayer::attach_events()
{
    if (!m_mp)
        return;
    libvlc_event_manager_t *em = libvlc_media_player_event_manager(static_cast<libvlc_media_player_t *>(m_mp));
    // cb_event uses a VLC-free signature in the header; the pointer types are
    // ABI-compatible, so cast to libvlc_callback_t at the attach site.
    libvlc_event_attach(em, libvlc_MediaPlayerEndReached,
                        reinterpret_cast<libvlc_callback_t>(&VlcPlayer::cb_event), this);
}

// ── transport ────────────────────────────────────────────────────────────────

void VlcPlayer::play()
{
    if (m_mp)
        libvlc_media_player_play(static_cast<libvlc_media_player_t *>(m_mp));
}

void VlcPlayer::pause()
{
    if (m_mp)
        libvlc_media_player_set_pause(static_cast<libvlc_media_player_t *>(m_mp), 1);
}

void VlcPlayer::stop()
{
    if (m_mp)
        libvlc_media_player_stop(static_cast<libvlc_media_player_t *>(m_mp));
}

void VlcPlayer::set_paused(bool paused)
{
    if (m_mp)
        libvlc_media_player_set_pause(static_cast<libvlc_media_player_t *>(m_mp), paused ? 1 : 0);
}

bool VlcPlayer::is_playing() const
{
    return m_mp && libvlc_media_player_is_playing(static_cast<libvlc_media_player_t *>(m_mp));
}

// ── video frame handoff ──────────────────────────────────────────────────────

void VlcPlayer::update_frame()
{
    std::lock_guard<std::mutex> lock(m_mutex);
    if (m_size_dirty && m_width > 0 && m_height > 0)
    {
        m_image = Image::create_empty(m_width, m_height, false, Image::FORMAT_RGBA8);
        m_texture = ImageTexture::create_from_image(m_image);
        m_size_dirty = false;
        m_frame_dirty = false;
        return;
    }
    if (!m_frame_dirty || m_texture.is_null() || m_image.is_null())
        return;
    m_image->set_data(m_width, m_height, false, Image::FORMAT_RGBA8, m_shared);
    m_texture->update(m_image);
    m_frame_dirty = false;
}

Ref<Texture2D> VlcPlayer::get_texture() const
{
    return m_texture;
}

Vector2i VlcPlayer::get_video_size() const
{
    return Vector2i((int)m_width, (int)m_height);
}

unsigned VlcPlayer::cb_format(void **opaque, char *chroma, unsigned *width,
                              unsigned *height, unsigned *pitches, unsigned *lines)
{
    VlcPlayer *self = static_cast<VlcPlayer *>(*opaque);
    unsigned w = *width;
    unsigned h = *height;
    std::memcpy(chroma, "RGBA", 4);
    *pitches = w * 4;
    *lines = h;
    {
        std::lock_guard<std::mutex> lock(self->m_mutex);
        self->m_width = w;
        self->m_height = h;
        self->m_decode.assign((size_t)w * h * 4, 0);
        self->m_shared.resize((int64_t)w * h * 4);
        self->m_size_dirty = true;
        self->m_frame_dirty = false;
    }
    return 1;
}

void VlcPlayer::cb_cleanup(void *opaque)
{
    VlcPlayer *self = static_cast<VlcPlayer *>(opaque);
    std::lock_guard<std::mutex> lock(self->m_mutex);
    self->m_decode.clear();
}

void *VlcPlayer::cb_lock(void *opaque, void **planes)
{
    VlcPlayer *self = static_cast<VlcPlayer *>(opaque);
    planes[0] = self->m_decode.empty() ? nullptr : self->m_decode.data();
    return nullptr;
}

void VlcPlayer::cb_unlock(void *opaque, void *picture, void *const *planes)
{
    (void)opaque;
    (void)picture;
    (void)planes;
}

void VlcPlayer::cb_display(void *opaque, void *picture)
{
    (void)picture;
    VlcPlayer *self = static_cast<VlcPlayer *>(opaque);
    std::lock_guard<std::mutex> lock(self->m_mutex);
    if (!self->m_decode.empty() && (size_t)self->m_shared.size() == self->m_decode.size())
    {
        std::memcpy(self->m_shared.ptrw(), self->m_decode.data(), self->m_decode.size());
        self->m_frame_dirty = true;
    }
}

void VlcPlayer::cb_event(const void *event, void *data)
{
    const libvlc_event_t *ev = static_cast<const libvlc_event_t *>(event);
    VlcPlayer *self = static_cast<VlcPlayer *>(data);
    if (ev->type == libvlc_MediaPlayerEndReached)
        self->call_deferred("emit_signal", "finished");
}

// ── DVD navigation / chapters / titles ───────────────────────────────────────

void VlcPlayer::navigate(int mode)
{
    if (m_mp)
        libvlc_media_player_navigate(static_cast<libvlc_media_player_t *>(m_mp), (unsigned)mode);
}

void VlcPlayer::menu_up() { navigate(libvlc_navigate_up); }
void VlcPlayer::menu_down() { navigate(libvlc_navigate_down); }
void VlcPlayer::menu_left() { navigate(libvlc_navigate_left); }
void VlcPlayer::menu_right() { navigate(libvlc_navigate_right); }
void VlcPlayer::menu_activate() { navigate(libvlc_navigate_activate); }
void VlcPlayer::menu_popup() { navigate(libvlc_navigate_popup); }

void VlcPlayer::go_to_menu()
{
    if (!m_mp)
        return;
    libvlc_media_player_t *mp = static_cast<libvlc_media_player_t *>(m_mp);
    // Find the first title flagged as a menu and jump to it — that returns the
    // dvdnav VM to the disc menu from anywhere in playback. (navigate(popup)
    // only requests a popup overlay, which most discs ignore mid-title.)
    libvlc_title_description_t **titles = nullptr;
    int n = libvlc_media_player_get_full_title_descriptions(mp, &titles);
    int menu_title = -1;
    if (n > 0 && titles)
    {
        for (int i = 0; i < n; ++i)
        {
            if (titles[i] && (titles[i]->i_flags & libvlc_title_menu))
            {
                menu_title = i;
                break;
            }
        }
        libvlc_title_descriptions_release(titles, n);
    }
    if (menu_title >= 0)
        libvlc_media_player_set_title(mp, menu_title);
    else
        libvlc_media_player_navigate(mp, libvlc_navigate_popup);   // fallback
}

void VlcPlayer::next_chapter()
{
    if (m_mp)
        libvlc_media_player_next_chapter(static_cast<libvlc_media_player_t *>(m_mp));
}

void VlcPlayer::prev_chapter()
{
    if (m_mp)
        libvlc_media_player_previous_chapter(static_cast<libvlc_media_player_t *>(m_mp));
}

void VlcPlayer::set_chapter(int chapter)
{
    if (m_mp)
        libvlc_media_player_set_chapter(static_cast<libvlc_media_player_t *>(m_mp), chapter);
}

int VlcPlayer::get_chapter() const
{
    return m_mp ? libvlc_media_player_get_chapter(static_cast<libvlc_media_player_t *>(m_mp)) : -1;
}

int VlcPlayer::get_chapter_count() const
{
    return m_mp ? libvlc_media_player_get_chapter_count(static_cast<libvlc_media_player_t *>(m_mp)) : 0;
}

void VlcPlayer::set_title(int title)
{
    if (m_mp)
        libvlc_media_player_set_title(static_cast<libvlc_media_player_t *>(m_mp), title);
}

int VlcPlayer::get_title() const
{
    return m_mp ? libvlc_media_player_get_title(static_cast<libvlc_media_player_t *>(m_mp)) : -1;
}

int VlcPlayer::get_title_count() const
{
    return m_mp ? libvlc_media_player_get_title_count(static_cast<libvlc_media_player_t *>(m_mp)) : 0;
}

bool VlcPlayer::is_in_menu() const
{
    if (!m_mp)
        return false;
    libvlc_media_player_t *mp = static_cast<libvlc_media_player_t *>(m_mp);
    int title = libvlc_media_player_get_title(mp);
    if (title < 0)
        return false;
    libvlc_title_description_t **titles = nullptr;
    int n = libvlc_media_player_get_full_title_descriptions(mp, &titles);
    bool menu = false;
    if (n > 0 && titles)
    {
        if (title < n && titles[title])
            menu = (titles[title]->i_flags & libvlc_title_menu) != 0;
        libvlc_title_descriptions_release(titles, n);
    }
    return menu;
}

// ── position / audio ─────────────────────────────────────────────────────────

double VlcPlayer::get_position() const
{
    return m_mp ? libvlc_media_player_get_position(static_cast<libvlc_media_player_t *>(m_mp)) : 0.0;
}

void VlcPlayer::set_position(double pos)
{
    if (m_mp)
        libvlc_media_player_set_position(static_cast<libvlc_media_player_t *>(m_mp), (float)pos);
}

int64_t VlcPlayer::get_length() const
{
    return m_mp ? libvlc_media_player_get_length(static_cast<libvlc_media_player_t *>(m_mp)) : 0;
}

int64_t VlcPlayer::get_time() const
{
    return m_mp ? libvlc_media_player_get_time(static_cast<libvlc_media_player_t *>(m_mp)) : 0;
}

void VlcPlayer::set_volume(int volume)
{
    if (m_mp)
        libvlc_audio_set_volume(static_cast<libvlc_media_player_t *>(m_mp), volume);
}

// ── Godot-routed audio ───────────────────────────────────────────────────────

int VlcPlayer::get_audio_rate() const { return m_audio_rate; }
int VlcPlayer::get_audio_channels() const { return m_audio_channels; }

void VlcPlayer::cb_audio_play(void *data, const void *samples, unsigned count, int64_t pts)
{
    (void)pts;
    VlcPlayer *self = static_cast<VlcPlayer *>(data);
    const int16_t *pcm = static_cast<const int16_t *>(samples);
    size_t n = (size_t)count * (size_t)self->m_audio_channels; // total int16 samples
    std::lock_guard<std::mutex> lock(self->m_audio_mutex);
    size_t cap = self->m_audio_ring.size();
    if (cap == 0)
        return;
    for (size_t i = 0; i < n; i++)
    {
        self->m_audio_ring[self->m_audio_tail] = pcm[i];
        self->m_audio_tail = (self->m_audio_tail + 1) % cap;
        if (self->m_audio_count < cap)
            self->m_audio_count++;
        else
            self->m_audio_head = (self->m_audio_head + 1) % cap; // overwrite oldest
    }
}

void VlcPlayer::cb_audio_flush(void *data, int64_t pts)
{
    (void)pts;
    VlcPlayer *self = static_cast<VlcPlayer *>(data);
    std::lock_guard<std::mutex> lock(self->m_audio_mutex);
    self->m_audio_head = 0;
    self->m_audio_tail = 0;
    self->m_audio_count = 0;
}

PackedVector2Array VlcPlayer::read_audio(int max_frames)
{
    PackedVector2Array out;
    int ch = m_audio_channels;
    if (ch < 1 || max_frames <= 0)
        return out;
    std::lock_guard<std::mutex> lock(m_audio_mutex);
    size_t cap = m_audio_ring.size();
    if (cap == 0)
        return out;
    int frames_avail = (int)(m_audio_count / (size_t)ch);
    int frames = std::min(max_frames, frames_avail);
    if (frames <= 0)
        return out;
    out.resize(frames);
    Vector2 *w = out.ptrw();
    for (int f = 0; f < frames; f++)
    {
        int16_t l = m_audio_ring[m_audio_head];
        m_audio_head = (m_audio_head + 1) % cap;
        int16_t r = l;
        if (ch >= 2)
        {
            r = m_audio_ring[m_audio_head];
            m_audio_head = (m_audio_head + 1) % cap;
        }
        for (int c = 2; c < ch; c++) // discard extra channels (we request stereo)
            m_audio_head = (m_audio_head + 1) % cap;
        w[f] = Vector2((float)l / 32768.0f, (float)r / 32768.0f);
        m_audio_count -= (size_t)ch;
    }
    return out;
}

// ── Audio-track / subtitle selection ─────────────────────────────────────────

static Array vlc_desc_to_array(libvlc_track_description_t *t)
{
    Array a;
    while (t)
    {
        Dictionary d;
        d["id"] = t->i_id;
        d["name"] = String::utf8(t->psz_name ? t->psz_name : "");
        a.append(d);
        t = t->p_next;
    }
    return a;
}

Array VlcPlayer::get_audio_tracks() const
{
    if (!m_mp)
        return Array();
    libvlc_media_player_t *mp = static_cast<libvlc_media_player_t *>(m_mp);
    libvlc_track_description_t *t = libvlc_audio_get_track_description(mp);
    Array a = vlc_desc_to_array(t);
    if (t)
        libvlc_track_description_list_release(t);
    return a;
}

int VlcPlayer::get_audio_track() const
{
    return m_mp ? libvlc_audio_get_track(static_cast<libvlc_media_player_t *>(m_mp)) : -1;
}

void VlcPlayer::set_audio_track(int id)
{
    if (m_mp)
        libvlc_audio_set_track(static_cast<libvlc_media_player_t *>(m_mp), id);
}

Array VlcPlayer::get_subtitle_tracks() const
{
    if (!m_mp)
        return Array();
    libvlc_media_player_t *mp = static_cast<libvlc_media_player_t *>(m_mp);
    libvlc_track_description_t *t = libvlc_video_get_spu_description(mp);
    Array a = vlc_desc_to_array(t);
    if (t)
        libvlc_track_description_list_release(t);
    return a;
}

int VlcPlayer::get_subtitle() const
{
    return m_mp ? libvlc_video_get_spu(static_cast<libvlc_media_player_t *>(m_mp)) : -1;
}

void VlcPlayer::set_subtitle(int id)
{
    if (m_mp)
        libvlc_video_set_spu(static_cast<libvlc_media_player_t *>(m_mp), id);
}

// ── bindings ─────────────────────────────────────────────────────────────────

void VlcPlayer::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("open", "path", "is_dvd"), &VlcPlayer::open, DEFVAL(true));
    ClassDB::bind_method(D_METHOD("play"), &VlcPlayer::play);
    ClassDB::bind_method(D_METHOD("pause"), &VlcPlayer::pause);
    ClassDB::bind_method(D_METHOD("stop"), &VlcPlayer::stop);
    ClassDB::bind_method(D_METHOD("set_paused", "paused"), &VlcPlayer::set_paused);
    ClassDB::bind_method(D_METHOD("is_playing"), &VlcPlayer::is_playing);

    ClassDB::bind_method(D_METHOD("update_frame"), &VlcPlayer::update_frame);
    ClassDB::bind_method(D_METHOD("get_texture"), &VlcPlayer::get_texture);
    ClassDB::bind_method(D_METHOD("get_video_size"), &VlcPlayer::get_video_size);

    ClassDB::bind_method(D_METHOD("navigate", "mode"), &VlcPlayer::navigate);
    ClassDB::bind_method(D_METHOD("menu_up"), &VlcPlayer::menu_up);
    ClassDB::bind_method(D_METHOD("menu_down"), &VlcPlayer::menu_down);
    ClassDB::bind_method(D_METHOD("menu_left"), &VlcPlayer::menu_left);
    ClassDB::bind_method(D_METHOD("menu_right"), &VlcPlayer::menu_right);
    ClassDB::bind_method(D_METHOD("menu_activate"), &VlcPlayer::menu_activate);
    ClassDB::bind_method(D_METHOD("menu_popup"), &VlcPlayer::menu_popup);
    ClassDB::bind_method(D_METHOD("go_to_menu"), &VlcPlayer::go_to_menu);

    ClassDB::bind_method(D_METHOD("next_chapter"), &VlcPlayer::next_chapter);
    ClassDB::bind_method(D_METHOD("prev_chapter"), &VlcPlayer::prev_chapter);
    ClassDB::bind_method(D_METHOD("set_chapter", "chapter"), &VlcPlayer::set_chapter);
    ClassDB::bind_method(D_METHOD("get_chapter"), &VlcPlayer::get_chapter);
    ClassDB::bind_method(D_METHOD("get_chapter_count"), &VlcPlayer::get_chapter_count);

    ClassDB::bind_method(D_METHOD("set_title", "title"), &VlcPlayer::set_title);
    ClassDB::bind_method(D_METHOD("get_title"), &VlcPlayer::get_title);
    ClassDB::bind_method(D_METHOD("get_title_count"), &VlcPlayer::get_title_count);
    ClassDB::bind_method(D_METHOD("is_in_menu"), &VlcPlayer::is_in_menu);

    ClassDB::bind_method(D_METHOD("get_position"), &VlcPlayer::get_position);
    ClassDB::bind_method(D_METHOD("set_position", "pos"), &VlcPlayer::set_position);
    ClassDB::bind_method(D_METHOD("get_length"), &VlcPlayer::get_length);
    ClassDB::bind_method(D_METHOD("get_time"), &VlcPlayer::get_time);
    ClassDB::bind_method(D_METHOD("set_volume", "volume"), &VlcPlayer::set_volume);

    ClassDB::bind_method(D_METHOD("get_audio_rate"), &VlcPlayer::get_audio_rate);
    ClassDB::bind_method(D_METHOD("get_audio_channels"), &VlcPlayer::get_audio_channels);
    ClassDB::bind_method(D_METHOD("read_audio", "max_frames"), &VlcPlayer::read_audio);

    ClassDB::bind_method(D_METHOD("get_audio_tracks"), &VlcPlayer::get_audio_tracks);
    ClassDB::bind_method(D_METHOD("get_audio_track"), &VlcPlayer::get_audio_track);
    ClassDB::bind_method(D_METHOD("set_audio_track", "id"), &VlcPlayer::set_audio_track);
    ClassDB::bind_method(D_METHOD("get_subtitle_tracks"), &VlcPlayer::get_subtitle_tracks);
    ClassDB::bind_method(D_METHOD("get_subtitle"), &VlcPlayer::get_subtitle);
    ClassDB::bind_method(D_METHOD("set_subtitle", "id"), &VlcPlayer::set_subtitle);

    ADD_SIGNAL(MethodInfo("finished"));
}

} // namespace SK
