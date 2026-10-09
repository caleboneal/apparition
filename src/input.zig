const std = @import("std");

const libinput = @import("libinput");

extern "c" fn open(path: [*c]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;

const Self = @This();

context: *libinput.libinput,
fd: c_int,

fn openRestricted(path: [*c]const u8, flags: c_int, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = user_data;
    return open(path, flags, @as(c_int, 0));
}

fn closeRestricted(fd: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    _ = close(fd);
}

const interface = libinput.libinput_interface{
    .open_restricted = openRestricted,
    .close_restricted = closeRestricted,
};

pub fn init() !Self {
    const li = libinput.libinput_path_create_context(&interface, null) orelse {
        std.log.err("Failed to create libinput context\n", .{});
        return error.LibinputInitFailed;
    };
    errdefer _ = libinput.libinput_unref(li);

    const dev_path = "/dev/input/event0";
    const device = libinput.libinput_path_add_device(li, dev_path) orelse {
        std.log.err("Failed to open device {s}. Try running with sudo?\n", .{dev_path});
        return error.DeviceAddFailed;
    };
    _ = device; // Handle is no longer needed

    const li_fd = libinput.libinput_get_fd(li);
    std.log.info("Listening for keys on {s}...\n", .{dev_path});

    // const input = c.apparition_input_create_export() orelse return error.FailedToInitializeInput;
    return .{ .context = li, .fd = li_fd };
}

pub fn deinit(self: *Self) void {
    _ = libinput.libinput_unref(self.context);
}

pub fn poll(self: *Self) void {
    _ = libinput.libinput_dispatch(self.context);

    while (libinput.libinput_get_event(self.context)) |event| {
        defer libinput.libinput_event_destroy(event);

        const ev_type = libinput.libinput_event_get_type(event);

        if (ev_type == libinput.LIBINPUT_EVENT_KEYBOARD_KEY) {
            const kbd_event = libinput.libinput_event_get_keyboard_event(event);

            const key = libinput.libinput_event_keyboard_get_key(kbd_event);
            const state = libinput.libinput_event_keyboard_get_key_state(kbd_event);

            const state_str = if (state == libinput.LIBINPUT_KEY_STATE_PRESSED)
                "PRESSED"
            else
                "RELEASED";

            std.log.info("Keycode {d} was {s}\n", .{ key, state_str });
        }
    }
}

pub fn wait(self: *Self) !void {
    var fds = [_]std.posix.pollfd{
        .{
            .fd = self.fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };

    _ = std.posix.poll(&fds, -1) catch |err| {
        std.log.err("Poll error: {}\n", .{err});
        return error.PollError;
    };
}
