const std = @import("std");

pub const MemoryPool = struct {
    backing: std.mem.Allocator,

    pub fn init(backing: std.mem.Allocator) MemoryPool {
        return .{ .backing = backing };
    }

    pub fn requestArena(self: MemoryPool) std.heap.ArenaAllocator {
        return std.heap.ArenaAllocator.init(self.backing);
    }
};
