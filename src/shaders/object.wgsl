

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
    bitmask: u64,
}

// a leaf node is 1 unit wide, so a single small block is 1/4 width wide
// id 0 equals air, so nothing
struct Block {
    id: u32,
}

@group(0) @binding(0) var<storage, read> nodes: array<Node>;
@group(0) @binding(1) var<storage, read> child_list: array<u32>;
@group(0) @binding(2) var<storage, read> blocks_list: array<Block>;




fn pow_2(exponent: u32) -> u32 {
    return 1u << exponent;
}



// Helper : Retourne si un bit spécifique est activé dans un masque 64 bits
fn is_bit_set(mask: u64, bit_index: u32) -> bool {
    const one: u64 = 1;
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
    let child_x = child_idx & 1u;
    let child_y = (child_idx >> 1u) & 1u;
    let child_z = (child_idx >> 2u) & 1u;
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
    let t_valid = select(vec3<f32>(1e38), t_planes, t_planes > 0.0);

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

fn node_stack_push(node: Node, node_ptr: u32, corner: vec3<u32>) {
    if (NODE_STACK_SIZE >= NODE_STACK_ALLOC) {
        let node: Node = Node(0, 0, 0, 0, 0);
        return StoredStackNode(node, NODE_EMPTY, vec3<u32>(0, 0, 0));
    }
    node_stack[NODE_STACK_SIZE] = StoredStackNode(node, node_ptr, corner);
    NODE_STACK_SIZE += 1;
}

fn node_stack_pop() -> StoredStackNode {
    if (NODE_STACK_SIZE == 0) {
        let node: Node = Node(0, 0, 0, 0, 0);
        return StoredStackNode(node, NODE_EMPTY, vec3<u32>(0, 0, 0));
    }
    NODE_STACK_SIZE -= 1;
    return node_stack[NODE_STACK_SIZE];
}

fn node_stack_depth() -> u32 {
    return NODE_STACK_SIZE - 1;
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
    if ((bitmask & (1u << initial_child_id)) != 0u) {
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
    let t_valid = select(vec3<f32>(1e38), t_planes, (t_planes > 0.0));

    // 5. Trouver quel plan médian (X, Y ou Z) est traversé en premier
    if (t_valid.x < t_valid.y && t_valid.x < t_valid.z) {
        // Le rayon traverse le plan X=0.5. On inverse le bit X du sous-cube initial.
        let next_child_id = initial_child_id ^ 1u;
        if (t_valid.x < 1.0 && (bitmask & (1u << next_child_id)) != 0u) { return next_child_id; }
    } else if (t_valid.y < t_valid.x && t_valid.y < t_valid.z) {
        // Le rayon traverse le plan Y=0.5. On inverse le bit Y (valeur 2).
        let next_child_id = initial_child_id ^ 2u;
        if (t_valid.y < 1.0 && (bitmask & (1u << next_child_id)) != 0u) { return next_child_id; }
    } else {
        // Le rayon traverse le plan Z=0.5. On inverse le bit Z (valeur 4).
        let next_child_id = initial_child_id ^ 4u;
        if (t_valid.z < 1.0 && (bitmask & (1u << next_child_id)) != 0u) { return next_child_id; }
    }

    // Aucun sous-cube intersecté n'est actif dans le bitmask avant de sortir de la cellule
    return NODE_EMPTY;
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

    for (var iter = 0u; iter < 256u; iter += 1) {
        // pop the stack
        let item = node_stack_pop();
        if (item.node_ptr == NODE_EMPTY) {
            // the stack is empty
            break;
        }

        // do not fetch the node from memory
        // used the cached value in the stack
        let node: Node = item.node;

        // if the current node if a leaf, check if the ray intersects the nodes blocks using the node bitmask
        if (node.leaf == 1) {
            // here, if there is an intersect, we return the intersect hit

            // if not, we just continue to traverse

            // for now, return directly the hit as if the child was full
            return RaymarchResult(Block(1u), actual_steps, max_distance);
        } else {
            // this is not a leaf node
            // if this node has children, we have to check if the children that contains our current position is allocated
            // if it is, we go down to it and add both the current node and it to the stack
            
            let hit = check_ray_intersect_nonleaf(
                node.bitmask,
                position,
                direction,
                item.corner,
            );

            if (hit != NODE_EMPTY) {
                // we did hit a child inside this
                // get the child idx
                // we need to read memory
                // might be good to cache this
                let child_ptr = child_list[node.children_ptr + hit];

                // position of this new corner node
                let i = hit % 2;
                let j = (hit / 2) % 4;
                let k = hit / 4;
                let child_half_width = pow_2(8u - (node_stack_depth() + 1));

                let child_corner = vec3<u32>(
                    item.corner.x + i * child_half_width,
                    item.corner.y + j * child_half_width,
                    item.corner.z + k * child_half_width,
                );

                // add ourself back to the stack, and the children
                node_stack_push(item);
                // fetch the node from memory
                node_stack_push(nodes[child_ptr], child_ptr, child_corner);

                // update position so we travel to the new child cell
                let own_width = pow_2(8u - node_stack_depth());
                position = traverse_world_grid_up_to_child(
                    position,
                    direction,
                    item.corner,
                    own_width,
                    hit
                );

                continue;

            } else {
                // we did not hit a child node inside the grid
                // traverse the whole grid cell and do not push ourself back to the stack

                let width = pow_2(8u - node_stack_depth());

                position = traverse_world_grid(
                    position,
                    direction,
                    item.corner,
                    width,
                );
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

    let ray_target_world = vec3<f32>(
        (in.uv.x * 2.0 - 1.0) * 1., 
        (in.uv.y * 2.0 - 1.0) * 1., 
        frustum_relative.z + 1.0
    );

    var dir = ray_target_world - frustum_relative;
    dir = normalize(dir);

    let camera_root_world = WorldPosition(vec3<u32>(0, 0, 0), vec3<f32>(0., 0., 0.));

    let result = raymarch(
        camera_root_world,
        dir,
        2e10,
    );

    //return vec4<f32>(f32(result.steps) / 600., 0., 0., 1.);

    if (result.hit.id != 0) {
        if (result.hit.id == 1) {
            return vec4<f32>(1., 0., 0., 1.0);
        } else {
            return vec4<f32>(0., 1., 0., 1.0);
        }
    }
    return vec4<f32>(0.1, 0.1, 0.1, 1.0);
}
