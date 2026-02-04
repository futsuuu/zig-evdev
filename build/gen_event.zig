const c = @cImport(@cInclude("libevdev/libevdev.h"));

const std = @import("std");

/// Transforms a string into lowercase using a static backing buffer. No need to deallocate.
/// Assumes string is not longer than MAX_LOWERCASE_LEN characters. Not thread-safe
pub fn lowercase(arg: []const u8) []const u8 {
    const MAX_LOWERCASE_LEN = 256;
    const Static = struct {
        var buf: [MAX_LOWERCASE_LEN]u8 = undefined;
    };
    if (arg.len > MAX_LOWERCASE_LEN)
        @panic("Failed to lowercase string. Reason: string too long");

    var fb = std.heap.FixedBufferAllocator.init(&Static.buf);
    return std.ascii.allocLowerString(fb.allocator(), arg) catch
        @panic("Failed to lowercase string for unknown reason");
}

fn isMetaConstant(name: []const u8) bool {
    for ([_][]const u8{ "_VERSION", "_CNT", "_MAX" }) |s| {
        if (std.mem.endsWith(u8, name, s)) return true;
    }
    return false;
}

const Constant = struct {
    name: []const u8,
    full_name: []const u8,
    value: c_int,

    fn collect(comptime prefix: []const u8) []const Constant {
        return comptime b: {
            var slice: []const Constant = &.{};
            for (@typeInfo(c).@"struct".decls) |decl| {
                // We need to filter declarations before accessing it with `@field()`
                // to avoid `@compileError()`.
                if (!std.mem.startsWith(u8, decl.name, prefix)) continue;
                if (isMetaConstant(decl.name)) continue;
                const self: Constant = .{
                    .name = decl.name[prefix.len..],
                    .full_name = decl.name,
                    .value = @field(c, decl.name),
                };
                slice = slice ++ &[_]Constant{self};
            }
            break :b slice;
        };
    }
};

pub fn main() !void {
    @setEvalBranchQuota(30000);
    const allocator = std.heap.page_allocator;

    var s: std.ArrayList(u8) = .empty;
    defer s.deinit(allocator);
    var w = s.writer(allocator);

    _ = w.write(
        \\code: Code,
        \\value: c_int,
        \\time: @import("std").posix.timeval = undefined,
        \\
    ) catch {};

    // SYN, KEY, REL, ...
    const event_types = comptime Constant.collect("EV_");

    {
        _ = w.write(
            \\pub const Type = enum(c_ushort) {
            \\
        ) catch {};
        for (event_types) |event_type| w.print(
            \\    {s} = {},
            \\
        , .{ lowercase(event_type.name), event_type.value }) catch {};
        _ = w.write(
            \\    pub inline fn new(integer: c_ushort) Type {
            \\        return @enumFromInt(integer);
            \\    }
            \\    pub inline fn intoInt(self: @This()) c_ushort {
            \\        return @intFromEnum(self);
            \\    }
            \\    pub inline fn CodeType(comptime self: @This()) type {
            \\        return @import("std").meta.TagPayload(Code, self);
            \\    }
            \\    pub fn getName(self: @This()) []const u8 {
            \\        return switch (self) {
            \\
        ) catch {};
        for (event_types) |event_type| w.print(
            \\          .{s} => "{s}",
            \\
        , .{ lowercase(event_type.name), event_type.full_name }) catch {};
        _ = w.write(
            \\        };
            \\    }
            \\};
            \\
        ) catch {};
    }

    {
        _ = w.write(
            \\pub const Code = union(Type) {
            \\
        ) catch {};

        defer _ = w.write(
            \\    pub fn new(@"type": Type, integer: c_ushort) Code {
            \\        return switch (@"type") {
            \\            inline else => |t| t.CodeType().new(integer).intoCode(),
            \\        };
            \\    }
            \\    pub fn intoInt(self: @This()) c_ushort {
            \\        return switch (self) {
            \\            inline else => |c| c.intoInt(),
            \\        };
            \\    }
            \\    pub fn getName(self: @This()) ?[]const u8 {
            \\        return switch (self) {
            \\            inline else => |c| c.getName(),
            \\        };
            \\    }
            \\    pub inline fn getType(self: @This()) Type {
            \\        return @import("std").meta.activeTag(self);
            \\    }
            \\};
            \\
        ) catch {};

        for (event_types) |event_type| w.print(
            \\    {s}: {s},
            \\
        , .{ lowercase(event_type.name), event_type.name }) catch {};

        inline for (event_types) |event_type| {
            w.print(
                \\    pub const {s} = enum(c_ushort) {{
                \\
            , .{event_type.name}) catch {};
            defer w.print(
                \\        pub inline fn new(integer: c_ushort) @This() {{
                \\            return @enumFromInt(integer);
                \\        }}
                \\        pub inline fn intoInt(self: @This()) c_ushort {{
                \\            return @intFromEnum(self);
                \\        }}
                \\        pub inline fn intoCode(self: @This()) Code {{
                \\            return Code{{ .{s} = self }};
                \\        }}
                \\        pub fn getName(self: @This()) ?[]const u8 {{
                \\            if (comptime @typeInfo(@This()).@"enum".fields.len == 0) return null;
                \\            return switch (self) {{
                \\                inline else => |c| @tagName(c),
                \\            }};
                \\        }}
                \\    }};
                \\
            , .{lowercase(event_type.name)}) catch {};

            const Alias = struct {
                name: []const u8,
                target: []const u8,
            };
            var aliases: std.ArrayList(Alias) = .empty;
            defer aliases.deinit(allocator);
            var is_empty = true;

            var event_codes: std.ArrayList(Constant) = .empty;
            defer event_codes.deinit(allocator);
            if (std.mem.eql(u8, event_type.name, "KEY")) {
                try event_codes.appendSlice(allocator, Constant.collect("KEY_"));
                try event_codes.appendSlice(allocator, Constant.collect("BTN_"));
            } else {
                try event_codes.appendSlice(allocator, Constant.collect(event_type.name ++ "_"));
            }
            for (event_codes.items) |event_code| {
                // Whether `event_code` should match a prefix that is longer than `event_type.name ++ "_"`.
                // e.g.: `FF_STATUS_PLAYING` code should be matched with `EV_FF_STATUS` type instead of `EV_FF` type.
                const is_mismatched = for (event_types) |t| {
                    if (t.name.len <= event_type.name.len) continue;
                    if (!std.mem.startsWith(u8, t.name, event_type.name)) continue;
                    if (std.mem.startsWith(u8, event_code.full_name, t.name)) break true;
                } else false;
                if (is_mismatched) continue;

                is_empty = false;

                const real_code_name = if (c.libevdev_event_code_get_name(
                    event_type.value,
                    @intCast(event_code.value),
                )) |p| std.mem.span(p) else event_code.full_name;
                if (std.mem.eql(u8, event_code.full_name, real_code_name))
                    w.print(
                        \\        {s} = {},
                        \\
                    , .{ event_code.full_name, event_code.value }) catch {}
                else
                    try aliases.append(allocator, .{ .name = event_code.full_name, .target = real_code_name });
            }

            for (aliases.items) |alias| w.print(
                \\        pub const {s} = @This().{s};
                \\
            , .{ alias.name, alias.target }) catch {};

            if (is_empty) _ = w.write(
                \\        _,
                \\
            ) catch {};
        }
    }

    var args = std.process.args();
    _ = args.next();
    if (args.next()) |filename| {
        var out = try std.fs.cwd().createFileZ(filename, .{});
        defer out.close();
        try out.writeAll(s.items);
    } else {
        std.debug.print("{s}", .{s.items});
    }
}
