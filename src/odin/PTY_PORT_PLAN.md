# PTY Port Plan — `os/pty_proc_unix.c` → `pty_proc.odin`

> Verified working notes for the Step-1 port. Source: `src/nvim/os/pty_proc_unix.c` (464 lines, Linux-only).
> Goal: replace the C file (move to `bak/`), give `pty_proc_teardown` a real body, and unblock
> the `proc.odin:106` `status = -1` PTY stub. Enables `:terminal` / `jobstart({pty:true})`.

## ABI facts (verified on this system, Linux x86_64)
- `struct winsize` = 8 bytes (`uint16 ws_row, ws_col, ws_xpixel, ws_ypixel`).
- `struct termios` = 60 bytes. **`core:sys/posix.termios` is NOT usable** — it is a `#sparse [Control_Char]cc_t`
  keyed map, not a flat `cc_t c_cc[NCCS]` array (`NCCS = 32` on Linux). Must mirror `termios` as a raw
  byte struct:
  ```
  Termios :: struct {
    c_iflag:  c.uint,   // tcflag_t (4)
    c_oflag:  c.uint,
    c_cflag:  c.uint,
    c_lflag:  c.uint,
    c_line:   c.uchar,  // cc_t (line discipline) — present on Linux glibc
    c_cc:     [32]c.uchar,
    _pad:     [4]c.uchar,   // 60 - (4*4 + 1 + 32) = 60-49 = 11? recompute below
  }
  ```
  **RECOMPUTED LAYOUT (must verify with a tiny C `offsetof` probe before trusting):**
  glibc `struct termios` order: `c_iflag, c_oflag, c_cflag, c_lflag, c_line, c_cc[NCCS]`.
  Sizes: 4+4+4+4+1+32 = 49 → pad to 60 ⇒ `_pad: [11]u8`. ALWAYS confirm via:
  ```c
  printf("termios=%zu iflag=%zu c_line=%zu c_cc=%zu\n",
         sizeof(struct termios), offsetof(struct termios,c_iflag),
         offsetof(struct termios,c_line), offsetof(struct termios,c_cc));
  ```
- `PtyProc` (pty_proc_unix.h): `{ Proc proc; uint16 width,height; winsize winsize; int tty_fd }`.
  Mirror exactly — `Proc` is already in `event_defs.odin`. Add `PtyProc` there or in `pty_proc.odin`.
- `libuv`: `uv_signal_start(&loop->children_watcher, chld_handler, SIGCHLD)`, `uv_signal_stop`,
  `uv_disable_stdio_inheritance()`, `uv_pipe_open(pipe, fd)`, `uv_chdir` (all FFI via uv_defs.odin).

## Signal constants (BROKEN in `posix.signal_libc` — are -1)
Use literal Linux x86_64 values:
- SIGHUP=1, SIGINT=2, SIGQUIT=3, SIGILL=4, SIGABRT=6, SIGKILL=9, SIGALRM=14,
  SIGTERM=15, SIGCHLD=17, SIGCONT=18, SIGSTOP=19, SIGTSTP=20, SIGWINCH=28.
- `SIG_DFL` = 0, `SIG_IGN` = 1 (cast to the handler proc type).

## Task checklist

### T1 — Struct mirrors (in `event_defs.odin` or `pty_proc.odin`)
- [ ] Add `Termios` raw byte struct (verify size/offset with C probe — see above).
- [ ] Add `Winsize :: struct { ws_row, ws_col, ws_xpixel, ws_ypixel: c.ushort }` (8 bytes).
- [ ] Add `PtyProc :: struct { proc: Proc, width, height: c.ushort, winsize: Winsize, tty_fd: c.int }`.
- [ ] Define `SIGCHLD`/etc literal constants (or a small `pty_sig` block).

### T2 — `vim_openpty` + `vim_forkpty` (Odin replacement for missing `forkpty`)
- [ ] `vim_openpty(master, slave, name, termp, winp)`:
  `master = linux.open("/dev/ptmx", O_RDWR)`; `posix.grantpt(master)`; `posix.unlockpt(master)`;
  `slave_name = posix.ptsname(master)`; `slave = linux.open(slave_name, O_RDWR|O_NOCTTY)`;
  if `termp != nil` → `termios_set(tm, TCSAFLUSH, termp)` via ioctl `TCSETS` (0x5402);
  if `winp != nil` → `linux.ioctl(slave, TIOCSWINSZ, uintptr(winp))`. On error close both, return -1.
  (Linux skips the `I_PUSH` stropts steps — those are Solaris only.)
