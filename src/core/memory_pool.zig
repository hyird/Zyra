const std = @import("std");

pub const MemoryPool = struct {
    backing: std.mem.Allocator,

    pub fn init(backing: std.mem.Allocator) MemoryPool {
        return .{ .backing = backing };
    }

    pub fn requestArena(self: MemoryPool) RequestArena {
        return .init(self.backing);
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
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn ensure(self: *RequestArena) *std.heap.ArenaAllocator {
        if (!self.initialized) {
            self.fallback = std.heap.stackFallback(initial_size, self.backing);
            self.arena = std.heap.ArenaAllocator.init(self.fallback.get());
            self.initialized = true;
        }
        return &self.arena;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *RequestArena = @ptrCast(@alignCast(ctx));
        return self.ensure().allocator().rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *RequestArena = @ptrCast(@alignCast(ctx));
        if (!self.initialized) return false;
        return self.arena.allocator().rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *RequestArena = @ptrCast(@alignCast(ctx));
        if (!self.initialized) return null;
        return self.arena.allocator().rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *RequestArena = @ptrCast(@alignCast(ctx));
        if (!self.initialized) return;
        self.arena.allocator().rawFree(memory, alignment, ret_addr);
    }
};
