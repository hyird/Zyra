//! WebSocket 协议（RFC 6455）—— 纯 Zig 帧编解码器和握手辅助函数。
//!
//! 本模块实现 RFC 6455 中自包含且无需网络即可完整测试的部分：
//!   * `computeAcceptKey` —— 从客户端的 `Sec-WebSocket-Key` 推导
//!     `Sec-WebSocket-Accept` 值。
//!   * `Opcode` / `CloseCode` —— 协议常量。
//!   * `Frame` —— 帧的解码（包含客户端 mask 处理）和编码。
//!
//! 基于连接的流式发送/接收由 `WebSocketSession` 提供；它构建于该编解码器之上，
//! 并通过 `std.Io` 读写。

const std = @import("std");

/// RFC 6455 §1.3 的魔法 GUID，在哈希前追加到客户端 key 后。
pub const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// WebSocket 操作码（RFC 6455 §5.2）。
pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,

    pub fn isControl(self: Opcode) bool {
        return (@intFromEnum(self) & 0x8) != 0;
    }
};

/// WebSocket 关闭码（RFC 6455 §7.4.1）。
pub const CloseCode = enum(u16) {
    normal = 1000,
    going_away = 1001,
    protocol_error = 1002,
    unsupported_data = 1003,
    invalid_payload = 1007,
    policy_violation = 1008,
    message_too_big = 1009,
    internal_error = 1011,
    _,
};

/// 默认最大消息大小（1 MiB），用于限制内存使用。
pub const default_max_message_size: usize = 1024 * 1024;

/// 根据给定客户端 key 计算 `Sec-WebSocket-Accept` 头值。把 base64 结果写入
/// `out`（必须 >= 28 字节），并返回写入的切片。
pub fn computeAcceptKey(client_key: []const u8, out: *[28]u8) []const u8 {
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(client_key);
    sha1.update(guid);
    var digest: [20]u8 = undefined;
    sha1.final(&digest);
    return std.base64.standard.Encoder.encode(out, &digest);
}

/// 一个已解码的 WebSocket 帧头，以及指向负载的切片。
pub const Frame = struct {
    fin: bool,
    rsv1: bool,
    opcode: Opcode,
    /// 负载字节。对于解码后的帧，它指向调用方提供且已解除 mask 的缓冲区。
    payload: []const u8,

    pub const DecodeError = error{
        Incomplete,
        PayloadTooLarge,
    };

    /// 尝试从 `data` 解码单个帧。成功时返回解码后的帧和消耗的总字节数。
    /// mask（客户端->服务端帧始终存在）会就地应用到 `data`。
    ///
    /// 若 `data` 尚未包含完整帧则返回 `error.Incomplete`；若负载超过
    /// `max_payload` 则返回 `error.PayloadTooLarge`。
    pub fn decode(data: []u8, max_payload: usize) DecodeError!struct { frame: Frame, consumed: usize } {
        if (data.len < 2) return error.Incomplete;

        const b0 = data[0];
        const b1 = data[1];
        const fin = (b0 & 0x80) != 0;
        const rsv1 = (b0 & 0x40) != 0;
        const opcode: Opcode = @enumFromInt(@as(u4, @truncate(b0 & 0x0F)));
        const masked = (b1 & 0x80) != 0;
        const len7: u64 = b1 & 0x7F;

        var offset: usize = 2;
        var payload_len: u64 = len7;
        if (len7 == 126) {
            if (data.len < offset + 2) return error.Incomplete;
            payload_len = std.mem.readInt(u16, data[offset..][0..2], .big);
            offset += 2;
        } else if (len7 == 127) {
            if (data.len < offset + 8) return error.Incomplete;
            payload_len = std.mem.readInt(u64, data[offset..][0..8], .big);
            offset += 8;
        }

        if (payload_len > max_payload) return error.PayloadTooLarge;

        var mask: [4]u8 = .{ 0, 0, 0, 0 };
        if (masked) {
            if (data.len < offset + 4) return error.Incomplete;
            @memcpy(&mask, data[offset..][0..4]);
            offset += 4;
        }

        const plen: usize = @intCast(payload_len);
        if (data.len < offset + plen) return error.Incomplete;

        const payload = data[offset .. offset + plen];
        if (masked) {
            for (payload, 0..) |*byte, i| byte.* ^= mask[i % 4];
        }

        return .{
            .frame = .{ .fin = fin, .rsv1 = rsv1, .opcode = opcode, .payload = payload },
            .consumed = offset + plen,
        };
    }

    /// 将一个服务端->客户端帧（按 RFC 6455 §5.1，不带 mask）编码到调用方拥有的
    /// 新分配缓冲区中。
    pub fn encode(allocator: std.mem.Allocator, opcode: Opcode, payload: []const u8, fin: bool) ![]u8 {
        const header_len: usize = if (payload.len < 126)
            2
        else if (payload.len <= 0xFFFF)
            4
        else
            10;

        var buf = try allocator.alloc(u8, header_len + payload.len);
        buf[0] = (if (fin) @as(u8, 0x80) else 0) | @as(u8, @intFromEnum(opcode));

        if (payload.len < 126) {
            buf[1] = @intCast(payload.len);
        } else if (payload.len <= 0xFFFF) {
            buf[1] = 126;
            std.mem.writeInt(u16, buf[2..4], @intCast(payload.len), .big);
        } else {
            buf[1] = 127;
            std.mem.writeInt(u64, buf[2..10], @intCast(payload.len), .big);
        }

        @memcpy(buf[header_len..], payload);
        return buf;
    }
};

