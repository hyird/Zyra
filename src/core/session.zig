//! In-memory session management.
//!
//! Mirrors Hical's `Session` / `SessionManager` / `makeSessionMiddleware`,
//! built on `std.Io` primitives: `std.Io.Mutex` for synchronization and
//! `std.Io.Clock` for time. Methods that lock or read the clock therefore take
//! an `io: std.Io` handle (sourced from `HttpRequest.io` at request time).
//!
//! - `Session` stores string key/value pairs, tracks a dirty flag, and records
//!   the last-access time.
//! - `SessionManager` owns the session store, generates random 64-hex IDs,
//!   enforces a maximum session count (DoS protection), and lazily
//!   garbage-collects expired sessions.
//! - `SessionMiddleware` integrates with the context-onion pipeline: it reads
//!   the session cookie, finds or creates a session, attaches it to the request
//!   as a pointer attribute, and writes a `Set-Cookie` header when the session
//!   was created or modified.
//!
//! Session values are strings (user id, token, role). The manager owns all
//! key/value memory and frees it on `destroy`/`deinit`.

const std = @import("std");
const http = @import("http.zig");
const middleware = @import("middleware.zig");

/// Request pointer-attribute key under which the active `*Session` is stored.
pub const session_attribute_key = "zyra.session";

fn nowNs(io: std.Io) i128 {
    return std.Io.Clock.now(.awake, io).nanoseconds;
}

/// A single session's data. Thread-safe via an `std.Io.Mutex`. The id is
/// immutable after construction.
pub const Session = struct {
    id_buf: [64]u8,
    allocator: std.mem.Allocator,
    data: std.StringHashMapUnmanaged([]const u8) = .empty,
    mutex: std.Io.Mutex = .init,
    dirty: bool = false,
    last_access_ns: i128,

    fn create(allocator: std.mem.Allocator, session_id: [64]u8, now: i128) Session {
        return .{
            .id_buf = session_id,
            .allocator = allocator,
            .last_access_ns = now,
        };
    }

    fn destroy(self: *Session) void {
        var it = self.data.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.data.deinit(self.allocator);
    }

    /// Session ID (immutable, no lock needed).
    pub fn id(self: *const Session) []const u8 {
        return &self.id_buf;
    }

    /// Sets a session attribute, duplicating both key and value. Marks the
    /// session dirty so the middleware refreshes the cookie.
    pub fn set(self: *Session, io: std.Io, key: []const u8, value: []const u8) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);

        const gop = try self.data.getOrPut(self.allocator, key);
        if (gop.found_existing) {
            self.allocator.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = self.allocator.dupe(u8, key) catch |err| {
                self.allocator.free(value_copy);
                self.data.removeByPtr(gop.key_ptr);
                return err;
            };
        }
        gop.value_ptr.* = value_copy;
        self.dirty = true;
    }

    /// Returns a borrowed view of the value for `key`, valid until the value is
    /// overwritten/removed. Returns null if absent.
    pub fn get(self: *Session, io: std.Io, key: []const u8) ?[]const u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.data.get(key);
    }

    pub fn has(self: *Session, io: std.Io, key: []const u8) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.data.contains(key);
    }

    pub fn remove(self: *Session, io: std.Io, key: []const u8) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.data.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
            self.dirty = true;
        }
    }

    /// Removes all attributes (does not destroy the session itself).
    pub fn clear(self: *Session, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var it = self.data.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.data.clearRetainingCapacity();
        self.dirty = true;
    }

    pub fn isDirty(self: *Session, io: std.Io) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.dirty;
    }

    /// Updates the last-access timestamp.
    pub fn touch(self: *Session, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.last_access_ns = nowNs(io);
    }

    /// Moves all data from `other` into `self` (used during ID regeneration).
    /// The caller holds the manager lock, so no per-session lock is taken.
    fn migrateFrom(self: *Session, other: *Session) void {
        self.data = other.data;
        other.data = .empty;
        self.dirty = true;
    }
};

