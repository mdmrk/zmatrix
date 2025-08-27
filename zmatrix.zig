const std = @import("std");
const print = std.debug.print;
const builtin = @import("builtin");

const zmatrix_options = @import("zmatrix_options");

const windows = builtin.os.tag == .windows;

var prng: std.Random.DefaultPrng = undefined;
var rand: std.Random = undefined;

var stdout_writer: std.fs.File.Writer = undefined;
var buf: []u8 = undefined;
var tty_win: std.os.windows.HANDLE = undefined;
var tty_nix: std.fs.File = undefined;

var matrix: [][]Matrix = undefined;
var prev_matrix: [][]Matrix = undefined;
var spaces: []u32 = &.{};
var lengths: []u32 = &.{};
var updates: []u32 = &.{};
var current_size: TermSize = .{ .width = 0, .height = 0 };
var update_time: u64 = 40_000_000;

var args: struct {
    help: bool = false,
    version: bool = false,
} = .{};

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

const Matrix = struct {
    val: i32,
    is_head: bool,
    color: u8,
};

const TermSize = struct {
    width: u32,
    height: u32,
};

const AnsiEscapeCodes = struct {
    const esc = "\x1B";
    const csi = esc ++ "[";

    const cursor_show = csi ++ "?25h";
    const cursor_hide = csi ++ "?25l";
    const cursor_home = csi ++ "1;1H";
    const cursor_pos = csi ++ "{d};{d}H";

    const color_fg = "38;5;";
    const color_bg = "48;5;";
    const color_fg_def = csi ++ color_fg ++ "15m";
    const color_bg_def = csi ++ color_bg ++ "0m";
    const color_def = color_fg_def;

    const color_bright_green = csi ++ "38;5;46m";
    const color_green = csi ++ "38;5;34m";
    const color_dark_green = csi ++ "38;5;22m";

    const screen_clear = csi ++ "2J";
    const screen_buf_on = csi ++ "?1049h";
    const screen_buf_off = csi ++ "?1049l";
    const nl = "\n";

    const term_on = screen_buf_on ++ cursor_hide ++ cursor_home ++ screen_clear ++ color_def;
    const term_off = screen_buf_off ++ cursor_show ++ nl;
};

fn parseArgs(alloc: std.mem.Allocator) !void {
    var args_it = try std.process.argsWithAllocator(alloc);
    defer args_it.deinit();

    const S = struct {
        inline fn checkArg(arg: []const u8, comptime short: []const u8, comptime long: []const u8) bool {
            return std.mem.eql(u8, arg, short) or std.mem.eql(u8, arg, long);
        }
    };

    _ = args_it.skip();
    while (args_it.next()) |arg| {
        if (S.checkArg(arg, "-h", "--help")) {
            args.help = true;
        } else if (S.checkArg(arg, "-v", "--version")) {
            args.version = true;
        }
    }
}

fn getTerminalSize() !TermSize {
    if (windows) {
        var info: std.os.windows.CONSOLE_SCREEN_BUFFER_INFO = .{
            .dwSize = .{ .X = 0, .Y = 0 },
            .dwCursorPosition = .{ .X = 0, .Y = 0 },
            .wAttributes = 0,
            .srWindow = .{ .Left = 0, .Top = 0, .Right = 0, .Bottom = 0 },
            .dwMaximumWindowSize = .{ .X = 0, .Y = 0 },
        };

        if (std.os.windows.kernel32.GetConsoleScreenBufferInfo(tty_win, &info) == 0) {
            switch (std.os.windows.kernel32.GetLastError()) {
                else => |e| return std.os.windows.unexpectedError(e),
            }
        }

        return .{
            .height = @intCast(info.srWindow.Bottom - info.srWindow.Top + 1),
            .width = @intCast(info.srWindow.Right - info.srWindow.Left + 1),
        };
    } else {
        const TIOCGWINSZ = std.c.T.IOCGWINSZ;
        const winsz = std.c.winsize{ .col = 0, .row = 0, .xpixel = 0, .ypixel = 0 };

        if (winsz.row == 0 or winsz.col == 0) {
            var lldb_winsz = std.c.winsize{ .col = 0, .row = 0, .xpixel = 0, .ypixel = 0 };
            const lldb_rv = std.os.linux.ioctl(tty_nix.handle, TIOCGWINSZ, @intFromPtr(&lldb_winsz));
            const lldb_err = std.posix.errno(lldb_rv);

            if (lldb_rv >= 0) {
                return .{ .height = lldb_winsz.row, .width = lldb_winsz.col };
            } else {
                return std.posix.unexpectedErrno(lldb_err);
            }
        } else {
            return .{ .height = winsz.row, .width = winsz.col };
        }
    }
}

