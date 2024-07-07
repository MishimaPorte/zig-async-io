const std = @import("std");

pub const ReadError = error{ NotEnoughBytes, BadLetter };
pub const Value = struct {
    pub const Write = struct {
        // assumes it has enough space
        pub fn bigString(buf: []u8, string: []const u8) void {
            std.debug.assert(buf.len >= string.len + 4);
            std.mem.writeInt(u32, @ptrCast(buf.ptr), @intCast(string.len), .big);
            @memcpy(buf[4 .. 4 + string.len], string);
        }
    };

    pub const Read = struct {
        pub fn shortString(buf: []u8) ![]u8 {
            if (buf.len < 1) return error.NotEnoughBytes;
            const len = buf[0];
            if (buf.len < len + 1) return error.NotEnoughBytes;
            return buf[1 .. len + 1];
        }
        pub fn bigString(buf: []u8) ![]u8 {
            if (buf.len < 4) return error.NotEnoughBytes;
            const len = std.mem.readVarInt(u32, buf[0..4], .big);
            if (buf.len < len + 4) return error.NotEnoughBytes;
            return buf[4 .. len + 4];
        }
        pub fn table(buf: []u8) TableParser {
            return TableParser.init(buf);
        }

        pub fn tableBoolean(buf: []u8) !bool {
            if (buf.len >= 2) return error.NotEnoughBytes;
            if (buf[0] == 't') return error.BadLetter;
            return buf[1] != 0;
        }
    };
};

test "static table returns an error when underlying buffer has no space" {
    var mem: [20]u8 = undefined;
    var st = try Table(.static).init(&mem);
    try st.addStringField("kek", "lol");
    try std.testing.expectError(error.NotEnoughMemory, st.addStringField("kek", "lol"));
}

const kek_param = true;

// a struct to parse table strings
pub const TableParser = struct {
    buf: []u8,

    pub const V = struct {
        name: []u8,
        value: union(enum) {
            boolean: bool,
            string: []u8,
            uint8: u8,
            uint16: u16,
            uint32: u32,
            uint64: u64,
            int8: i8,
            int16: i16,
            int32: i32,
            int64: i64,
            float: f32,
            double: f64,
            decimal: void,
            timestamp: i64,
            table: TableParser,
            void: void,
        },
    };

    pub fn init(buf: []u8) TableParser {
        const len = std.mem.readVarInt(u32, buf[0..4], .big);
        return .{ .buf = buf[4 .. len + 4] };
    }

    pub fn nextValue(self: *TableParser) !V {
        const name = try Value.Read.shortString(self.buf);
        self.buf = self.buf[name.len + 1 ..];
        if (self.buf.len == 0)
            return error.NotEnoughBytes;

        switch (self.buf[0]) {
            // boolean
            't' => {
                const val = self.buf[2] != 0;
                self.buf = self.buf[2..];
                return .{ .name = name, .value = .{
                    .boolean = val,
                } };
            },

            // ints
            'b' => {
                const val: i8 = @intCast(self.buf[2]);
                self.buf = self.buf[3..];
                return .{ .name = name, .value = .{
                    .int8 = val,
                } };
            },
            'U' => {
                const val = std.mem.readVarInt(i16, self.buf[2..4], .big);
                self.buf = self.buf[4..];
                return .{ .name = name, .value = .{
                    .int16 = val,
                } };
            },
            'I' => {
                const val = std.mem.readVarInt(i32, self.buf[2..6], .big);
                self.buf = self.buf[6..];
                return .{ .name = name, .value = .{
                    .int32 = val,
                } };
            },
            'L' => {
                const val = std.mem.readVarInt(i64, self.buf[2..10], .big);
                self.buf = self.buf[10..];
                return .{ .name = name, .value = .{
                    .int64 = val,
                } };
            },

            // uints
            'B' => {
                const val = self.buf[2];
                self.buf = self.buf[3..];
                return .{ .name = name, .value = .{
                    .uint8 = val,
                } };
            },
            'u' => {
                const val = std.mem.readVarInt(u16, self.buf[2..4], .big);
                self.buf = self.buf[4..];
                return .{ .name = name, .value = .{
                    .uint16 = val,
                } };
            },
            'i' => {
                const val = std.mem.readVarInt(u32, self.buf[2..6], .big);
                self.buf = self.buf[6..];
                return .{ .name = name, .value = .{
                    .uint32 = val,
                } };
            },
            'l' => {
                const val = std.mem.readVarInt(u64, self.buf[2..10], .big);
                self.buf = self.buf[10..];
                return .{ .name = name, .value = .{
                    .uint64 = val,
                } };
            },

            // void
            'V' => {
                const val = void{};
                self.buf = self.buf[2..];
                return .{ .name = name, .value = .{
                    .void = val,
                } };
            },

            //big string
            'S' => {
                const val = try Value.Read.bigString(self.buf[1..]);
                self.buf = self.buf[5 + val.len ..];
                return .{ .name = name, .value = .{
                    .string = val,
                } };
            },

            'f' => @panic("not implemented: 'f'"),
            'd' => @panic("not implemented: 'd'"),

            'D' => @panic("not implemented: 'D'"),
            's' => @panic("not implemented: 's'"),
            else => return error.BadLetter,
        }
    }
};

test "table parser" {
    var buf: [1024]u8 = undefined;
    var t = try Table(.static).init(&buf);
    try t.addStringField("fiels", "lol");
    try t.addStringField("fiel1", "lol");
    try t.addStringField("fiel2", "lol");
    try t.addStringField("fiel44", "lol");
    try t.addStringField("fiel3", "lol");
    const size = t.writeSize();
    std.log.warn("tabel buf len: {d}", .{size});

    var p = TableParser.init(t.buf[0..t.ptr]);
    while (p.nextValue() catch b: {
        break :b null;
    }) |val| {
        std.log.warn("tabel buf len: {d}, val: {s}, name: {s}", .{ p.buf.len, val.value.string, val.name });
    }
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

        fn initStatic(buf: []u8) !Self {
            comptime std.debug.assert(backing == .static);
            return .{
                .allocator = void{},
                .ptr = 4,
                .buf = buf,
            };
        }
        fn initDynamic(allocator: std.mem.Allocator) !Self {
            comptime std.debug.assert(backing == .dynamic);
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
