use crate::{app::{App, Schedule}, object::Block};


mod app;
mod renderer;
mod object;


fn main() -> Result<(), Box<dyn std::error::Error>> {
    App::new()
        .add_system(Schedule::Startup, create_objects)
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
                println!("{:?}, {:?}", pos, pos.length());
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
    app.object_mut(world).set_block_at([1, 0, 0], block_data);

}