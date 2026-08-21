// PTY process backend (port of src/nvim/os/pty_proc_unix.c, Linux).
// Backed by libuv FFI (-luv) + core:sys/posix + core:sys/linux syscalls.
// NOTE: fork-safety — init_child runs only async-signal-safe POSIX calls; the child
// env array is built BEFORE fork() (see pty_proc_spawn) and stashed in child_environ.

package main

import "core:sys/posix"
import "core:sys/linux"
import "core:c"
import "base:runtime"

foreign _ {
	uv_disable_stdio_inheritance :: proc() ---
}

// Module-level default termios, lazily initialized (mirrors C static termios_default).
termios_default: Termios
// Child env array built pre-fork, applied in init_child.
child_environ: ^^u8

init_termios :: proc(t: ^Termios) {
	t.c_iflag = c.uint(0x100 | 0x400)                      // ICRNL | IXON
	t.c_oflag = c.uint(0x1 | 0x2)                          // OPOST | ONLCR
	t.c_cflag = c.uint(0x30 | 0x80)                        // CS8 | CREAD
	t.c_lflag = c.uint(0x80 | 0x2 | 0x8000 | 0x8 | 0x10 | 0x20)  // ISIG|ICANON|IEXTEN|ECHO|ECHOE|ECHOK
	t.c_line = 0
	t.c_cflag |= c.uint(0x9600)                            // B38400 speed bits
	t.c_iflag |= c.uint(0x4000)                            // IUTF8
	t.c_lflag |= c.uint(0x200 | 0x800)                     // ECHOCTL | ECHOKE
	t.c_cc = {}
	t.c_cc[0]  = 0x1f & 'C'  // VINTR
	t.c_cc[1]  = 0x1f & '\\' // VQUIT
	t.c_cc[2]  = 0x7f        // VERASE
	t.c_cc[3]  = 0x1f & 'U'  // VKILL
	t.c_cc[4]  = 0x1f & 'D'  // VEOF
	t.c_cc[11] = 0           // VEOL (_POSIX_VDISABLE)
	t.c_cc[16] = 0           // VEOL2
	t.c_cc[8]  = 0x1f & 'Q'  // VSTART
	t.c_cc[9]  = 0x1f & 'S'  // VSTOP
	t.c_cc[10] = 0x1f & 'Z'  // VSUSP
	t.c_cc[12] = 0x1f & 'R'  // VREPRINT
	t.c_cc[14] = 0x1f & 'W'  // VWERASE
	t.c_cc[15] = 0x1f & 'V'  // VLNEXT
	t.c_cc[6]  = 1           // VMIN
	t.c_cc[5]  = 0           // VTIME
}

vim_openpty :: proc(amaster: ^posix.FD, aslave: ^posix.FD, name: ^c.uchar, termp: ^Termios, winp: ^Winsize) -> c.int {
	master := posix.open(cstring("/dev/ptmx"), posix.O_Flags{.RDWR}, posix.mode_t{})
	if master < 0 {
		return -1
	}
	if posix.grantpt(master) == .FAIL {
		linux.close(linux.Fd(master))
		return -1
	}
	if posix.unlockpt(master) == .FAIL {
		linux.close(linux.Fd(master))
		return -1
	}
	slave_name := posix.ptsname(master)
	if slave_name == nil {
		linux.close(linux.Fd(master))
		return -1
	}
	slave := posix.open(slave_name, posix.O_Flags{.RDWR, .NOCTTY}, posix.mode_t{})
	if slave < 0 {
		linux.close(linux.Fd(master))
		return -1
	}
	if termp != nil {
		linux.ioctl(linux.Fd(slave), c.uint(TCSETS), uintptr(rawptr(termp)))
	}
	if winp != nil {
		linux.ioctl(linux.Fd(slave), c.uint(TIOCSWINSZ), uintptr(rawptr(winp)))
	}
	amaster^ = master
	aslave^ = slave
	return 0
}

