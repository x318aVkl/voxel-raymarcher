use std::sync::Arc;

use bytemuck::NoUninit;
use wgpu::{Buffer, util::{BufferInitDescriptor, DeviceExt}};



// 32 bits, 4 bytes per block
#[repr(C)]
#[derive(Clone, Copy, bytemuck::NoUninit, bytemuck::AnyBitPattern)]
pub struct Block {
    /// block type
    id: u32,
}

impl Block {
    pub const VOID: Block = Block {id: 0};

    pub const STONE: Block = Block {id: 1};

    pub const GRASS: Block = Block {id: 2};
}



// 40 bytes per node
#[repr(C)]
#[derive(Clone, Copy, Debug, bytemuck::NoUninit, bytemuck::AnyBitPattern, PartialEq)]
pub struct Node {
    children_ptr: u32,
    leaf: u32,
    parent: u32,
    data: u32,
    bitmask: u64,
}


const NODE_EMPTY: u32 = 4294967295;

impl Node {
    pub const ROOT: Node = Node {
        children_ptr: NODE_EMPTY,
        leaf: 0,
        parent: NODE_EMPTY,
        data: 0,
        bitmask: 0,
    };
    pub const EMPTY: Node = Node {
        children_ptr: NODE_EMPTY,
        leaf: 0,
        parent: NODE_EMPTY,
        data: 1,
        bitmask: 0,
    };
}

pub struct Object {
    nodes_buffer: Buffer,
    child_buffer: Buffer,
    blocks_buffer: Buffer,

    queue: wgpu::Queue,
    bind_group: wgpu::BindGroup,

    cpu_nodes: Vec<Node>,
    cpu_child_list: Vec<u32>,

    max_allocated_node: usize,
    available_nodes: Vec<usize>,
    max_allocated_child_group: usize,
    available_child_group: Vec<usize>,
    max_allocated_blocks_group: usize,
    available_blocks_group: Vec<usize>,
}


pub const MAX_NODE_SIZE: usize = 262144;
pub const CHILD_PER_NODE: usize = 8;
pub const BLOOCK_PER_NODE: usize = 64;
pub const MAX_LEVEL: u32 = 8;




impl Object {

    // creates a new object with empty data
    pub fn new(
        device: wgpu::Device,
        queue: wgpu::Queue,
        bind_group_layout: &wgpu::BindGroupLayout,
    ) -> Self {

        let mut node_data = vec![Node::EMPTY; MAX_NODE_SIZE];
        node_data[0] = Node::ROOT;

        let nodes_buffer = device.create_buffer_init(
            &BufferInitDescriptor {
                label: Some("Storage Buffer"),
                contents: bytemuck::cast_slice(&node_data),
                usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC | wgpu::BufferUsages::COPY_DST,
            }
        );

        // data for non leaf node
        // 8 per non leaf node
        let child_data = vec![NODE_EMPTY; MAX_NODE_SIZE * 8];

        let child_buffer = device.create_buffer_init(
            &BufferInitDescriptor {
                label: Some("Storage Buffer"),
                contents: bytemuck::cast_slice(&child_data),
                usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC | wgpu::BufferUsages::COPY_DST,
            }
        );


        // data for leaf node, blocks
        // 64 per non leaf node
        let data = vec![Block::VOID; MAX_NODE_SIZE * 64];

        let blocks_buffer = device.create_buffer_init(
            &BufferInitDescriptor {
                label: Some("Storage Buffer"),
                contents: bytemuck::cast_slice(&data),
                usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC | wgpu::BufferUsages::COPY_DST,
            }
        );

        let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("object bind group"),
            layout: bind_group_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: nodes_buffer.as_entire_binding(),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: child_buffer.as_entire_binding(),
                },
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: blocks_buffer.as_entire_binding(),
                }
            ]
        });

        Self {
            nodes_buffer,
            child_buffer,
            blocks_buffer,
            bind_group,
            queue,
            cpu_child_list: child_data,
            cpu_nodes: node_data,
            max_allocated_node: 1,
            available_nodes: vec![],
            max_allocated_child_group: 0,
            available_child_group: vec![],
            max_allocated_blocks_group: 0,
            available_blocks_group: vec![],
        }

    }

    pub fn bind_group(&self) -> &wgpu::BindGroup {
        &self.bind_group
    }


}





