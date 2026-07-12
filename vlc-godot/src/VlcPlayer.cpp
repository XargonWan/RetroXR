#include "VlcPlayer.hpp"

#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <vlc/vlc.h>

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

VlcPlayer::VlcPlayer() {}

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

    ADD_SIGNAL(MethodInfo("finished"));
}

} // namespace SK
