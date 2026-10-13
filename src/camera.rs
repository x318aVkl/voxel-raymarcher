use glam::{Mat3, Mat4, Vec3, Vec4};



pub struct Camera {
    rotation: Mat3,
    translation: Vec3,
}


impl Camera {
    pub fn new() -> Self {
        Self { rotation: Mat3::IDENTITY, translation: Vec3::ZERO, }
    }

    pub fn transform(&self) -> Mat4 {
        let mut t = Mat4::from_mat3(self.rotation);
        *t.col_mut(3) += Vec4::new(self.translation.x, self.translation.y, self.translation.z, 0.);
        t
    }

    pub fn translate(&mut self, delta: Vec3) {
        self.translation += delta;
    }

    pub fn rotate(&mut self, axis: Vec3, angle: f32) {
        let rot_block = Mat3::from_axis_angle(axis, angle);
        self.rotation = rot_block * self.rotation;
    }

    pub fn get_local(&self, axis: Vec3) -> Vec3 {
        self.rotation * axis
    }
}

