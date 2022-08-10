const std = @import("std");
const preimp = @import("../preimp.zig");
const u = preimp.util;

pub const ValueTag = enum {
    nil,
    @"true",
    @"false",
    symbol,
    string,
    number,
    list,
    vec,
    map,
    tagged,
    builtin,
    fun,
};

pub const ValueInner = union(ValueTag) {
    nil,
    @"true",
    @"false",
    symbol: []const u8,
    string: []const u8,
    number: f64,
    list: []Value,
    vec: []Value,
    // sorted by key
    map: []KeyVal,
    tagged: Tagged,
    builtin: Builtin,
    fun: Fun,

    pub fn fromZig(allocator: u.Allocator, zig_value: anytype) !ValueInner {
        const T = @TypeOf(zig_value);
        switch (T) {
            ValueInner => return zig_value,
            []const u8 => return ValueInner{ .string = zig_value },
            else => {},
        }
        switch (@typeInfo(T)) {
            .Int, .ComptimeInt => return ValueInner{ .number = @intToFloat(f64, zig_value) },
            .Float, .ComptimeFloat => return ValueInner{ .number = @floatCast(f64, zig_value) },
            .Struct => |info| {
                var map_values = u.ArrayList(KeyVal).init(allocator);
                inline for (info.fields) |field| {
                    try map_values.append(.{
                        .key = try ValueInner.fromZig(allocator, field.name),
                        .val = try ValueInner.fromZig(allocator, @field(zig_value, field.name)),
                    });
                }
                return ValueInner{ .map = map_values.toOwnedSlice() };
            },
            .Enum => |info| {
                inline for (info.fields) |field| {
                    if (@enumToInt(zig_value) == field.value) {
                        return ValueInner{ .string = field.name };
                    }
                }
                unreachable;
            },
            else => @compileError("Don't know how to turn value of type " ++ @typeName(T) ++ " into preimp.Value"),
        }
    }

    pub fn format(allocator: u.Allocator, source: [:0]const u8, args: anytype) !ValueInner {
        return (try Value.format(allocator, source, args)).inner;
    }

    pub fn replace(self: *ValueInner, arg_ix: *usize, args: []const Value) void {
        switch (self.*) {
            .nil, .@"true", .@"false", .string, .number, .builtin, .fun, .symbol => {},
            .list => |list| {
                for (list) |*elem|
                    elem.replace(arg_ix, args);
            },
            .vec => |vec| {
                for (vec) |*elem|
                    elem.replace(arg_ix, args);
            },
            .map => |map| {
                for (map) |*elem| {
                    elem.key.replace(arg_ix, args);
                    elem.val.replace(arg_ix, args);
                }
            },
            .tagged => |*tagged| {
                tagged.key.replace(arg_ix, args);
                tagged.val.replace(arg_ix, args);
            },
        }
    }

    pub fn isError(self: ValueInner) bool {
        return self == .tagged and
            self.tagged.key.inner == .string and
            u.deepEqual(self.tagged.key.inner.string, "error");
    }

    pub fn dumpInto(writer: anytype, indent: u32, self: ValueInner) anyerror!void {
        switch (self) {
            .nil => {
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll("nil");
                try writer.writeAll("\n");
            },
            .@"true" => {
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll("true");
                try writer.writeAll("\n");
            },
            .@"false" => {
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll("false");
                try writer.writeAll("\n");
            },
            .symbol => |symbol| {
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll(symbol);
                try writer.writeAll("\n");
            },
            .string => |string| {
                try writer.writeByteNTimes(' ', indent);
                try std.fmt.format(writer, "\"{}\"", .{std.zig.fmtEscapes(string)});
                try writer.writeAll("\n");
            },
            .number => |number| {
                try writer.writeByteNTimes(' ', indent);
                try std.fmt.format(writer, "{}", .{number});
                try writer.writeAll("\n");
            },
            .list => |list| {
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll("(\n");
                for (list) |value|
                    try Value.dumpInto(writer, indent + 4, value);
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll(")\n");
            },
            .vec => |vec| {
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll("[\n");
                for (vec) |value|
                    try Value.dumpInto(writer, indent + 4, value);
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll("]\n");
            },
            .map => |map| {
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll("{\n");
                for (map) |key_val| {
                    try Value.dumpInto(writer, indent + 4, key_val.key);
                    try Value.dumpInto(writer, indent + 4, key_val.val);
                }
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll("}\n");
            },
            .tagged => |tagged| {
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll("#\n");
                try Value.dumpInto(writer, indent + 4, tagged.key.*);
                try Value.dumpInto(writer, indent + 4, tagged.val.*);
            },
            .builtin => |builtin| {
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll(std.meta.tagName(builtin));
                try writer.writeAll("\n");
            },
            .fun => |_| {
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll("<fn>");
                try writer.writeAll("\n");
            },
        }
    }
};

