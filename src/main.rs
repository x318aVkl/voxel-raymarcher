use glam::Vec3;

use crate::{app::{App, ObjectHandle, Schedule}, camera::Camera, input::{Key, Keyboard, Mouse}, object::Block, time::Time};


mod app;
mod renderer;
mod object;
mod camera;
mod input;
mod time;


fn main() -> Result<(), Box<dyn std::error::Error>> {
    App::new()
        .add_system(Schedule::Startup, create_spawner)
        .add_system(Schedule::Update, move_camera)
        .add_system(Schedule::Update, update_spawner)
        .add_system(Schedule::Update, check_exit)
        .run()
}



fn create_spawner(app: &mut App) {

    // create the world object
    let world = app.create_object(crate::object::WORLD_SIZE);

    let mut block_data = [Block::VOID; 64];
    for i in 0..4 {
        for j in 0..4 {
            for k in 0..4 {

                if j < 5 {
                    if k >= 2 {
                        block_data[i + j*4 + k*16] = Block::STONE;
                    } else {
                        block_data[i + j*4 + k*16] = Block::GRASS;
                    }
                }
            }
        }
    }
    // println!("{:?}", block_data);

    //app.object_mut(world).set_block_at([0, 0, 0], block_data);

    // for i in (-200)..=200 {
    //     for j in (-200)..=200 {
    //         app.object_mut(world).set_block_at([i, 0, j], block_data);
    //     }
    // }

    app.insert_resource(Spawner { current_id: 0, world, block_data, max_distance: 50 })
}


struct Spawner {
    current_id: u32,
    world: ObjectHandle,
    block_data: [Block; 64],
    max_distance: u32,
}



fn update_spawner(app: &mut App) {
    let spawner = app.resource_mut::<Spawner>();
    let id = spawner.current_id;
    let max_distance = spawner.max_distance;
    if id <= max_distance {
        spawner.current_id += 1;
    }
    let block_data = spawner.block_data;
    let world = spawner.world;


    let world = app.object_mut(world);
    
    if id > max_distance {
        return;
    }

    if id == 0 {
        world.set_block_at([0, 0, 0], block_data);
    } else {
        let id = id as i64;
        for i in (-id)..=id {
            world.set_block_at([i, 0, -id], block_data);
            world.set_block_at([i, 0, id], block_data);
        }
        for i in (-id + 1)..id {
            world.set_block_at([-id, 0, i], block_data);
            world.set_block_at([id, 0, i], block_data);
        }
    }

    if id % 10 == 0 {// max_distance {
        world.allocator_info();
    }

}

fn move_camera(app: &mut App) {
    let keyboard = app.resource::<Keyboard>().clone();
    let mouse = app.resource::<Mouse>().clone();
    let dt = app.resource::<Time>().delta().as_secs_f32();

    //println!("fps = {:.1}", 1.0 / dt);

    let cam = app.resource_mut::<Camera>();

    let mut forward = cam.get_local(Vec3::Z).normalize();
    forward.y = 0.;
    let forward = forward.normalize();
    let side = -forward.cross(Vec3::Y).normalize();
    let up = Vec3::Y;

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
    cam.translate(delta * dt * 2.0);

    
    let delta = mouse.delta() * dt;
    cam.rotate_pitch_yaw(delta.y, delta.x);
    
}


fn check_exit(app: &mut App) {
    let keyboard = app.resource::<Keyboard>();

    if keyboard.just_pressed(Key::Escape) {
        app.exit();
    }
}