pub const SessionOptions = struct {
    cookie_name: []const u8 = "ZYRA_SESSION",
    /// Session lifetime in seconds.
    max_age_seconds: i64 = 3600,
    http_only: bool = true,
    secure: bool = true,
    same_site: http.SameSite = .lax,
    path: []const u8 = "/",
    /// Lazy GC interval in seconds: GC only runs if at least this many seconds
    /// elapsed since the previous run.
    gc_interval_seconds: i64 = 300,
    /// Maximum live sessions (0 = unlimited). Guards against memory exhaustion.
    max_sessions: usize = 100_000,
};

pub const SessionError = error{
    /// The session store reached `max_sessions`.
    SessionStoreFull,
};

/// Thread-safe in-memory session store. Typically a long-lived singleton shared
/// with the server through `SessionMiddleware`.
pub const SessionManager = struct {
    allocator: std.mem.Allocator,
    options: SessionOptions,
    mutex: std.Io.Mutex = .init,
    store: std.StringHashMapUnmanaged(*Session) = .empty,
    last_gc_ns: i128 = 0,

    pub fn init(allocator: std.mem.Allocator, options: SessionOptions) SessionManager {
        return .{ .allocator = allocator, .options = options };
    }

    pub fn deinit(self: *SessionManager, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        var it = self.store.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.destroy();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.store.deinit(self.allocator);
        self.mutex.unlock(io);
    }

    fn isExpired(self: *const SessionManager, session: *const Session, now_ns: i128) bool {
        if (self.options.max_age_seconds <= 0) return false;
        const age_ns = now_ns - session.last_access_ns;
        const max_ns: i128 = @as(i128, self.options.max_age_seconds) * std.time.ns_per_s;
        return age_ns > max_ns;
    }

    /// Looks up a session by ID. Returns null if missing or expired (an expired
    /// session is removed as a side effect).
    pub fn find(self: *SessionManager, io: std.Io, id: []const u8) ?*Session {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const session = self.store.get(id) orelse return null;
        if (self.isExpired(session, nowNs(io))) {
            self.removeLocked(id);
            return null;
        }
        return session;
    }

    /// Creates a new session with a fresh random ID. Returns
    /// `SessionError.SessionStoreFull` when the store is at capacity.
    pub fn create(self: *SessionManager, io: std.Io) !*Session {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.createLocked(io);
    }

    fn createLocked(self: *SessionManager, io: std.Io) !*Session {
        if (self.options.max_sessions != 0 and self.store.count() >= self.options.max_sessions) {
            self.gcLocked(io, true);
            if (self.store.count() >= self.options.max_sessions) {
                return SessionError.SessionStoreFull;
            }
        }

        const new_id = generateId(io);
        const session = try self.allocator.create(Session);
        errdefer self.allocator.destroy(session);
        session.* = Session.create(self.allocator, new_id, nowNs(io));

        try self.store.put(self.allocator, session.id(), session);
        return session;
    }

    /// Destroys the session with the given ID (e.g. on logout).
    pub fn destroy(self: *SessionManager, io: std.Io, id: []const u8) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.removeLocked(id);
    }

    fn removeLocked(self: *SessionManager, id: []const u8) void {
        if (self.store.fetchRemove(id)) |kv| {
            kv.value.destroy();
            self.allocator.destroy(kv.value);
        }
    }

    /// Regenerates a session's ID while preserving its data (defends against
    /// session-fixation attacks). The old ID is invalidated immediately.
    /// Returns the session under its new ID, or null if `old_id` was unknown.
    pub fn regenerate(self: *SessionManager, io: std.Io, old_id: []const u8) !?*Session {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const old = self.store.get(old_id) orelse return null;

        const new_session = try self.allocator.create(Session);
        errdefer self.allocator.destroy(new_session);
        new_session.* = Session.create(self.allocator, generateId(io), nowNs(io));
        new_session.migrateFrom(old);

        try self.store.put(self.allocator, new_session.id(), new_session);
        self.removeLocked(old_id);
        return new_session;
    }

    /// Removes expired sessions. With `force = false` it is a no-op unless at
    /// least `gc_interval_seconds` elapsed since the previous run.
    pub fn gc(self: *SessionManager, io: std.Io, force: bool) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.gcLocked(io, force);
    }

    fn gcLocked(self: *SessionManager, io: std.Io, force: bool) void {
        const now = nowNs(io);
        if (!force) {
            const interval_ns: i128 = @as(i128, self.options.gc_interval_seconds) * std.time.ns_per_s;
            if (now - self.last_gc_ns < interval_ns) return;
        }
        self.last_gc_ns = now;

        var expired: std.ArrayListUnmanaged([]const u8) = .empty;
        defer expired.deinit(self.allocator);

        var it = self.store.iterator();
        while (it.next()) |entry| {
            if (self.isExpired(entry.value_ptr.*, now)) {
                expired.append(self.allocator, entry.key_ptr.*) catch break;
            }
        }
        for (expired.items) |id| self.removeLocked(id);
    }

    pub fn count(self: *SessionManager, io: std.Io) usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.store.count();
    }

    fn generateId(io: std.Io) [64]u8 {
        var bytes: [32]u8 = undefined;
        io.random(&bytes);
        var out: [64]u8 = undefined;
        const hex = "0123456789abcdef";
        for (bytes, 0..) |b, i| {
            out[i * 2] = hex[b >> 4];
            out[i * 2 + 1] = hex[b & 0x0f];
        }
        return out;
    }
};

