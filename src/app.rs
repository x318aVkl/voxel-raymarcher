use std::{collections::HashMap, error::Error, sync::Arc};

use wgpu::rwh::HasDisplayHandle;
use winit::{application::ApplicationHandler, event::WindowEvent, event_loop::{ActiveEventLoop, ControlFlow, EventLoop}, window::Window};

use crate::{object::Object, renderer::Renderer};


#[repr(usize)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Schedule {
    Startup,
    Update,
}
pub const N_SCHEDULES: usize = 2;

pub struct App {
    window: Option<Arc<Window>>,

    renderer: Option<Renderer>,

    objects: Vec<Object>,

    systems: Vec<Vec<Box<dyn Fn(&mut App)>>>,
}



impl ApplicationHandler for App {

    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        let window = event_loop.create_window(Window::default_attributes()).unwrap();

        let window = Arc::new(window);
        self.window = Some(Arc::clone(&window));

        self.renderer = Some(
            pollster::block_on(Renderer::new(
                event_loop.owned_display_handle(),
                Arc::clone(&window),
            ))
        );

        window.request_redraw();

        // run the startup systems
        self.run_systems(Schedule::Startup);
    }


    fn window_event(
        &mut self,
        event_loop: &ActiveEventLoop,
        window_id: winit::window::WindowId,
        event: winit::event::WindowEvent,
    )
    {
        match event {
            WindowEvent::CloseRequested => {
                println!("The close button was pressed; stopping");
                event_loop.exit();
            },
            WindowEvent::RedrawRequested => {
                // Redraw the application.
                //
                // It's preferable for applications that do not render continuously to render in
                // this event rather than in AboutToWait, since rendering in here allows
                // the program to gracefully handle redraws requested by the OS.

                // Draw.

                // Queue a RedrawRequested event.
                //
                // You only need to call this if you've determined that you need to redraw in
                // applications which do not always need to. Applications that redraw continuously
                // can render here instead.

                // run the update systems
                self.run_systems(Schedule::Update);

                if let Some(renderer) = self.renderer.as_mut() {
                    renderer.render(&self.objects);
                }
                self.window.as_ref().unwrap().request_redraw();
            },
            WindowEvent::Resized(size) => {
                if let Some(renderer) = self.renderer.as_mut() {
                    renderer.resize(size);
                }
            },
            _ => (),
        }
    }


}

impl App {

    pub fn new() -> Self {
        let mut s = vec![];
        for _ in 0..N_SCHEDULES {
            s.push(vec![]);
        }
        Self {
            window: None,
            renderer: None,
            objects: vec![],
            systems: s,
        }
    }

    pub fn add_system(&mut self, schedule: Schedule, system: impl Fn(&mut App) + 'static) -> &mut Self {

        self.systems[schedule as usize].push(Box::new(system));

        self
    }


    fn run_systems(&mut self, schedule: Schedule) {
        let mut i = 0;
        loop {
            if i >= self.systems[schedule as usize].len() {
                break;
            }
            self.systems[schedule as usize][i](unsafe {
                &mut *(self as *const App as *mut App)
            });
            i += 1;
        }
    }

    pub fn run(&mut self) -> Result<(), Box<dyn Error>> {
        let event_loop = EventLoop::new()?;

        event_loop.set_control_flow(ControlFlow::Poll);

        event_loop.run_app(self)?;

        Ok(())
    }




    pub fn create_object(&mut self) -> ObjectHandle {
        let renderer = self.renderer.as_ref().unwrap();

        self.objects.push(Object::new(renderer.device().clone(), renderer.queue().clone(), renderer.object_bind_group_layout()));
        
        ObjectHandle(self.objects.len() - 1)
    }

    pub fn object_mut(&mut self, handle: ObjectHandle) -> &mut Object {
        &mut self.objects[handle.0]
    }
}

#[derive(Clone, Copy, Debug)]
pub struct ObjectHandle(usize);