- [ ] `vim_forkpty(master, name, termp, winp)`:
  `vim_openpty(...)`; `pid = posix.fork()`; child: `close(master)`, `vim_login_tty(slave)`, return 0;
  parent: `close(slave)`, `*master = master`, return pid.
- [ ] `vim_login_tty(fd)`: `posix.setsid()`; `linux.ioctl(fd, TIOCSCTTY, 0)`; `posix.dup2(fd, 0/1/2)`;
  if `fd > 2` close(fd). (matches C `vim_login_tty`.)

### T3 — `init_termios` (build the default termios)
- [ ] Replicate `init_termios` field-by-field into the `Termios` mirror.
  Use raw flag constants from `<termios.h>` (ICRNL=0x100, IXON=0x400, OPOST=0x1, ONLCR=0x2,
  CS8=0x30, CREAD=0x80, ISIG=0x80, ICANON=0x2, IEXTEN=0x8000, ECHO=0x8, ECHOE=0x10, ECHOK=0x20,
  IUTF8=0x4000, ECHOCTL=0x200, ECHOKE=0x800, plus cfsetispeed/cfsetospeed B38400=0x1001 via
  `cfsetispeed`/`cfsetospeed` FFI or by writing the speed into `c_cflag` — simpler to FFI them).
  Set `c_cc[]` array entries with `_POSIX_VDISABLE` (0) and the `0x1f & 'X'` literals.
  **Easiest correct path**: FFI the C `cfsetispeed`/`cfsetospeed`? They are NOT in posix.termios cleanly —
  instead set `c_cflag` speed bits manually (B38400 = 0x1001) OR keep a thin C helper. Document choice.

### T4 — `init_child` (fork-safety critical)
- [ ] Run ONLY async-signal-safe POSIX: `posix.setsid()`, `posix.signal(SIG*, SIG_DFL)` for
  SIGCHLD/SIGHUP/SIGINT/SIGQUIT/SIGTERM/SIGALRM, `uv_chdir(proc->cwd)` (FFI, returns uv error),
  `environ = tv_dict_to_env(proc->env)` (FFI — MUST be called pre-fork or is unsafe; see T7),
  `posix.execvp(prog, proc->argv)`, then `_exit(122)` on failure.
- [ ] `prog = proc_get_exepath(proc)` — FFI the C `proc_get_exepath`.

### T5 — `pty_proc_spawn` (the real body; replaces `proc.odin:106` stub)
- [ ] Lazily init `termios_default` (module-level `Termios` global, set via `init_termios` when `c_cflag==0`).
- [ ] `uv_signal_start(&proc->loop->children_watcher, chld_handler, SIGCHLD)` (FFI).
- [ ] `ptyproc->winsize = {height, width, 0, 0}`; `uv_disable_stdio_inheritance()` (FFI).
- [ ] `pid = vim_forkpty(&master, nil, &termios_default, &ptyproc->winsize)`; on `<0` return `-errno`.
  Child calls `init_child` (never returns).
- [ ] Make master non-blocking: `fcntl(master, F_GETFL)` / `fcntl(master, F_SETFL, flags|O_NONBLOCK)`
  (posix.fcntl), `os_set_cloexec(master)` (FFI to `os_fs.odin`).
- [ ] Wire master into `proc->in.uv.pipe` / `proc->out.s.uv.pipe` via `set_duplicating_descriptor`
  (dup + cloexec + `uv_pipe_open`) — only if not closed.
- [ ] `ptyproc->tty_fd = master`; `proc->pid = pid`; return 0. On error: close(master), kill(pid,SIGKILL),
  waitpid(pid,nil,0).

### T6 — remaining exported procs
- [ ] `pty_proc_tty_name` → `posix.ptsname(ptyproc->tty_fd)`.
- [ ] `pty_proc_resize` → set winsize, `linux.ioctl(tty_fd, TIOCSWINSZ, &winsize)`.
- [ ] `pty_proc_resume` → `posix.killpg(proc->pid, SIGCONT)` (FFI `posix.killpg` if present else syscall).
- [ ] `pty_proc_flush_master` → Linux-only `poll()` loop (posix.poll) on `POLLIN`, retry on EINTR.
- [ ] `pty_proc_close` → `pty_proc_close_master` + `proc->internal_close_cb(proc)`.
- [ ] `pty_proc_close_master` → close tty_fd if >=0, set -1.
- [ ] `pty_proc_teardown` → real body: `uv_signal_stop(&loop->children_watcher)` (REPLACES the
  `foreign _` `---` decl at `proc.odin:13`).