/// Context-onion session middleware. Construct with `init(manager)` and register
/// via `attach(server)` or `server.useOnionCtx(&mw, SessionMiddleware.handle)`.
pub const SessionMiddleware = struct {
    manager: *SessionManager,

    pub fn init(manager: *SessionManager) SessionMiddleware {
        return .{ .manager = manager };
    }

    pub fn attach(self: *SessionMiddleware, server: anytype) !void {
        try server.useOnionCtx(self, handle);
    }

    pub fn handle(ctx: *anyopaque, req: *http.HttpRequest, next: *middleware.Next) anyerror!http.HttpResponse {
        const self: *SessionMiddleware = @ptrCast(@alignCast(ctx));
        const io = req.io orelse return error.MissingIo;
        const opts = self.manager.options;

        const incoming_id = (req.cookie(opts.cookie_name) catch null);

        var session: ?*Session = null;
        var had_valid_cookie = false;
        if (incoming_id) |id| {
            session = self.manager.find(io, id);
            if (session != null) had_valid_cookie = true;
        }
        if (session == null) {
            session = self.manager.create(io) catch |err| switch (err) {
                SessionError.SessionStoreFull => {
                    var res = http.HttpResponse{ .status = .service_unavailable };
                    res.setBody("Service Unavailable: session store full", "text/plain");
                    return res;
                },
                else => return err,
            };
        }
        const active = session.?;
        active.touch(io);

        try req.setAttributePtr(session_attribute_key, active);

        var response = try next.run(req);

        // Refresh the cookie when the session is new or was modified.
        if (active.isDirty(io) or !had_valid_cookie) {
            try response.setCookie(opts.cookie_name, active.id(), .{
                .max_age_seconds = opts.max_age_seconds,
                .path = opts.path,
                .secure = opts.secure,
                .http_only = opts.http_only,
                .same_site = opts.same_site,
            });
        }
        return response;
    }
};

