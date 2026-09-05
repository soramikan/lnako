#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc < 3) return 2;
    long long x = strtoll(argv[argc - 2], NULL, 10);
    long long iterations = strtoll(argv[argc - 1], NULL, 10);
    long long total = 0;
    for (long long i = 0; i < iterations; i++) {
        x = (x * 1664525 + 1013904223) % 2147483647;
        total += x % 1000;
    }
    printf("%lld\n", total);
    return 0;
}