impl Object {
    fn allocate_node(&mut self) -> u32 {
        let res = if let Some(idx) = self.available_nodes.pop() {
            idx as u32
        } else {
            let idx = self.max_allocated_node;
            self.max_allocated_node += 1;
            idx as u32
        };
        println!("Allocated new node base slot: {}", res);
        res
    }

    fn allocate_child_group(&mut self) -> u32 {
        let res = if let Some(idx) = self.available_child_group.pop() {
            (idx * CHILD_PER_NODE) as u32
        } else {
            let idx = self.max_allocated_child_group;
            self.max_allocated_child_group += 1;
            (idx * CHILD_PER_NODE) as u32
        };
        println!("Allocated child group base slot: {}", res);
        res
    }

    fn allocate_blocks_group(&mut self) -> u32 {
        let res = if let Some(idx) = self.available_blocks_group.pop() {
            (idx * BLOOCK_PER_NODE) as u32
        } else {
            let idx = self.max_allocated_blocks_group;
            self.max_allocated_blocks_group += 1;
            (idx * BLOOCK_PER_NODE) as u32
        };
        println!("Allocated block group base slot: {}", res);
        res
    }

    pub fn level_size(level: u32) -> u32 {
        let level = level.min(MAX_LEVEL);
        2_u32.pow(MAX_LEVEL - level)
    }

