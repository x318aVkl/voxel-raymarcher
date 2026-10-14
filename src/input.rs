use std::collections::HashSet;


use glam::Vec2;
use winit::{event::KeyEvent, keyboard::PhysicalKey};
pub use winit::keyboard::KeyCode as Key;


#[derive(Clone, Debug)]
pub struct Keyboard {
    just_pressed: HashSet<Key>,
    pressed: HashSet<Key>,
}


impl Keyboard {
    pub fn new() -> Self {
        Self { just_pressed: HashSet::new(), pressed: HashSet::new() }
    }

    pub fn just_pressed(&self, key: Key) -> bool {
        self.just_pressed.contains(&key)
    }

    pub fn pressed(&self, key: Key) -> bool {
        self.pressed.contains(&key)
    }

    pub fn clear_just_pressed(&mut self) {
        self.just_pressed.clear();
    }

    pub fn on_keyboard_event(&mut self, event: KeyEvent) {
        let code = match event.physical_key {
            PhysicalKey::Code(code) => code,
            _ => return
        };
        match event.state {
            winit::event::ElementState::Pressed => {
                self.just_pressed.insert(code);
                self.pressed.insert(code);
            },
            winit::event::ElementState::Released => {
                self.pressed.remove(&code);
            }
        }
    }
}


#[derive(Clone, Debug)]
pub struct Mouse {
    position: Vec2,
    delta: Vec2,
    initialized: bool,
}

impl Mouse {
    pub fn new() -> Self {
        Self { position: Vec2::ZERO, delta: Vec2::ZERO, initialized: false, }
    }
    pub fn on_cursor_moved(&mut self, new_pos: Vec2) {
        let delta = new_pos - self.position;
        self.position = new_pos;
        if self.initialized {
            self.delta = delta;
        } else {
            self.initialized = true;
        }
    }
    pub fn on_mouse_delta(&mut self, delta: Vec2) {
        self.delta = delta;
        self.position += delta;
    }
    pub fn clear_delta(&mut self) {
        self.delta = Vec2::ZERO;
    }
    pub fn delta(&self) -> Vec2 {
        self.delta
    }
}