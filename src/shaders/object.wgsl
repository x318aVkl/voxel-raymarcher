

const NODE_EMPTY: u32 =  4294967295u;

struct Node {
    // contains either NODE_EMPTY if its empty
    // or a value to the start of its 64 sized region of blocks (4 by 4 by 4) or 8 sized of children (2 by 2 by 2)
    children_ptr: u32,
    // if leaf is set (1), this is a leaf node, and children_ptr points to blocks
    // if leaf is unset (0), this is not a leaf node, and children_ptr points to the child list
    leaf: u32,
    // the parent of this node, NODE_EMPTY if it is the root
    parent: u32,
    // filler value
    data: u32,
    // 64 bits, if bit i is set to 1, a block is there
    bitmask_low: u32,
    bitmask_high: u32,
}

// a leaf node is 1 unit wide, so a single small block is 1/4 width wide
// id 0 equals air, so nothing
struct Block {
    id: u32,
}

struct Uniforms {
    camera_view: mat4x4<f32>,
}


@group(0) @binding(0) var<uniform> system: Uniforms;

@group(1) @binding(0) var<storage, read> nodes: array<Node>;
@group(1) @binding(1) var<storage, read> child_list: array<u32>;
@group(1) @binding(2) var<storage, read> blocks_list: array<Block>;




fn pow_2(exponent: u32) -> u32 {
    return 1u << exponent;
}


fn extract_bitmask(node: Node) -> u64 {
    let low = u64(node.bitmask_low);
    let high = u64(node.bitmask_high);

    return (high << 32u) | low;
}


// Helper : Retourne si un bit spécifique est activé dans un masque 64 bits
fn is_bit_set(mask: u64, bit_index: u32) -> bool {
    const one: u64 = u64(1u);
    let shifted: u64 = mask >> bit_index;
    return (shifted & one) == one;
}

// Helper : Trouve l'index (0-7) du sous-cube (2x2x2) contenant un point localisé entre 0.0 et 1.0
fn get_octant_index(local_pos: vec3f) -> u32 {
    let x = select(0u, 1u, local_pos.x >= 0.5);
    let y = select(0u, 2u, local_pos.y >= 0.5);
    let z = select(0u, 4u, local_pos.z >= 0.5);
    return x | y | z;
}

// Helper : Trouve l'index (0-63) du voxel (4x4x4) dans un nœud feuille
fn get_block_index(local_pos: vec3f) -> u32 {
    let grid = clamp(vec3u(local_pos * 4.0), vec3u(0u), vec3u(3u));
    return grid.x + (grid.y * 4u) + (grid.z * 16u);
}


struct WorldPosition {
    grid: vec3<u32>,
    fract: vec3<f32>,
}

fn move_world(pos: WorldPosition, delta: vec3<f32>) -> WorldPosition {
    let integer = vec3<i64>(
        i64(delta.x),
        i64(delta.y),
        i64(delta.z),
    );

    var new_pos = pos;
    new_pos.grid.x = u32( i64(pos.grid.x) + integer.x );
    new_pos.grid.y = u32( i64(pos.grid.y) + integer.y );
    new_pos.grid.z = u32( i64(pos.grid.z) + integer.z );

    var fract = vec3<f32>(
        delta.x % 1.,
        delta.y % 1.,
        delta.z % 1.,
    );
    new_pos.fract += fract;

    if new_pos.fract.x > 1.0 {
        new_pos.fract.x -= 1.0;
        new_pos.grid.x += 1;
    }
    if new_pos.fract.x < 0.0 {
        new_pos.fract.x += 1.0;
        new_pos.grid.x -= 1;
    }

    if new_pos.fract.y > 1.0 {
        new_pos.fract.y -= 1.0;
        new_pos.grid.y += 1;
    }
    if new_pos.fract.y < 0.0 {
        new_pos.fract.y += 1.0;
        new_pos.grid.y -= 1;
    }

    if new_pos.fract.z > 1.0 {
        new_pos.fract.z -= 1.0;
        new_pos.grid.z += 1;
    }
    if new_pos.fract.z < 0.0 {
        new_pos.fract.z += 1.0;
        new_pos.grid.z -= 1;
    }

    return new_pos;
}

fn traverse_world_grid(
    position: WorldPosition, 
    ray_direction: vec3<f32>,
    current_cell_corner: vec3<u32>,
    current_cell_width: u32,
) -> WorldPosition {
    var next_pos = position;

    // 1. Déterminer la direction de progression sur chaque axe (+1 ou -1)
    let ray_sign = sign(ray_direction);
    let step_dir = vec3<i32>(ray_sign);

    // 2. Calculer la distance fractionnaire restante jusqu'à la prochaine face de la grille unitaire
    // Si la direction est positive, la distance jusqu'à la prochaine grille est (1.0 - fract)
    // Si la direction est négative, la distance jusqu'à la prochaine grille est fract
    let dist_to_boundary = select(position.fract, vec3<f32>(1.0) - position.fract, ray_direction > vec3<f32>(0.0));

    // 3. Calculer le paramètre 't' (le temps / la distance de voyage du rayon) pour chaque axe
    // On ajoute un petit epsilon pour éviter la division par zéro si ray_direction est nulle sur un axe
    let t_to_boundary = dist_to_boundary / (abs(ray_direction) + vec3<f32>(1e-6));

    // Si le rayon s'éloigne ou est parallèle sur un axe, on force un 't' immense pour l'ignorer
    let t_valid = select(vec3<f32>(1e38), t_to_boundary, abs(ray_direction) > vec3<f32>(0.0));

    // 4. Trouver quel axe rencontre la prochaine frontière en premier (le 't' minimal)
    var t_min = t_valid.x;
    var step_mask = vec3<i32>(1, 0, 0);

    if (t_valid.y < t_min) {
        t_min = t_valid.y;
        step_mask = vec3<i32>(0, 1, 0);
    }
    if (t_valid.z < t_min) {
        t_min = t_valid.z;
        step_mask = vec3<i32>(0, 0, 1);
    }

    // 5. Avancer la fraction globale du rayon de la distance t_min
    next_pos.fract = position.fract + ray_direction * t_min;

    // 6. Mettre à jour la grille entière et forcer la fraction de l'axe traversé à être exacte (0.0 ou 1.0)
    // Cela élimine l'accumulation d'erreurs f32 à chaque intersection
    let grid_step = step_mask * step_dir;
    next_pos.grid = vec3<u32>(vec3<i32>(position.grid) + grid_step);

    // Ajustement de la fraction pour l'axe qui a franchi la frontière
    if (step_mask.x == 1) {
        next_pos.fract.x = select(1.0, 0.0, ray_direction.x > 0.0);
    } else if (step_mask.y == 1) {
        next_pos.fract.y = select(1.0, 0.0, ray_direction.y > 0.0);
    } else if (step_mask.z == 1) {
        next_pos.fract.z = select(1.0, 0.0, ray_direction.z > 0.0);
    }

    // 7. Gérer les cas aux limites (Floating-point Snap)
    // Si à cause d'arrondis mineurs une autre coordonnée dépasse légèrement, on la remet d'équerre
    // et on ajuste la grille en conséquence
    if (next_pos.fract.x >= 1.0) { next_pos.fract.x -= 1.0; next_pos.grid.x += 1u; }
    if (next_pos.fract.x <  0.0) { next_pos.fract.x += 1.0; next_pos.grid.x -= 1u; }
    if (next_pos.fract.y >= 1.0) { next_pos.fract.y -= 1.0; next_pos.grid.y += 1u; }
    if (next_pos.fract.y <  0.0) { next_pos.fract.y += 1.0; next_pos.grid.y -= 1u; }
    if (next_pos.fract.z >= 1.0) { next_pos.fract.z -= 1.0; next_pos.grid.z += 1u; }
    if (next_pos.fract.z <  0.0) { next_pos.fract.z += 1.0; next_pos.grid.z -= 1u; }

    return next_pos;
}

