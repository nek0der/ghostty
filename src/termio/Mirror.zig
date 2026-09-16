//! Mirror implements a termio backend whose bytes come from the embedder
//! instead of from a child process on a pty.
//!
//! The embedder hands us one already-connected file descriptor, typically
//! one end of a `socketpair(2)`. Everything the embedder writes into its
//! end is parsed as terminal output, and everything the terminal would
//! have written to a pty (key encodings, protocol responses) is written
//! back out to the embedder. We never fork, never allocate a pty, and
//! never touch termios, so the byte stream is carried verbatim in both
//! directions.
//!
//! This exists so a surface can display a screen that some other process
//! owns: a terminal multiplexer speaking its own protocol, a remote
//! session, or a recorded stream. The embedder owns the transport and
//! the process lifecycle; we only own the parsing and the rendering.
const Mirror = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const global = @import("../global.zig");
const xev = global.xev;
const fastmem = @import("../fastmem.zig");
const internal_os = @import("../os/main.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;

const log = std.log.scoped(.io_mirror);

/// Our own duplicate of the descriptor the embedder handed us. We read
/// terminal output from it and write terminal input back to it. We own
/// the duplicate and close it only after the reader thread has been
/// joined, so the embedder may close its copy at any moment without the
/// number being reused under a live reader. The stream ends when the far
/// end of the connection is closed.
fd: posix.fd_t,

pub const Config = struct {
    /// Borrowed for the duration of `init` only.
    fd: posix.fd_t,
};

pub fn init(cfg: Config) !Mirror {
    // The reader is the POSIX one from the exec backend, and a Windows
    // handle cannot be duplicated this way; no embedder uses it there.
    if (comptime builtin.os.tag == .windows) return error.Unsupported;

    // F_DUPFD_CLOEXEC rather than dup(2), so a command some other surface
    // spawns never inherits the copy.
    const rc = posix.system.fcntl(cfg.fd, posix.F.DUPFD_CLOEXEC, @as(c_int, 0));
    return switch (posix.errno(rc)) {
        .SUCCESS => .{ .fd = @intCast(rc) },
        .BADF => error.InvalidDescriptor,
        .MFILE => error.ProcessFdQuotaExceeded,
        else => |err| posix.unexpectedErrno(err),
    };
}

/// Runs after `threadExit` has joined the reader (`Surface.deinit` stops
/// the IO thread before it deinitializes termio).
pub fn deinit(self: *Mirror) void {
    _ = posix.system.close(self.fd);
}

/// There is no child process to inherit a working directory from and no
/// pty whose window size needs seeding, so the terminal starts exactly
/// as the core initialized it.
pub fn initTerminal(self: *Mirror, t: *terminal.Terminal) void {
    _ = self;
    _ = t;
}

pub fn threadEnter(
    self: *Mirror,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = alloc;

    // The pipe we use to tell the read thread to stop. pipe[0] is the
    // read end, pipe[1] is the write end.
    const pipe = try internal_os.pipe();
    errdefer _ = posix.system.close(pipe[0]);
    errdefer _ = posix.system.close(pipe[1]);

    var stream = xev.Stream.initFd(self.fd);
    errdefer stream.deinit();

    // We reuse the exec backend's reader verbatim. It is written
    // against a bare descriptor, so nothing in it is pty-specific.
    const read_thread = try std.Thread.spawn(
        .{},
        termio.Exec.ReadThread.threadMainPosix,
        .{ self.fd, io, pipe[0] },
    );
    read_thread.setName(global.io(), "io-reader") catch {};

    td.backend = .{ .mirror = .{
        .write_stream = stream,
        .read_thread = read_thread,
        .read_thread_pipe = pipe[1],
    } };
}

pub fn threadExit(self: *Mirror, td: *termio.Termio.ThreadData) void {
    _ = self;
    const mirror = &td.backend.mirror;

    switch (posix.errno(posix.system.write(mirror.read_thread_pipe, "x", 1))) {
        .SUCCESS => {},

        // The read thread already closed its end, which is what we
        // were asking for anyway.
        .PIPE => {},

        else => |e| log.warn(
            "error writing to read thread quit pipe err=E{s}",
            .{@tagName(e)},
        ),
    }

    mirror.read_thread.join();
}

/// Focus is a property of the embedder's window, not of our transport.
/// The core already encodes focus events into the write path when the
/// running application asked for them, and that is the only thing the
/// far side can act on.
pub fn focusGained(
    self: *Mirror,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;
    _ = td;
    _ = focused;
}

/// There is no pty whose window size we could set. The embedder knows
/// the grid size (`ghostty_surface_size`) and is responsible for telling
/// whatever owns the far side about it.
pub fn resize(
    self: *Mirror,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    _ = self;
    _ = grid_size;
    _ = screen_size;
}

pub fn queueWrite(
    self: *Mirror,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = self;
    const mirror = &td.backend.mirror;

    var i: usize = 0;
    while (i < data.len) {
        const w = try mirror.write_pool.create(alloc);
        w.td = mirror;
        const buf = &w.buf;
        const slice = slice: {
            const max = @min(data.len, i + buf.len);

            if (!linefeed) {
                fastmem.copy(u8, buf, data[i..max]);
                const len = max - i;
                i = max;
                break :slice buf[0..len];
            }

            // Slow path, replace \r with \r\n.
            var buf_i: usize = 0;
            while (i < data.len and buf_i < buf.len - 1) {
                const ch = data[i];
                i += 1;

                if (ch != '\r') {
                    buf[buf_i] = ch;
                    buf_i += 1;
                    continue;
                }

                buf[buf_i] = '\r';
                buf[buf_i + 1] = '\n';
                buf_i += 2;
            }

            break :slice buf[0..buf_i];
        };

        mirror.write_stream.queueWrite(
            td.loop,
            &mirror.write_queue,
            &w.req,
            .{ .slice = slice },
            ThreadData.Write,
            w,
            mirrorWrite,
        );
    }
}

fn mirrorWrite(
    w_: ?*ThreadData.Write,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.Stream,
    _: xev.WriteBuffer,
    r: xev.WriteError!usize,
) xev.CallbackAction {
    const w = w_.?;
    w.td.write_pool.destroy(w);

    _ = r catch |err| {
        log.err("write error: {}", .{err});
        return .disarm;
    };

    return .disarm;
}

/// There is no child process, so there is no abnormal exit to explain.
pub fn childExitedAbnormally(
    self: *Mirror,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    _ = self;
    _ = gpa;
    _ = t;
    _ = exit_code;
    _ = runtime_ms;
}

/// We have no process of our own. Whatever is running lives on the far
/// side of the embedder's transport, where we cannot see it.
pub fn getProcessInfo(
    self: *Mirror,
    comptime info: ProcessInfo,
) ?ProcessInfo.Type(info) {
    _ = self;
    return null;
}

/// The thread local data for the mirror implementation.
pub const ThreadData = struct {
    /// See termio.Exec.ThreadData.Write.
    pub const Write = struct {
        td: *ThreadData,
        req: xev.WriteRequest,
        buf: [64]u8,
    };

    /// The stream we write terminal input into.
    write_stream: xev.Stream,

    /// The pool of available (unused) write states.
    write_pool: std.heap.MemoryPool(Write) = .empty,

    /// The write queue for the data stream.
    write_queue: xev.WriteQueue = .{},

    /// Reader thread state.
    read_thread: std.Thread,
    read_thread_pipe: posix.fd_t,

    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = posix.system.close(self.read_thread_pipe);
        self.write_pool.deinit(alloc);
        self.write_stream.deinit();
    }
};
