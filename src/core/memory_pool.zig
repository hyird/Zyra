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
        if (!self.initialized) {
            self.fallback = std.heap.stackFallback(initial_size, self.backing);
            self.arena = std.heap.ArenaAllocator.init(self.fallback.get());
            self.initialized = true;
        }
        return self.arena.allocator();
    }
};
