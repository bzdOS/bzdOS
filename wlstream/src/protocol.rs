//! Damage rect primitives for partial surface updates.

/// Axis-aligned rectangle (x, y, w, h) in pixels.
///
/// Used for damage regions in SURFACE_COMMIT events.
/// All coordinates are relative to the surface origin (top-left).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rect {
    pub x: u16,
    pub y: u16,
    pub w: u16,
    pub h: u16,
}

impl Rect {
    pub fn new(x: u16, y: u16, w: u16, h: u16) -> Self {
        Self { x, y, w, h }
    }

    pub fn zero() -> Self {
        Self {
            x: 0,
            y: 0,
            w: 0,
            h: 0,
        }
    }

    pub fn is_zero(&self) -> bool {
        self.w == 0 || self.h == 0
    }
}

/// Clamp damage rect to surface bounds.
///
/// Zero-sized damage means full surface (Wayland convention).
/// Returns `None` if the clamped rect has zero area (completely outside bounds).
pub fn clamp_damage(damage: Rect, surface_w: u16, surface_h: u16) -> Option<Rect> {
    if damage.is_zero() {
        return Some(Rect::new(0, 0, surface_w, surface_h));
    }

    let x = damage.x.min(surface_w);
    let y = damage.y.min(surface_h);
    let x2 = (damage.x.saturating_add(damage.w)).min(surface_w);
    let y2 = (damage.y.saturating_add(damage.h)).min(surface_h);

    let w = x2.saturating_sub(x);
    let h = y2.saturating_sub(y);

    if w == 0 || h == 0 {
        None
    } else {
        Some(Rect::new(x, y, w, h))
    }
}

/// Merge two damage rects into a single bounding rect (union).
pub fn merge_damage(d1: Rect, d2: Rect) -> Rect {
    if d1.is_zero() {
        return d2;
    }
    if d2.is_zero() {
        return d1;
    }

    let x1 = d1.x.min(d2.x);
    let y1 = d1.y.min(d2.y);
    let x2 = (d1.x.saturating_add(d1.w)).max(d2.x.saturating_add(d2.w));
    let y2 = (d1.y.saturating_add(d1.h)).max(d2.y.saturating_add(d2.h));

    Rect::new(x1, y1, x2.saturating_sub(x1), y2.saturating_sub(y1))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn damage_inside_bounds_passes_through() {
        let damage = Rect::new(10, 20, 30, 40);
        assert_eq!(
            clamp_damage(damage, 100, 100),
            Some(Rect::new(10, 20, 30, 40))
        );
    }

    #[test]
    fn damage_partially_outside_is_clamped() {
        let damage = Rect::new(80, 80, 50, 50);
        assert_eq!(
            clamp_damage(damage, 100, 100),
            Some(Rect::new(80, 80, 20, 20))
        );
    }

    #[test]
    fn damage_completely_outside_returns_none() {
        let damage = Rect::new(200, 200, 10, 10);
        assert_eq!(clamp_damage(damage, 100, 100), None);
    }

    #[test]
    fn damage_zero_size_means_full_surface() {
        let damage = Rect::new(0, 0, 0, 0);
        assert_eq!(
            clamp_damage(damage, 100, 100),
            Some(Rect::new(0, 0, 100, 100))
        );
    }

    #[test]
    fn damage_exactly_at_surface_edge_kept() {
        let damage = Rect::new(90, 90, 10, 10);
        assert_eq!(
            clamp_damage(damage, 100, 100),
            Some(Rect::new(90, 90, 10, 10))
        );
    }

    #[test]
    fn damage_with_overflow_xy_clamps() {
        let damage = Rect::new(65535, 65535, 100, 100);
        assert_eq!(clamp_damage(damage, 100, 100), None);
    }

    #[test]
    fn damage_zero_width_means_full_surface() {
        let damage = Rect::new(0, 0, 0, 50);
        assert_eq!(
            clamp_damage(damage, 100, 100),
            Some(Rect::new(0, 0, 100, 100))
        );
    }

    #[test]
    fn damage_zero_height_means_full_surface() {
        let damage = Rect::new(0, 0, 50, 0);
        assert_eq!(
            clamp_damage(damage, 100, 100),
            Some(Rect::new(0, 0, 100, 100))
        );
    }

    #[test]
    fn merge_disjoint_rects_returns_enclosing() {
        let d1 = Rect::new(0, 0, 10, 10);
        let d2 = Rect::new(20, 20, 10, 10);
        assert_eq!(merge_damage(d1, d2), Rect::new(0, 0, 30, 30));
    }

    #[test]
    fn merge_overlapping_rects_returns_enclosing() {
        let d1 = Rect::new(0, 0, 20, 20);
        let d2 = Rect::new(10, 10, 20, 20);
        assert_eq!(merge_damage(d1, d2), Rect::new(0, 0, 30, 30));
    }

    #[test]
    fn merge_same_rects_returns_same() {
        let d1 = Rect::new(5, 5, 10, 10);
        let d2 = Rect::new(5, 5, 10, 10);
        assert_eq!(merge_damage(d1, d2), Rect::new(5, 5, 10, 10));
    }

    #[test]
    fn merge_with_empty_returns_other() {
        let d1 = Rect::new(0, 0, 0, 0);
        let d2 = Rect::new(10, 10, 20, 20);
        assert_eq!(merge_damage(d1, d2), Rect::new(10, 10, 20, 20));
    }
}