/// 一条收到的 WebSocket 消息及其类型。
pub const Message = struct {
    opcode: Opcode,
    data: []const u8,
};

/// 一个存活的 WebSocket 连接。
///
/// 这是标准库 `std.http.Server.WebSocket` 之上的一层薄包装；后者实现了
/// RFC 6455 握手和帧读写。服务器在升级成功后构造一个 session，并传给已注册
/// 的处理器。
///
/// 注意：底层 `readMessage` 要求每条消息都能放入服务器读缓冲区，并且不会重组
/// 分片（`fin == false`）消息。
pub const WebSocketSession = struct {
    ws: *std.http.Server.WebSocket,
    open: bool = true,

    pub const ReceiveError = std.http.Server.WebSocket.ReadSmallTextMessageError;
    pub const SendError = std.Io.Writer.Error;

    /// 发送 UTF-8 文本消息。
    pub fn send(self: *WebSocketSession, text: []const u8) SendError!void {
        try self.ws.writeMessage(text, .text);
    }

    /// 发送二进制消息。
    pub fn sendBinary(self: *WebSocketSession, data: []const u8) SendError!void {
        try self.ws.writeMessage(data, .binary);
    }

    /// 发送带可选负载的 ping 帧（最多 125 字节）。
    pub fn sendPing(self: *WebSocketSession, payload: []const u8) SendError!void {
        try self.ws.writeMessage(payload, .ping);
    }

    /// 接收下一条消息。当对端关闭连接时返回 `null`。返回的数据指向连接读缓冲区，
    /// 会在下一次 `receive` 调用时失效。
    pub fn receive(self: *WebSocketSession) ReceiveError!?Message {
        const msg = self.ws.readSmallMessage() catch |err| switch (err) {
            error.ConnectionClose => {
                self.open = false;
                return null;
            },
            else => return err,
        };
        return .{ .opcode = stdToOpcode(msg.opcode), .data = msg.data };
    }

    /// 连接是否仍被认为处于打开状态。
    pub fn isOpen(self: *const WebSocketSession) bool {
        return self.open;
    }

    /// 用给定代码发送关闭帧，并将 session 标记为已关闭。
    pub fn close(self: *WebSocketSession, code: CloseCode) SendError!void {
        var payload: [2]u8 = undefined;
        std.mem.writeInt(u16, &payload, @intFromEnum(code), .big);
        self.ws.writeMessage(&payload, .connection_close) catch {};
        self.open = false;
    }
};

