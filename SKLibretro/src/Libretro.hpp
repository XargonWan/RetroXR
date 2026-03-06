#pragma once

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/input_event.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include <memory>

namespace SK
{
class LibretroOptionCategory : public godot::RefCounted
{
    GDCLASS(LibretroOptionCategory, godot::RefCounted);

    friend class Libretro;

public:
    const godot::String& GetDescription() const { return m_desc; }
    const godot::String& GetInfo() const { return m_info; }

private:
    godot::String m_desc;
    godot::String m_info;

protected:
    static void _bind_methods()
    {
        godot::ClassDB::bind_method(godot::D_METHOD("GetDescription"), &GetDescription);
        godot::ClassDB::bind_method(godot::D_METHOD("GetInfo"), &GetInfo);
    }
};

class LibretroOptionValue : public godot::RefCounted
{
    GDCLASS(LibretroOptionValue, godot::RefCounted);

    friend class Libretro;

public:
    const godot::String& GetValue() const { return m_value; }
    const godot::String& GetLabel() const { return m_label; }

private:
    godot::String m_value;
    godot::String m_label;

protected:
    static void _bind_methods()
    {
        godot::ClassDB::bind_method(godot::D_METHOD("GetValue"), &GetValue);
        godot::ClassDB::bind_method(godot::D_METHOD("GetLabel"), &GetLabel);
    }
};

class LibretroOptionDefinition : public godot::RefCounted
{
    GDCLASS(LibretroOptionDefinition, godot::RefCounted);

    friend class Libretro;

public:
    const godot::String& GetDescription() const { return m_desc; }
    const godot::String& GetDescriptionCategorized() const { return m_desc_categorized; }
    const godot::String& GetInfo() const { return m_info; }
    const godot::String& GetInfoCategorized() const { return m_info_categorized; }
    const godot::String& GetCategoryKey() const { return m_category_key; }
    const godot::Array& GetValues() const { return m_values; }
    const godot::String& GetDefaultValue() const { return m_default_value; }

private:
    godot::String m_desc;
    godot::String m_desc_categorized;
    godot::String m_info;
    godot::String m_info_categorized;
    godot::String m_category_key;
    godot::Array m_values;
    godot::String m_default_value;
    
protected:
    static void _bind_methods()
    {
        godot::ClassDB::bind_method(godot::D_METHOD("GetDescription"), &GetDescription);
        godot::ClassDB::bind_method(godot::D_METHOD("GetDescriptionCategorized"), &GetDescriptionCategorized);
        godot::ClassDB::bind_method(godot::D_METHOD("GetInfo"), &GetInfo);
        godot::ClassDB::bind_method(godot::D_METHOD("GetInfoCategorized"), &GetInfoCategorized);
        godot::ClassDB::bind_method(godot::D_METHOD("GetCategoryKey"), &GetCategoryKey);
        godot::ClassDB::bind_method(godot::D_METHOD("GetValues"), &GetValues);
        godot::ClassDB::bind_method(godot::D_METHOD("GetDefaultValue"), &GetDefaultValue);
    }
};

class Wrapper;

class Libretro : public godot::Node
{
    GDCLASS(Libretro, godot::Node);

    friend class Wrapper;
    
public:
    Libretro();
    ~Libretro() = default;

    void StartContent(godot::MeshInstance3D* node, godot::String root_directory, godot::String core_name, godot::String game_path);
    void StopContent();
    void SetCoreOption(const godot::String& key, const godot::String& value);
    void SetInputEnabled(bool enabled);

    void ConnectOptionsReady(const godot::Callable& callable, uint32_t flags = 0u);

    void _exit_tree();
    void _input(const godot::Ref<godot::InputEvent>& event);
    void _process(double delta);

    /// Called from the emulation thread (via Wrapper::m_libretro_node) when options are ready.
    void NotifyOptionsReady();

private:
    std::unique_ptr<Wrapper> m_wrapper;

    godot::Dictionary GetOptionCategories();
    godot::Dictionary GetOptionDefinitions();
    godot::Dictionary GetOptionValues();

    static void _bind_methods();
};
}
