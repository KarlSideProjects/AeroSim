#include "aerosim_probe.hpp"

#include <cstdlib>

int main() {
    return aerosim::probe_value() == 47 ? EXIT_SUCCESS : EXIT_FAILURE;
}