vim_login_tty :: proc(fd: posix.FD) -> c.int {
	posix.setsid()
	if linux.ioctl(linux.Fd(fd), c.uint(TIOCSCTTY), 0) != 0 {
		return -1
	}
	posix.dup2(fd, posix.STDIN_FILENO)
	posix.dup2(fd, posix.STDOUT_FILENO)
	posix.dup2(fd, posix.STDERR_FILENO)
	if fd > 2 {
		linux.close(linux.Fd(fd))
	}
	return 0
}

vim_forkpty :: proc(amaster: ^posix.FD, name: ^c.uchar, termp: ^Termios, winp: ^Winsize) -> c.int {
	master, slave: posix.FD
	if vim_openpty(&master, &slave, name, termp, winp) == -1 {
		return -1
	}
	pid := posix.fork()
	if pid == -1 {
		linux.close(linux.Fd(master))
		linux.close(linux.Fd(slave))
		return -1
	} else if pid == 0 {
		linux.close(linux.Fd(master))
		vim_login_tty(slave)
		return 0
	}
	linux.close(linux.Fd(slave))
	amaster^ = master
	return c.int(pid)
}

// init_child runs in the forked child. Async-signal-safe ONLY.
init_child :: proc(ptyproc: ^PtyProc) {
	pr := &ptyproc.proc_base
	posix.setsid()
	posix.signal(posix.Signal(SIGHUP), nil)
	posix.signal(posix.Signal(SIGINT), nil)
	posix.signal(posix.Signal(SIGQUIT), nil)
	posix.signal(posix.Signal(SIGALRM), nil)
	posix.signal(posix.Signal(SIGTERM), nil)
	posix.signal(posix.Signal(SIGCHLD), nil)
	if pr.cwd != nil {
		if uv_chdir(cstring(rawptr(pr.cwd))) != 0 {
			posix._exit(122)
		}
	}
	_c_environ = (^cstring)(child_environ)
	prog := proc_get_exepath(pr)
	posix.execvp(cstring(prog), ([^]cstring)(pr.argv))
	posix._exit(122)
}

set_duplicating_descriptor :: proc(fd: posix.FD, pipe: ^uv_pipe_t) -> c.int {
	fd_dup := posix.dup(fd)
	if fd_dup < 0 {
		return -1
	}
	if os_set_cloexec(c.int(fd_dup)) == -1 {
		linux.close(linux.Fd(fd_dup))
		return -1
	}
	status := uv_pipe_open(pipe, uv_file(fd_dup))
	if status != 0 {
		linux.close(linux.Fd(fd_dup))
		return status
	}
	return 0
}

@(export) pty_proc_spawn :: proc "c" (ptyproc: ^PtyProc) -> c.int {
	context = runtime.default_context()
	if termios_default.c_cflag == 0 {
		init_termios(&termios_default)
	}

	pr := &ptyproc.proc_base
	assert(pr.err_s.s.closed)
	uv_signal_start(&pr.loop.children_watcher, rawptr(chld_handler), SIGCHLD)

	ptyproc.winsize = Winsize{ptyproc.height, ptyproc.width, 0, 0}
	uv_disable_stdio_inheritance()

	// Build child env BEFORE fork (tv_dict_to_env allocates; not fork-safe after fork).
	child_environ = nil
	if pr.env != nil {
		child_environ = tv_dict_to_env(pr.env)
	}

	master: posix.FD
	pid := vim_forkpty(&master, nil, &termios_default, &ptyproc.winsize)
	if pid < 0 {
		return -1
	} else if pid == 0 {
		init_child(ptyproc)  // never returns
	}

	master_status_flags := posix.fcntl(master, posix.FCNTL_Cmd.GETFL)
	if master_status_flags == -1 {
		return -1
	}
	if posix.fcntl(master, posix.FCNTL_Cmd.SETFL, c.int(master_status_flags) | posix.O_NONBLOCK) == -1 {
		return -1
	}
	if os_set_cloexec(c.int(master)) == -1 {
		return -1
	}

	if !pr.in_s.closed {
		if set_duplicating_descriptor(master, (^uv_pipe_t)(&pr.in_s.uv)) != 0 {
			linux.close(linux.Fd(master))
			posix.kill(posix.pid_t(pr.pid), posix.Signal(SIGKILL))
			posix.waitpid(posix.pid_t(pr.pid), nil, posix.Wait_Flags{.NOHANG})
			return -1
		}
	}
	if !pr.out_s.s.closed {
		if set_duplicating_descriptor(master, (^uv_pipe_t)(&pr.out_s.s.uv)) != 0 {
			linux.close(linux.Fd(master))
			posix.kill(posix.pid_t(pr.pid), posix.Signal(SIGKILL))
			posix.waitpid(posix.pid_t(pr.pid), nil, posix.Wait_Flags{.NOHANG})
			return -1
		}
	}

	ptyproc.tty_fd = c.int(master)
	pr.pid = pid
	return 0
}