fn deallocateMatrix(alloc: std.mem.Allocator, mat: [][]Matrix) void {
    for (mat) |row| {
        alloc.free(row);
    }
    alloc.free(mat);
}

fn allocateMatrix(alloc: std.mem.Allocator, width: u32, height: u32) ![][]Matrix {
    const mat = try alloc.alloc([]Matrix, height + 1);
    errdefer {
        for (mat[0..height]) |row| {
            alloc.free(row);
        }
        alloc.free(mat);
    }

    for (mat) |*row| {
        row.* = try alloc.alloc(Matrix, width);
        for (row.*) |*cell| {
            cell.* = .{ .is_head = false, .val = -1, .color = 0 };
        }
    }
    return mat;
}

fn initializeColumns(alloc: std.mem.Allocator, width: u32, height: u32) !void {
    if (spaces.len > 0) {
        alloc.free(spaces);
        alloc.free(lengths);
        alloc.free(updates);
    }

    spaces = try alloc.alloc(u32, width);
    lengths = try alloc.alloc(u32, width);
    updates = try alloc.alloc(u32, width);

    var j: u32 = 0;
    while (j <= width - 1) : (j += 1) {
        spaces[j] = rand.uintLessThan(u32, height) + 1;
        lengths[j] = rand.uintLessThan(u32, height - 3) + 3;
        if (j < matrix[1].len) matrix[1][j].val = ' ';
        updates[j] = rand.uintLessThan(u32, 3) + 1;
    }
}

fn renderFrame(alloc: std.mem.Allocator, term_size: TermSize, buffer: *std.ArrayList(u8)) !void {
    buffer.clearRetainingCapacity();

    for (1..term_size.height + 1) |i| {
        for (0..term_size.width) |j| {
            const cell = matrix[i][j];

            if (cell.val == -1) {
                try buffer.append(alloc, ' ');
            } else if (cell.val == ' ') {
                try buffer.append(alloc, ' ');
            } else {
                if (cell.is_head) {
                    try buffer.appendSlice(alloc, AnsiEscapeCodes.color_bright_green);
                } else {
                    try buffer.appendSlice(alloc, AnsiEscapeCodes.color_green);
                }

                try buffer.append(alloc, @as(u8, @intCast(cell.val)));
                try buffer.appendSlice(alloc, AnsiEscapeCodes.color_def);
            }
        }
        if (i < term_size.height) {
            try buffer.append(alloc, '\n');
        }
    }
}

fn renderFrameDiff(alloc: std.mem.Allocator, term_size: TermSize, buffer: *std.ArrayList(u8)) !void {
    buffer.clearRetainingCapacity();

    for (1..term_size.height + 1) |i| {
        for (0..term_size.width) |j| {
            const curr = matrix[i][j];
            const prev = prev_matrix[i][j];

            if (curr.val != prev.val or curr.is_head != prev.is_head) {
                try buffer.writer(alloc).print("\x1B[{d};{d}H", .{ i, j + 1 });

                if (curr.val == -1) {
                    try buffer.append(alloc, ' ');
                } else if (curr.val == ' ') {
                    try buffer.append(alloc, ' ');
                } else {
                    if (curr.is_head) {
                        try buffer.appendSlice(alloc, AnsiEscapeCodes.color_bright_green);
                    } else {
                        try buffer.appendSlice(alloc, AnsiEscapeCodes.color_green);
                    }

                    try buffer.append(alloc, @as(u8, @intCast(curr.val)));
                    try buffer.appendSlice(alloc, AnsiEscapeCodes.color_def);
                }
            }
        }
    }
}

