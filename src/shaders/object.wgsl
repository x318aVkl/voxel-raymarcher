

const NODE_EMPTY: u32 =  4294967295u;
const MAX_LEVEL: u32 = 10u;

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
    aspect_ratio: f32,
}


@group(0) @binding(0) var<uniform> system: Uniforms;

@group(1) @binding(0) var<storage, read> nodes: array<Node>;
@group(1) @binding(1) var<storage, read> child_list: array<u32>;
@group(1) @binding(2) var<storage, read> blocks_list: array<Block>;
@group(1) @binding(3) var<storage, read> color_palette: array<vec4<f32>>;




fn pow_2(exponent: u32) -> u32 {
    return 1u << exponent;
}

fn level_to_width(level: u32) -> u32 {
    return pow_2(MAX_LEVEL - level);
}


fn extract_bitmask(node: Node) -> u64 {
    let low = u64(node.bitmask_low);
    let high = u64(node.bitmask_high);

    return (high << 32u) | low;
}

struct WorldPosition {
    grid: vec3<u32>,
    fract: vec3<f32>,
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
    //let inv_dir = vec3<f32>(1.0) / (direction + select(vec3<f32>(1e-6), vec3<f32>(-1e-6), direction < vec3<f32>(0.0)));
    let inv_dir = vec3<f32>(1.0) / select(direction, sign(direction) * 1e-6, abs(direction) < vec3<f32>(1e-6));

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
    //let inv_dir = vec3<f32>(1.0) / (direction + select(vec3<f32>(1e-6), vec3<f32>(-1e-6), direction < vec3<f32>(0.0)));
    let inv_dir = vec3<f32>(1.0) / select(direction, sign(direction) * 1e-6, abs(direction) < vec3<f32>(1e-6));

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

    // 5. Sécurité d'arrondi flottant très stricte pour s'assurer de rester dans les bornes [0.0, 1.0]
    if (result.fract.x >  1.0) { result.grid.x += 1u; result.fract.x -= 1.0; }
    if (result.fract.x <  0.0) { result.grid.x -= 1u; result.fract.x += 1.0; }
    
    while (result.fract.y > 1.0) { result.grid.y += 1u; result.fract.y -= 1.0; }
    while (result.fract.y <  0.0) { result.grid.y -= 1u; result.fract.y += 1.0; }
    
    while (result.fract.z > 1.0) { result.grid.z += 1u; result.fract.z -= 1.0; }
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
    let step_bit = vec3<u32>(1u, 2u, 4u);


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
    
    var tz = 1e38;
    if (abs(direction.z) > 1e-5) {
        tz = (half_width_f - local_source.z) / direction.z;
    }

