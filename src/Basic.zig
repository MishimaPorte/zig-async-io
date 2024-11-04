const Channel = @import("channel.zig").Channel;
const mem = @import("std").mem;
const log = @import("std").log;
const Allocator = mem.Allocator;
const Frame = @import("frame.zig").Frame;
const Class = @import("frame.zig").Class;
const ReadError = @import("amqp_encoding.zig").ReadError;
const Read = @import("amqp_encoding.zig").Value.Read;
const Write = @import("amqp_encoding.zig").Value.Write;
const Task = @import("task.zig").TaskHeader;

pub fn qos(chan: *Channel, allocator: Allocator, frame: *const Frame) !void {
    chan.prefetch_size = mem.readInt(u32, frame.bodyArrayPtr(0, 4), .big);
    chan.prefetch_count = mem.readInt(u16, frame.bodyArrayPtr(4, 2), .big);
    const is_global = @as(packed struct(u8) {
        is_global: bool,
        _: u7,
    }, @bitCast(frame.bodyArrayPtr(6, 1)[0])).is_global;
    log.err("pref size: {}, pref count: {}, is_global: {}", .{
        chan.prefetch_size, chan.prefetch_count, is_global,
    });
    var ok = try Frame.fromAllocator(allocator, .{
        .len = 8,
        .type = .Method,
        .channel_id = frame.header.channel_id,
    });
    ok.setMethod(Class.Basic.id, Class.Basic.Method.qos_ok.asU16());
    return chan.c.sendFrame(ok);
}

pub fn consume(chan: *Channel, allocator: Allocator, frame: *const Frame) !void {
    const queue = try Read.shortString(frame.bodyOffset(2));
    const consumer_tag = try Read.shortString(frame.bodyOffset(3 + queue.len));
    const flags = @as(packed struct(u8) {
        nolocal: bool,
        noack: bool,
        exclusive: bool,
        nowait: bool,
        _: u4,
    }, @bitCast(frame.bodyArrayPtr(4 + queue.len + consumer_tag.len, 1)[0]));
    const is_nolocal = flags.nolocal;
    const is_noack = flags.noack;
    const is_exclusive = flags.exclusive;
    const is_nowait = flags.nowait;
    log.err("queue: '{s}' consumer_tag: '{s}' is_nolocal: {} is_noack: {} is_exclusive: {}, is_nowait: {}", .{
        queue, consumer_tag, is_nolocal, is_noack, is_exclusive, is_nowait,
    });
    // we just ignore the table of arguments.
    const argparser = Read.table(frame.bodyOffset(5 + queue.len + consumer_tag.len));
    _ = argparser;
    var ok = try Frame.fromAllocator(allocator, .{
        .len = 9 + @as(u32, @intCast(consumer_tag.len)),
        .type = .Method,
        .channel_id = frame.header.channel_id,
    });
    ok.setMethod(Class.Basic.id, Class.Basic.Method.consume_ok.asU16());
    Write.shortString(ok.bodyOffset(0), consumer_tag);
    return chan.c.sendFrame(ok);
}