### T7 — fork-safety: child env
- [ ] `init_child` calls `tv_dict_to_env(proc->env)` which allocates. To stay async-signal-safe,
  build the env array BEFORE `fork()` (call `tv_dict_to_env` in `pty_proc_spawn`, store `^^u8` in
  PtyProc or a local, and have `init_child` read the pre-built array and assign to `environ`).
  Alternatively FFI a minimal C helper `pty_build_env(Dict *env) -> char**`. Prefer pre-fork build.

### T8 — `chld_handler` (SIGCHLD reaper, wires to `loop->children`)
- [ ] Mirror exactly: read `loop = handle->loop->data`; iterate `kv_children_size(loop)` →
  `proc = kv_A(loop->children, i)`; `waitpid(pid, &stat, WNOHANG|WUNTRACED|WCONTINUED)` (posix.waitpid);
  dispatch WIFSTOPPED→`state_cb(proc,true,data)`, WIFCONTINUED→`state_cb(proc,false,data)`,
  WIFEXITED→`proc->status = WEXITSTATUS(stat)`, WIFSIGNALED→`proc->status = 128+WTERMSIG(stat)`,
  then `proc->internal_exit_cb(proc)`. Call as Odin-calling-convention callback from `uv_signal_start`.

### T9 — wire into `proc.odin`
- [ ] Replace `proc.odin:106-107` stub:
  ```
  } else {
    status = pty_proc_spawn((^PtyProc)(pr))
  }
  ```
- [ ] Remove the `foreign _` `pty_proc_teardown` decl at `proc.odin:13` (now a real `@(export)` in
  `pty_proc.odin`). Keep `shell_free_argv` decl (still C until shell.odin lands).
- [ ] `pty_proc_init` — add an Odin `@(export)` matching C `pty_proc_init(loop, data)`:
  `rv = {0}; rv.proc = proc_init(loop, kProcTypePty, data); rv.width=80; rv.height=24; rv.tty_fd=-1`.

### T10 — move C file + rebuild + gate
- [ ] Move `src/nvim/os/pty_proc_unix.c` → `bak/os/pty_proc_unix.c` (CMake globs `os/*.c`).
- [ ] `cmake --build build --target libnvim` (rebuild static lib without the pty C file).
- [ ] Relink Odin via `build.sh` (or the odin build command).
- [ ] Gate (all exit 0): `./build/bin/nvim_odin --version`;
  `VIMRUNTIME=runtime ./build/bin/nvim_odin -u NONE -c qa!`;
  `VIMRUNTIME=runtime ./build/bin/nvim_odin -es -c 'qa!'`.
- [ ] Functional: `:terminal` opens a shell and is interactive; `jobstart(['cat'], {'pty':v:true})`
  returns a jobid and streams I/O; `:qa!` tears the pty down cleanly (no SIGSEGV/SIGABRT).

## Reusable Odin already present
- `rstream_init_fd/start/stop/may_close`, `stream_init` (stream.odin/rstream.odin).
- `uv_signal_start/stop`, `uv_pipe_open`, `uv_disable_stdio_inheritance`, `uv_chdir` (FFI in uv_defs.odin / loop.odin).
- `proc_init`, `Kvec_Proc_ptr` + `kv_children_size`/`kv_A` (event_defs.odin / proc.odin).
- `xmalloc`/`xfree`, `os_set_cloexec`/`os_fopen` (memory.odin / os_fs.odin).
- `posix.fork/execvp/setsid/dup/fcntl/poll/waitpid/signal/grantpt/unlockpt/ptsname`.
- `linux.open/ioctl` (raw syscalls — avoids posix.open name conflict).

## Riskiest parts (verify first)
1. `Termios` raw mirror size/offset (T1) — mismatch silently corrupts the slave terminal.
2. `forkpty` reimplementation correctness (T2) — if broken, `:terminal` won't spawn.
3. `chld_handler` reaping + `loop->children` kvec access (T8) — wrong index → SIGSEGV at child exit.
4. `init_child` async-signal-safety (T4/T7) — calling allocator/FFI-after-fork may deadlock/crash.
