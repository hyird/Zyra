//! 大小写不敏感、多值 HTTP 头容器。
//!
//! 镜像 Hical 的 `HeaderMap`：条目按插入顺序存储在扁平的 `(name, value)` 对列表中。
//! HTTP 消息很少携带超过约 20 个头，因此线性扫描仍停留在 L1 缓存内，并避免哈希
//! map 的哈希和指针追逐开销。名称按大小写不敏感方式比较
//! （`std.ascii.eqlIgnoreCase`）。
//!
//! 该容器不拥有 `name`/`value` 字节切片；调用方必须在 map 的生命周期内保持其后备
//! 存储存活（通常是请求作用域 arena）。只有条目列表本身会通过提供的分配器在堆上
//! 分配。

const std = @import("std");

pub const Entry = struct {
    name: []const u8,
    value: []const u8,
};

pub const HeaderMap = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator) HeaderMap {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *HeaderMap) void {
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// 大小写不敏感的名称相等判断（ASCII）。
    pub fn iequals(a: []const u8, b: []const u8) bool {
        return std.ascii.eqlIgnoreCase(a, b);
    }

    /// 返回第一个匹配 `name` 的头值；没有则返回 null。
    pub fn find(self: *const HeaderMap, name: []const u8) ?[]const u8 {
        for (self.entries.items) |entry| {
            if (iequals(entry.name, name)) return entry.value;
        }
        return null;
    }

    /// 覆盖第一个匹配 `name` 的头；若不存在则追加新条目。用于单值头。
    pub fn set(self: *HeaderMap, name: []const u8, value: []const u8) !void {
        for (self.entries.items) |*entry| {
            if (iequals(entry.name, name)) {
                entry.value = value;
                return;
            }
        }
        try self.entries.append(self.allocator, .{ .name = name, .value = value });
    }

    /// 始终追加新条目，保留任何已有值。用于 `Set-Cookie` 等多值头。
    pub fn insert(self: *HeaderMap, name: []const u8, value: []const u8) !void {
        try self.entries.append(self.allocator, .{ .name = name, .value = value });
    }

    /// 移除每个匹配 `name` 的头。返回移除数量。
    pub fn erase(self: *HeaderMap, name: []const u8) usize {
        var write_index: usize = 0;
        const list = self.entries.items;
        for (list) |entry| {
            if (!iequals(entry.name, name)) {
                list[write_index] = entry;
                write_index += 1;
            }
        }
        const removed = list.len - write_index;
        self.entries.shrinkRetainingCapacity(write_index);
        return removed;
    }

    /// 当至少一个头匹配 `name` 时返回 true。
    pub fn contains(self: *const HeaderMap, name: []const u8) bool {
        return self.find(name) != null;
    }

    /// 统计匹配 `name` 的头数量。
    pub fn count(self: *const HeaderMap, name: []const u8) usize {
        var n: usize = 0;
        for (self.entries.items) |entry| {
            if (iequals(entry.name, name)) n += 1;
        }
        return n;
    }

    /// 将每个匹配 `name` 的值追加到 `out`（按插入顺序）。
    pub fn findAll(self: *const HeaderMap, name: []const u8, out: *std.ArrayListUnmanaged([]const u8), allocator: std.mem.Allocator) !void {
        for (self.entries.items) |entry| {
            if (iequals(entry.name, name)) try out.append(allocator, entry.value);
        }
    }

    /// 已存储条目的总数（跨所有名称）。
    pub fn size(self: *const HeaderMap) usize {
        return self.entries.items.len;
    }

    pub fn isEmpty(self: *const HeaderMap) bool {
        return self.entries.items.len == 0;
    }

    /// 为 `n` 个条目预留容量。
    pub fn reserve(self: *HeaderMap, n: usize) !void {
        try self.entries.ensureTotalCapacity(self.allocator, n);
    }

    /// 移除所有条目，保留已分配容量。
    pub fn clear(self: *HeaderMap) void {
        self.entries.clearRetainingCapacity();
    }

    /// 借用底层条目切片以供迭代。
    pub fn items(self: *const HeaderMap) []const Entry {
        return self.entries.items;
    }
};

// ----------------------------------------------------------------------------
// 测试
// ----------------------------------------------------------------------------

test "iequals compares names case-insensitively" {
    try std.testing.expect(HeaderMap.iequals("Content-Type", "content-type"));
    try std.testing.expect(HeaderMap.iequals("X-Foo", "x-foo"));
    try std.testing.expect(!HeaderMap.iequals("X-Foo", "X-Bar"));
    try std.testing.expect(!HeaderMap.iequals("abc", "abcd"));
}

test "set overwrites first match and find is case-insensitive" {
    var map = HeaderMap.init(std.testing.allocator);
    defer map.deinit();

    try map.set("Content-Type", "text/plain");
    try map.set("content-type", "application/json"); // 覆盖已有值

    try std.testing.expectEqual(@as(usize, 1), map.size());
    try std.testing.expectEqualStrings("application/json", map.find("CONTENT-TYPE").?);
}

test "insert keeps multiple values and findAll collects them" {
    var map = HeaderMap.init(std.testing.allocator);
    defer map.deinit();

    try map.insert("Set-Cookie", "a=1");
    try map.insert("set-cookie", "b=2");
    try map.set("Vary", "Origin");

    try std.testing.expectEqual(@as(usize, 2), map.count("set-cookie"));
    try std.testing.expectEqual(@as(usize, 3), map.size());

    var values: std.ArrayListUnmanaged([]const u8) = .empty;
    defer values.deinit(std.testing.allocator);
    try map.findAll("Set-Cookie", &values, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), values.items.len);
    try std.testing.expectEqualStrings("a=1", values.items[0]);
    try std.testing.expectEqualStrings("b=2", values.items[1]);
}

test "contains and erase" {
    var map = HeaderMap.init(std.testing.allocator);
    defer map.deinit();

    try map.insert("X-A", "1");
    try map.insert("x-a", "2");
    try map.insert("X-B", "3");

    try std.testing.expect(map.contains("x-a"));
    const removed = map.erase("X-A");
    try std.testing.expectEqual(@as(usize, 2), removed);
    try std.testing.expect(!map.contains("x-a"));
    try std.testing.expect(map.contains("X-B"));
    try std.testing.expectEqual(@as(usize, 1), map.size());
}

test "reserve clear and isEmpty" {
    var map = HeaderMap.init(std.testing.allocator);
    defer map.deinit();

    try std.testing.expect(map.isEmpty());
    try map.reserve(16);
    try map.set("A", "1");
    try std.testing.expect(!map.isEmpty());

    map.clear();
    try std.testing.expect(map.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), map.size());
}

test "items exposes insertion-ordered entries" {
    var map = HeaderMap.init(std.testing.allocator);
    defer map.deinit();

    try map.set("First", "1");
    try map.insert("Second", "2");
    try map.insert("Second", "3");

    const list = map.items();
    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqualStrings("First", list[0].name);
    try std.testing.expectEqualStrings("Second", list[1].name);
    try std.testing.expectEqualStrings("3", list[2].value);
}
