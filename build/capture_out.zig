//! Capture stdout and write it into the <file>.
//! Usage: capture_out <file> <command> [args...]

const std = @import("std");
const fs = std.fs;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var arg_iter = std.process.args();
    defer arg_iter.deinit();

    _ = arg_iter.next();
    const outpath = arg_iter.next() orelse unreachable;

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    while (arg_iter.next()) |arg| try args.append(allocator, arg);

    const res = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = args.items,
        .max_output_bytes = std.math.maxInt(usize),
    });

    var out = try std.fs.cwd().createFile(outpath, .{});
    defer out.close();
    try out.writeAll(res.stdout);
    try fs.File.stderr().writeAll(res.stderr);

    std.process.exit(res.term.Exited);
}