    fn set_block_at_inner(
        &mut self,
        position: [u32; 3],
        block_data: [Block; 64]
    ) {
        println!("\n=== Setting new block group ===");
        // start at the tree root
        let mut current_node_idx = 0;

        let mut level = 0;

        let mut current_node_center = [
            Self::level_size(1),
            Self::level_size(1),
            Self::level_size(1)
        ];

        let mut leaf_node = loop {

            let mut current_node = self.cpu_nodes[current_node_idx];
            let starting_node = current_node;

            if current_node.leaf == 1 {
                // we found a leaf node! break with it
                break current_node;
            }

            // this is not a leaf node, handle octree child group
            if current_node.children_ptr == NODE_EMPTY {
                // allocate a children group
                current_node.children_ptr = self.allocate_child_group();
                // reset the bitmask so the node knows it is empty
                current_node.bitmask = 0;
            }

            let current_node_child_group_start = current_node.children_ptr;

            // figure out the children of this node to go down into
            let child = [
                if position[0] < current_node_center[0] {0} else {1},
                if position[1] < current_node_center[1] {0} else {1},
                if position[2] < current_node_center[2] {0} else {1},
            ];

            let child_flat_idx = child[0] + child[1]*2 + child[2]*4;

            // check if the child group is allocated, if not allocate
            let child_node_idx = if (current_node.bitmask & (1 << child_flat_idx)) == 0 {
                // the children is not allocated, allocate it and update both the children group and bitmask
                let new_child_node = self.allocate_node();

                self.cpu_nodes[new_child_node as usize] = Node {
                    children_ptr: NODE_EMPTY,
                    leaf: if (level + 1) == MAX_LEVEL {1} else {0},
                    bitmask: 0,
                    parent: current_node_idx as u32,
                    data: 0,
                };

                // queue the changes to the new child node to send to the gpu
                let child_node_byte_offset = (new_child_node as u64) * (std::mem::size_of::<Node>() as u64);
                self.queue.write_buffer(
                    &self.nodes_buffer,
                    child_node_byte_offset as u64,
                    bytemuck::bytes_of(&self.cpu_nodes[new_child_node as usize]),
                );

                // set the child node in the cpu child list
                self.cpu_child_list[(current_node_child_group_start + child_flat_idx) as usize] = new_child_node;

                // update the bitmask of the current node
                current_node.bitmask |= 1 << (child_flat_idx as u64);
                
                println!("child_idx: {}, bits: {:064b}", child_flat_idx, current_node.bitmask);

                new_child_node
            } else {
                // the children already exists, just go down to it
                self.cpu_child_list[(current_node_child_group_start + child_flat_idx) as usize]
            };

            // in any case, we need to queue the changes to the child list to the gpu
            // send the whole new child list
            // might be better to only send the child we changed, but anyway
            println!("new child list at {} : {:?}", current_node_child_group_start, &self.cpu_child_list[(current_node_child_group_start as usize)..(current_node_child_group_start as usize + 8)]);
            self.queue.write_buffer(
                &self.child_buffer,
                (current_node_child_group_start as u64) * (std::mem::size_of::<u32>() as u64),
                bytemuck::cast_slice(&self.cpu_child_list[(current_node_child_group_start as usize)..(current_node_child_group_start as usize + 8)]),
            );


            if true | (current_node != starting_node) {
                // node has been updated and should be written to the gpu
                self.cpu_nodes[current_node_idx] = current_node;

                let node_byte_offset = (current_node_idx as u64) * (std::mem::size_of::<Node>() as u64);
                self.queue.write_buffer(
                    &self.nodes_buffer,
                    node_byte_offset,
                    bytemuck::bytes_of(&current_node),
                );
            }

            // move to the child node
            current_node_idx = child_node_idx as usize;

            level += 1;

            let new_child_width = Self::level_size(level + 1) as i64;
            current_node_center[0] = (  (current_node_center[0] as i64) + new_child_width * if child[0] == 0 {-1} else {1}  ) as u32;
            current_node_center[1] = (  (current_node_center[1] as i64) + new_child_width * if child[1] == 0 {-1} else {1}  ) as u32;
            current_node_center[2] = (  (current_node_center[2] as i64) + new_child_width * if child[2] == 0 {-1} else {1}  ) as u32;

        };

        // handle the leaf node we got

        // check if the leaf node has an allocated block group, if not allocate it, update bitmask, and send the data
        // if it does, update bitmask and send the data, overwriting it
        if leaf_node.children_ptr == NODE_EMPTY {
            // unallocated, allocate it
            leaf_node.children_ptr = self.allocate_blocks_group();
        }

        // send the block data to the gpu
        let blocks_byte_offset = (leaf_node.children_ptr as u64) * (std::mem::size_of::<Block>() as u64);
        self.queue.write_buffer(
            &self.blocks_buffer,
            blocks_byte_offset,
            bytemuck::cast_slice(&block_data),
        );

        // update the bitmask
        let mut mask = 0_u64;
        for i in 0..64 {
            if block_data[i].id != 0 {
                mask |= 1 << (i as u64);
            }
        }
        println!("block bitmask: {:064b}", mask);
        leaf_node.bitmask = mask;

        // set the new leaf node in both cpu and gpu buffers
        self.cpu_nodes[current_node_idx] = leaf_node;
        let node_byte_offset = (current_node_idx as u64) * (std::mem::size_of::<Node>() as u64);
        self.queue.write_buffer(
            &self.nodes_buffer,
            node_byte_offset,
            bytemuck::bytes_of(&leaf_node),
        );

        // we are done!
    }
    

    pub fn set_block_at(
        &mut self,
        position: [i64; 3],
        block_data: [Block; 64],
    ) {
        let base_halfwidth = Self::level_size(1) as i64;
        let world_position = [
            (position[0] + base_halfwidth) as u32,
            (position[1] + base_halfwidth) as u32,
            (position[2] + base_halfwidth) as u32,
        ];
        self.set_block_at_inner(world_position, block_data);
    }
}


