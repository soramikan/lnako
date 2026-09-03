def make_adder(a):
    return lambda b: a + b

g = make_adder(1)
n = 0
for _ in range(10000):
    n = g(n)
print(n)
