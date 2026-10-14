use std::sync::Arc;

use wgpu::util::DeviceExt;
use winit::{event_loop::OwnedDisplayHandle, window::Window};

use crate::object::Object;



pub struct Renderer {

    window: Arc<Window>,
    instance: wgpu::Instance,
    device: wgpu::Device,
    queue: wgpu::Queue,
    size: winit::dpi::PhysicalSize<u32>,
    surface: wgpu::Surface<'static>,
    surface_format: wgpu::TextureFormat,
    
    #[allow(dead_code)]
    object_shader_module: wgpu::ShaderModule,
    object_render_pipeline: wgpu::RenderPipeline,
    object_bind_group_layout: wgpu::BindGroupLayout,

    uniforms_buffer: wgpu::Buffer,
    uniforms_bind_group: wgpu::BindGroup,
    #[allow(dead_code)]
    uniforms_bind_group_layout: wgpu::BindGroupLayout,

    cpu_uniforms: Uniforms,
}


#[repr(C)]
#[derive(Clone, Copy, bytemuck::NoUninit, bytemuck::AnyBitPattern)]
pub struct Uniforms {
    camera_view: [[f32; 4]; 4],
    aspect_ratio: f32,
    padding: [f32; 15],
}


impl Renderer {

    pub fn device(&self) -> &wgpu::Device {
        &self.device
    }

    pub fn queue(&self) -> &wgpu::Queue {
        &self.queue
    }

    pub fn object_bind_group_layout(&self) -> &wgpu::BindGroupLayout {
        &self.object_bind_group_layout
    }

