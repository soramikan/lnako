#include <stdio.h>

int add1(int b) {
    return 1 + b;
}

int main(void) {
    int (*g)(int) = add1;
    int n = 0;
    for (int i = 0; i < 10000; i++) {
        n = g(n);
    }
    printf("%d\n", n);
    return 0;
}
