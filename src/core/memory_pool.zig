const std = @import("std");

/// 请求作用域内存的工厂。`MemoryPool` 只持有一个后备分配器，并据此
/// 按需创建每个请求独立的 `RequestArena`。框架在每个请求开始时取一个
/// arena，请求结束时整体释放，避免逐个对象释放的开销。
pub const MemoryPool = struct {
    backing: std.mem.Allocator,

    pub fn init(backing: std.mem.Allocator) MemoryPool {
        return .{ .backing = backing };
    }

    /// 为单个请求创建一个新的 arena。返回值按值传递，调用方负责其生命周期
    /// （用完调用 `deinit`）。
    pub fn requestArena(self: MemoryPool) RequestArena {
        return .init(self.backing);
    }
};

/// 单个请求作用域的 arena 分配器。前 `initial_size` 字节走栈上回退分配器
/// （`StackFallbackAllocator`），超出后再退到 arena/后备分配器；因此小请求
/// 完全不触发堆分配。arena 采用惰性初始化：只有真正发生分配时才建立，
/// 避免为无分配的请求付出建立成本。
pub const RequestArena = struct {
    /// 栈上回退缓冲区大小：小于此值的分配尽量走栈，不碰堆。
    const initial_size = 1024;

    backing: std.mem.Allocator,
    fallback: std.heap.StackFallbackAllocator(initial_size) = undefined,
    arena: std.heap.ArenaAllocator = undefined,
    /// arena/fallback 是否已建立。在首次分配前为 false，以支持惰性初始化。
    initialized: bool = false,

    pub fn init(backing: std.mem.Allocator) RequestArena {
        return .{ .backing = backing };
    }

    /// 释放本请求的全部分配。从未分配过（未初始化）时是空操作。
    pub fn deinit(self: *RequestArena) void {
        if (self.initialized) self.arena.deinit();
    }

    /// 返回一个指向本 arena 的 `std.mem.Allocator` 接口。
    pub fn allocator(self: *RequestArena) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    /// 惰性建立 fallback + arena，并返回 arena 指针。首次分配时被调用。
    fn ensure(self: *RequestArena) *std.heap.ArenaAllocator {
        if (!self.initialized) {
            self.fallback = std.heap.stackFallback(initial_size, self.backing);
            self.arena = std.heap.ArenaAllocator.init(self.fallback.get());
            self.initialized = true;
        }
        return &self.arena;
    }

    // 下面四个函数实现 std.mem.Allocator 的 vtable。alloc 会触发惰性
    // 初始化；resize/remap/free 在未初始化时直接返回（不可能有先于
    // alloc 的这些操作）。
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
