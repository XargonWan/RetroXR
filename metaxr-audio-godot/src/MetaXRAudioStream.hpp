#pragma once

#include <godot_cpp/classes/audio_stream.hpp>
#include <godot_cpp/classes/audio_stream_playback.hpp>
#include <godot_cpp/classes/audio_frame.hpp>

namespace Xenu
{

/// Playback half of the mixer. Its _mix runs on Godot's audio thread and is the
/// only place the Meta context is touched during rendering.
class MetaXRAudioPlayback : public godot::AudioStreamPlayback
{
    GDCLASS(MetaXRAudioPlayback, godot::AudioStreamPlayback)

public:
    int32_t _mix(godot::AudioFrame* p_buffer, float p_rate_scale, int32_t p_frames) override;
    void    _start(double p_from_pos) override;
    void    _stop() override;
    bool    _is_playing() const override;

protected:
    static void _bind_methods() {}

private:
    bool m_playing = false;
};

/// The stream handed to the server's internal AudioStreamPlayer. Carries no
/// state of its own — everything lives in MetaXRAudioServer.
class MetaXRAudioStream : public godot::AudioStream
{
    GDCLASS(MetaXRAudioStream, godot::AudioStream)

public:
    godot::Ref<godot::AudioStreamPlayback> _instantiate_playback() const override;
    godot::String _get_stream_name() const override;
    double        _get_length() const override;
    bool          _is_monophonic() const override;

protected:
    static void _bind_methods() {}
};

} // namespace Xenu