fn copyMatrix(src: [][]Matrix, dst: [][]Matrix) void {
    for (src, dst) |src_row, dst_row| {
        for (src_row, dst_row) |src_cell, *dst_cell| {
            dst_cell.* = src_cell;
        }
    }
}

fn checkResize(alloc: std.mem.Allocator) !bool {
    const new_size = try getTerminalSize();
    if (new_size.width != current_size.width or new_size.height != current_size.height) {
        if (current_size.width > 0) {
            deallocateMatrix(alloc, matrix);
            deallocateMatrix(alloc, prev_matrix);
        }

        matrix = try allocateMatrix(alloc, new_size.width, new_size.height);
        prev_matrix = try allocateMatrix(alloc, new_size.width, new_size.height);

        try initializeColumns(alloc, new_size.width, new_size.height);

        current_size = new_size;

        print("{s}{s}", .{
            AnsiEscapeCodes.screen_clear,
            AnsiEscapeCodes.cursor_home,
        });

        return true;
    }
    return false;
}

fn kbhit() bool {
    const fd = if (windows)
        @as(std.os.windows.ws2_32.SOCKET, @ptrCast(std.os.windows.kernel32.GetStdHandle(std.os.windows.STD_INPUT_HANDLE)))
    else
        std.posix.STDIN_FILENO;
    const fds: std.posix.pollfd = .{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    };
    return std.posix.poll(@constCast(&[_]std.posix.pollfd{fds}), 0) catch 0 > 0;
}

fn getch() !u8 {
    var buffer: [1]u8 = undefined;
    const fd = if (windows)
        @as(std.os.windows.ws2_32.SOCKET, @ptrCast(std.os.windows.kernel32.GetStdHandle(std.os.windows.STD_INPUT_HANDLE)))
    else
        std.posix.STDIN_FILENO;
    const bytes_read = try std.posix.read(fd, &buffer);
    if (bytes_read > 0) {
        return buffer[0];
    }
    return error.NoInput;
}

fn handle_keypress(key: u8) void {
    switch (key) {
        '0' => {
            update_time = 4_000;
        },
        '1' => {
            update_time = 4_000_0;
        },
        '2' => {
            update_time = 4_000_00;
        },
        '3' => {
            update_time = 4_000_000;
        },
        '4' => {
            update_time = 4_000_000_0;
        },
        '5' => {
            update_time = 4_000_000_00;
        },
        '6' => {
            update_time = 4_000_000_000;
        },
        '7' => {
            update_time = 4_000_000_000_0;
        },
        '8' => {
            update_time = 4_000_000_000_00;
        },
        '9' => {
            update_time = 4_000_000_000_000;
        },
        else => {},
    }
}

fn setupTty() !void {
    if (windows) {} else {
        const original_termios = try std.posix.tcgetattr(tty_nix.handle);
        var raw = original_termios;

        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.oflag.OPOST = false;
        raw.cflag.CSIZE = .CS8;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;

        try std.posix.tcsetattr(tty_nix.handle, .FLUSH, raw);
    }
}