fn stdToOpcode(op: std.http.Server.WebSocket.Opcode) Opcode {
    return switch (op) {
        .continuation => .continuation,
        .text => .text,
        .binary => .binary,
        .connection_close => .close,
        .ping => .ping,
        .pong => .pong,
        _ => .text,
    };
}

test "computeAcceptKey matches RFC 6455 example" {
    // RFC 6455 §1.3 中的示例。
    var out: [28]u8 = undefined;
    const accept = computeAcceptKey("dGhlIHNhbXBsZSBub25jZQ==", &out);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept);
}

test "Opcode.isControl" {
    try std.testing.expect(!Opcode.text.isControl());
    try std.testing.expect(!Opcode.binary.isControl());
    try std.testing.expect(Opcode.close.isControl());
    try std.testing.expect(Opcode.ping.isControl());
    try std.testing.expect(Opcode.pong.isControl());
}

test "Frame.encode small text frame" {
    const buf = try Frame.encode(std.testing.allocator, .text, "Hello", true);
    defer std.testing.allocator.free(buf);
    // FIN + 文本操作码，长度 5，无 mask，带负载。
    try std.testing.expectEqual(@as(u8, 0x81), buf[0]);
    try std.testing.expectEqual(@as(u8, 5), buf[1]);
    try std.testing.expectEqualStrings("Hello", buf[2..]);
}

test "Frame.encode 16-bit length" {
    const payload = "x" ** 200;
    const buf = try Frame.encode(std.testing.allocator, .binary, payload, true);
    defer std.testing.allocator.free(buf);
    try std.testing.expectEqual(@as(u8, 0x82), buf[0]);
    try std.testing.expectEqual(@as(u8, 126), buf[1]);
    try std.testing.expectEqual(@as(u16, 200), std.mem.readInt(u16, buf[2..4], .big));
    try std.testing.expectEqual(@as(usize, 204), buf.len);
}

test "Frame.decode masked client frame" {
    // "Hi" 的客户端帧：FIN+text，已 mask，长度 2，mask 0x37fa213d。
    var data = [_]u8{
        0x81, 0x82, 0x37, 0xfa, 0x21, 0x3d,
        0x37 ^ 'H', 0xfa ^ 'i',
    };
    const res = try Frame.decode(&data, default_max_message_size);
    try std.testing.expect(res.frame.fin);
    try std.testing.expectEqual(Opcode.text, res.frame.opcode);
    try std.testing.expectEqualStrings("Hi", res.frame.payload);
    try std.testing.expectEqual(@as(usize, 8), res.consumed);
}

test "Frame.decode reports incomplete" {
    var data = [_]u8{0x81};
    try std.testing.expectError(error.Incomplete, Frame.decode(&data, default_max_message_size));
}

test "Frame.decode enforces max payload" {
    // len7 = 5，但最大值为 4。
    var data = [_]u8{ 0x81, 0x05, 'h', 'e', 'l', 'l', 'o' };
    try std.testing.expectError(error.PayloadTooLarge, Frame.decode(&data, 4));
}

test "encode/decode round trip" {
    // 编码一个服务端帧，然后像客户端一样给它加 mask 并解码回来。
    const original = "round-trip payload";
    const server = try Frame.encode(std.testing.allocator, .text, original, true);
    defer std.testing.allocator.free(server);

    // 用同一个负载构建一个已 mask 的客户端帧。
    var client: std.ArrayListUnmanaged(u8) = .empty;
    defer client.deinit(std.testing.allocator);
    try client.append(std.testing.allocator, 0x81);
    try client.append(std.testing.allocator, 0x80 | @as(u8, @intCast(original.len)));
    const mask = [4]u8{ 0x11, 0x22, 0x33, 0x44 };
    try client.appendSlice(std.testing.allocator, &mask);
    for (original, 0..) |c, i| try client.append(std.testing.allocator, c ^ mask[i % 4]);

    const res = try Frame.decode(client.items, default_max_message_size);
    try std.testing.expectEqualStrings(original, res.frame.payload);
    try std.testing.expectEqual(client.items.len, res.consumed);
}

