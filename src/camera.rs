use glam::{Mat3, Mat4, Vec3, Vec4};



pub struct Camera {
    rotation: Mat3,
    translation: Vec3,
}


impl Camera {
    pub fn new() -> Self {
        Self { rotation: Mat3::IDENTITY, translation: Vec3::ZERO }
    }

    pub fn transform(&self) -> Mat4 {
        let mut t = Mat4::from_mat3(self.rotation);
        *t.col_mut(3) += Vec4::new(self.translation.x, self.translation.y, self.translation.z, 0.);
        t
    }

    pub fn translate(&mut self, delta: Vec3) {
        self.translation += delta;
    }

    pub fn rotate_pitch_yaw(&mut self, pitch: f32, yaw: f32) {

        let yaw_mat = Mat3::from_axis_angle(Vec3::Y, yaw);
        let pitch_mat = Mat3::from_axis_angle(Vec3::X, pitch);

        self.rotation = yaw_mat * self.rotation * pitch_mat;
    }

    pub fn get_local(&self, axis: Vec3) -> Vec3 {
        self.rotation * axis
    }
}