pub fn main() !void {
    const alloc = gpa.allocator();
    try parseArgs(alloc);

    if (args.help) {
        std.debug.print(
            \\zmatrix - Matrix on the terminal
            \\
            \\Usage: zmatrix [options]
            \\
            \\    Options:
            \\        --version, -v   Print version string
            \\        --help, -h      Print this message
            \\
        , .{});
        return;
    }
    if (args.version) {
        print("{s}\n", .{zmatrix_options.version});
        return;
    }

    prng = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    rand = prng.random();

    if (!windows) {
        tty_nix = try std.fs.cwd().openFile("/dev/tty", .{});
    }
    defer {
        if (!windows) {
            tty_nix.close();
        }
    }

    try setupTty();
    const term_size = try getTerminalSize();

    buf = try alloc.alloc(u8, term_size.width * term_size.height * 4);
    stdout_writer = std.fs.File.stdout().writer(buf);

    current_size = try getTerminalSize();
    matrix = try allocateMatrix(alloc, current_size.width, current_size.height);
    prev_matrix = try allocateMatrix(alloc, current_size.width, current_size.height);

    for (matrix, prev_matrix) |*row, *prev_row| {
        row.* = try alloc.alloc(Matrix, term_size.width);
        prev_row.* = try alloc.alloc(Matrix, term_size.width);

        for (row.*, prev_row.*) |*cell, *prev_cell| {
            cell.* = .{ .is_head = false, .val = -1, .color = 0 };
            prev_cell.* = .{ .is_head = false, .val = -1, .color = 0 };
        }
    }

    try initializeColumns(alloc, current_size.width, current_size.height);

    print("{s}", .{AnsiEscapeCodes.term_on});
    defer print("{s}", .{AnsiEscapeCodes.term_off});

    const randmin = 33;
    const randnum = 90;

    var frame_buffer = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer frame_buffer.deinit(alloc);

    var count: u32 = 0;
    var use_diff_rendering = false;

    while (true) {
        const resized = try checkResize(alloc);
        if (resized) {
            use_diff_rendering = false;
        }

        count += 1;
        if (count > 4) count = 1;

        if (kbhit()) {
            const key = getch() catch continue;
            if (key == 'q' or key == 'Q') {
                break;
            }
            handle_keypress(key);
        }

        if (use_diff_rendering) {
            copyMatrix(matrix, prev_matrix);
        }

        var j: u32 = 0;
        while (j <= current_size.width - 1) : (j += 2) {
            if (count > updates[j]) continue;

            if (matrix[0][j].val == -1 and matrix[1][j].val == ' ' and spaces[j] > 0) {
                spaces[j] -= 1;
            } else if (matrix[0][j].val == -1 and matrix[1][j].val == ' ') {
                lengths[j] = rand.uintLessThan(u32, current_size.height - 3) + 3;
                matrix[0][j].val = @intCast(rand.uintLessThan(u32, randnum) + randmin);
                spaces[j] = rand.uintLessThan(u32, current_size.height) + 1;
            }

            var i: u32 = 0;
            var y: u32 = 0;
            var z: u32 = 0;
            var firstcoldone: bool = false;

            while (i <= current_size.height) {
                while (i <= current_size.height and (matrix[i][j].val == ' ' or matrix[i][j].val == -1)) {
                    i += 1;
                }
                if (i > current_size.height) break;

                z = i;
                y = 0;
                while (i <= current_size.height and (matrix[i][j].val != ' ' and matrix[i][j].val != -1)) {
                    matrix[i][j].is_head = false;
                    i += 1;
                    y += 1;
                }
                if (i > current_size.height) {
                    matrix[z][j].val = ' ';
                    continue;
                }

                matrix[i][j].val = @intCast(rand.uintLessThan(u32, randnum) + randmin);
                matrix[i][j].is_head = true;

                if (y > lengths[j] or firstcoldone) {
                    matrix[z][j].val = ' ';
                    matrix[0][j].val = -1;
                }
                firstcoldone = true;
                i += 1;
            }
        }

        if (use_diff_rendering) {
            try renderFrameDiff(alloc, current_size, &frame_buffer);
        } else {
            try renderFrame(alloc, current_size, &frame_buffer);
            print("{s}", .{AnsiEscapeCodes.cursor_home});
            use_diff_rendering = true;
        }

        _ = try stdout_writer.interface.write(frame_buffer.items);
        try stdout_writer.interface.flush();

        std.Thread.sleep(update_time);
    }
}
