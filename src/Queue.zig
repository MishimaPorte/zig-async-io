const Channel = @import("channel.zig").Channel;
const Frame = @import("frame.zig").Frame;
const body_start = @import("frame.zig").body_start;
const Read = @import("amqp_encoding.zig").Value.Read;
const Class = @import("frame.zig").Class;
const Write = @import("amqp_encoding.zig").Value.Write;
const log = @import("std").log;
const Allocator = @import("std").mem.Allocator;
const mem = @import("std").mem;

pub fn declare(chan: *Channel, allocator: Allocator, frame: *const Frame) !void {
    // one byte at the beginning is reserved
    const q_name = try Read.shortString(frame.bodyOffset(2));
    const flags_byte: packed struct(u8) {
        passive: bool,
        durable: bool,
        exclusive: bool,
        autodelete: bool,
        no_wait: bool,
        _: u3,
    } = @bitCast(frame.data[body_start + 1 + q_name.len + 1 + 1]);
    log.info("queue declare: flags {}, q name: {s}", .{ flags_byte, q_name });
    var table = Read.table(frame.bodyOffset(1 + q_name.len + 1 + 1 + 1));
    while (true) {
        const val = table.nextValue() catch |err| {
            if (err == error.TableEnd) break;
            log.err("error while reading a table: {}", .{err});
            break;
        };
        log.info("arg: name {s}, val: {any}", .{ val.name, val.value });
    }
    const resp = try Frame.fromAllocator(allocator, .{
        .len = @intCast(4 + q_name.len + 1 + 4 + 4),
        .type = .Method,
        .channel_id = frame.header.channel_id,
    });
    resp.setMethod(Class.Queue.id, Class.Queue.Method.declare_ok.asU16());
    Write.shortString(resp.bodyOffset(0), q_name);
    mem.writeInt(u32, resp.bodyArrayPtr(q_name.len + 1, 4), 0, .big); // message count
    mem.writeInt(u32, resp.bodyArrayPtr(q_name.len + 1 + 4, 4), 0, .big); // consumer count
    try chan.c.sendFrame(resp);
}