    // 4. Parcourir séquentiellement les cloisons rencontrées devant la caméra
    var current_id = start_id;
    // ex. 0010 for id 2, x = 0, y = 1, z = 0
    let eps = 1e-4;

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
        if ((0.5 * min_t / cell_width_f) > (1.0 + eps)) { 
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
        } else if (min_t == valid_z) {
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


fn check_ray_intersect_nonleaf(
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

    // check if there is any hit
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



fn check_ray_intersect_nonleaf_fmod(
    bitmask: u64,
    ray_position: WorldPosition,
    ray_direction: vec3<f32>,
    cell_corner_position: vec3<u32>,
    cell_corner_offset: vec3<f32>,
    cell_width: f32,
) -> u32 {
    let grid_diff = vec3<i32>(ray_position.grid) - vec3<i32>(cell_corner_position);
    let local_source = vec3<f32>(grid_diff) + ray_position.fract - cell_corner_offset;
    let cell_width_f = f32(cell_width);
    let half_width_f = cell_width_f * 0.5;

    // 2. Récupérer le masque de trajectoire (converti explicitement en u32 pour la suite)
    let ray_traversal_mask = get_ray_traversal_bitmask(local_source, ray_direction, cell_width_f);

    //return select(0u, 1u, (ray_traversal_mask & (u64(1u) << 4)) != u64(0u));
    //return select(0u, 1u, abs(local_source.x - 127.9) < 1e-4);
    //return u32(ray_traversal_mask);

    // check if there is any hit
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




fn get_ray_traversal_bitmask_leaf(
    local_source: vec3<f32>,
    direction: vec3<f32>,
    cell_width_f: f32,
) -> u64 {
    let half_width_f = cell_width_f * 0.5;

    // consider the cell as a group of 8 possible subcells
    // this will lead to the same logic as before
    // set all bits of the subcells accordingly
    var mask = u64(0);
    for (var child = 0u; child < 8u; child += 1) {
        let i = child % 2u;
        let j = (child / 2u) % 2u;
        let k = child / 4u;

        let child_offset = vec3<f32>(f32(i), f32(j), f32(k));
        let child_min = child_offset * half_width_f;
        let child_max = child_min + vec3<f32>(half_width_f);

        let dist = get_child_aabb_distance(local_source, direction, child_min, child_max);
        if (dist < 1e30) {
            let local_bitmask = get_ray_traversal_bitmask(local_source + direction * dist - child_min, direction, half_width_f) & u64(255);
            mask |= (local_bitmask << (child * 8));
        }
    }

    return mask;
}

fn check_ray_intersect_leaf(
    bitmask: u64,
    ray_position: WorldPosition,
    ray_direction: vec3<f32>,
    cell_corner_position: vec3<u32>,
    cell_width: u32,
) -> u32 {

    // get the subchild ray traversal mask

    let grid_diff = vec3<i32>(ray_position.grid) - vec3<i32>(cell_corner_position);
    let local_source = vec3<f32>(grid_diff) + ray_position.fract;
    let cell_width_f = f32(cell_width);
    let half_width_f = cell_width_f * 0.5;

    let ray_traversal_mask = get_ray_traversal_bitmask(local_source, ray_direction, cell_width_f);

    // for each child, get the submask and check if any hit
    var closest_child_id = NODE_EMPTY;
    var min_dist = 1e30;

    for (var child = 0u; child < 8u; child += 1) {
        let mask_shift: u64 = u64(1u) << child;
        let is_bit_set: bool = (ray_traversal_mask & mask_shift) != u64(0u);

        if (is_bit_set) {
            // get the local child mask and intersect
            let child_mask = (bitmask >> (child * 8)) & u64(255);

            let i = child & 1u;
            let j = (child >> 1u) & 1u;
            let k = child >> 2u;

            let child_offset = vec3<f32>(f32(i), f32(j), f32(k));

            let hit = check_ray_intersect_nonleaf_fmod(
                child_mask,
                ray_position,
                ray_direction,
                cell_corner_position,
                child_offset * half_width_f,
                half_width_f
            );

            if hit != NODE_EMPTY {
                let dist = get_child_aabb_distance(
                    local_source, 
                    ray_direction, 
                    child_offset*half_width_f, 
                    child_offset*half_width_f + vec3<f32>(half_width_f)
                );

                if (dist < min_dist) {
                    min_dist = dist;
                    closest_child_id = child * 8 + hit;
                }
            }
        }
    }


    return closest_child_id;
}





fn single_raymarch(
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
        let width = level_to_width(node_stack_size() - 1u); 
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

            let hit = check_ray_intersect_leaf(
                extract_bitmask(node),
                position,
                direction,
                item.corner,
                width,
            );

            if (hit == NODE_EMPTY) {
                // remove ourself from the stack and move through ourself

                let t_range = ray_box_distance(position, direction, item.corner, width); 
                position = offset(position, direction * max(t_range.y, 1e-4) );
                position = offset(position, sign(direction) * 0.0001);

                node_stack_pop();
            } else {
                // we did hit a block
                // get the block from the block buffer
                let block_hit = blocks_list[node.children_ptr + hit];
                return RaymarchResult(block_hit, actual_steps, max_distance);
            }
        } else {
            // this is not a leaf node
            // if this node has children, we have to check if the children that contains our current position is allocated
            // if it is, we go down to it and add both the current node and it to the stack
            
            let hit = check_ray_intersect_nonleaf(
                extract_bitmask(node),
                position,
                direction,
                item.corner,
                width,
            );

            if (hit != NODE_EMPTY) {
                // --- CAS A : ON DESCEND VERS UN ENFANT OCCUPÉ ---
                let child_ptr = child_list[node.children_ptr + hit];
                if (child_ptr == NODE_EMPTY) { return RaymarchResult(air, actual_steps, max_distance); }

                let own_half_width = level_to_width(node_stack_size());
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
                    //position = offset(position, direction * 1e-1);

                    // move directly
                    position = offset(position, direction * max(t_range.x, 1e-4));
                    position = offset(position, sign(direction) * 0.0001);
                }

            } else {
                // Le nœud est vide, on l'enjambe d'un coup sec jusqu'à sa face de sortie !
                //position = ray_box_intersect(position, direction, item.corner, width);
                //position = offset(position, direction * 1e-2);

                let t_range = ray_box_distance(position, direction, item.corner, width); 
                position = offset(position, direction * max(t_range.y, 1e-4) );
                position = offset(position, sign(direction) * 0.0001);

                
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


fn skybox(direction: vec3<f32>) -> vec4<f32> {
    // 1. S'assurer que le vecteur de direction est parfaitement normalisé
    let d = normalize(direction);

    // 2. Définition du Soleil
    // Position du soleil dans le ciel (ici incliné vers le haut et un peu sur le côté)
    let sun_dir = normalize(vec3<f32>(0.3, 0.6, 0.7)); 
    let sun_dot = dot(d, sun_dir);
    
    // Calcul de l'intensité du soleil (un cœur blanc très brillant avec un dégradé doux)
    let sun_glow = pow(max(0.0, sun_dot), 350.0);       // Cœur du soleil
    let sun_flare = pow(max(0.0, sun_dot), 20.0) * 0.4; // Évasement lumineux autour du soleil
    let sun_color = vec3<f32>(1.0, 0.95, 0.8) * (sun_glow * 10.0 + sun_flare);

    // 3. Couleurs du Ciel et du Sol
    let sky_zenith = vec3<f32>(0.2, 0.5, 0.9);   // Bleu azur soutenu au zénith
    let sky_horizon = vec3<f32>(0.6, 0.8, 1.0);  // Bleu très clair/blanc à l'horizon
    let ground_color = vec3<f32>(0.35, 0.35, 0.35); // Sol gris neutre

    // 4. Mélange (Lerp) basé sur la hauteur (d.y)
    var final_color = vec3<f32>(0.0);

    if (d.y >= 0.0) {
        // Hémisphère supérieur : Dégradé du ciel (Zénith <-> Horizon)
        // d.y va de 0.0 (horizon) à 1.0 (zénith)
        let sky_gradient = pow(d.y, 0.7); // Légère courbe pour étirer l'horizon
        final_color = mix(sky_horizon, sky_zenith, sky_gradient);
        
        // Ajouter le soleil uniquement s'il est au-dessus de l'horizon
        final_color += sun_color;
    } else {
        // Hémisphère inférieur : Sol gris avec un léger assombrissement vers le bas (Nadir)
        // d.y va de 0.0 (horizon) à -1.0 (nadir)
        let ground_gradient = pow(abs(d.y), 0.5);
        let ground_nadir = vec3<f32>(0.2, 0.2, 0.2); // Gris plus sombre au fond
        final_color = mix(ground_color, ground_nadir, ground_gradient);
    }

    // 5. Adoucissement de l'horizon (Blending de la démarcation ciel/sol)
    // Crée une transition brumeuse très douce entre le ciel et le sol pile à d.y = 0.0
    let horizon_glow = pow(1.0 - abs(d.y), 8.0);
    final_color = mix(final_color, sky_horizon, horizon_glow * 0.6);

    // Retourne la couleur finale avec une opacité de 1.0
    return vec4<f32>(final_color, 1.0);
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
        x * system.aspect_ratio, 
        y, 
        1.0
    );

    var rotated_ray_world = vec4<f32>(ray_target_world, 0.0);
    rotated_ray_world = system.camera_view * rotated_ray_world;

    var dir = normalize(rotated_ray_world.xyz);

    let half_width = level_to_width(1);
    let world_halfway = vec3<u32>(
        half_width, half_width, half_width,
    );

    var camera_root_world = WorldPosition(world_halfway - vec3<u32>(0, 0, 4), vec3<f32>(0.5, 0.5, 0.5));

    let world_offset = system.camera_view * vec4<f32>(0., 0., 0., 1.);
    camera_root_world = offset(camera_root_world, world_offset.xyz);

    let result = single_raymarch(
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
        return color_palette[result.hit.id];
    }

    /*
    return vec4<f32>(
        colormap_inferno(f32(result.steps) / 256.),
        1.
    );
    */
    
    return skybox(dir);
}
