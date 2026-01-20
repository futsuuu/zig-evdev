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

pub fn main() !void {
    @setEvalBranchQuota(220000);
    const allocator = std.heap.page_allocator;

    const consts = comptime b: {
        var consts: []const []const u8 = &.{};
        for (@typeInfo(c).@"struct".decls) |decl|
            consts = consts ++ &[_][]const u8{decl.name};
        break :b consts;
    };

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
    const types = comptime b: {
        var types: []const []const u8 = &.{};
        for (consts) |cnst| {
            if (filter(cnst, "EV_"))
                types = types ++ &[_][]const u8{cnst["EV_".len..]};
        }
        break :b types;
    };

    {
        _ = w.write(
            \\pub const Type = enum(c_ushort) {
            \\
        ) catch {};
        inline for (types) |typ| w.print(
            \\    {s} = {},
            \\
        , .{ lowercase(typ), @field(c, "EV_" ++ typ) }) catch {};
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
        inline for (types) |typ| w.print(
            \\          .{s} => "EV_{s}",
            \\
        , .{ lowercase(typ), typ }) catch {};
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

        for (types) |typ| w.print(
            \\    {s}: {s},
            \\
        , .{ lowercase(typ), typ }) catch {};

        inline for (types) |typ| {
            w.print(
                \\    pub const {s} = enum(c_ushort) {{
                \\
            , .{typ}) catch {};
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
            , .{lowercase(typ)}) catch {};

            const Alias = struct {
                name: []const u8,
                target: []const u8,
            };
            var aliases: std.ArrayList(Alias) = .empty;
            defer aliases.deinit(allocator);
            var is_empty = true;

            consts: inline for (consts) |cnst| {
                comptime if (!filter(cnst, typ ++ "_"))
                    if (!(std.mem.eql(u8, typ, "KEY") and filter(cnst, "BTN_")))
                        continue;
                comptime for (types) |t|
                    if (!std.mem.eql(u8, typ, t) and filter(cnst, t ++ "_"))
                        // - typ != t
                        // - cnst starts with both typ and t
                        if (typ.len < t.len)
                            // t includes typ
                            continue :consts;

                is_empty = false;

                const code: c_ushort = @field(c, cnst);
                const code_name = if (c.libevdev_event_code_get_name(@field(c, "EV_" ++ typ), code)) |p| std.mem.span(p) else cnst;
                if (std.mem.eql(u8, cnst, code_name))
                    w.print(
                        \\        {s} = {},
                        \\
                    , .{ cnst, code }) catch {}
                else
                    try aliases.append(allocator, .{ .name = cnst, .target = code_name });
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

fn filter(name: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, name, prefix))
        return false;

    for ([_][]const u8{ "_VERSION", "_CNT", "_MAX" }) |s|
        if (std.mem.endsWith(u8, name, s))
            return false;

    return true;
}
