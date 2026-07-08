#include "aerosim_native.hpp"

#include "aerosim_probe.hpp"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

void AeroSimNative::_bind_methods() {
    ClassDB::bind_method(D_METHOD("probe_value"), &AeroSimNative::probe_value);
}

std::int32_t AeroSimNative::probe_value() const {
    return aerosim::probe_value();
}
