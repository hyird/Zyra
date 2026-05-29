//! Case-insensitive, multi-value HTTP header container.
//!
//! Mirrors Hical's `HeaderMap`: entries are stored in insertion order in a flat
//! list of `(name, value)` pairs. HTTP messages rarely carry more than ~20
//! headers, so a linear scan stays inside the L1 cache and avoids the hashing
//! and pointer-chasing overhead of a hash map. Names are compared
//! case-insensitively (`std.ascii.eqlIgnoreCase`).
//!
//! The container does NOT own the `name`/`value` byte slices; callers must keep
//! the backing storage alive for the lifetime of the map (typically a
//! request-scoped arena). Only the entry list itself is heap-allocated through
//! the provided allocator.

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

    /// Case-insensitive name equality (ASCII).
    pub fn iequals(a: []const u8, b: []const u8) bool {
        return std.ascii.eqlIgnoreCase(a, b);
    }

    /// Returns the value of the first header matching `name`, or null.
    pub fn find(self: *const HeaderMap, name: []const u8) ?[]const u8 {
        for (self.entries.items) |entry| {
            if (iequals(entry.name, name)) return entry.value;
        }
        return null;
    }

    /// Overwrites the first header matching `name`, or appends a new entry when
    /// none exists. Use this for single-value headers.
    pub fn set(self: *HeaderMap, name: []const u8, value: []const u8) !void {
        for (self.entries.items) |*entry| {
            if (iequals(entry.name, name)) {
                entry.value = value;
                return;
            }
        }
        try self.entries.append(self.allocator, .{ .name = name, .value = value });
    }

    /// Always appends a new entry, preserving any existing values. Use this for
    /// multi-value headers such as `Set-Cookie`.
    pub fn insert(self: *HeaderMap, name: []const u8, value: []const u8) !void {
        try self.entries.append(self.allocator, .{ .name = name, .value = value });
    }

    /// Removes every header matching `name`. Returns the number removed.
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

    /// Returns true when at least one header matches `name`.
    pub fn contains(self: *const HeaderMap, name: []const u8) bool {
        return self.find(name) != null;
    }

    /// Counts the headers matching `name`.
    pub fn count(self: *const HeaderMap, name: []const u8) usize {
        var n: usize = 0;
        for (self.entries.items) |entry| {
            if (iequals(entry.name, name)) n += 1;
        }
        return n;
    }

    /// Appends every value matching `name` to `out` (in insertion order).
    pub fn findAll(self: *const HeaderMap, name: []const u8, out: *std.ArrayListUnmanaged([]const u8), allocator: std.mem.Allocator) !void {
        for (self.entries.items) |entry| {
            if (iequals(entry.name, name)) try out.append(allocator, entry.value);
        }
    }

    /// Total number of stored entries (across all names).
    pub fn size(self: *const HeaderMap) usize {
        return self.entries.items.len;
    }

    pub fn isEmpty(self: *const HeaderMap) bool {
        return self.entries.items.len == 0;
    }

    /// Pre-reserves capacity for `n` entries.
    pub fn reserve(self: *HeaderMap, n: usize) !void {
        try self.entries.ensureTotalCapacity(self.allocator, n);
    }

    /// Removes all entries, keeping allocated capacity.
    pub fn clear(self: *HeaderMap) void {
        self.entries.clearRetainingCapacity();
    }

    /// Borrows the underlying entry slice for iteration.
    pub fn items(self: *const HeaderMap) []const Entry {
        return self.entries.items;
    }
};

// ----------------------------------------------------------------------------
// Tests
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
    try map.set("content-type", "application/json"); // overwrites existing

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
