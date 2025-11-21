#include "options_handler.hpp"

int main(int argc, const char **argv) {
    if (!runArmorTool(argc, argv)) {
        return 1;
    }
    return 0;
}