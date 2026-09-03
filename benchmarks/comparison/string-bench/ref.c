#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void) {
    size_t len = 0;
    size_t cap = 1;
    char *s = malloc(cap);
    if (!s) return 1;
    s[0] = '\0';

    for (int i = 0; i < 10000; i++) {
        if (len + 2 > cap) {
            cap = cap * 2;
            s = realloc(s, cap);
            if (!s) return 1;
        }
        s[len] = 'a';
        s[len + 1] = '\0';
        len++;
    }

    printf("%zu\n", len);
    free(s);
    return 0;
}