/// Convenience accessor: retrieves the active `*Session` from a request, or null
/// if the session middleware did not run.
pub fn fromRequest(req: *const http.HttpRequest) ?*Session {
    const ptr = req.getAttributePtr(session_attribute_key) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

// ----------------------------------------------------------------------------
// Tests (driven by a single-threaded zio runtime, since std.Io.Mutex needs io)
// ----------------------------------------------------------------------------

const zio = @import("zio");
const router_mod = @import("router.zig");

const TestResult = struct {
    err: ?anyerror = null,
    fn check(self: TestResult) !void {
        if (self.err) |e| return e;
    }
};

fn runOnIo(comptime func: anytype) !void {
    var runtime = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer runtime.deinit();
    const io = runtime.io();

    var result = TestResult{};
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    const Wrapper = struct {
        fn run(r: *TestResult, the_io: std.Io) std.Io.Cancelable!void {
            func(the_io) catch |e| {
                r.err = e;
            };
        }
    };
    try group.concurrent(io, Wrapper.run, .{ &result, io });
    group.await(io) catch {};
    try result.check();
}

test "session set/get/has/remove round-trip" {
    try runOnIo(struct {
        fn body(io: std.Io) anyerror!void {
            var mgr = SessionManager.init(std.testing.allocator, .{});
            defer mgr.deinit(io);

            const s = try mgr.create(io);
            try std.testing.expect(!s.isDirty(io));
            try s.set(io, "user", "alice");
            try std.testing.expect(s.isDirty(io));
            try std.testing.expectEqualStrings("alice", s.get(io, "user").?);
            try std.testing.expect(s.has(io, "user"));

            try s.set(io, "user", "bob");
            try std.testing.expectEqualStrings("bob", s.get(io, "user").?);

            s.remove(io, "user");
            try std.testing.expect(!s.has(io, "user"));
            try std.testing.expect(s.get(io, "user") == null);
        }
    }.body);
}

test "manager find and destroy" {
    try runOnIo(struct {
        fn body(io: std.Io) anyerror!void {
            var mgr = SessionManager.init(std.testing.allocator, .{});
            defer mgr.deinit(io);

            const s = try mgr.create(io);
            var id_buf: [64]u8 = undefined;
            @memcpy(&id_buf, s.id());

            try std.testing.expectEqual(@as(usize, 1), mgr.count(io));
            try std.testing.expect(mgr.find(io, &id_buf) != null);

            mgr.destroy(io, &id_buf);
            try std.testing.expect(mgr.find(io, &id_buf) == null);
            try std.testing.expectEqual(@as(usize, 0), mgr.count(io));
        }
    }.body);
}

test "generated ids are unique 64-hex strings" {
    try runOnIo(struct {
        fn body(io: std.Io) anyerror!void {
            var mgr = SessionManager.init(std.testing.allocator, .{});
            defer mgr.deinit(io);

            const a = try mgr.create(io);
            const b = try mgr.create(io);
            try std.testing.expectEqual(@as(usize, 64), a.id().len);
            for (a.id()) |c| try std.testing.expect(std.ascii.isHex(c));
            try std.testing.expect(!std.mem.eql(u8, a.id(), b.id()));
        }
    }.body);
}

test "regenerate preserves data under a new id" {
    try runOnIo(struct {
        fn body(io: std.Io) anyerror!void {
            var mgr = SessionManager.init(std.testing.allocator, .{});
            defer mgr.deinit(io);

            const s = try mgr.create(io);
            try s.set(io, "user", "alice");
            var old_id: [64]u8 = undefined;
            @memcpy(&old_id, s.id());

            const regenerated = (try mgr.regenerate(io, &old_id)).?;
            try std.testing.expect(!std.mem.eql(u8, regenerated.id(), &old_id));
            try std.testing.expectEqualStrings("alice", regenerated.get(io, "user").?);
            try std.testing.expect(mgr.find(io, &old_id) == null);
            try std.testing.expectEqual(@as(usize, 1), mgr.count(io));
        }
    }.body);
}

test "expired sessions are evicted on find" {
    try runOnIo(struct {
        fn body(io: std.Io) anyerror!void {
            var mgr = SessionManager.init(std.testing.allocator, .{ .max_age_seconds = 1, .gc_interval_seconds = 0 });
            defer mgr.deinit(io);

            const s = try mgr.create(io);
            var id_buf: [64]u8 = undefined;
            @memcpy(&id_buf, s.id());

            // Force the last-access timestamp far into the past.
            s.last_access_ns = nowNs(io) - 5 * std.time.ns_per_s;

            try std.testing.expect(mgr.find(io, &id_buf) == null);
            try std.testing.expectEqual(@as(usize, 0), mgr.count(io));
        }
    }.body);
}

test "max_sessions cap returns SessionStoreFull" {
    try runOnIo(struct {
        fn body(io: std.Io) anyerror!void {
            var mgr = SessionManager.init(std.testing.allocator, .{ .max_sessions = 2, .gc_interval_seconds = 1_000_000 });
            defer mgr.deinit(io);

            _ = try mgr.create(io);
            _ = try mgr.create(io);
            try std.testing.expectError(SessionError.SessionStoreFull, mgr.create(io));
        }
    }.body);
}

test "middleware creates session and sets cookie for new visitor" {
    try runOnIo(struct {
        fn body(io: std.Io) anyerror!void {
            var router = router_mod.Router.init(std.testing.allocator);
            defer router.deinit();
            try router.get("/", touchHandler);

            var mgr = SessionManager.init(std.testing.allocator, .{ .cookie_name = "SID", .secure = false });
            defer mgr.deinit(io);
            var mw = SessionMiddleware.init(&mgr);

            var pipeline = middleware.MiddlewarePipeline.init(std.testing.allocator);
            defer pipeline.deinit();
            try pipeline.useOnionCtx(&mw, SessionMiddleware.handle);

            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var req: http.HttpRequest = .{ .allocator = arena.allocator(), .method = .get, .path = "/", .target = "/", .io = io };
            const response = try pipeline.execute(&router, &req);

            try std.testing.expectEqualStrings("touched", response.body);
            try std.testing.expectEqual(@as(usize, 1), mgr.count(io));
            try std.testing.expect(response.inline_cookie_count == 1);
            try std.testing.expectEqualStrings("SID", response.inline_cookies[0].name);
        }
    }.body);
}

test "middleware reuses an existing session from the cookie" {
    try runOnIo(struct {
        fn body(io: std.Io) anyerror!void {
            var router = router_mod.Router.init(std.testing.allocator);
            defer router.deinit();
            try router.get("/", readUserHandler);

            var mgr = SessionManager.init(std.testing.allocator, .{ .cookie_name = "SID", .secure = false });
            defer mgr.deinit(io);
            var mw = SessionMiddleware.init(&mgr);

            const seeded = try mgr.create(io);
            try seeded.set(io, "user", "carol");
            var id_buf: [64]u8 = undefined;
            @memcpy(&id_buf, seeded.id());

            var pipeline = middleware.MiddlewarePipeline.init(std.testing.allocator);
            defer pipeline.deinit();
            try pipeline.useOnionCtx(&mw, SessionMiddleware.handle);

            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var req: http.HttpRequest = .{ .allocator = arena.allocator(), .method = .get, .path = "/", .target = "/", .io = io };
            const cookie_header = try std.fmt.allocPrint(arena.allocator(), "SID={s}", .{&id_buf});
            try req.addHeader("Cookie", cookie_header);

            const response = try pipeline.execute(&router, &req);
            try std.testing.expectEqualStrings("carol", response.body);
            try std.testing.expectEqual(@as(usize, 1), mgr.count(io));
        }
    }.body);
}

fn touchHandler(_: *http.HttpRequest) anyerror!http.HttpResponse {
    return http.HttpResponse.text("touched");
}

fn readUserHandler(req: *http.HttpRequest) anyerror!http.HttpResponse {
    const io = req.io orelse return http.HttpResponse.serverError();
    const session = fromRequest(req) orelse return http.HttpResponse.badRequest("no session");
    const user = session.get(io, "user") orelse return http.HttpResponse.badRequest("anonymous");
    return http.HttpResponse.text(user);
}
