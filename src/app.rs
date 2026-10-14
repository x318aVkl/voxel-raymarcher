use std::{any::{Any, TypeId}, collections::HashMap, error::Error, sync::Arc};

use winit::{application::ApplicationHandler, dpi::LogicalSize, event::{DeviceEvent, WindowEvent}, event_loop::{ActiveEventLoop, ControlFlow, EventLoop}, window::{Window, WindowAttributes}};

use crate::{camera::Camera, input::{Keyboard, Mouse}, object::Object, renderer::Renderer, time::Time};


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

    resources: HashMap<TypeId, Box<dyn Any>>,
}



impl ApplicationHandler for App {

    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        let window = event_loop.create_window(WindowAttributes::default()
            .with_inner_size(LogicalSize::new(1920, 1080))
        ).unwrap();

        let window = Arc::new(window);
        self.window = Some(Arc::clone(&window));

        window.set_cursor_grab(winit::window::CursorGrabMode::Locked)
            .or_else(|_| window.set_cursor_grab(winit::window::CursorGrabMode::Confined))
            .unwrap();

        window.set_cursor_visible(false);

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

    fn device_event(
        &mut self,
        _event_loop: &ActiveEventLoop,
        _device_id: winit::event::DeviceId,
        event: winit::event::DeviceEvent,
    )
    {
        match event {
            DeviceEvent::MouseMotion { delta } => {
                let mouse = self.resource_mut::<Mouse>();
                mouse.on_mouse_delta(glam::Vec2::new(delta.0 as f32, delta.1 as f32));
            },
            _ => {}
        }
    }

    fn window_event(
        &mut self,
        event_loop: &ActiveEventLoop,
        _window_id: winit::window::WindowId,
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
                // refresh the time resource
                {
                    let time = self.resource_mut::<Time>();
                    time.refresh();
                }

                self.run_systems(Schedule::Update);

                if self.window.is_none() {
                    event_loop.exit();
                    return;
                }

                let camera = self.resource::<Camera>().transform().clone();

                if let Some(renderer) = self.renderer.as_mut() {
                    renderer.set_camera_transform(camera);
                    renderer.render(&self.objects);
                }
                self.window.as_ref().unwrap().request_redraw();

                // also clear the keyboard just pressed
                let keyboard = self.resource_mut::<Keyboard>();
                keyboard.clear_just_pressed();
                let mouse = self.resource_mut::<Mouse>();
                mouse.clear_delta();
                
            },
            WindowEvent::Resized(size) => {
                if let Some(renderer) = self.renderer.as_mut() {
                    renderer.resize(size);
                }
            },
            WindowEvent::KeyboardInput { device_id: _, event, is_synthetic: _ } => {
                let keyboard = self.resource_mut::<Keyboard>();
                keyboard.on_keyboard_event(event);
            },
            WindowEvent::CursorMoved { device_id: _, position } => {
                let new_pos = glam::Vec2::new(position.x as f32, position.y as f32);
                let mouse = self.resource_mut::<Mouse>();
                mouse.on_cursor_moved(new_pos);
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
            resources: Self::create_default_resources(),
        }
    }

    pub fn exit(&mut self) {
        self.window = None;
    }

    pub fn add_system(&mut self, schedule: Schedule, system: impl Fn(&mut App) + 'static) -> &mut Self {

        self.systems[schedule as usize].push(Box::new(system));

        self
    }

    pub fn insert_resource<T: 'static>(&mut self, res: T) {
        self.resources.insert(TypeId::of::<T>(), Box::new(res));
    }

    pub fn resource<T: 'static>(&self) -> &T {
        self.resources.get(&TypeId::of::<T>()).unwrap().downcast_ref().unwrap()
    }

    pub fn resource_mut<T: 'static>(&mut self) -> &mut T {
        self.resources.get_mut(&TypeId::of::<T>()).unwrap().downcast_mut().unwrap()
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

    pub fn create_object(&mut self, size: usize) -> ObjectHandle {
        let renderer = self.renderer.as_ref().unwrap();

        self.objects.push(Object::new(renderer.device().clone(), renderer.queue().clone(), renderer.object_bind_group_layout(), size));
        
        ObjectHandle(self.objects.len() - 1)
    }

    pub fn object_mut(&mut self, handle: ObjectHandle) -> &mut Object {
        &mut self.objects[handle.0]
    }

    pub fn create_default_resources() -> HashMap<TypeId, Box<dyn Any>> {

        let mut resources: HashMap<TypeId, Box<dyn Any>> = HashMap::new();
        resources.insert(TypeId::of::<Camera>(), Box::new(Camera::new()));
        resources.insert(TypeId::of::<Keyboard>(), Box::new(Keyboard::new()));
        resources.insert(TypeId::of::<Mouse>(), Box::new(Mouse::new()));
        resources.insert(TypeId::of::<Time>(), Box::new(Time::new()));

        resources
    }
}

#[derive(Clone, Copy, Debug)]
pub struct ObjectHandle(usize);