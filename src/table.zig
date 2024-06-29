const std = @import("std");
pub const TableWriter = struct {
    buf: []u8,
    ptr: usize,

    pub fn addName(self: *TableWriter, name: []const u8) !void {
        std.debug.assert(name.len <= 255);
        std.debug.assert(self.buf.len >= self.ptr + name.len + 1);
        self.buf[self.ptr] = @intCast(name.len);
        @memcpy(self.buf[self.ptr + 1 .. self.ptr + 1 + name.len], name);
        self.ptr = self.ptr + name.len + 1;
    }

    pub const Field = enum(u8) {
        BigString = 'S',
        pub fn asU8(self: Field) u8 {
            return @intFromEnum(self);
        }
    };

    pub fn addString(self: *TableWriter, value: []const u8) !void {
        std.debug.assert(value.len <= std.math.maxInt(u32));
        std.debug.assert(self.buf.len >= self.ptr + value.len + 5);
        self.buf[self.ptr] = Field.BigString.asU8();
        std.mem.writeInt(u32, @ptrCast(self.buf[self.ptr + 1 ..].ptr), @intCast(value.len), .big);
        @memcpy(self.buf[self.ptr + 5 .. self.ptr + 5 + value.len], value);
        self.ptr = self.ptr + value.len + 5;
    }
};

pub const StaticTable = struct {
    w: TableWriter,

    pub fn init(mem: []u8) StaticTable {
        return .{ .w = .{
            .ptr = 4,
            .buf = mem,
        } };
    }

    pub fn writeSize(self: *StaticTable) void {
        std.mem.writeInt(u32, @ptrCast(self.w.buf.ptr), @intCast(self.w.ptr - 4), .big);
    }

    pub fn buffer(self: *StaticTable) []u8 {
        self.writeSize();
        return self.w.buf[0..self.w.ptr];
    }

    const StaticTableWriteError = error{
        NotEnoughMemory,
    };

    pub fn addString(self: *StaticTable, name: []const u8, value: []const u8) !void {
        const need_cap = value.len + name.len + 6;
        if (self.w.buf.len < self.w.ptr + need_cap) {
            // reallocate better than this shit
            return error.NotEnoughMemory;
        }
        try self.w.addName(name);
        try self.w.addString(value);
    }
};

test "static table returns an error when underlying buffer has no space" {
    var mem: [20]u8 = undefined;
    var st = StaticTable.init(&mem);
    try st.addString("kek", "lol");
    try std.testing.expectError(error.NotEnoughMemory, st.addString("kek", "lol"));
}

pub const Table = struct {
    w: TableWriter,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Table {
        return .{ .allocator = allocator, .w = .{
            .ptr = 4,
            .buf = try allocator.alloc(u8, 128),
        } };
    }

    pub fn commit(self: *StaticTable) []u8 {
        std.mem.writeInt(u32, @ptrCast(self.w.buf[0..].ptr), @intCast(self.ptr - 4), .big);
        return self.w.buf[0..self.w.ptr];
    }

    pub fn addString(self: *Table, name: []const u8, value: []const u8) !void {
        const need_cap = value.len + name.len + 6;
        if (self.w.buf.len < self.ptr + need_cap) {
            // reallocate better than this shit
            try self.allocator.realloc(self.w.buf, self.w.buf.len + need_cap);
        }
        self.w.addName(name);
        self.w.addString(value);
    }
};
