use std::env;

fn main() {
    let args: Vec<String> = env::args().collect();
    let iterations: usize = args[args.len() - 1].parse().unwrap();
    let mut s = String::with_capacity(iterations * 2);
    for _ in 0..iterations {
        s.push_str("ab");
    }
    println!("{}", s.len());
}
