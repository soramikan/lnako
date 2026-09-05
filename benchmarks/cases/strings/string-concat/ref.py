import sys

iterations = int(sys.argv[-1])
s = ""
for _ in range(iterations):
    s = s + "ab"
print(len(s))