pub const Value = struct {
    inner: ValueInner,
    meta: []KeyVal,

    pub fn fromInner(inner: ValueInner) Value {
        return Value{
            .inner = inner,
            .meta = &.{},
        };
    }

    pub fn fromZig(allocator: u.Allocator, zig_value: anytype) !Value {
        if (@TypeOf(zig_value) == Value)
            return zig_value;
        const inner = try ValueInner.fromZig(allocator, zig_value);
        return Value.fromInner(inner);
    }

    pub fn format(allocator: u.Allocator, source: [:0]const u8, args: anytype) !Value {
        var arg_values: [args.len]Value = undefined;
        comptime var i: usize = 0;
        inline while (i < args.len) : (i += 1)
            arg_values[i] = try Value.fromZig(allocator, args[i]);
        return Value.formatValues(allocator, source, &arg_values);
    }

    pub fn formatValues(allocator: u.Allocator, source: [:0]const u8, args: []const Value) !Value {
        // TODO be careful about leaking tokens etc
        var parser = try preimp.Parser.init(allocator, source);
        const exprs = try parser.parseExprs(null, .eof);
        u.assert(exprs.len == 1);
        var value = exprs[0];
        var arg_ix: usize = 0;
        value.replace(&arg_ix, args);
        u.assert(arg_ix == args.len);
        return value;
    }

    pub fn replace(self: *Value, arg_ix: *usize, args: []const Value) void {
        if (self.inner == .symbol and u.deepEqual(self.inner.symbol, "?")) {
            self.* = args[arg_ix.*];
            arg_ix.* += 1;
        } else {
            self.inner.replace(arg_ix, args);
            // don't reach into meta
        }
    }

    pub fn dumpInto(writer: anytype, indent: u32, self: Value) anyerror!void {
        try ValueInner.dumpInto(writer, indent, self.inner);
    }

    pub fn deepCompare(a: Value, b: Value) std.math.Order {
        return u.deepCompare(a.inner, b.inner);
    }
};

pub const KeyVal = struct {
    key: Value,
    val: Value,

    pub fn get(key_vals: []const KeyVal, key: Value) ?Value {
        return switch (u.binarySearch(preimp.KeyVal, key, key_vals, {}, (struct {
            fn compare(_: void, key_: preimp.Value, key_val: preimp.KeyVal) std.math.Order {
                return u.deepCompare(key_, key_val.key);
            }
        }).compare)) {
            .Found => |pos| key_vals[pos].val,
            .NotFound => null,
        };
    }

    pub fn put(allocator: u.Allocator, key_vals: []const KeyVal, key: Value, val: Value) ![]KeyVal {
        var new_key_vals = try u.ArrayList(preimp.KeyVal).initCapacity(allocator, key_vals.len);
        try new_key_vals.appendSlice(key_vals);

        switch (u.binarySearch(preimp.KeyVal, key, new_key_vals.items, {}, (struct {
            fn compare(_: void, key_: preimp.Value, key_val: preimp.KeyVal) std.math.Order {
                return u.deepCompare(key_, key_val.key);
            }
        }).compare)) {
            .Found => |pos| new_key_vals.items[pos].val = val,
            .NotFound => |pos| try new_key_vals.insert(pos, .{ .key = key, .val = val }),
        }

        return new_key_vals.toOwnedSlice();
    }
};

pub const Tagged = struct {
    key: *Value,
    val: *Value,
};

pub const Builtin = enum {
    @"=",
    get,
    put,
    @"+",
    @"-",
    @"*",
    @"/",
    @"get-meta",
    @"put-meta",
    count,
};

pub const Fun = struct {
    env: []const Binding,
    args: []const []const u8,
    body: []const Value,
};

pub const Binding = struct {
    name: []const u8,
    value: Value,
};
