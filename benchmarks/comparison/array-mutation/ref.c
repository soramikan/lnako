#include <stdio.h>
#include <stdlib.h>

int main(void) {
    int *a = NULL;
    int n = 0;
    int cap = 0;
    for (int i = 1; i <= 1000; i++) {
        if (n >= cap) {
            cap = cap ? cap * 2 : 1;
            a = realloc(a, (size_t)cap * sizeof(int));
        }
        a[n++] = i;
    }
    printf("%d\n", n);
    free(a);
    return 0;
}
