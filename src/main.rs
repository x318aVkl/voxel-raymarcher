use std::ops::RangeInclusive;

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
        .add_system(Schedule::Startup, setup)
        .add_system(Schedule::Update, move_camera)
        .add_system(Schedule::Update, update_spawner)
        .add_system(Schedule::Update, check_exit)
        .run()
}



fn setup(app: &mut App) {

    // create the world object
    let world = app.create_object(crate::object::WORLD_SIZE);

    let mut block_data = [Block::VOID; 64];
    for i in 0..4 {
        for j in 0..4 {
            for k in 0..4 {

                let cutoff = if (i > 0) & (i < 3) & (k > 0) & (k < 3) {3} else {2};
                if j < cutoff {
                    block_data[i + j*4 + k*16] = Block::new(1);
                }
            }
        }
    }
    // println!("{:?}", block_data);

    app.object_mut(world).load_palette_from_bytes(include_bytes!("../assets/palette.png")).unwrap();

    for i in 0..100 {
        app.object_mut(world).set_block_at([0, i, 0], block_data);
    }

    // for i in (-200)..=200 {
    //     for j in (-200)..=200 {
    //         app.object_mut(world).set_block_at([i, 0, j], block_data);
    //     }
    // }

    app.insert_resource(Spawner { current_id: 0, world, block_data, max_distance: 400, iterator: None });
}


struct Spawner {
    current_id: u32,
    world: ObjectHandle,
    block_data: [Block; 64],
    max_distance: u32,
    iterator: Option<RangeInclusive<i64>>,
}



fn update_spawner(app: &mut App) {
    let spawner = app.resource_mut::<Spawner>();
    let mut id = spawner.current_id;
    let max_distance = spawner.max_distance;
    if id > max_distance {
        return;
    }
    let block_data = spawner.block_data;
    let world = spawner.world;
    let iterator = spawner.iterator.clone();

    let mut iterator = if let Some(iterator) = iterator {
        iterator
    } else {
        spawner.current_id += 1;
        let lid = spawner.current_id as i64;
        spawner.iterator = Some((-lid)..=lid);
        id = lid as u32;
        spawner.iterator.clone().unwrap()
    };

    let world = app.object_mut(world);
    
    if id > max_distance {
        return;
    }

    if id == 0 {
        world.set_block_at([0, 0, 0], block_data);
    } else {
        let id = id as i64;

        if id < 160 {
            // place the actual blocks
            let h = id / 10 - 2;
            for _ in 0..20 {
                let i = if let Some(i) = iterator.next() {
                    i
                } else {
                    break;
                };
                world.set_block_at([i, h, -id], block_data);
                world.set_block_at([i, h, id], block_data);
                world.set_block_fill([i, h - 1, -id], Block::STONE);
                world.set_block_fill([i, h - 1, id], Block::STONE);

                if (i != (-id)) && (i != id) {
                    world.set_block_at([-id, h, i], block_data);
                    world.set_block_at([id, h, i], block_data);
                    world.set_block_fill([-id, h - 1, i], Block::STONE);
                    world.set_block_fill([id, h - 1, i], Block::STONE);
                }
            }
        } else {
            // place a filled block
            let h = id / 10 - 3;
            for _ in 0..60 {
                let i = if let Some(i) = iterator.next() {
                    i
                } else {
                    break;
                };
                world.set_block_fill([i, h, -id], Block::STONE);
                world.set_block_fill([i, h, id], Block::STONE);
                if (i != (-id)) && (i != id) {
                    world.set_block_fill([-id, h, i], Block::STONE);
                    world.set_block_fill([id, h, i], Block::STONE);
                }
            }
        }
    }

    if id % 100 == 0 {// max_distance {
        world.allocator_info();
    }

    // update the iterator
    app.resource_mut::<Spawner>().iterator = if iterator.is_empty() {None} else {Some(iterator)};

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