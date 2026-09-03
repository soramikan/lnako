fn main() {
    let g = |b| 1 + b;
    let mut n = 0;
    for _ in 0..10000 {
        n = g(n);
    }
    println!("{}", n);
}
