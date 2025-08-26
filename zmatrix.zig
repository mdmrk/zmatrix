const std = @import("std");
const print = std.debug.print;
const builtin = @import("builtin");

const windows = builtin.os.tag == .windows;
const linux = !windows;

var prng: std.Random.DefaultPrng = undefined;
var rand: std.Random = undefined;

var stdout: std.fs.File.Writer = undefined;
var g_tty_win: std.os.windows.HANDLE = undefined;

var matrix: [][]Matrix = undefined;
var spaces: []usize = undefined;
var lengths: []usize = undefined;
var updates: []usize = undefined;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

const Matrix = struct {
    val: i32,
    is_head: bool,
};

const AnsiEscapeCodes = struct {
    const esc = "\x1B";
    const csi = esc ++ "[";

    const cursor_show = csi ++ "?25h";
    const cursor_hide = csi ++ "?25l";
    const cursor_home = csi ++ "1;1H";

    const color_fg = "38;5;";
    const color_bg = "48;5;";
    const color_fg_def = csi ++ color_fg ++ "15m";
    const color_bg_def = csi ++ color_bg ++ "0m";
    const color_def = color_fg_def;

    const screen_clear = csi ++ "2J";
    const screen_buf_on = csi ++ "?1049h";
    const screen_buf_off = csi ++ "?1049l";
    const nl = "\n";

    const term_on = screen_buf_on ++ cursor_hide ++ cursor_home ++ screen_clear ++ color_def;
    const term_off = screen_buf_off ++ cursor_show ++ nl;
};

fn getTerminalSize() !struct { width: usize, height: usize } {
    if (windows) {
        var info: std.os.windows.CONSOLE_SCREEN_BUFFER_INFO = .{
            .dwSize = .{ .X = 0, .Y = 0 },
            .dwCursorPosition = .{ .X = 0, .Y = 0 },
            .wAttributes = 0,
            .srWindow = .{ .Left = 0, .Top = 0, .Right = 0, .Bottom = 0 },
            .dwMaximumWindowSize = .{ .X = 0, .Y = 0 },
        };

        if (std.os.windows.kernel32.GetConsoleScreenBufferInfo(g_tty_win, &info) == 0) {
            switch (std.os.windows.kernel32.GetLastError()) {
                _ => |e| return std.os.windows.unexpectedError(e),
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
            var lldb_tty_nix = try std.fs.cwd().openFile("/dev/tty", .{});
            defer lldb_tty_nix.close();

            var lldb_winsz = std.c.winsize{ .col = 0, .row = 0, .xpixel = 0, .ypixel = 0 };
            const lldb_rv = std.os.linux.ioctl(lldb_tty_nix.handle, TIOCGWINSZ, @intFromPtr(&lldb_winsz));
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

pub fn main() !void {
    prng = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    rand = prng.random();
    const alloc = gpa.allocator();

    const term_size = try getTerminalSize();

    matrix = try alloc.alloc([]Matrix, term_size.height + 1);
    for (matrix) |*row| {
        row.* = try alloc.alloc(Matrix, term_size.width);
        for (row.*) |*cell| {
            cell.* = .{ .is_head = false, .val = -1 };
        }
    }

    spaces = try alloc.alloc(usize, term_size.width);
    lengths = try alloc.alloc(usize, term_size.width);
    updates = try alloc.alloc(usize, term_size.width);

    var j: usize = 0;
    while (j <= term_size.width - 1) : (j += 1) {
        spaces[j] = rand.uintLessThan(usize, term_size.height) + 1;
        lengths[j] = rand.uintLessThan(usize, term_size.height - 3) + 3;
        matrix[1][j].val = ' ';
        updates[j] = rand.uintLessThan(usize, 3) + 1;
    }

    const randmin = 33;
    const randnum = 90;

    var count: usize = 0;
    while (true) {
        count += 1;
        if (count > 4) count = 1;

        j = 0;
        while (j <= term_size.width - 1) : (j += 2) {
            if (count > updates[j]) continue;

            if (matrix[0][j].val == -1 and matrix[1][j].val == ' ' and spaces[j] > 0) {
                spaces[j] -= 1;
            } else if (matrix[0][j].val == -1 and matrix[1][j].val == ' ') {
                lengths[j] = rand.uintLessThan(usize, term_size.height - 3) + 3;
                matrix[0][j].val = @intCast(rand.uintLessThan(u32, randnum) + randmin);
                spaces[j] = rand.uintLessThan(usize, term_size.height) + 1;
            }

            var i: usize = 0;
            var y: usize = 0;
            var z: usize = 0;
            var firstcoldone: bool = false;

            while (i <= term_size.height) {
                while (i <= term_size.height and (matrix[i][j].val == ' ' or matrix[i][j].val == -1)) {
                    i += 1;
                }
                if (i > term_size.height) break;

                z = i;
                y = 0;
                while (i <= term_size.height and (matrix[i][j].val != ' ' and matrix[i][j].val != -1)) {
                    matrix[i][j].is_head = false;
                    i += 1;
                    y += 1;
                }
                if (i > term_size.height) {
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

        print("{s}", .{AnsiEscapeCodes.term_on});
        defer print("{s}", .{AnsiEscapeCodes.term_off});
        for (1..term_size.height + 1) |i| {
            j = 0;
            while (j <= term_size.width - 1) : (j += 1) {
                if (matrix[i][j].val == -1) {
                    print(" ", .{});
                } else {
                    print("{c}", .{@as(u8, @intCast(matrix[i][j].val))});
                }
            }
            print("\n", .{});
        }

        std.Thread.sleep(40_000_000);
    }
}
