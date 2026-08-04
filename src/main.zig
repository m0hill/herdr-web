const std = @import("std");
const posix = std.posix;

// The forkpty and WebSocket handshake/frame patterns are adapted from Nexus
// (https://github.com/Edward-lyz/Nexus), MIT licensed.

const Pty = struct {
    fd: posix.fd_t,
    pid: posix.pid_t,

    fn spawn(cols: u16, rows: u16) !Pty {
        var fd: posix.fd_t = undefined;
        var ws = std.c.winsize{ .col = cols, .row = rows, .xpixel = 0, .ypixel = 0 };
        const pid = forkpty(&fd, null, null, &ws);
        if (pid < 0) return error.ForkPtyFailed;
        if (pid == 0) {
            _ = setenv("TERM", "xterm-256color", 1);
            // The web PTY is a separate Herdr client, not a nested pane process.
            _ = unsetenv("HERDR_ENV");
            _ = unsetenv("HERDR_PANE_ID");
            _ = unsetenv("HERDR_TAB_ID");
            _ = unsetenv("HERDR_WORKSPACE_ID");
            _ = unsetenv("HERDR_STARTUP_CWD");
            const argv = [_:null]?[*:0]const u8{ "herdr", null };
            const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
            posix.execvpeZ("herdr", &argv, envp) catch posix.exit(127);
        }
        return .{ .fd = fd, .pid = pid };
    }

    fn resize(self: Pty, cols: u16, rows: u16) void {
        var ws = std.c.winsize{ .col = cols, .row = rows, .xpixel = 0, .ypixel = 0 };
        const request: c_int = @bitCast(@as(c_uint, 0x80087467));
        _ = std.c.ioctl(self.fd, request, @intFromPtr(&ws));
    }

    fn stop(self: Pty) void {
        posix.kill(self.pid, posix.SIG.TERM) catch {};
        posix.close(self.fd);
        var attempts: u8 = 0;
        while (attempts < 20) : (attempts += 1) {
            if (posix.waitpid(self.pid, std.c.W.NOHANG).pid != 0) return;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        posix.kill(self.pid, posix.SIG.KILL) catch {};
        _ = posix.waitpid(self.pid, 0);
    }
};

const Frame = struct { opcode: u8, payload: []u8 };

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var host: []const u8 = "0.0.0.0";
    var port: u16 = 7681;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--host") and index + 1 < args.len) {
            index += 1;
            host = args[index];
        } else if (std.mem.eql(u8, arg, "--port") and index + 1 < args.len) {
            index += 1;
            port = std.fmt.parseInt(u16, args[index], 10) catch return error.InvalidPort;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("Usage: herdr-web [--host ADDRESS] [--port PORT]\n", .{});
            return;
        } else {
            std.log.err("unknown argument: {s}", .{arg});
            return error.InvalidArgument;
        }
    }

    const address = try std.net.Address.parseIp4(host, port);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();
    std.log.info("listening on http://{s}:{d}", .{ host, port });
    while (true) {
        const connection = try server.accept();
        const thread = std.Thread.spawn(.{}, handleConnection, .{connection.stream}) catch {
            connection.stream.close();
            continue;
        };
        thread.detach();
    }
}

fn handleConnection(stream: std.net.Stream) void {
    var request_buf: [16384]u8 = undefined;
    const n = stream.read(&request_buf) catch {
        stream.close();
        return;
    };
    if (n == 0) {
        stream.close();
        return;
    }
    const request = request_buf[0..n];
    const target = requestTarget(request) orelse {
        stream.close();
        return;
    };
    if (std.mem.startsWith(u8, target, "/ws")) {
        if (header(request, "Upgrade")) |upgrade| {
            if (std.ascii.eqlIgnoreCase(upgrade, "websocket")) {
                handleWebSocket(stream, request, target);
                return;
            }
        }
    }
    serveStatic(stream, target);
}

fn handleWebSocket(stream: std.net.Stream, request: []const u8, target: []const u8) void {
    defer stream.close();
    const key = header(request, "Sec-WebSocket-Key") orelse return;
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(key);
    sha.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    const digest = sha.finalResult();
    var accept_buf: [28]u8 = undefined;
    const accept = std.base64.standard.Encoder.encode(&accept_buf, &digest);
    var response_buf: [512]u8 = undefined;
    const response = std.fmt.bufPrint(&response_buf, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{accept}) catch return;
    writeAll(stream, response) catch return;

    const cols = queryU16(target, "cols") orelse 80;
    const rows = queryU16(target, "rows") orelse 24;
    const pty = Pty.spawn(cols, rows) catch return;
    const output_thread = std.Thread.spawn(.{}, forwardPty, .{ pty.fd, stream }) catch {
        pty.stop();
        return;
    };
    while (readFrame(std.heap.page_allocator, stream)) |frame| {
        defer std.heap.page_allocator.free(frame.payload);
        switch (frame.opcode) {
            0x2 => writeFdAll(pty.fd, frame.payload) catch break,
            0x1 => handleResize(pty, frame.payload),
            0x8 => {
                sendFrame(stream, 0x8, frame.payload) catch {};
                break;
            },
            0x9 => sendFrame(stream, 0xA, frame.payload) catch break,
            else => {},
        }
    }
    pty.stop();
    output_thread.join();
}