fn traverse_world_grid_up_to_child(
    position: WorldPosition, 
    ray_direction: vec3<f32>,
    current_cell_corner: vec3<u32>,
    current_cell_width: u32,
    child_idx: u32,
) -> WorldPosition {
    var target_pos = position;

    // 1. Déterminer la position du sous-cube enfant cible dans la grille locale (0 ou 1 sur chaque axe)
    let child_x = child_idx % 2u;
    let child_y = (child_idx / 2u) % 2u;
    let child_z = child_idx / 4u;
    let child_offset_grid = vec3<u32>(child_x, child_y, child_z);

    // 2. Calculer la demi-largeur de la cellule courante
    let half_width = current_cell_width / 2u;

    // 3. Calculer les coordonnées absolues de début et de fin de l'enfant cible dans la grille entière
    let child_min_grid = current_cell_corner + child_offset_grid * half_width;
    let child_max_grid = child_min_grid + vec3<u32>(half_width);

    // 4. Calculer la position globale actuelle du rayon en combinant sa grille et sa fraction
    // On fait la soustraction en i32 par rapport au coin de l'enfant pour éviter les erreurs f32
    let local_grid_diff = vec3<i32>(position.grid) - vec3<i32>(child_min_grid);
    let current_local_pos = vec3<f32>(local_grid_diff) + position.fract;

    // 5. Vérifier si le rayon est déjà mathématiquement à l'intérieur des limites de l'enfant
    let half_width_f = f32(half_width);
    let inside_x = (current_local_pos.x >= 0.0) && (current_local_pos.x <= half_width_f);
    let inside_y = (current_local_pos.y >= 0.0) && (current_local_pos.y <= half_width_f);
    let inside_z = (current_local_pos.z >= 0.0) && (current_local_pos.z <= half_width_f);

    if (inside_x && inside_y && inside_z) {
        return position; // Déjà à l'intérieur, pas besoin de bouger
    }

    // 6. Calculer la distance 't' pour atteindre les faces d'entrée de l'enfant cible
    // Si la direction est positive, l'entrée est à la face 'min'. Si négative, l'entrée est à la face 'max'.
    let target_local_plane = select(vec3<f32>(half_width_f), vec3<f32>(0.0), ray_direction > vec3<f32>(0.0));
    
    // t = (plan_cible - position_actuelle) / direction
    let t_planes = (target_local_plane - current_local_pos) / (ray_direction + sign(ray_direction) * 1e-6);

    // Ne retenir que les plans devant le rayon (t > 0.0)
    let t_valid = select(vec3<f32>(1e38), t_planes, t_planes > vec3<f32>(0.0));

    // Trouver le 't' d'entrée le plus lointain parmi les axes valides (c'est l'entrée dans la boîte AABB)
    let t_enter = max(max(t_valid.x, t_valid.y), t_valid.z);

    // 7. Faire avancer la position du rayon de t_enter
    let advanced_local_pos = current_local_pos + ray_direction * t_enter;

    // 8. Reconstruire la WorldPosition finale par rapport au repère de l'enfant pour une précision absolue
    let integer_offset = vec3<i32>(floor(advanced_local_pos));
    
    target_pos.grid = vec3<u32>(vec3<i32>(child_min_grid) + integer_offset);
    target_pos.fract = advanced_local_pos - vec3<f32>(integer_offset);

    // 9. Sécurité pour le cas où la fraction vaut exactement 1.0 suite à l'arrondi de l'avancée
    if (target_pos.fract.x >= 1.0) { target_pos.fract.x -= 1.0; target_pos.grid.x += 1u; }
    if (target_pos.fract.y >= 1.0) { target_pos.fract.y -= 1.0; target_pos.grid.y += 1u; }
    if (target_pos.fract.z >= 1.0) { target_pos.fract.z -= 1.0; target_pos.grid.z += 1u; }
    if (target_pos.fract.x <  0.0) { target_pos.fract.x += 1.0; target_pos.grid.x -= 1u; }
    if (target_pos.fract.y <  0.0) { target_pos.fract.y += 1.0; target_pos.grid.y -= 1u; }
    if (target_pos.fract.z <  0.0) { target_pos.fract.z += 1.0; target_pos.grid.z -= 1u; }

    return target_pos;
}


struct RaymarchResult {
    hit: Block,
    steps: u32,
    distance: f32,
}

struct StoredStackNode {
    node: Node,
    node_ptr: u32,
    corner: vec3<u32>,
}

var<private> node_stack: array<StoredStackNode, 32>;
var<private> NODE_STACK_SIZE: u32 = 0;
const NODE_STACK_ALLOC: u32 = 32;

