const std = @import("std");
const tracy = @import("tracy");

var finalise_threads: std.Io.Event = .unset;
var io: std.Io = undefined;

fn handleSigInt(_: std.posix.SIG) callconv(.c) void {
    finalise_threads.set(io);
}

pub fn main(init: std.process.Init) !void {
    tracy.setThreadName("Main");
    defer tracy.message("Graceful main thread exit");

    io = init.io;
    std.posix.sigaction(std.posix.SIG.INT, &.{
        .handler = .{ .handler = handleSigInt },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);

    const other_thread = try std.Thread.spawn(.{}, otherThread, .{});
    defer other_thread.join();

    while (!finalise_threads.isSet()) {
        tracy.frameMark();

        const zone = tracy.initZone(@src(), .{ .name = "Important work" });
        defer zone.deinit();
        try std.Io.sleep(io, .{ .nanoseconds = 100 }, .awake);
    }
}

fn otherThread() void {
    tracy.setThreadName("Other");
    defer tracy.message("Graceful other thread exit");

    var os_allocator = tracy.TracingAllocator.init(std.heap.page_allocator);

    var arena = std.heap.ArenaAllocator.init(os_allocator.allocator());
    defer arena.deinit();

    var tracing_allocator = tracy.TracingAllocator.initNamed("arena", arena.allocator());

    var stack = std.Io.Writer.Allocating.init(tracing_allocator.allocator());
    defer stack.deinit();

    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &rbuf);
    var stdin = &stdin_reader.interface;
    var stdout_writer = std.Io.File.stdout().writer(io, &wbuf);
    var stdout = &stdout_writer.interface;

    while (!finalise_threads.isSet()) {
        const zone = tracy.initZone(@src(), .{ .name = "IO loop" });
        defer zone.deinit();

        stdout.print("Enter string: ", .{}) catch break;
        stdout.flush() catch break;

        const stream_zone = tracy.initZone(@src(), .{ .name = "Writer.streamUntilDelimiter" });
        _ = stdin.streamDelimiter(&stack.writer, '\n') catch break;
        _ = stdin.discard(.limited(1)) catch break;
        stream_zone.deinit();

        const toowned_zone = tracy.initZone(@src(), .{ .name = "ArrayList.toOwnedSlice" });
        const str = stack.toOwnedSlice() catch break;
        defer tracing_allocator.allocator().free(str);
        toowned_zone.deinit();

        const reverse_zone = tracy.initZone(@src(), .{ .name = "std.mem.reverse" });
        std.mem.reverse(u8, str);
        reverse_zone.deinit();

        stdout.print("Reversed: {s}\n", .{str}) catch break;
        stdout.flush() catch break;
    }
}
