#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    long iterations = strtol(argv[argc - 1], NULL, 10);
    size_t length = 0;
    char *s = malloc(1);
    if (!s) return 1;
    s[0] = '\0';
    for (long i = 0; i < iterations; i++) {
        char *next = malloc(length + 3);
        if (!next) {
            free(s);
            return 1;
        }
        memcpy(next, s, length);
        next[length] = 'a';
        next[length + 1] = 'b';
        next[length + 2] = '\0';
        free(s);
        s = next;
        length += 2;
    }
    printf("%zu\n", length);
    free(s);
    return 0;
}
