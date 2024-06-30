const std = @import("std");

pub const ValueWriter = struct {
    // assumes it has enough space
    pub fn writeBigString(buf: []u8, string: []const u8) void {
        std.debug.assert(buf.len >= string.len + 4);
        std.mem.writeInt(u32, @ptrCast(buf.ptr), @intCast(string.len), .big);
        @memcpy(buf[4 .. 4 + string.len], string);
    }
};

test "static table returns an error when underlying buffer has no space" {
    var mem: [20]u8 = undefined;
    var st = try Table(.static).init(&mem);
    try st.addStringField("kek", "lol");
    try std.testing.expectError(error.NotEnoughMemory, st.addStringField("kek", "lol"));
}

pub fn Table(backing: enum { dynamic, static }) type {
    return struct {
        buf: []u8,
        ptr: usize,
        allocator: if (backing == .dynamic) std.mem.Allocator else void,

        const Self = @This();
        pub const Field = enum(u8) {
            BigString = 'S',
            pub fn asU8(self: Field) u8 {
                return @intFromEnum(self);
            }
        };

        pub const init = if (backing == .dynamic) initStatic else initStatic;

        pub fn initStatic(buf: []u8) !Self {
            return .{
                .allocator = void{},
                .ptr = 4,
                .buf = buf,
            };
        }
        pub fn initDynamic(allocator: std.mem.Allocator) !Self {
            return .{
                .allocator = allocator,
                .ptr = 4,
                .buf = try allocator.alloc(u8, 128),
            };
        }

        pub fn writeSize(self: *Self) u32 {
            const size: u32 = @intCast(self.ptr - 4);
            std.mem.writeInt(u32, @ptrCast(self.buf[0..].ptr), size, .big);
            return @intCast(self.ptr);
        }

        pub fn commit(self: *Self) []u8 {
            std.mem.writeInt(u32, @ptrCast(self.buf[0..].ptr), @intCast(self.ptr - 4), .big);
            return self.buf[0..self.ptr];
        }

        pub fn addName(self: *Self, name: []const u8) !void {
            std.debug.assert(name.len <= 255);
            std.debug.assert(self.buf.len >= self.ptr + name.len + 1);
            self.buf[self.ptr] = @intCast(name.len);
            @memcpy(self.buf[self.ptr + 1 .. self.ptr + 1 + name.len], name);
            self.ptr = self.ptr + name.len + 1;
        }

        pub fn addStringField(self: *Self, name: []const u8, value: []const u8) !void {
            std.debug.assert(value.len <= std.math.maxInt(u32));
            const need_cap = value.len + name.len + value.len + 6;
            if (self.buf.len < self.ptr + need_cap) {
                if (backing == .dynamic) {
                    try self.allocator.realloc(self.buf, self.buf.len + need_cap);
                } else {
                    return error.NotEnoughMemory;
                }
            }
            try self.addName(name);
            self.buf[self.ptr] = Field.BigString.asU8();
            std.mem.writeInt(u32, @ptrCast(&self.buf[self.ptr + 1]), @intCast(value.len), .big);
            @memcpy(self.buf[self.ptr + 5 .. self.ptr + 5 + value.len], value);
            self.ptr = self.ptr + value.len + 5;
        }
    };
}