// adds a node to the stack
// returns 0 if no errors
// returns nonzero if error (stack full)
fn node_stack_push(node: Node, node_ptr: u32, corner: vec3<u32>) -> u32 {
    if (NODE_STACK_SIZE >= NODE_STACK_ALLOC) {
        return 1;
    }
    node_stack[NODE_STACK_SIZE] = StoredStackNode(node, node_ptr, corner);
    NODE_STACK_SIZE += 1;
    return 0;
}

fn node_stack_peek() -> StoredStackNode {
    if (NODE_STACK_SIZE == 0) {
        let node: Node = Node(0, 0, 0, 0, 0, 0);
        return StoredStackNode(node, NODE_EMPTY, vec3<u32>(0, 0, 0));
    }
    return node_stack[NODE_STACK_SIZE - 1];
}

fn node_stack_pop() -> StoredStackNode {
    if (NODE_STACK_SIZE == 0) {
        let node: Node = Node(0, 0, 0, 0, 0, 0);
        return StoredStackNode(node, NODE_EMPTY, vec3<u32>(0, 0, 0));
    }
    NODE_STACK_SIZE -= 1;
    return node_stack[NODE_STACK_SIZE];
}

fn node_stack_size() -> u32 {
    return NODE_STACK_SIZE;
}

fn check_ray_intersect_nonleaf(
    bitmask: u64,
    ray_position: WorldPosition,
    ray_direction: vec3<f32>,
    cell_corner_position: vec3<u32>,
) -> u32 {
    // ray position is somewhere on the faces of the grid cell
    // returns NODE_EMPTY if no intersect
    // returns the id of the child (0 to 7) of the intersect if it does intersect
    // bitmask bit nth is set to 1 if child n exists, n = i + j*2 + k*4
    // bitmask only needs 8 bits, but 64 are set, the first bits are the used ones

    // 1. Calculer la position locale du rayon à l'intérieur de la cellule courante (de 0.0 à 1.0)
    // Nous combinons la grille absolue et la fraction pour trouver le décalage par rapport au coin
    let grid_diff = vec3<i32>(ray_position.grid) - vec3<i32>(cell_corner_position);

    // 2. Convertir le delta entier en float et ajouter la partie fractionnaire
    let local_pos = vec3<f32>(grid_diff) + ray_position.fract;

    // 2. Trouver le sous-cube initial (enfant de 0 à 7) où se trouve le rayon en entrant
    // Le centre de la cellule est à 0.5 sur chaque axe
    let step_xyz = step(vec3<f32>(0.5), local_pos); // 1.0 si >= 0.5, sinon 0.0
    let child_idx_pos = vec3<u32>(step_xyz);
    let initial_child_id = child_idx_pos.x + (child_idx_pos.y * 2u) + (child_idx_pos.z * 4u);

    // 3. Vérifier si le sous-cube de départ est occupé dans le bitmask
    if ((bitmask & (u64(1u) << initial_child_id)) != u64(0u)) {
        return initial_child_id;
    }

    // 4. Si le sous-cube de départ est vide, le rayon doit voyager à l'intérieur de la cellule
    // Calculer les distances (t) jusqu'aux frontières des sous-cubes (les plans x=0.5, y=0.5, z=0.5)
    // On évite la division par zéro en ajoutant un epsilon ou en gérant le signe
    let t_target = select(vec3<f32>(0.5), vec3<f32>(0.5), ray_direction > vec3<f32>(0.0));
    
    // t = (position_cible - position_actuelle) / direction
    // Si la direction est proche de 0, la distance sera infinie (ce qui est correct pour l'algorithme)
    let t_planes = (t_target - local_pos) / (ray_direction + sign(ray_direction) * 1e-6);

    // Ignorer les axes où le rayon s'éloigne du plan médian
    let t_valid = select(vec3<f32>(1e38), t_planes, (t_planes >vec3<f32>(0.0)));

    // 5. Trouver quel plan médian (X, Y ou Z) est traversé en premier
    if (t_valid.x < t_valid.y && t_valid.x < t_valid.z) {
        // Le rayon traverse le plan X=0.5. On inverse le bit X du sous-cube initial.
        let next_child_id = initial_child_id ^ 1u;
        if (t_valid.x < 1.0 && (bitmask & (u64(1u) << next_child_id)) != u64(0u)) { return next_child_id; }
    } else if (t_valid.y < t_valid.x && t_valid.y < t_valid.z) {
        // Le rayon traverse le plan Y=0.5. On inverse le bit Y (valeur 2).
        let next_child_id = initial_child_id ^ 2u;
        if (t_valid.y < 1.0 && (bitmask & (u64(1u) << next_child_id)) != u64(0u)) { return next_child_id; }
    } else {
        // Le rayon traverse le plan Z=0.5. On inverse le bit Z (valeur 4).
        let next_child_id = initial_child_id ^ 4u;
        if (t_valid.z < 1.0 && (bitmask & (u64(1u) << next_child_id)) != u64(0u)) { return next_child_id; }
    }

    // Aucun sous-cube intersecté n'est actif dans le bitmask avant de sortir de la cellule
    return NODE_EMPTY;
}


fn ray_plane_intersect(
    source: WorldPosition,
    direction: vec3<f32>,
    plane_point: vec3<u32>,
    plane_normal: vec3<f32>,
) -> f32 {
    // the integer component in world position
    // might be too large to allow floating point calculations

    let dir_dot_n = dot(direction, plane_normal);
    if (abs(dir_dot_n) < 1e-5) {
        // the ray is parallel to the plane
        // return an infinite distance
        return 1e20;
    }

    let source_relative = vec3<f32>(vec3<i32>(plane_point) - vec3<i32>(source.grid)) - source.fract;


    let t = dot(source_relative, plane_normal) / dir_dot_n;

    return t;
}

