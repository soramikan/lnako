use std::env;

fn main() {
    let args: Vec<String> = env::args().collect();
    let mut x: i64 = args[args.len() - 2].parse().unwrap();
    let iterations: i64 = args[args.len() - 1].parse().unwrap();
    let mut total = 0_i64;
    for _ in 0..iterations {
        x = (x * 1_664_525 + 1_013_904_223) % 2_147_483_647;
        total += x % 1000;
    }
    println!("{total}");
}
