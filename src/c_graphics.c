#include "c_graphics.h"

apparition_input *apparition_input_create_export(void) {
    return apparition_input_create();
}

void apparition_input_destroy_export(apparition_input *input) {
    apparition_input_destroy(input);
}

int apparition_input_wait_export(apparition_input *input) {
    return apparition_input_wait(input);
}

int apparition_input_next_text_export(apparition_input *input, char *text, size_t text_size) {
    return apparition_input_next_text(input, text, text_size);
}