// closest distance in the direction of the ray to a box plane
// ray doesnt have to be in the box, can be outside
fn approx_positive_distance_to_closest_box_plane(
    source: WorldPosition,
    direction: vec3<f32>,
    box_corner: vec3<u32>,
    box_width: u32,
) -> f32 {

    // compute the current local position based on grid points
    let source_relative = WorldPosition(source.grid - box_corner, source.fract);

    // x plane check
    var t_min = 1e10;
    if (abs(direction.x) > 1e-6 ) {
        // check the x plane only
        var t = ray_plane_intersect(source_relative, direction, vec3<u32>(box_width, 0, 0), vec3<f32>(1., 0., 0.));
        if (t > 1e-6) {
            t_min = min(t_min, t);
        }
        // check the x minus plane only
        t = ray_plane_intersect(source_relative, direction, vec3<u32>(0, 0, 0), vec3<f32>(-1., 0., 0.));
        if (t > 1e-6) {
            t_min = min(t_min, t);
        }
    }

    // y plane check
    if (abs(direction.y) > 1e-6) {
        // check the y plane only
        var t = ray_plane_intersect(source_relative, direction, vec3<u32>(0, box_width, 0), vec3<f32>(0., 1., 0.));
        if (t > 1e-6) {
            t_min = min(t_min, t);
        }
        // check the y minus plane only
        t = ray_plane_intersect(source_relative, direction, vec3<u32>(0, 0, 0), vec3<f32>(0., -1, 0.));
        if (t > 1e-6) {
            t_min = min(t_min, t);
        }
    }

    // z plane check
    if (abs(direction.z) > 1e-6) {
        // check the z plane only
        var t = ray_plane_intersect(source_relative, direction, vec3<u32>(0, 0, box_width), vec3<f32>(0., 0., 1.));
        if (t > 1e-6) {
            t_min = min(t_min, t);
        }
        // check the z minus plane only
        t = ray_plane_intersect(source_relative, direction, vec3<u32>(0, 0, 0), vec3<f32>(0., 0, -1.));
        if (t > 1e-6) {
            t_min = min(t_min, t);
        }
    }

    return t_min;
}


fn ray_box_intersect_old(
    source: WorldPosition,
    direction: vec3<f32>,
    box_corner: vec3<u32>,
    box_width: u32,
) -> WorldPosition {
    let dist = approx_positive_distance_to_closest_box_plane(
        source, direction, box_corner, box_width
    );

    var source_pos = vec3<f32>(source.grid - box_corner) + source.fract;
    
    let new_pos = source_pos + dist * direction;

    let box_width_f = f32(box_width);
    let half_width = box_width_f / 2.0;

    // since its on a face, one axis is exactly either 0 or 1
    // that axis should have exact result world pos as box_corner or box_corner + box_width
    let is_x = (new_pos.x < 1e-5) || (new_pos.x > (box_width_f*0.99999));
    let is_y = (new_pos.y < 1e-5) || (new_pos.y > (box_width_f*0.99999));
    let is_z = (new_pos.z < 1e-5) || (new_pos.z > (box_width_f*0.99999));

    var result_pos = WorldPosition(box_corner, vec3<f32>(0., 0., 0.));
    if (is_x) {
        // snap to x axis
        result_pos.grid.x += select(0u, box_width, new_pos.x > half_width);
    } else {
        // do not snap, but move with approximate fractional step
        let delta_int = u32(new_pos.x);
        let delta_fract = new_pos.x - f32(delta_int);
        result_pos.grid.x += delta_int;
        result_pos.fract.x += delta_fract;
    }
    if (is_y) {
        result_pos.grid.y += select(0u, box_width, new_pos.y > half_width);
    } else {
        // do not snap, but move with approximate fractional step
        let delta_int = u32(new_pos.y);
        let delta_fract = new_pos.y - f32(delta_int);
        result_pos.grid.y += delta_int;
        result_pos.fract.y += delta_fract;
    }
    if (is_z) {
        result_pos.grid.z += select(0u, box_width, new_pos.z > half_width);
    } else {
        // do not snap, but move with approximate fractional step
        let delta_int = u32(new_pos.z);
        let delta_fract = new_pos.z - f32(delta_int);
        result_pos.grid.z += delta_int;
        result_pos.fract.z += delta_fract;
    }

    return result_pos;
}



// Retourne la distance d'entrée (t_enter) et de sortie (t_exit) dans un vec2<f32>
// Si pas d'intersection, t_enter > t_exit
fn ray_box_distance(
    source: WorldPosition,
    direction: vec3<f32>,
    box_corner: vec3<u32>,
    box_width: u32,
) -> vec2<f32> {
    // 1. Soustraction sécurisée en i32 pour éviter les underflows u32
    let grid_diff = vec3<i32>(source.grid) - vec3<i32>(box_corner);
    let local_source = vec3<f32>(grid_diff) + source.fract;
    let local_target_max = vec3<f32>(f32(box_width));

    // 2. Éviter les divisions par zéro
    let inv_dir = vec3<f32>(1.0) / (direction + select(vec3<f32>(1e-6), vec3<f32>(-1e-6), direction < vec3<f32>(0.0)));

    // 3. Calculer les intersections avec les plans min et max de la boîte
    let t0 = (vec3<f32>(0.0) - local_source) * inv_dir;
    let t1 = (local_target_max - local_source) * inv_dir;

    // 4. Trier pour avoir t_min (entrée) et t_max (sortie) sur chaque axe
    let t_min_axes = min(t0, t1);
    let t_max_axes = max(t0, t1);

    // 5. Réduire les axes pour trouver l'intervalle global de la boîte
    let t_enter = max(max(t_min_axes.x, t_min_axes.y), t_min_axes.z);
    let t_exit = min(min(t_max_axes.x, t_max_axes.y), t_max_axes.z);

    return vec2<f32>(t_enter, t_exit);
}