const zio = @import("zio");

// 端到端：在回环连接上进行真实 WebSocket 握手 + echo，由 zio 运行时驱动，
// 覆盖 WebSocketSession.receive/send。
const E2eState = struct {
    io: std.Io,
    port: u16 = 0,
    received: [64]u8 = undefined,
    received_len: usize = 0,
    ok: bool = false,
};

fn e2eServer(state: *E2eState, listener: *std.Io.net.Server) std.Io.Cancelable!void {
    const io = state.io;
    const stream = listener.accept(io) catch return;
    defer stream.close(io);

    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    var writer = stream.writer(io, &wbuf);
    var server = std.http.Server.init(&reader.interface, &writer.interface);

    var req = server.receiveHead() catch return;
    const upgrade = req.upgradeRequested();
    const key = switch (upgrade) {
        .websocket => |k| k orelse return,
        else => return,
    };
    var socket = req.respondWebSocket(.{ .key = key }) catch return;
    socket.flush() catch return;

    var session = WebSocketSession{ .ws = &socket };
    const msg = (session.receive() catch return) orelse return;
    // 原样回显。
    session.send(msg.data) catch return;
    socket.flush() catch {};
}

fn e2eClient(state: *E2eState) std.Io.Cancelable!void {
    const io = state.io;

    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", state.port) catch return;
    const stream = addr.connect(io, .{ .mode = .stream }) catch return;
    defer stream.close(io);

    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    var writer = stream.writer(io, &wbuf);

    // 最小 WebSocket 客户端握手。
    const handshake =
        "GET /chat HTTP/1.1\r\n" ++
        "Host: 127.0.0.1\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n\r\n";
    writer.interface.writeAll(handshake) catch return;
    writer.interface.flush() catch return;

    // 读取到响应头结束（\r\n\r\n）。
    var header_buf: [1024]u8 = undefined;
    var header_len: usize = 0;
    while (header_len < header_buf.len) {
        const n = reader.interface.readSliceShort(header_buf[header_len .. header_len + 1]) catch return;
        if (n == 0) return;
        header_len += 1;
        if (header_len >= 4 and std.mem.eql(u8, header_buf[header_len - 4 .. header_len], "\r\n\r\n")) break;
    }

    // 发送已 mask 的文本帧 "ping"。
    const payload = "ping";
    const mask = [4]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
    var frame: [10]u8 = undefined;
    frame[0] = 0x81; // FIN + 文本
    frame[1] = 0x80 | @as(u8, payload.len); // 已 mask + 长度
    @memcpy(frame[2..6], &mask);
    for (payload, 0..) |c, i| frame[6 + i] = c ^ mask[i % 4];
    writer.interface.writeAll(frame[0 .. 6 + payload.len]) catch return;
    writer.interface.flush() catch return;

    // 读取回显的（未 mask）服务端帧。
    var resp: [64]u8 = undefined;
    var resp_len: usize = 0;
    while (resp_len < 6) {
        const n = reader.interface.readSliceShort(resp[resp_len..]) catch return;
        if (n == 0) break;
        resp_len += n;
    }
    const decoded = Frame.decode(resp[0..resp_len], default_max_message_size) catch return;
    @memcpy(state.received[0..decoded.frame.payload.len], decoded.frame.payload);
    state.received_len = decoded.frame.payload.len;
    state.ok = decoded.frame.opcode == .text;
}

fn e2eRoot(state: *E2eState, listener: *std.Io.net.Server) anyerror!void {
    const io = state.io;
    state.port = listener.socket.address.getPort();

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, e2eServer, .{ state, listener });
    try group.concurrent(io, e2eClient, .{state});
    group.await(io) catch {};
}

test "websocket end-to-end handshake and echo" {
    var runtime = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer runtime.deinit();
    const io = runtime.io();

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    var state = E2eState{ .io = io };
    try e2eRoot(&state, &listener);

    try std.testing.expect(state.ok);
    try std.testing.expectEqualStrings("ping", state.received[0..state.received_len]);
}
