#pragma once

#include <cstdint>

#include <godot_cpp/classes/ref_counted.hpp>

class AeroSimNative : public godot::RefCounted {
    GDCLASS(AeroSimNative, godot::RefCounted)

protected:
    static void _bind_methods();

public:
    std::int32_t probe_value() const;
};
