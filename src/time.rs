use std::time::{Duration, Instant};


#[derive(Clone)]
pub struct Time {
    last: Instant,
    delta: Duration,
}

impl Time {
    pub fn new() -> Self {
        Self { last: Instant::now(), delta: Duration::from_secs_f32(1e-5) }
    }

    pub fn refresh(&mut self) {
        let new = Instant::now();
        self.delta = new - self.last;
        self.last = new;
    }

    pub fn delta(&self) -> Duration {
        self.delta
    }
}
