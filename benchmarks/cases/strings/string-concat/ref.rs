use std::env;

fn main() {
    let args: Vec<String> = env::args().collect();
    let iterations: usize = args[args.len() - 1].parse().unwrap();
    let mut s = String::new();
    for _ in 0..iterations {
        let mut next = String::with_capacity(s.len() + 2);
        next.push_str(&s);
        next.push_str("ab");
        s = next;
    }
    println!("{}", s.len());
}
