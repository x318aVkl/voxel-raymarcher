use glam::Vec3;

use crate::{app::{App, Schedule}, camera::Camera, input::{Key, Keyboard, Mouse}, object::Block, time::Time};


mod app;
mod renderer;
mod object;
mod camera;
mod input;
mod time;


fn main() -> Result<(), Box<dyn std::error::Error>> {
    App::new()
        .add_system(Schedule::Startup, create_objects)
        .add_system(Schedule::Update, move_camera)
        .run()
}



fn create_objects(app: &mut App) {

    // create the world object
    let world = app.create_object();

    let mut block_data = [Block::STONE; 64];
    for i in 0..4 {
        for j in 0..4 {
            for k in 0..4 {
                let pos = glam::Vec3::new(
                    (i as f32) / 3. * 2.0 - 1.0,
                    (j as f32) / 3. * 2.0 - 1.0,
                    (k as f32) / 3. * 2.0 - 1.0,
                );
                if k > 0 {
                    block_data[i + j*4 + k*16] = Block::GRASS;
                }
                if pos.length() > 1.3 {
                    block_data[i + j*4 + k*16] = Block::VOID;
                }
            }
        }
    }

    app.object_mut(world).set_block_at([0, 0, 0], block_data);
    app.object_mut(world).set_block_at([0, 1, 0], block_data);
    app.object_mut(world).set_block_at([-1, 0, 0], block_data);

    app.object_mut(world).allocator_info();
}


fn move_camera(app: &mut App) {
    let keyboard = app.resource::<Keyboard>().clone();
    let mouse = app.resource::<Mouse>().clone();
    let dt = app.resource::<Time>().delta().as_secs_f32();

    //println!("fps = {:.1}", 1.0 / dt);

    let cam = app.resource_mut::<Camera>();

    let forward = cam.get_local(Vec3::Z);
    let side = cam.get_local(Vec3::X);
    let up = cam.get_local(Vec3::Y);

    let mut delta = Vec3::ZERO;
    if keyboard.pressed(Key::KeyA) {
        delta -= side;
    }
    if keyboard.pressed(Key::KeyD) {
        delta += side;
    }
    if keyboard.pressed(Key::Space) {
        delta += up;
    }
    if keyboard.pressed(Key::ShiftLeft) {
        delta -= up;
    }
    if keyboard.pressed(Key::KeyW) {
        delta += forward;
    }
    if keyboard.pressed(Key::KeyS) {
        delta -= forward;
    }
    cam.translate(delta * dt);

    /*
    let delta = mouse.delta() * dt;
    if delta.x.abs() > 1e-5 {
        cam.rotate(up, delta.x);
    }
    if delta.y.abs() > 1e-5 {
        cam.rotate(side, delta.y);
    }
    */
}
