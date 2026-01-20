const std = @import("std");

const evdev = @import("evdev");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .evdev, .level = .err },
    },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    var args = std.process.args();
    _ = args.skip();
    var keyboard = try evdev.Device.open(args.next().?, .{});
    defer keyboard.closeAndFree();
    std.debug.assert(keyboard.isKeyboard());

    var builder = evdev.VirtualDevice.Builder.new();
    builder.setName("ctrl2cap");
    try builder.copyCapabilities(keyboard);
    var writer = try builder.build();
    defer writer.destroy();

    try keyboard.grab();
    defer keyboard.ungrab() catch {};

    var event_buf: std.ArrayList(evdev.Event) = .empty;
    defer event_buf.deinit(allocator);
    main: while (true) {
        if (try keyboard.readEvents(allocator, &event_buf) == 0) continue;
        defer event_buf.clearRetainingCapacity();
        for (event_buf.items) |event| {
            std.debug.print("{}\n", .{event});
            var out = event;
            switch (out.code) {
                .key => |*k| switch (k.*) {
                    .KEY_CAPSLOCK => k.* = .KEY_LEFTCTRL,
                    .KEY_LEFTCTRL => k.* = .KEY_CAPSLOCK,
                    .KEY_Q => break :main,
                    else => {},
                },
                else => {},
            }
            try writer.writeEvent(out.code, out.value);
        }
    }
}