fn ray_box_intersect_oldai(
    source: WorldPosition,
    direction: vec3<f32>,
    box_corner: vec3<u32>,
    box_width: u32,
) -> WorldPosition {
    let t_range = ray_box_distance(source, direction, box_corner, box_width);
    
    // Si le rayon commence en dehors, on prend t_enter. S'il commence dedans, on prend 0.0 (déjà dedans).
    // Si t_range.x > t_range.y, le rayon rate complètement la boîte.
    var dist = max(0.0, t_range.x);
    if (t_range.x > t_range.y) {
        return source; // Pas d'intersection valide, on retourne la position inchangée
    }

    // Calcul de la position locale par rapport au coin de la boîte
    let grid_diff = vec3<i32>(source.grid) - vec3<i32>(box_corner);
    let local_start = vec3<f32>(grid_diff) + source.fract;
    let local_end = local_start + dist * direction;

    var result_pos = source;
    let box_width_f = f32(box_width);

    // Détermination de l'axe de collision et alignement parfait (Snap)
    let eps = 1e-4;
    let on_min_face = local_end < vec3<f32>(eps);
    let on_max_face = local_end > vec3<f32>(box_width_f - eps);

    // Traitement de l'axe X
    if (on_min_face.x) {
        result_pos.grid.x = box_corner.x;
        result_pos.fract.x = 0.0;
    } else if (on_max_face.x) {
        result_pos.grid.x = box_corner.x + box_width;
        result_pos.fract.x = 0.0; 
    } else {
        let int_part = i32(floor(local_end.x));
        result_pos.grid.x = vec3<u32>(vec3<i32>(box_corner) + vec3<i32>(int_part, 0, 0)).x;
        result_pos.fract.x = local_end.x - f32(int_part);
    }

    // Traitement de l'axe Y
    if (on_min_face.y) {
        result_pos.grid.y = box_corner.y;
        result_pos.fract.y = 0.0;
    } else if (on_max_face.y) {
        result_pos.grid.y = box_corner.y + box_width;
        result_pos.fract.y = 0.0;
    } else {
        let int_part = i32(floor(local_end.y));
        result_pos.grid.y = vec3<u32>(vec3<i32>(box_corner) + vec3<i32>(0, int_part, 0)).y;
        result_pos.fract.y = local_end.y - f32(int_part);
    }

    // Traitement de l'axe Z
    if (on_min_face.z) {
        result_pos.grid.z = box_corner.z;
        result_pos.fract.z = 0.0;
    } else if (on_max_face.z) {
        result_pos.grid.z = box_corner.z + box_width;
        result_pos.fract.z = 0.0;
    } else {
        let int_part = i32(floor(local_end.z));
        result_pos.grid.z = vec3<u32>(vec3<i32>(box_corner) + vec3<i32>(0, 0, int_part)).z;
        result_pos.fract.z = local_end.z - f32(int_part);
    }

    return result_pos;
}



fn ray_box_intersect_oldai2(
    source: WorldPosition,
    direction: vec3<f32>,
    box_corner: vec3<u32>,
    box_width: u32,
) -> WorldPosition {
    let t_range = ray_box_distance(source, direction, box_corner, box_width);
    
    if (t_range.x > t_range.y) {
        return source; // Pas d'intersection valide (le rayon rate la boîte)
    }

    // --- CORRECTION ICI ---
    // Si t_enter (t_range.x) est négatif ou nul, cela signifie que le rayon démarre DÉJÀ dans la boîte.
    // Pour trouver la sortie de la boîte, on doit donc avancer de t_exit (t_range.y).
    // Si t_enter est positif, le rayon est à l'extérieur, on avance de t_enter (t_range.x).
    var dist = t_range.x;
    if (t_range.x <= 1e-5) {
        dist = t_range.y;
    }
    // ----------------------

    // Calcul de la position locale par rapport au coin de la boîte
    let grid_diff = vec3<i32>(source.grid) - vec3<i32>(box_corner);
    let local_start = vec3<f32>(grid_diff) + source.fract;
    let local_end = local_start + dist * direction;

    var result_pos = source;
    let box_width_f = f32(box_width);

    // Détermination de l'axe de collision et alignement parfait (Snap)
    let eps = 1e-4;
    let on_min_face = local_end < vec3<f32>(eps);
    let on_max_face = local_end > vec3<f32>(box_width_f - eps);

    // Traitement de l'axe X
    if (on_min_face.x) {
        result_pos.grid.x = box_corner.x;
        result_pos.fract.x = 0.0;
    } else if (on_max_face.x) {
        result_pos.grid.x = box_corner.x + box_width;
        result_pos.fract.x = 0.0; 
    } else {
        let int_part = i32(floor(local_end.x));
        result_pos.grid.x = vec3<u32>(vec3<i32>(box_corner) + vec3<i32>(int_part, 0, 0)).x;
        result_pos.fract.x = local_end.x - f32(int_part);
    }

    // Traitement de l'axe Y
    if (on_min_face.y) {
        result_pos.grid.y = box_corner.y;
        result_pos.fract.y = 0.0;
    } else if (on_max_face.y) {
        result_pos.grid.y = box_corner.y + box_width;
        result_pos.fract.y = 0.0;
    } else {
        let int_part = i32(floor(local_end.y));
        result_pos.grid.y = vec3<u32>(vec3<i32>(box_corner) + vec3<i32>(0, int_part, 0)).y;
        result_pos.fract.y = local_end.y - f32(int_part);
    }

    // Traitement de l'axe Z
    if (on_min_face.z) {
        result_pos.grid.z = box_corner.z;
        result_pos.fract.z = 0.0;
    } else if (on_max_face.z) {
        result_pos.grid.z = box_corner.z + box_width;
        result_pos.fract.z = 0.0;
    } else {
        let int_part = i32(floor(local_end.z));
        result_pos.grid.z = vec3<u32>(vec3<i32>(box_corner) + vec3<i32>(0, 0, int_part)).z;
        result_pos.fract.z = local_end.z - f32(int_part);
    }

    return result_pos;
}


