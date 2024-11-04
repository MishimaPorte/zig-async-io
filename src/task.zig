const Read = @import("amqp_encoding.zig").Value.Read;

pub const Task = packed struct {
    header: TaskHeader,
};

pub const TaskHeader = packed struct {
    full_len: u32,
    // len (in bytes) of the whole header (key\val) section for the task
    header_len: u32,
    // afterwards comes the other part of the task
}; //              ||
//                 \/
//|------------------------------|
//|task header (TaskHeader)      |
//|------------------------------|
//|repeated headers (key+value)  |
//|------------------------------|
//| task body <opaque>           |
//|______________________________|

pub fn headersIter(self: *Task, th: *TaskHeaderIter) void {
    th.buf = @as(
        [*]u8,
        @ptrCast(@intFromPtr(self) + @sizeOf(TaskHeader)),
    )[0..self.header.header_len];
}

pub fn body(self: *Task) []u8 {
    return @as(
        [*]u8,
        @ptrFromInt(@intFromPtr(self) + @sizeOf(TaskHeader)),
    )[self.header.header_len..];
}

pub const TaskHeaderIter = struct {
    buf: []u8,
};

pub fn next(self: *TaskHeaderIter, key: *[]u8, val: *[]u8) !bool {
    if (self.buf.len == 0) return false;
    key.* = try Read.shortString(self.buf);
    val.* = try Read.shortString(self.buf[key.len + 1 ..]);
    self.buf = self.buf[2 + key.len + val.len ..];
    return true;
}
