

pub struct Camera {
    transform: glam::Mat4,
}


impl Camera {
    pub fn new() -> Self {
        Self { transform: glam::Mat4::IDENTITY }
    }

    pub fn transform(&self) -> &glam::Mat4 {
        &self.transform
    }

    pub fn translate(&mut self, delta: glam::Vec3) {
        *self.transform.col_mut(3) += glam::Vec4::new(delta.x, delta.y, delta.z, 0.);
    }
}