fn ray_box_intersect(
    source: WorldPosition,
    direction: vec3<f32>,
    box_corner: vec3<u32>,
    box_width: u32,
) -> WorldPosition {
    // 1. Soustraction sécurisée pour éviter les underflows u32
    let grid_diff = vec3<i32>(source.grid) - vec3<i32>(box_corner);
    let local_source = vec3<f32>(grid_diff) + source.fract;
    let box_width_f = f32(box_width);

    // 2. Éviter les divisions par zéro de manière robuste
    let inv_dir = vec3<f32>(1.0) / (direction + select(vec3<f32>(1e-6), vec3<f32>(-1e-6), direction < vec3<f32>(0.0)));

    // 3. Calculer les distances vers le mur MIN (0) et le mur MAX (box_width) de cette boîte
    let t0 = (vec3<f32>(0.0) - local_source) * inv_dir;
    let t1 = (vec3<f32>(box_width_f) - local_source) * inv_dir;

    // Pour chaque axe, trouver quelle face est la face de SORTIE (selon le signe de la direction)
    let t_max_axes = max(t0, t1);

    // La distance minimale pour SORTIR de la boîte par la première face rencontrée
    var dist = min(min(t_max_axes.x, t_max_axes.y), t_max_axes.z);

    // Sûreté : si dist est négatif (ne devrait pas arriver si on est dedans), on ne bouge pas
    dist = max(0.0, dist);

    // 4. Calculer le point d'impact exact sur la face de sortie
    let local_end = local_source + dist * direction;

    var result_pos = source;

    // 5. Aligner parfaitement l'axe de collision (Snap) pour éliminer les erreurs de flottants
    let eps = 1e-3; // Tolérance légèrement augmentée pour intercepter les micro-dérives
    let on_min_face = local_end < vec3<f32>(eps);
    let on_max_face = local_end > vec3<f32>(box_width_f - eps);

    // Axe X
    if (on_min_face.x) {
        result_pos.grid.x = box_corner.x;
        result_pos.fract.x = 0.0;
    } else if (on_max_face.x) {
        result_pos.grid.x = box_corner.x + box_width;
        result_pos.fract.x = 0.0; 
    } else {
        let int_part = i32(floor(local_end.x));
        result_pos.grid.x = vec3<u32>(vec3<i32>(box_corner) + vec3<i32>(int_part, 0, 0)).x;
        result_pos.fract.x = local_end.x - f32(int_part);
    }

    // Axe Y
    if (on_min_face.y) {
        result_pos.grid.y = box_corner.y;
        result_pos.fract.y = 0.0;
    } else if (on_max_face.y) {
        result_pos.grid.y = box_corner.y + box_width;
        result_pos.fract.y = 0.0;
    } else {
        let int_part = i32(floor(local_end.y));
        result_pos.grid.y = vec3<u32>(vec3<i32>(box_corner) + vec3<i32>(0, int_part, 0)).y;
        result_pos.fract.y = local_end.y - f32(int_part);
    }

    // Axe Z
    if (on_min_face.z) {
        result_pos.grid.z = box_corner.z;
        result_pos.fract.z = 0.0;
    } else if (on_max_face.z) {
        result_pos.grid.z = box_corner.z + box_width;
        result_pos.fract.z = 0.0;
    } else {
        let int_part = i32(floor(local_end.z));
        result_pos.grid.z = vec3<u32>(vec3<i32>(box_corner) + vec3<i32>(0, 0, int_part)).z;
        result_pos.fract.z = local_end.z - f32(int_part);
    }

    return result_pos;
}




// offset a world position by a vec3 offset
fn offset_old(
    source: WorldPosition,
    delta: vec3<f32>,
) -> WorldPosition {
    var result = source;

    if (delta.x >= 0.) {
        result.fract.x += delta.x;
    } else {
        result.grid.x -= 1;
        result.fract.x += 1.0 - delta.x;
    }

    if (delta.y >= 0.) {
        result.fract.y += delta.y;
    } else {
        result.grid.y -= 1;
        result.fract.y += 1.0 - delta.y;
    }

    if (delta.z >= 0.) {
        result.fract.z += delta.z;
    } else {
        result.grid.z -= 1;
        result.fract.z += 1.0 - delta.z;
    }

    if (result.fract.x >= 1.0) {
        result.grid.x += 1;
        result.fract.x -= 1.0;
    }
    if (result.fract.y >= 1.0) {
        result.grid.y += 1;
        result.fract.y -= 1.0;
    }
    if (result.fract.z >= 1.0) {
        result.grid.z += 1;
        result.fract.z -= 1.0;
    }

    return result;
}

fn offset(
    source: WorldPosition,
    delta: vec3<f32>,
) -> WorldPosition {
    var result = source;

    // 1. On applique directement le micro-décalage sur la fraction
    let raw_fract = source.fract + delta;

    // 2. On calcule la partie entière du déplacement (sera 0, 1, ou -1 pour un petit epsilon)
    // floor() gère nativement les nombres négatifs : floor(-0.0001) = -1.0
    let int_offset = vec3<i32>(floor(raw_fract));

    // 3. On met à jour la grille en passant par des i32 signés pour éviter les underflows de u32
    result.grid = vec3<u32>(vec3<i32>(source.grid) + int_offset);

    // 4. La nouvelle fraction est le reste (toujours garanti d'être entre 0.0 et 1.0)
    result.fract = raw_fract - vec3<f32>(int_offset);

    // 5. Sécurité d'arrondi flottant très stricte pour s'assurer de rester dans les bornes [0.0, 1.0[
    while (result.fract.x >= 1.0) { result.grid.x += 1u; result.fract.x -= 1.0; }
    while (result.fract.x <  0.0) { result.grid.x -= 1u; result.fract.x += 1.0; }
    
    while (result.fract.y >= 1.0) { result.grid.y += 1u; result.fract.y -= 1.0; }
    while (result.fract.y <  0.0) { result.grid.y -= 1u; result.fract.y += 1.0; }
    
    while (result.fract.z >= 1.0) { result.grid.z += 1u; result.fract.z -= 1.0; }
    while (result.fract.z <  0.0) { result.grid.z -= 1u; result.fract.z += 1.0; }

    return result;
}



fn get_ray_traversal_bitmask(
    local_source: vec3<f32>,
    direction: vec3<f32>,
    cell_width_f: f32
) -> u64 {
    let half_width_f = cell_width_f * 0.5;

    // 1. Déterminer le sous-cube d'entrée initial (0 à 7)
    let start_xyz = vec3<u32>(step(vec3<f32>(half_width_f), local_source));
    let start_id = start_xyz.x + start_xyz.y * 2u + start_xyz.z * 4u;
    
    // Initialisation du masque avec le premier enfant traversé
    var traversal_mask: u64 = (u64(1u) << start_id);

    // 2. Déterminer les pas de déplacement binaires (+1 pour X, +2 pour Y, +4 pour Z)
    // erhm this only flips bits in positive motion
    // let step_bit = vec3<u32>(
    //     select(0u, 1u, direction.x > 0.0),
    //     select(0u, 2u, direction.y > 0.0),
    //     select(0u, 4u, direction.z > 0.0)
    // );
    let step_bit = vec3<u32>(
        1u,
        2u,
        4u,
    );

    // 3. Calculer la distance 't' linéaire exacte pour atteindre chaque plan médian
    // On n'effectue la division que si le rayon se déplace sur cet axe pour éviter le NaN
    var tx = 1e38;
    if (abs(direction.x) > 1e-5) {
        tx = (half_width_f - local_source.x) / direction.x;
    }
    
    var ty = 1e38;
    if (abs(direction.y) > 1e-5) {
        ty = (half_width_f - local_source.y) / direction.y;
    }
    // 128 - 128.9
    // direction = -1.0
    // ty = 0.9
    
    var tz = 1e38;
    if (abs(direction.z) > 1e-5) {
        tz = (half_width_f - local_source.z) / direction.z;
    }

    // 4. Parcourir séquentiellement les cloisons rencontrées devant la caméra
    var current_id = start_id;
    // ex. 0010 for id 2, x = 0, y = 1, z = 0
    let eps = 1e-4;

    // 

    // Nous effectuons 3 passes indépendantes pour accumuler tous les quadrants traversés 
    // par ordre chronologique de distance.
    var n = 0;
    for (var passi = 0u; passi < 3u; passi += 1) {
        // Filtrer pour ne garder que les 't' valides (devant le rayon)
        let valid_x = select(1e38, tx, tx > 1e-5);
        let valid_y = select(1e38, ty, ty > 1e-5);
        let valid_z = select(1e38, tz, tz > 1e-5);

        let min_t = min(min(valid_x, valid_y), valid_z);

        // Si aucune cloison n'est devant le rayon ou si on sort de la cellule (t > 1.0)
        // thats an error, we exit if (position +/- t) > bounding box
        if ((min_t / cell_width_f) > 1.0 + eps) { 
            break; 
        }
        n += 1;

        // Appliquer la transition binaire (XOR) sur l'axe le plus proche
        if (min_t == valid_x) {
            // we must actually flip the bit, not just xor it
            current_id ^= step_bit.x;
            tx = -1e38; // Invalider pour la passe suivante
        } else if (min_t == valid_y) {
            current_id ^= step_bit.y;
            ty = -1e38;
        } else {
            current_id ^= step_bit.z;
            tz = -1e38;
        }

        // Ajouter le quadrant nouvellement pénétré au masque
        traversal_mask |= (u64(1u) << current_id);
    }

    return traversal_mask;
}



