#pragma once

#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/standard_material3d.hpp>

#include <cstdint>

#include <SDL3/SDL_video.h>

#include <libretro.h>

namespace SK
{
class VideoHandler
{
public:
    static void RefreshCallback(const void* data, uint32_t width, uint32_t height, size_t pitch);
    static uintptr_t HwRenderGetCurrentFramebuffer();
    static retro_proc_address_t HwRenderGetProcAddress(const char* sym);

    void Init(godot::MeshInstance3D* mesh);
    void DeInit();

    bool InitHwRenderContext(int32_t width, int32_t height);
    void SetImageFormat(godot::Image::Format format);
    void CreateTexture(int32_t width, int32_t height, godot::Image::Format image_format, godot::PackedByteArray pixel_data, bool flip_y);
    void UpdateTexture(godot::PackedByteArray pixel_data, bool flip_y);

    bool SetRotation(uint32_t rotation);
    bool GetOverscan(int32_t* overscan);
    bool GetCanDupe(bool* can_dupe);
    bool SetPixelFormat(const retro_pixel_format* pixel_format);
    bool SetGeometry(const retro_game_geometry* geometry);
    bool SetHwRender(retro_hw_render_callback* hw_render_callback);
    bool GetPreferredHwRender(retro_hw_context_type* hw_context_type) const;

private:
    godot::Ref<godot::StandardMaterial3D> m_original_surface_material_override = nullptr;
    godot::Ref<godot::StandardMaterial3D> m_new_material = nullptr;
    uint32_t m_last_width = 0;
    uint32_t m_last_height = 0;
    godot::Image::Format m_image_format;
    godot::Ref<godot::Image> m_image = nullptr;
    godot::Ref<godot::ImageTexture> m_texture = nullptr;
    SDL_Window* m_sdl_window = nullptr;
    SDL_GLContext m_sdl_gl_context = nullptr;

    uint32_t m_rotation = 0;
    retro_hw_context_reset_t m_context_reset = nullptr;
    retro_pixel_format m_pixel_format = RETRO_PIXEL_FORMAT_UNKNOWN;
    retro_hw_context_reset_t m_context_destroy = nullptr;
};
}
