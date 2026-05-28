const std = @import("std");

pub const MemoryPool = struct {
    const pooled_largest_block = 512 * 1024;
    const pooled_min_block = 256;
    const class_count = std.math.log2(pooled_largest_block) - std.math.log2(pooled_min_block) + 1;

    backing: std.mem.Allocator,

    pub fn init(backing: std.mem.Allocator) MemoryPool {
        return .{ .backing = backing };
    }

    pub fn requestArena(self: *MemoryPool) RequestArena {
        return .init(self.threadLocalAllocator());
    }

    fn threadLocalAllocator(self: *MemoryPool) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &thread_local_vtable,
        };
    }

    const FreeNode = struct {
        next: ?*FreeNode = null,
    };

    const ThreadCache = struct {
        owner: ?*MemoryPool = null,
        free_lists: [class_count]?*FreeNode = .{null} ** class_count,

        fn ensureOwner(self: *ThreadCache, owner: *MemoryPool) void {
            if (self.owner == owner) return;
            self.flush();
            self.owner = owner;
        }

        fn flush(self: *ThreadCache) void {
            const owner = self.owner orelse return;
            for (&self.free_lists, 0..) |*head, index| {
                const size = classSize(index);
                var node = head.*;
                while (node) |current| {
                    node = current.next;
                    owner.backing.rawFree(@as([*]u8, @ptrCast(current))[0..size], .of(FreeNode), @returnAddress());
                }
                head.* = null;
            }
            self.owner = null;
        }
    };

    threadlocal var thread_cache: ThreadCache = .{};

    const thread_local_vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *MemoryPool = @ptrCast(@alignCast(ctx));
        if (classIndex(len, alignment)) |index| {
            thread_cache.ensureOwner(self);
            if (thread_cache.free_lists[index]) |node| {
                thread_cache.free_lists[index] = node.next;
                return @ptrCast(node);
            }
            return self.backing.rawAlloc(classSize(index), .of(FreeNode), ret_addr);
        }
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return false;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *MemoryPool = @ptrCast(@alignCast(ctx));
        if (classIndex(memory.len, alignment)) |index| {
            thread_cache.ensureOwner(self);
            const node: *FreeNode = @ptrCast(@alignCast(memory.ptr));
            node.* = .{ .next = thread_cache.free_lists[index] };
            thread_cache.free_lists[index] = node;
            return;
        }
        self.backing.rawFree(memory, alignment, ret_addr);
    }

    fn classIndex(len: usize, alignment: std.mem.Alignment) ?usize {
        if (alignment.toByteUnits() > @alignOf(FreeNode)) return null;
        const needed = @max(len, @sizeOf(FreeNode));
        if (needed > pooled_largest_block) return null;
        const size = std.math.ceilPowerOfTwoAssert(usize, @max(needed, pooled_min_block));
        return std.math.log2(size) - std.math.log2(pooled_min_block);
    }

    fn classSize(index: usize) usize {
        return std.math.shl(usize, pooled_min_block, index);
    }
};

pub const RequestArena = struct {
    const initial_size = 4096;

    backing: std.mem.Allocator,
    fallback: std.heap.StackFallbackAllocator(initial_size) = undefined,
    arena: std.heap.ArenaAllocator = undefined,
    initialized: bool = false,

    pub fn init(backing: std.mem.Allocator) RequestArena {
        return .{ .backing = backing };
    }

    pub fn deinit(self: *RequestArena) void {
        if (self.initialized) self.arena.deinit();
    }

    pub fn allocator(self: *RequestArena) std.mem.Allocator {
        if (!self.initialized) {
            self.fallback = std.heap.stackFallback(initial_size, self.backing);
            self.arena = std.heap.ArenaAllocator.init(self.fallback.get());
            self.initialized = true;
        }
        return self.arena.allocator();
    }
};