// Fonction utilitaire : Calcule la distance d'entrée (t_enter) dans l'AABB d'un enfant.
// Retourne un f32 représentant la distance d'impact. Si le rayon rate la boîte, renvoie 1e38.
fn get_child_aabb_distance(
    local_source: vec3<f32>,
    direction: vec3<f32>,
    child_min: vec3<f32>,
    child_max: vec3<f32>
) -> f32 {
    // Protection contre les divisions par zéro
    let inv_dir = 1.0 / (direction + select(vec3<f32>(1e-6), vec3<f32>(-1e-6), direction < vec3<f32>(0.0)));

    let t0 = (child_min - local_source) * inv_dir;
    let t1 = (child_max - local_source) * inv_dir;

    let t_min_axes = min(t0, t1);
    let t_max_axes = max(t0, t1);

    let t_enter = max(max(t_min_axes.x, t_min_axes.y), t_min_axes.z);
    let t_exit  = min(min(t_max_axes.x, t_max_axes.y), t_max_axes.z);

    let eps = 1e-4;
    // Si le rayon traverse la boîte et que l'intersection n'est pas complètement derrière lui
    if (t_enter <= t_exit + eps && t_exit >= -eps) {
        // Si le rayon commence déjà à l'intérieur, t_enter peut être négatif. 
        // On le sature à 0.0 car la distance pour l'atteindre est immédiate.
        return max(0.0, t_enter);
    }

    return 1e38; // Le rayon rate cette boîte
}


fn check_ray_intersect_nonleaf_new(
    bitmask: u64,
    ray_position: WorldPosition,
    ray_direction: vec3<f32>,
    cell_corner_position: vec3<u32>,
    cell_width: u32,
) -> u32 {
    let grid_diff = vec3<i32>(ray_position.grid) - vec3<i32>(cell_corner_position);
    let local_source = vec3<f32>(grid_diff) + ray_position.fract;
    let cell_width_f = f32(cell_width);
    let half_width_f = cell_width_f * 0.5;

    // 2. Récupérer le masque de trajectoire (converti explicitement en u32 pour la suite)
    let ray_traversal_mask = get_ray_traversal_bitmask(local_source, ray_direction, cell_width_f);

    //return select(0u, 1u, (ray_traversal_mask & (u64(1u) << 4)) != u64(0u));
    //return select(0u, 1u, abs(local_source.x - 127.9) < 1e-4);
    //return u32(ray_traversal_mask);

    // 3. Comparaison native en u32 (Uint, width: 4)
    let active_intersections = bitmask & ray_traversal_mask;
    if (active_intersections == u64(0u)) {
        return NODE_EMPTY; 
    }

    var closest_child_id: u32 = NODE_EMPTY;
    var min_distance: f32 = 1e30;

    // 4. Boucle d'élection géométrique
    for (var child_id = 0u; child_id < 8u; child_id += 1) {
        
        // CORRECTION DE TYPE : Toutes les constantes et variables ici sont des u32 (width: 4)
        let mask_shift: u64 = u64(1u) << child_id;
        let is_bit_set: bool = (active_intersections & mask_shift) != u64(0u);
        
        if (is_bit_set) {
            let i = child_id & 1u;
            let j = (child_id >> 1u) & 1u;
            let k = child_id >> 2u;

            let child_offset = vec3<f32>(f32(i), f32(j), f32(k));
            let child_min = child_offset * half_width_f;
            let child_max = child_min + vec3<f32>(half_width_f);

            let dist = get_child_aabb_distance(local_source, ray_direction, child_min, child_max);

            if (dist < min_distance) {
                min_distance = dist;
                closest_child_id = child_id;
            }
        }
    }

    return closest_child_id;
}







