import sys

iterations = int(sys.argv[-1])
parts = []
for _ in range(iterations):
    parts.append("ab")
print(len("".join(parts)))