fn forwardPty(fd: posix.fd_t, stream: std.net.Stream) void {
    var buf: [16384]u8 = undefined;
    while (true) {
        const n = posix.read(fd, &buf) catch break;
        if (n == 0) break;
        sendFrame(stream, 0x2, buf[0..n]) catch break;
    }
}

fn handleResize(pty: Pty, bytes: []const u8) void {
    const Resize = struct { type: []const u8, cols: u16, rows: u16 };
    const parsed = std.json.parseFromSlice(Resize, std.heap.page_allocator, bytes, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    if (std.mem.eql(u8, parsed.value.type, "resize") and parsed.value.cols > 0 and parsed.value.rows > 0)
        pty.resize(parsed.value.cols, parsed.value.rows);
}

fn readFrame(allocator: std.mem.Allocator, stream: std.net.Stream) ?Frame {
    var h: [2]u8 = undefined;
    readAll(stream, &h) catch return null;
    const opcode = h[0] & 0x0f;
    const masked = h[1] & 0x80 != 0;
    var len: u64 = h[1] & 0x7f;
    if (len == 126) {
        var x: [2]u8 = undefined;
        readAll(stream, &x) catch return null;
        len = std.mem.readInt(u16, &x, .big);
    }
    if (len == 127) {
        var x: [8]u8 = undefined;
        readAll(stream, &x) catch return null;
        len = std.mem.readInt(u64, &x, .big);
    }
    if (!masked or len > 1024 * 1024) return null;
    var mask: [4]u8 = undefined;
    readAll(stream, &mask) catch return null;
    const payload = allocator.alloc(u8, @intCast(len)) catch return null;
    readAll(stream, payload) catch {
        allocator.free(payload);
        return null;
    };
    for (payload, 0..) |*b, i| b.* ^= mask[i % 4];
    return .{ .opcode = opcode, .payload = payload };
}

fn sendFrame(stream: std.net.Stream, opcode: u8, payload: []const u8) !void {
    var h: [10]u8 = undefined;
    h[0] = 0x80 | opcode;
    var n: usize = 2;
    if (payload.len < 126) h[1] = @intCast(payload.len) else if (payload.len <= 65535) {
        h[1] = 126;
        std.mem.writeInt(u16, h[2..4], @intCast(payload.len), .big);
        n = 4;
    } else {
        h[1] = 127;
        std.mem.writeInt(u64, h[2..10], payload.len, .big);
        n = 10;
    }
    try writeAll(stream, h[0..n]);
    try writeAll(stream, payload);
}

fn serveStatic(stream: std.net.Stream, target: []const u8) void {
    defer stream.close();
    const clean = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    if (std.mem.indexOf(u8, clean, "..") != null) return sendError(stream, "403 Forbidden");
    const rel = if (std.mem.eql(u8, clean, "/")) "index.html" else std.mem.trimLeft(u8, clean, "/");
    var path_buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "web/dist/{s}", .{rel}) catch return;
    const file = std.fs.cwd().openFile(path, .{}) catch return sendError(stream, "404 Not Found");
    defer file.close();
    const stat = file.stat() catch return;
    var hdr: [512]u8 = undefined;
    const headers = std.fmt.bufPrint(&hdr, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ mime(rel), stat.size }) catch return;
    writeAll(stream, headers) catch return;
    var buf: [16384]u8 = undefined;
    while (true) {
        const n = file.read(&buf) catch return;
        if (n == 0) break;
        writeAll(stream, buf[0..n]) catch return;
    }
}

fn sendError(stream: std.net.Stream, status: []const u8) void {
    var b: [256]u8 = undefined;
    const r = std.fmt.bufPrint(&b, "HTTP/1.1 {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{status}) catch return;
    writeAll(stream, r) catch {};
}
fn mime(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return "text/html; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".js")) return "application/javascript";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css";
    return "application/octet-stream";
}
fn requestTarget(r: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, r, "GET ")) return null;
    const end = std.mem.indexOfScalar(u8, r[4..], ' ') orelse return null;
    return r[4 .. 4 + end];
}
fn header(r: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, r, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..colon], name)) return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}
fn queryU16(target: []const u8, name: []const u8) ?u16 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var parts = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (parts.next()) |part| {
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        if (std.mem.eql(u8, part[0..eq], name)) return std.fmt.parseInt(u16, part[eq + 1 ..], 10) catch null;
    }
    return null;
}
fn readAll(stream: std.net.Stream, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = try stream.read(buf[off..]);
        if (n == 0) return error.EndOfStream;
        off += n;
    }
}
fn writeAll(stream: std.net.Stream, buf: []const u8) !void {
    var off: usize = 0;
    while (off < buf.len) off += try stream.write(buf[off..]);
}
fn writeFdAll(fd: posix.fd_t, buf: []const u8) !void {
    var off: usize = 0;
    while (off < buf.len) off += try posix.write(fd, buf[off..]);
}

extern "c" fn forkpty(master: *posix.fd_t, name: ?[*:0]u8, termp: ?*anyopaque, winp: *std.c.winsize) posix.pid_t;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
comptime {
    _ = std.c;
}