fn raymarch(
    source: WorldPosition,
    direction: vec3<f32>,
    max_distance: f32,
) -> RaymarchResult {
    let air = Block(0u);

    var actual_steps = 0u;

    var position: WorldPosition = source;

    // we start by pushing to the node stack the root node
    node_stack_push(nodes[0], 0, vec3<u32>(0, 0, 0));

    var max_stack_depth = 0u;

    // we start the main raymarching loop from a end node (no children) that contains the start position
    for (var iter = 0u; iter < 256u; iter += 1) {
        actual_steps += 1;

        //max_stack_depth = max(max_stack_depth, node_stack_size());

        // 1. Regarder le nœud au sommet de la pile sans le supprimer (peek)
        var item = node_stack_peek();
        if (item.node_ptr == NODE_EMPTY) { break; } // Plus rien dans l'arbre, on sort !

        // 2. NETTOYAGE CRITIQUE : Si le rayon est sorti des frontières de ce nœud, 
        // on doit le dépiler immédiatement et passer DIRECTEMENT au parent sans faire de calculs.
        let local_diff = vec3<i32>(position.grid) - vec3<i32>(item.corner);
        let width = pow_2(8u - (node_stack_size() - 1u)); 
        let width_i = i32(width);

        if (local_diff.x < 0 || local_diff.x >= width_i ||
            local_diff.y < 0 || local_diff.y >= width_i ||
            local_diff.z < 0 || local_diff.z >= width_i) {
            
            node_stack_pop(); // On retire ce nœud car le rayon l'a quitté
            continue;         // On passe directement à l'itération suivante pour tester le parent !
        }

        // --- À partir d'ici, on est GARANTI que 'position' est STRICTEMENT à l'intérieur d'item ---
        let node: Node = item.node;

        // if the current node if a leaf, check if the ray intersects the nodes blocks using the node bitmask
        if (node.leaf == 1) {
            // for now, return directly the hit as if the child was full
            return RaymarchResult(Block(1u), actual_steps, max_distance);
        } else {
            // this is not a leaf node
            // if this node has children, we have to check if the children that contains our current position is allocated
            // if it is, we go down to it and add both the current node and it to the stack
            
            let hit = check_ray_intersect_nonleaf_new(
                extract_bitmask(node),
                position,
                direction,
                item.corner,
                width,
            );


            //return RaymarchResult(Block(0u), hit, max_distance);

            //max_stack_depth = select(0u, 1u, (hit == NODE_EMPTY) && (actual_steps == 1));

            //return RaymarchResult(Block(0u), select(0u, 1u, hit == NODE_EMPTY), max_distance);

            if (hit != NODE_EMPTY) {
                // --- CAS A : ON DESCEND VERS UN ENFANT OCCUPÉ ---
                let child_ptr = child_list[node.children_ptr + hit];
                if (child_ptr == NODE_EMPTY) { return RaymarchResult(air, actual_steps, max_distance); }

                let own_half_width = pow_2(8u - node_stack_size());
                let i = hit % 2u;
                let j = (hit / 2u) % 2u;
                let k = hit / 4u;
                let child_corner = item.corner + vec3<u32>(i * own_half_width, j * own_half_width, k * own_half_width);

                // Réinsérer le parent et ajouter l'enfant
                //node_stack_push(item.node, item.node_ptr, item.corner);
                node_stack_push(nodes[child_ptr], child_ptr, child_corner);

                // /!\ CORRECTION CRITIQUE : 
                // On NE DOIT PAS appeler ray_box_intersect ici si le rayon est déjà dans l'enfant.
                // On utilise une fonction de distance de boîte. Si t_enter > 0, on avance à l'entrée de l'enfant.
                // Si t_enter == 0, on ne touche à rien car le rayon est déjà dedans !
                let t_range = ray_box_distance(position, direction, child_corner, own_half_width); 
                if (t_range.x > 1e-5) {
                    //position = ray_box_intersect(position, direction, child_corner, own_half_width);

                    // move directly
                    position = offset(position, direction * t_range.x * 1.001);
                
                    if (actual_steps == 1) {
                        //return RaymarchResult(Block(0u), select(0u, 1u, abs(t_range.y - 128.0) < 1e-4), max_distance);
                    }
                    
                    // Pas besoin de gros offset, un infime epsilon directionnel pour passer la face (ex: 1e-4)
                    //position = offset(position, direction * 1e-3);
                }

            } else {
                // Le nœud est vide, on l'enjambe d'un coup sec jusqu'à sa face de sortie !
                position = ray_box_intersect(position, direction, item.corner, width);
                position = offset(position, direction * 1e-3);

                //actual_steps += 1;
                
                node_stack_pop(); // On le supprime, le 'continue' du prochain tour remontera la pile proprement si besoin
            }
        }
    }

    return RaymarchResult(air, actual_steps, max_distance);
}



fn colormap_inferno(t_in: f32) -> vec3<f32> {
    let t = clamp(t_in, 0., 1.);
    // On sature la valeur entre 0.0 et 1.0 pour éviter les artefacts hors limites
    let x = clamp(t, 0.0, 1.0);

    // Approximation polynomiale de la courbe Inferno
    let r = 1.0 / (1.0 + exp(-11.5 * (x - 0.43)));
    let g = 0.95 * pow(x, 2.5) + 0.05 * x;
    let b = 0.90 * pow(x, 7.0) + 0.15 * sin(x * 3.14159265);

    return vec3<f32>(r, g, b);
}




struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) vertex_index: u32) -> VertexOutput {
    var out: VertexOutput;
    var pos = array<vec2<f32>, 3>(
        vec2<f32>(-1.0, -1.0), // Bas-gauche
        vec2<f32>( 3.0, -1.0), // Extrême droite hors-écran
        vec2<f32>(-1.0,  3.0)  // Extrême haut hors-écran
    );
    
    let x = pos[vertex_index].x;
    let y = pos[vertex_index].y;
    
    out.position = vec4<f32>(x, y, 0.0, 1.0);
    // Génère des UV parfaits de 0.0 à 1.0 sur l'écran
    out.uv = vec2<f32>(x * 0.5 + 0.5, 1.0 - (y * 0.5 + 0.5)); 
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {

    let frustum_relative = vec3<f32>(0.0, 0.0, 0.0);

    let x = 2.0 * in.uv.x - 1.0;
    let y = 2.0 * (1.0 - in.uv.y) - 1.0;

    let ray_target_world = vec3<f32>(
        x, 
        y, 
        1.0
    );

    var dir = normalize(ray_target_world);

    let world_halfway = vec3<u32>(
        128, 128, 128
    );

    var camera_root_world = WorldPosition(vec3<u32>(128, 128, 124), vec3<f32>(0.9, 0.9, 0.0));

    let world_offset = system.camera_view * vec4<f32>(0., 0., 0., 1.);
    camera_root_world = offset(camera_root_world, world_offset.xyz);

    let result = raymarch(
        camera_root_world,
        dir,
        2e10,
    );

    /*/
    return vec4<f32>(
        select(0., 1., result.steps == 0u),
        select(0., 1., result.steps == 1u),
        select(0., 1., result.steps == 2u),
        1.
    );
    */

    if (result.hit.id != 0) {
        if (result.hit.id == 1) {
            return vec4<f32>(1., 0.5, 0., 1.0);
        } else {
            return vec4<f32>(0., 1., 0., 1.0);
        }
    }

    return vec4<f32>(
        colormap_inferno(f32(result.steps) / 64.),
        1.
    );
    
    return vec4<f32>(0.1, 0.1, 0.1, 1.0);
}
