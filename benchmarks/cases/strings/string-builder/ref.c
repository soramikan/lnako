#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    long iterations = strtol(argv[argc - 1], NULL, 10);
    size_t length = 0;
    size_t capacity = 16;
    char *s = malloc(capacity);
    if (!s) return 1;
    s[0] = '\0';
    for (long i = 0; i < iterations; i++) {
        if (length + 3 > capacity) {
            while (length + 3 > capacity) capacity *= 2;
            char *next = realloc(s, capacity);
            if (!next) {
                free(s);
                return 1;
            }
            s = next;
        }
        s[length++] = 'a';
        s[length++] = 'b';
        s[length] = '\0';
    }
    printf("%zu\n", length);
    free(s);
    return 0;
}