@(export) pty_proc_tty_name :: proc "c"(ptyproc: ^PtyProc) -> cstring {
	return posix.ptsname(posix.FD(ptyproc.tty_fd))
}

@(export) pty_proc_resize :: proc "c"(ptyproc: ^PtyProc, width: c.ushort, height: c.ushort) {
	ptyproc.winsize = Winsize{height, width, 0, 0}
	linux.ioctl(linux.Fd(ptyproc.tty_fd), c.uint(TIOCSWINSZ), uintptr(rawptr(&ptyproc.winsize)))
}

@(export) pty_proc_resume :: proc "c"(ptyproc: ^PtyProc) {
	pr := &ptyproc.proc_base
	posix.killpg(posix.pid_t(pr.pid), posix.Signal(SIGCONT))
}

@(export) pty_proc_flush_master :: proc "c"(ptyproc: ^PtyProc) {
	pollfd := posix.pollfd{posix.FD(ptyproc.tty_fd), posix.Poll_Event{.IN}, posix.Poll_Event{}}
	for {
		n := posix.poll(&pollfd, 1, 0)
		if n >= 0 {
			break
		}
		if posix.get_errno() != posix.Errno.EINTR {
			break
		}
	}
}

@(export) pty_proc_close :: proc "c"(ptyproc: ^PtyProc) {
	pty_proc_close_master(ptyproc)
	context = runtime.default_context()
	pr := &ptyproc.proc_base
	if pr.internal_close_cb != nil {
		pr.internal_close_cb(pr)
	}
}

@(export) pty_proc_close_master :: proc "c"(ptyproc: ^PtyProc) {
	if ptyproc.tty_fd >= 0 {
		linux.close(linux.Fd(ptyproc.tty_fd))
		ptyproc.tty_fd = -1
	}
}

@(export) pty_proc_teardown :: proc "c"(loop: ^Loop) {
	uv_signal_stop(&loop.children_watcher)
}

chld_handler :: proc "c" (handle: ^uv_signal_t, signum: c.int) {
	context = runtime.default_context()
	loop := (^Loop)(handle.loop.data)
	for i := c.size_t(0); i < kv_children_size(loop); i += 1 {
		pr := kv_children_at(loop, i)
		stat_loc: c.int
		pid: posix.pid_t
		for {
			pid = posix.waitpid(posix.pid_t(pr.pid), &stat_loc, posix.Wait_Flags{.NOHANG, .UNTRACED, .CONTINUED})
			if !(c.int(pid) < 0 && posix.errno() == posix.Errno.EINTR) {
				break
			}
		}
		if c.int(pid) <= 0 {
			continue
		}
		if posix.WIFSTOPPED(stat_loc) {
			pr.state_cb(pr, true, pr.data)
			continue
		}
		if posix.WIFCONTINUED(stat_loc) {
			pr.state_cb(pr, false, pr.data)
			continue
		}
		if posix.WIFEXITED(stat_loc) {
			pr.status = posix.WEXITSTATUS(stat_loc)
		} else if posix.WIFSIGNALED(stat_loc) {
			pr.status = 128 + c.int(posix.WTERMSIG(stat_loc))
		}
		pr.internal_exit_cb(pr)
	}
}

@(export) pty_proc_init :: proc "c" (loop: ^Loop, data: rawptr) -> PtyProc {
	context = runtime.default_context()
	rv: PtyProc
	rv.proc_base = proc_init(loop, ProcType.Pty, data)
	rv.width = 80
	rv.height = 24
	rv.tty_fd = -1
	return rv
}
