#include <stdio.h>

int main(void) {
    int n = 0;
    for (int i = 0; i < 10000; i++) {
        n += 1;
    }
    printf("%d\n", n);
    return 0;
}
