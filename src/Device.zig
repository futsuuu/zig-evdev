const std = @import("std");
const log = std.log.scoped(.evdev);
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const module = @import("root.zig");
const Event = module.Event;
const Property = module.Property;

const rawModule = @import("raw.zig");

const Device = @This();

raw: rawModule.Device,

pub fn open(path: []const u8, flags: std.posix.O) !Device {
    return try Device.fromFd(try std.posix.open(path, flags, 0o444));
}

pub fn fromFd(fd: c_int) !Device {
    return Device{
        .raw = try rawModule.Device.fromFd(fd),
    };
}

pub fn free(self: Device) void {
    self.raw.free();
}

pub fn closeAndFree(self: Device) void {
    std.posix.close(self.getFd());
    self.free();
}

// https://source.android.com/docs/core/interaction/input/touch-devices#touch-device-classification
// https://source.android.com/docs/core/interaction/input/touch-devices#touch-device-driver-requirements
// https://source.android.com/docs/core/interaction/input/input-device-configuration-files#rationale

pub fn isMultiTouch(self: Device) bool {
    inline for ([_]Event.Code{
        .{ .key = .BTN_TOUCH },
        .{ .abs = .ABS_MT_POSITION_X },
        .{ .abs = .ABS_MT_POSITION_Y },
    }) |code| if (!self.hasEventCode(code)) return false;
    return 1 < self.getNumSlots() and !self.isGamepad();
}

pub fn isSingleTouch(self: Device) bool {
    inline for ([_]Event.Code{
        .{ .key = .BTN_TOUCH },
        .{ .abs = .ABS_X },
        .{ .abs = .ABS_Y },
    }) |code| if (!self.hasEventCode(code)) return false;
    return !self.isMultiTouch();
}

pub fn isGamepad(self: Device) bool {
    return self.hasEventCode(
        .{ .key = Event.Code.KEY.BTN_GAMEPAD },
    );
}

pub fn isMouse(self: Device) bool {
    inline for ([_]Event.Code{
        .{ .key = Event.Code.KEY.BTN_MOUSE },
        .{ .rel = .REL_X },
        .{ .rel = .REL_Y },
    }) |code| if (!self.hasEventCode(code)) return false;
    return true;
}

pub fn isKeyboard(self: Device) bool {
    inline for ([_]Event.Code{
        .{ .key = .KEY_SPACE },
        .{ .key = .KEY_A },
        .{ .key = .KEY_Z },
    }) |code| if (!self.hasEventCode(code)) return false;
    return true;
}

pub fn readEvents(self: Device, allocator: Allocator, dest: *ArrayList(Event)) !usize {
    const dest_len = dest.items.len;

    var ev: Event = try self.nextEvent(ReadFlags.NORMAL) orelse return 0;
    // read events until SYN_REPORT event is received
    while (true) {
        ev = (try self.nextEvent(ReadFlags.NORMAL)).?;
        try dest.append(allocator, ev);
        const syn = switch (ev.code) {
            .syn => |e| e,
            else => continue,
        };
        if (syn == .SYN_REPORT) break;
        if (syn != .SYN_DROPPED) continue;
        // read all events currently available on the device when SYN_DROPPED event is received
        while (true) {
            log.info("handling dropped events...", .{});
            if (try self.nextEvent(ReadFlags.SYNC)) |ev2|
                try dest.append(allocator, ev2)
            else
                break;
        }
    }

    removeInvalidEvents(dest, dest_len);
    return dest.items.len - dest_len;
}

fn removeInvalidEvents(events: *ArrayList(Event), start_index: usize) void {
    var dropped = false;
    var start_idx = start_index;

    var idx = start_index;
    while (idx < events.items.len) : (idx += 1) {
        const syn = switch (events.items[idx].code) {
            .syn => |e| e,
            else => continue,
        };
        switch (syn) {
            .SYN_DROPPED => {
                dropped = true;
            },
            .SYN_REPORT => if (dropped) {
                dropped = false;
                events.replaceRangeAssumeCapacity(start_idx, idx + 1 - start_idx, &.{});
                idx = start_idx - 1;
            } else {
                start_idx = idx + 1;
            },
            .SYN_CONFIG => unreachable, // currently not used
            .SYN_MT_REPORT => unreachable, // used for MT protocol type A
        }
    }
}

test removeInvalidEvents {
    const allocator = std.testing.allocator;
    // zig fmt: off
    const before: []const Event = &.{
        .{ .code = .{ .abs = .ABS_X },       .value = 9 },
        .{ .code = .{ .abs = .ABS_Y },       .value = 8 },
        .{ .code = .{ .syn = .SYN_REPORT },  .value = 0 },
        // ---
        .{ .code = .{ .abs = .ABS_X },       .value = 10 },
        .{ .code = .{ .abs = .ABS_Y },       .value = 10 },
        .{ .code = .{ .syn = .SYN_DROPPED }, .value = 0 },
        .{ .code = .{ .abs = .ABS_Y },       .value = 15 },
        .{ .code = .{ .syn = .SYN_REPORT },  .value = 0 },
        // ---
        .{ .code = .{ .abs = .ABS_X },       .value = 11 },
        .{ .code = .{ .key = .BTN_TOUCH },   .value = 0 },
        .{ .code = .{ .syn = .SYN_REPORT },  .value = 0 },
    };
    const after: []const Event = &.{
        .{ .code = .{ .abs = .ABS_X },       .value = 9 },
        .{ .code = .{ .abs = .ABS_Y },       .value = 8 },
        .{ .code = .{ .syn = .SYN_REPORT },  .value = 0 },
        // ---
        .{ .code = .{ .abs = .ABS_X },       .value = 11 },
        .{ .code = .{ .key = .BTN_TOUCH },   .value = 0 },
        .{ .code = .{ .syn = .SYN_REPORT },  .value = 0 },
    };
    // zig fmt: on
    var events: ArrayList(Event) = .empty;
    defer events.deinit(allocator);
    try events.appendSlice(allocator, before);
    removeInvalidEvents(&events, 0);
    try std.testing.expectEqualSlices(Event, after, events.items);
}

const ReadFlags = rawModule.Device.ReadFlags;

fn nextEvent(self: Device, flags: c_uint) !?Event {
    return self.raw.nextEvent(flags);
}

pub fn grab(self: Device) !void {
    return self.raw.grab();
}

pub fn ungrab(self: Device) !void {
    return self.raw.ungrab();
}

pub fn getFd(self: Device) c_int {
    return self.raw.getFd().?;
}

pub fn getName(self: Device) []const u8 {
    return self.raw.getName();
}

pub fn hasProperty(self: Device, prop: Property) bool {
    return self.raw.hasProperty(prop);
}

pub fn hasEventType(self: Device, typ: Event.Type) bool {
    return self.raw.hasEventType(typ);
}

pub fn hasEventCode(self: Device, code: Event.Code) bool {
    return self.raw.hasEventCode(code);
}

pub fn getAbsInfo(self: Device, axis: Event.Code.ABS) [*c]const rawModule.AbsInfo {
    return self.raw.getAbsInfo(axis);
}

pub fn getNumSlots(self: Device) c_int {
    return self.raw.getNumSlots();
}

pub fn getRepeat(self: Device, repeat: Event.Code.REP) ?c_int {
    return self.raw.getRepeat(repeat);
}
