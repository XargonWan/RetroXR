#pragma once

// VlcPlayer — a libVLC-backed video/DVD engine exposed to GDScript.
//
// Owns a libVLC instance + media player, decodes into a CPU RGBA buffer via
// libVLC's video callbacks, and hands the latest frame to Godot as an
// ImageTexture (poll get_texture() after calling update_frame() each frame).
// For DVDs it opens dvd:// (dvdnav) so real disc menus render into the picture;
// menu navigation and chapter/title control are forwarded to libVLC.
//
// libVLC types are kept out of this header (handles stored as void*, callbacks
// declared with the raw C signatures) so RegisterTypes and other TUs need not
// see <vlc/vlc.h>.

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/texture2d.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <cstdint>
#include <mutex>
#include <vector>

namespace Xenu
{
class VlcPlayer : public godot::RefCounted
{
    GDCLASS(VlcPlayer, godot::RefCounted);

public:
    VlcPlayer();
    ~VlcPlayer();

    // Open a DVD image (VIDEO_TS folder or .iso) via dvd:// (menus), or a plain
    // media path when is_dvd is false. Returns true on success.
    bool open(const godot::String &path, bool is_dvd = true);

    void play();
    void pause();
    void stop();
    void set_paused(bool paused);
    bool is_playing() const;

    // Copy the most recently decoded frame into the texture. Call once per frame
    // from the owning node's _process; cheap when no new frame arrived.
    void update_frame();
    godot::Ref<godot::Texture2D> get_texture() const;
    godot::Vector2i get_video_size() const;

    // DVD menu navigation (modes: activate=0,up=1,down=2,left=3,right=4,popup=5).
    void navigate(int mode);
    void menu_up();
    void menu_down();
    void menu_left();
    void menu_right();
    void menu_activate();
    void menu_popup();
    // Return to the disc's root menu (the "Menu" button). libVLC 3's navigate()
    // has no root-menu mode, so jump to the first menu-flagged title instead.
    void go_to_menu();

    void next_chapter();
    void prev_chapter();
    void set_chapter(int chapter);
    int get_chapter() const;
    int get_chapter_count() const;

    void set_title(int title);
    int get_title() const;
    int get_title_count() const;
    bool is_in_menu() const;

    double get_position() const;   // 0..1
    void set_position(double pos);
    int64_t get_length() const;    // ms
    int64_t get_time() const;      // ms
    void set_volume(int volume);   // 0..100 (libVLC internal gain)

    // Godot-routed audio: libVLC decodes to a PCM ring buffer here; the owner
    // pulls frames each _process into an AudioStreamGenerator on a 3D player, so
    // DVD sound is spatialised at the TV and follows Godot's volume/attenuation.
    int get_audio_rate() const;        // Hz (we request 48000)
    int get_audio_channels() const;    // channels (we request stereo = 2)
    // Pop up to max_frames stereo frames (L,R in -1..1); returns what was ready.
    godot::PackedVector2Array read_audio(int max_frames);

    // How far behind the decoder the playback currently is, in milliseconds --
    // i.e. the audio latency this ring is contributing. Diagnostic.
    int get_audio_backlog_ms() const;
    // Backlog the ring holds to, in milliseconds. Playback primes to this before
    // the first frame is served and is trimmed back to it if it ever exceeds it,
    // which is what keeps the latency fixed instead of drifting; see read_audio.
    // Raise it to hold the audio back against a slower video path.
    int get_audio_target_latency_ms() const;
    void set_audio_target_latency_ms(int ms);

    // Audio-track + subtitle (spu) selection for the options panel. Each entry is
    // { "id": int, "name": String }; id -1 disables (subtitles off).
    godot::Array get_audio_tracks() const;
    int get_audio_track() const;
    void set_audio_track(int id);
    godot::Array get_subtitle_tracks() const;
    int get_subtitle() const;
    void set_subtitle(int id);

protected:
    static void _bind_methods();

private:
    void ensure_instance();
    void attach_events();
    void release_player();

    // libVLC video callbacks (raw C signatures matching the libvlc typedefs).
    static void *cb_lock(void *opaque, void **planes);
    static void cb_unlock(void *opaque, void *picture, void *const *planes);
    static void cb_display(void *opaque, void *picture);
    static unsigned cb_format(void **opaque, char *chroma, unsigned *width,
                              unsigned *height, unsigned *pitches, unsigned *lines);
    static void cb_cleanup(void *opaque);
    // End-of-media event → deferred "finished" signal.
    static void cb_event(const void *event, void *data);
    // libVLC audio callbacks (VLC-free signatures matching the typedefs).
    static void cb_audio_play(void *data, const void *samples, unsigned count, int64_t pts);
    static void cb_audio_flush(void *data, int64_t pts);

    void *m_vlc = nullptr;   // libvlc_instance_t*
    void *m_mp = nullptr;    // libvlc_media_player_t*

    mutable std::mutex m_mutex;
    std::vector<uint8_t> m_decode;   // VLC writes here (single plane, RGBA)
    godot::PackedByteArray m_shared; // last complete frame, mutex-guarded
    unsigned m_width = 0;
    unsigned m_height = 0;
    bool m_frame_dirty = false;
    bool m_size_dirty = false;

    godot::Ref<godot::Image> m_image;
    godot::Ref<godot::ImageTexture> m_texture;

    // Audio PCM ring buffer (interleaved int16), filled on VLC's audio thread.
    mutable std::mutex m_audio_mutex;
    std::vector<int16_t> m_audio_ring;
    size_t m_audio_head = 0;
    size_t m_audio_tail = 0;
    size_t m_audio_count = 0;
    int m_audio_rate = 48000;
    int m_audio_channels = 2;
    // Target steady-state backlog, and whether we have reached it since the last
    // flush. Both are read under m_audio_mutex.
    int m_audio_target_ms = 60;
    bool m_audio_primed = false;
};
} // namespace Xenu
