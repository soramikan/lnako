import sys

seed = int(sys.argv[-2])
iterations = int(sys.argv[-1])
x = seed
total = 0
for _ in range(iterations):
    x = (x * 1664525 + 1013904223) % 2147483647
    total += x % 1000
print(total)