    pub async fn new(
        display: OwnedDisplayHandle,
        window: Arc<Window>,
    ) -> Renderer {
         let instance = wgpu::Instance::new(wgpu::InstanceDescriptor::new_with_display_handle(
            Box::new(display),
        ));
        let adapter = instance
            .request_adapter(&wgpu::RequestAdapterOptions::default())
            .await
            .unwrap();

        let (device, queue) = adapter
            .request_device(&wgpu::DeviceDescriptor {
                required_features: wgpu::Features::SHADER_INT64,
                required_limits: wgpu::Limits {
                    max_storage_buffer_binding_size: adapter.limits().max_storage_buffer_binding_size,
                    max_buffer_size: adapter.limits().max_buffer_size,
                    ..wgpu::Limits::defaults()
                },
                memory_hints: wgpu::MemoryHints::Performance,
                ..Default::default()
            })
            .await
            .unwrap();

        println!("got device {:?}", device.adapter_info());

        let size = window.inner_size();

        let surface = instance.create_surface(window.clone()).unwrap();
        let cap = surface.get_capabilities(&adapter);
        let surface_format = cap.formats[0];

        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("object shader"),
            source: wgpu::ShaderSource::Wgsl(include_str!("shaders/object.wgsl").into()),
        });
        let bind_group_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("object pipeline bind group layout"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    count: None,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Buffer { 
                        ty: wgpu::BufferBindingType::Storage { read_only: true }, 
                        has_dynamic_offset: false, 
                        min_binding_size: std::num::NonZero::new((crate::object::WORLD_SIZE * std::mem::size_of::<crate::object::Node>()) as u64), 
                    }
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    count: None,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Buffer { 
                        ty: wgpu::BufferBindingType::Storage { read_only: true }, 
                        has_dynamic_offset: false, 
                        min_binding_size: std::num::NonZero::new((crate::object::WORLD_SIZE * crate::object::CHILD_PER_NODE / crate::object::CHILD_BUFFER_REDUCTION * std::mem::size_of::<u32>()) as u64), 
                    }
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 2,
                    count: None,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Buffer { 
                        ty: wgpu::BufferBindingType::Storage { read_only: true }, 
                        has_dynamic_offset: false, 
                        min_binding_size: std::num::NonZero::new((crate::object::WORLD_SIZE * crate::object::BLOCK_PER_NODE / crate::object::BLOCK_BUFFER_REDUCTION * std::mem::size_of::<crate::object::Block>()) as u64), 
                    }
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 3,
                    count: None,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Buffer { 
                        ty: wgpu::BufferBindingType::Storage { read_only: true }, 
                        has_dynamic_offset: false, 
                        min_binding_size: std::num::NonZero::new(((u16::MAX as usize) * std::mem::size_of::<[f32; 4]>()) as u64), 
                    }
                },
            ],
        });
        let uniforms_bind_group_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("object pipeline uniform bind group layout"),
            entries: &[
                // the uniforms buffer object for the camera
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    count: None,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Buffer { 
                        ty: wgpu::BufferBindingType::Uniform, 
                        has_dynamic_offset: false, 
                        min_binding_size: None, 
                    }
                },
            ],
        });
        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("object pipeline layout"),
            immediate_size: 0,
            bind_group_layouts: &[
                Some(&uniforms_bind_group_layout),
                Some(&bind_group_layout),
            ],
        });
        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("Ray Tracer Pipeline"),
            layout: Some(&pipeline_layout),
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: Some("vs_main"),
                buffers: &[], // No vertex data needs to be uploaded!
                compilation_options: Default::default(),
            },
            fragment: Some(wgpu::FragmentState {
                module: &shader,
                entry_point: Some("fs_main"),
                targets: &[Some(wgpu::ColorTargetState {
                    format: wgpu::TextureFormat::Bgra8UnormSrgb,
                    blend: Some(wgpu::BlendState::REPLACE),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
                compilation_options: Default::default(),
            }),
            primitive: wgpu::PrimitiveState {
                topology: wgpu::PrimitiveTopology::TriangleList,
                strip_index_format: None,
                front_face: wgpu::FrontFace::Ccw,
                cull_mode: None,
                ..Default::default()
            },
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview_mask: None,
            cache: None,
        });

        let window_size = window.inner_size();

        let uniforms_data = Uniforms {
            camera_view: [[1., 0., 0., 0.], [0., 1., 0., 0.], [0., 0., 1., 0.], [0., 0., 0., 1.]],
            aspect_ratio: (window_size.width as f32) / (window_size.height as f32),
            padding: [0.0; 15],
        };

        let uniforms_buffer = device.create_buffer_init(
            &wgpu::util::BufferInitDescriptor {
                label: Some("Storage Buffer"),
                contents: bytemuck::cast_slice(&[uniforms_data]),
                usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            }
        );


        let uniforms_bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("object uniforms bind group"),
            layout: &uniforms_bind_group_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: uniforms_buffer.as_entire_binding(),
                },
            ]
        });


        let renderer = Renderer {
            instance,
            window,
            device,
            queue,
            size,
            surface,
            surface_format,
            object_shader_module: shader,
            object_render_pipeline: pipeline,
            object_bind_group_layout: bind_group_layout,
            uniforms_bind_group_layout,
            uniforms_buffer,
            uniforms_bind_group,
            cpu_uniforms: uniforms_data
        };

        // Configure surface for the first time
        renderer.configure_surface();

        renderer
    }


    fn configure_surface(&self) {
         let surface_config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format: self.surface_format,
            color_space: wgpu::SurfaceColorSpace::Auto,
            // Request compatibility with the sRGB-format texture view we‘re going to create later.
            view_formats: vec![self.surface_format.add_srgb_suffix()],
            alpha_mode: wgpu::CompositeAlphaMode::Auto,
            width: self.size.width,
            height: self.size.height,
            desired_maximum_frame_latency: 2,
            present_mode: wgpu::PresentMode::AutoVsync,
        };
        self.surface.configure(&self.device, &surface_config);
    }
    

    pub fn resize(&mut self, new_size: winit::dpi::PhysicalSize<u32>) {
        self.size = new_size;

        // reconfigure the surface
        self.configure_surface();

        // also update the gpu uniforms with the new aspect ratio
        self.cpu_uniforms.aspect_ratio = (self.size.width as f32) / (self.size.height as f32);

        self.queue.write_buffer(
            &self.uniforms_buffer,
            0,
            bytemuck::cast_slice(&[self.cpu_uniforms]),
        );
    }


    pub fn render(&mut self, objects: &[Object]) {


        // Create texture view.
        // NOTE: We must handle Timeout because the surface may be unavailable
        // (e.g., when the window is occluded on macOS).
        let surface_texture = match self.surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(texture) => texture,
            wgpu::CurrentSurfaceTexture::Occluded | wgpu::CurrentSurfaceTexture::Timeout => return,
            wgpu::CurrentSurfaceTexture::Suboptimal(texture) => {
                drop(texture);
                self.configure_surface();
                return;
            }
            wgpu::CurrentSurfaceTexture::Outdated => {
                self.configure_surface();
                return;
            }
            wgpu::CurrentSurfaceTexture::Validation => {
                unreachable!("No error scope registered, so validation errors will panic")
            }
            wgpu::CurrentSurfaceTexture::Lost => {
                self.surface = self.instance.create_surface(self.window.clone()).unwrap();
                self.configure_surface();
                return;
            }
        };
        let texture_view = surface_texture
            .texture
            .create_view(&wgpu::TextureViewDescriptor {
                // Without add_srgb_suffix() the image we will be working with
                // might not be "gamma correct".
                format: Some(self.surface_format.add_srgb_suffix()),
                ..Default::default()
            });

        // Renders a GREEN screen
        let mut encoder = self.device.create_command_encoder(&Default::default());
        // Create the renderpass which will clear the screen.
        let mut renderpass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: None,
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: &texture_view,
                depth_slice: None,
                resolve_target: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Clear(wgpu::Color {r: 0.05, g: 0.05, b: 0.05, a: 1.0}),
                    store: wgpu::StoreOp::Store,
                },
            })],
            depth_stencil_attachment: None,
            timestamp_writes: None,
            occlusion_query_set: None,
            multiview_mask: None,
        });

        // If you wanted to call any drawing commands, they would go here.
        renderpass.set_pipeline(&self.object_render_pipeline);

        renderpass.set_bind_group(0, &self.uniforms_bind_group, &[]);

        for object in objects {
            // draw the object
            // bind the objects buffer
            
            renderpass.set_bind_group(1, object.bind_group(), &[]);

            renderpass.draw(0..3, 0..1); 
        }

        // End the renderpass.
        drop(renderpass);

        // Submit the command in the queue to execute
        self.queue.submit([encoder.finish()]);
        self.window.pre_present_notify();
        self.queue.present(surface_texture);

    }


    pub fn set_camera_transform(&mut self, t: glam::Mat4) {
        self.cpu_uniforms.camera_view = t.to_cols_array_2d();
        self.cpu_uniforms.aspect_ratio = (self.size.width as f32) / (self.size.height as f32);

        self.queue.write_buffer(
            &self.uniforms_buffer,
            0,
            bytemuck::cast_slice(&[self.cpu_uniforms]),
        );
    }

}