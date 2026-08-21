# Phase 0 Findings

Build process, linker quirks, and Odin gotchas discovered during Phase 0.

---

## Build & Link

### CMake — `libnvim` target

- Target is `EXCLUDE_FROM_ALL` — must build explicitly:
  ```bash
  cmake --build build --target libnvim
  ```
- Defines `MAKE_LIB` which renames `main()` → `nvim_main()`
- Output: `build/lib/libnvim.a`
- Automatically builds dependencies (libuv, LuaJIT, luv, lpeg, tree-sitter, etc.) and generated headers

### Linker libraries needed

From the CMake nvim_bin link command (build/build.ninja:2936) and `ldd`:

| Library | Link flag | Notes |
|---|---|---|
| libnvim.a | `-lnvim` with `-Lbuild/lib` | Static lib of all C code |
| libuv | `-luv` | Event loop |
| LuaJIT | `-lluajit-5.1` | Lua runtime |
| luv | `-lluv` | Lua libuv bindings |
| tree-sitter | `-ltree-sitter` | Incremental parsing |
| utf8proc | `-lutf8proc` | UTF-8 processing |
| unibilium | `-lunibilium` | Terminfo |
| lpeg | full path to `.so` | Lua pattern matching — **not `-llpeg`** (file is `lpeg.so`, not `liblpeg.so`) |
| libm | `-lm` | Math |
| libnsl | `-lnsl` | Network services |
| libtirpc | `-ltirpc` | RPC |
| libdl | `-ldl` | Dynamic loading |
| pthread | `-lpthread` | Threading |

LPEG must be linked by full path, not `-l` flag:
```bash
/usr/lib/lua/5.1/lpeg.so          # correct
-llpeg                             # wrong — file is named lpeg.so not liblpeg.so
```

### `-rdynamic` required for LuaJIT FFI

LuaJIT FFI accesses C global variables (`textlock`, `cmdpreview`, etc.) via `ffi.C`. These symbols must be in the **dynamic symbol table** of the executable. The C build passes `-rdynamic -Wl,--export-dynamic` to achieve this.

The Odin build must pass `-rdynamic` via `-extra-linker-flags`:

```bash
-extra-linker-flags:"-rdynamic \
    -L$ROOT/build/lib \
    ..."
```

Without this, plugins like noice.nvim that use `ffi.cdef("extern int textlock;"); ffi.C.textlock` will fail with:

```
undefined symbol: textlock
```

This manifests as broken floating window positioning, cmdline issues, and other erratic GUI behavior.

### Link order matters

System libraries must come after `libnvim.a` to resolve symbols. The current order works:

```
libnvim.a → lpeg.so → libuv → luajit → luv → tree-sitter → utf8proc → unibilium → m → nsl → tirpc → dl → pthread
```

---

## Odin-Specific Gotchas

### `foreign import` path resolution

Paths in `foreign import "..."` are **relative to the `.odin` source file's directory**, not the working directory.

```odin
// In src/odin/main.odin:
foreign import nvim "../../build/lib/libnvim.a"   // correct
foreign import nvim "build/lib/libnvim.a"          // wrong — looks in src/odin/build/
```

Use relative paths from the odin file to the `.a` file.

### `cstring` conversion

Cannot cast a runtime `string` to `cstring` directly:
```odin
// Does NOT compile:
c_args[i] = cstring(a)   // Error: Cannot cast 'a' as 'cstring' from 'string'

// Correct:
c_args[i] = strings.clone_to_cstring(a)  // allocates null-terminated copy
```

`strings.clone_to_cstring()` allocates — but since `nvim_main` never returns (it enters `normal_enter()`) these allocations are not freed. Acceptable since the process exits.

### `delete` on `[^]cstring`

The built-in `delete` procedures don't support `[^]T` (untyped pointer to C array):
```odin
c_args := make([^]cstring, len(args))
defer delete(c_args)   // Error: no matching overload for [^]cstring

// Fix: just don't delete — nvim_main never returns anyway
// Or use delete with explicit allocator:
delete(c_args, context.allocator)
```

### No `main()` return needed

Odin's `main :: proc()` returns void. The C `nvim_main()` returns `int` but never actually returns (it calls `normal_enter()` which is an infinite loop). If `nvim_main` somehow returned, the return value would be lost.

### Tracking allocator — `defer` never runs, `atexit` required

Using `context.allocator = mem.tracking_allocator(...)` with `defer` to print leaks **does not work** because:
1. `normal_enter(false)` never returns — it's an infinite input dispatch loop
2. C's `os_exit()` → `exit()` terminates the process immediately — Odin's `defer` blocks in `main()` never execute

**Fix**: Use C's `atexit()` to register a callback that prints leaks before termination.
No `when ODIN_DEBUG` guard — tracking runs unconditionally in debug builds.

```odin
_memory: Memory   // package-level — atexit callback needs access

main :: proc() {
    mem.tracking_allocator_init(&_memory.track, context.allocator)
    context.allocator = mem.tracking_allocator(&_memory.track)
    virtual.arena_init_growing(&_memory.arena)

    atexit(proc "c" () {
        context = runtime.default_context()
        // print allocation_map / bad_free_array
        mem.tracking_allocator_destroy(&_memory.track)
        virtual.arena_destroy(&_memory.arena)
    })

    // Intentional permanent allocations (c_args, etc.) use arena allocator
    // so they don't appear as tracked leaks:
    allocator := virtual.arena_allocator(&_memory.arena)
    c_args := make([^]cstring, len(args), allocator)
    c_args[i] = strings.clone_to_cstring(a, allocator)
}
```

Key details:
- `atexit` is from libc — declared as `foreign _ { atexit :: proc(fn: proc "c" ()) -> c.int --- }`
- `atexit` callback is `proc "c"` — no implicit `context`, must set `context = runtime.default_context()`
- `Memory` struct holds both a `virtual.Arena` and `mem.Tracking_Allocator`
- `_memory` must be package-level (not a local in `main()`) so the `atexit` closure can reference it
- C's `exit()` always runs `atexit` handlers, regardless of which code path triggers the exit
- `os_exit` is declared directly in `foreign nvim` (not an Odin wrapper) — no name collision because C's `os_exit` is the only symbol
- Intentional permanent allocations (e.g., `c_args` for `argv`) use the arena allocator to avoid polluting the leak report
- The atexit callback only prints and cleans up — it does **not** call `os_exit` / `exit()` itself

---

## Symbol Visibility

As of Phase 0, ALL functions called directly from `main()` are exported from `libnvim.a`:

### Un-static'd from main.c (previously static, now exported)

| Symbol | Purpose |
|---|---|
| `early_init` | Early initialization (estack, eval, path, highlight, locale, home, options) |
| `command_line_scan` | Parse CLI arguments |
| `init_params` | Copy argc/argv into mparm_T struct |
| `init_startuptime` | Record startup wall-clock time |
| `check_and_set_isatty` | Check stdin/stdout/stderr isatty |
| `set_argf_var` | Set v:argv variable |
| `create_windows` | Create requested number of windows |
| `edit_buffers` | Start editing files in additional windows |
| `exe_pre_commands` | Execute --cmd arguments |
| `exe_commands` | Execute +, -c, -S arguments |
| `source_startup_scripts` | Source init.lua / init.vim |
| `remote_request` | Handle --remote-* arguments |
| `edit_stdin` | Check if stdin should be edited |
| `get_fname` | Get filename from arglist |
| `set_window_layout` | Decide window layout for diff mode |
| `handle_quickfix` | Load error file (-q) |
| `handle_tag` | Jump to tag (-t) |
| `read_stdin` | Read text from stdin |

### C wrapper functions added for Odin (struct-heavy inline logic)

| Symbol | Purpose |
|---|---|
| `startup_gargcount` | Returns `GARGCOUNT` macro value |
| `startup_set_cursor_last_line` | Sets `curwin->w_cursor.lnum = curbuf->b_ml.ml_line_count` |
| `startup_save_firstwin_height` | Sets `firstwin->w_prev_height = firstwin->w_height` |
| `startup_diff_win_options_all` | Applies diff options to all windows via `FOR_ALL_WINDOWS_IN_TAB` |
| `startup_recovery_list_swaps` | Recovery mode: lists swap files and exits |
| `startup_channel_from_stdio` | Opens stdin/stdout as msgpack-rpc channel |
| `startup_shada_nonempty` | Returns non-zero if `*p_shada != NUL` |

### Already exported (from other .c files)

`appname_is_valid`, `event_init`, `set_argv_var`, `nlua_init`, `nlua_init_defaults`, `server_init`, `normal_enter`, `os_exit`, `getout`, `win_init_size`, `default_grid_alloc`, `set_init_2`, `set_init_3`, `init_highlight`, `screenclear`, `win_new_screensize`, `load_plugins`, `shada_read_everything`, `ui_client_start_server`, `ui_client_run`, `ui_comp_syn_init`, `diff_win_options`, `open_scriptin`, `os_fopen`, `filetype_plugin_enable`, `filetype_maybe_enable`, `syn_maybe_enable`, `set_vim_var_nr`, `set_vim_var_string`, `get_vim_var_list`, `set_vim_var_list`, `tv_list_alloc`, `apply_autocmds`, `setmouse`, `redraw_later`, `setpcmark`, `qf_jump`, `shorten_fnames`, `input_start`, `remote_ui_wait_for_attach`, `channel_from_stdio`, `recover_names`, `tv_clear`, `tv_list_alloc_ret`

---

## Testing

The binary needs `VIMRUNTIME` set to the project's runtime directory when run from the build tree:

```bash
VIMRUNTIME=runtime ./build/bin/nvim_odin --clean -c "echo test" -c "q"
```

**All plugins work** with `VIMRUNTIME=runtime` (no `--clean` flag needed):
```bash
VIMRUNTIME=runtime ./build/bin/nvim_odin
```

This includes lazy.nvim, LSP, treesitter, and all user config — both `nvim` and `nvim_odin` produce identical behavior.

**Why this works:** `VIMRUNTIME` tells Neovim where to find runtime files (Lua modules, syntax files, colorschemes, etc.). Without it, the binary searches system install paths (`/usr/local/share/nvim/`) which are stale or missing for this dev build.

**Without `VIMRUNTIME`:** The `vim/uri.lua` module (and others) can't be found because they live in `runtime/lua/vim/uri.lua` inside the project tree, not in the installed system path. The `E5113: module 'vim.uri' not found` error appears. User configs that depend on these modules (e.g., lazy.nvim) fail.

Basic smoke tests that pass:
```bash
./build/bin/nvim_odin --version
VIMRUNTIME=runtime ./build/bin/nvim_odin --clean --headless -c "echo ok" -c "q"
VIMRUNTIME=runtime ./build/bin/nvim_odin --clean --headless -c "checkhealth" -c "q"
```

### Memory Model Override (`#pragma weak`)

The memory model (`xmalloc`, `xfree`, `xcalloc`, `xrealloc`, `try_malloc`, `verbose_try_malloc`) is overridden from Odin using weak symbols:

**C side** (`memory.c`):
```c
#pragma weak xmalloc
#pragma weak xfree
#pragma weak xcalloc
#pragma weak xrealloc
#pragma weak try_malloc
#pragma weak verbose_try_malloc
```

`#pragma weak` is a **preprocessor directive** — the LPEG grammar in `gen_declarations.lua` parses it as a `preproc` node and skips it, seeing clean function definitions. The alternative `__attribute__((weak))` before the return type breaks the grammar because it doesn't match any known pattern.

**Odin side** (`memory.odin`): Each function is exported with `@(export)` and the exact C calling convention. The linker resolves all calls to the strong Odin symbol.

**Link order**: Odin `.o` files are linked before `-lnvim`, so the strong Odin `xmalloc` resolves first. If the C test path (`nvim_bin`) needs Odin symbols, `--whole-archive` is used around `libklib_stripped.a`.

### Leak Tracking System

At exit, the atexit handler reports:

1. **C-side leaks**: Allocations from `xmalloc`/`xcalloc`/`xrealloc`/`try_malloc`/`verbose_try_malloc` that were never passed to `xfree`. Stored in `alloc_sizes: map[rawptr]AllocInfo` in `memory.odin`. Each entry records `{size, caller_return_address}`.

2. **Odin-side leaks**: All allocations through `context.allocator` (a `mem.Tracking_Allocator`) that remain unfreed. Dumped via `_memory.track.allocation_map` iteration. Confirmed: **0 Odin-side leaks**.

3. **Incorrect frees**: Tracked by the tracking allocator's `bad_free_array`.

**Backtrace capture**: `capture_caller()` in `memory.odin` uses `backtrace(bt, 8)` to traverse the call stack. It skips known wrapper functions (`alloc_block`, `ga_grow`, `xmallocz`, `xstrdup`, `xmemdupz`, `xstrnsave`, `xrealloc`) to reveal the actual C caller.

**Symbol resolution**: At exit, the atexit handler in `main.odin` calls `dladdr` on each stored caller address, resolving it to `function+offset`. The `Dl_info` struct is declared via FFI:
```odin
Dl_info :: struct {
  dli_fname:  cstring,
  dli_fbase:  rawptr,
  dli_sname:  cstring,
  dli_saddr:  rawptr,
}
dladdr :: proc "c" (addr: rawptr, info: ^Dl_info) -> c.int ---
```

**EXITFREE**: The build uses `-D CMAKE_C_FLAGS="-DEXITFREE"`, which enables `free_all_mem()` inside `os_exit()`. This frees almost all persistent C data before exit (previously these appeared as 8253 leaked allocations). After the fix, only pre-existing C infrastructure leaks remain (~15 small strings, ~776 B).

### I/O Primitives Override (`os/fs.c` Phase A)

Seven I/O primitives from `os/fs.c` are overridden from Odin using weak symbols:

| Function | C Signature | Odin Implementation |
|---|---|---|
| `os_open` | `(path, flags, mode) -> int` | `linux.open` syscall → `uv_translate_sys_error` |
| `os_close` | `(fd) -> int` | `linux.close` syscall |
| `os_read` | `(fd, &eof, buf, size, non_blocking) -> ptrdiff_t` | `linux.read` syscall + EAGAIN/EINTR retry loop |
| `os_readv` | `(fd, &eof, iov, iov_size, non_blocking) -> ptrdiff_t` | `posix.readv` + retry loop |
| `os_write` | `(fd, buf, size, non_blocking) -> ptrdiff_t` | `linux.write` syscall + EAGAIN/EINTR retry loop |
| `os_fsync` | `(fd) -> int` | `linux.fsync` syscall |
| `os_open_stdin_fd` | `() -> int` | `linux.dup` of stdin fd 0 |

**C side** (`os/fs.c`):
```c
#pragma weak os_open
#pragma weak os_close
#pragma weak os_open_stdin_fd
#pragma weak os_read
#pragma weak os_readv
#pragma weak os_write
#pragma weak os_fsync
```

**Odin side** (`os_fs.odin`): Each function is exported with `@(export)` and the exact C calling convention. The linker resolves all calls to the strong Odin symbol.

**ABI preservation**: Return values use negative libuv error codes (matching C convention). `uv_translate_sys_error` is called via FFI to convert POSIX errno values to libuv error codes.

**Key design decision**: Used `core:sys/linux` raw syscalls instead of FFI-declaring libc functions directly. This avoids a name collision between `@(link_name="open")` in our package and `posix.open` in `core:sys/posix` — Odin rejects duplicate foreign procedure names across packages.

#### Errno Handling

The `core:sys/linux` syscall interface returns `(result, Errno)` tuples rather than setting C's `errno`. Since C callers read `errno` via `uv_translate_sys_error`, we must bridge:

```odin
_c_open :: proc(path: cstring, flags: c.int, mode: c.int) -> c.int {
    fd, err := linux.open(path, transmute(linux.Open_Flags)flags, transmute(linux.Mode)mode)
    if err != .NONE {
        posix.set_errno(posix.Errno(err))  // bridge: linux.Errno → C errno
        return -1
    }
    return c.int(fd)
}
```

The exported `os_open` function reads `posix.errno()` (which reads C's `errno`) and passes it to `uv_translate_sys_error`.

### Filesystem Functions Override (`os/fs.c` Phase B)

All remaining filesystem functions from `os/fs.c` are overridden from Odin using weak symbols:

| Function | C Signature | Odin Implementation |
|---|---|---|
| `os_chdir` | `(path: cstring) -> int` | `posix.chdir` + `ui_call_chdir` |
| `os_dirname` | `(buf: cstring, len: size_t) -> int` | `posix.getcwd` |
| `os_mkdir` | `(path: cstring, mode: int32_t) -> int` | `posix.mkdir` |
| `os_mkdir_recurse` | `(dir, mode, failed_dir, created) -> int` | `os.make_directory_all` |
| `os_mkdtemp` | `(templ: cstring, path: cstring) -> int` | `posix.mkdtemp` |
| `os_rmdir` | `(path: cstring) -> int` | `posix.rmdir` |
| `os_remove` | `(path: cstring) -> int` | `posix.unlink` |
| `os_rename` | `(path, new_path: cstring) -> int` | libc `rename` FFI |
| `os_copy` | `(path, new_path: cstring, flags: int) -> int` | `os.copy_file` |
| `os_getperm` | `(name: cstring) -> int32_t` | `_c_stat` → extract `st_mode` |
| `os_setperm` | `(name: cstring, perm: int) -> int` | `posix.chmod` |
| `os_chown` | `(path: cstring, owner, group: int) -> int` | `posix.chown` |
| `os_fchown` | `(fd: int, owner, group: int) -> int` | `posix.fchown` |
| `os_file_settime` | `(path: cstring, atime, mtime: double) -> int` | `linux.utimensat` |
| `os_path_exists` | `(path: cstring) -> bool` | `_c_stat` check |
| `os_file_is_readable` | `(name: cstring) -> bool` | `posix.access(.R_OK)` |
| `os_file_is_writable` | `(name: cstring) -> int` | `posix.access(.W_OK)` + directory check |
| `os_isdir` | `(name: cstring) -> bool` | `_c_stat` + `S_IFDIR` check |
| `os_isrealdir` | `(name: cstring) -> bool` | `_c_lstat` + symlink bypass |
| `os_nodetype` | `(name: cstring) -> int` | `_c_stat` + mode switch |
| `os_exepath` | `(buffer: cstring, size: ^size_t) -> int` | `posix.readlink(/proc/self/exe)` |
| `os_can_exe` | `(name: cstring, abspath: ^cstring, use_path: bool) -> bool` | `_c_stat` + `posix.access(.X_OK)` + PATH walk |
| `os_realpath` | `(name: cstring, buf: cstring, len: size_t) -> cstring` | `posix.realpath` |
| `os_file_owned` | `(fname: cstring) -> bool` | `_c_stat` + `_c_getuid` |
| `os_fopen` | `(path, flags: cstring) -> rawptr` | `os_open` + `_c_fdopen` |
| `os_dup` | `(fd: int) -> int` | `linux.dup` syscall |
| `os_dup_cloexec` | `(fd: int) -> int` | `os_dup` + `os_set_cloexec` |
| `os_set_cloexec` | `(fd: int) -> int` | `posix.fcntl(.GETFD/.SETFD)` + `FD_CLOEXEC` |
| `os_file_mkdir` | `(fname: cstring, mode: int32_t) -> int` | `os.make_directory_all` on parent |
| `os_scandir` | `(dir: rawptr, path: cstring) -> bool` | `posix.opendir` + handle map |
| `os_scandir_next` | `(dir: rawptr) -> cstring` | `posix.readdir` |
| `os_closedir` | `(dir: rawptr)` | `posix.closedir` + handle map cleanup |
| `os_fileinfo*` | (6 variants) | `_c_stat`/`_c_lstat`/`_c_fstat` → `FileInfo` |
| `os_fileid*` | (3 variants) | Extract `st_ino`/`st_dev` from `FileInfo` |

**C side** (`os/fs.c`):
```c
#pragma weak os_chdir os_dirname os_mkdir os_mkdir_recurse os_mkdtemp
#pragma weak os_rmdir os_remove os_rename os_copy os_getperm os_setperm
#pragma weak os_chown os_fchown os_file_settime os_path_exists
#pragma weak os_file_is_readable os_file_is_writable os_isdir os_isrealdir
#pragma weak os_nodetype os_exepath os_can_exe os_realpath os_file_owned
#pragma weak os_fopen os_dup os_dup_cloexec os_set_cloexec os_file_mkdir
#pragma weak os_scandir os_scandir_next os_closedir
#pragma weak os_fileinfo os_fileinfo_link os_fileinfo_fd
#pragma weak os_fileinfo_id_equal os_fileinfo_id os_fileinfo_inode
#pragma weak os_fileinfo_size os_fileinfo_hardlinks os_fileinfo_blocksize
#pragma weak os_fileid os_fileid_equal
```

**Odin side** (`os_fs.odin`): All functions exported with `@(export)` and `"c"` calling convention. The linker resolves all calls to the strong Odin symbol.

**Key design decisions**:
- Used `CStat` struct (matching x86_64 Linux `struct stat` layout with `#align(8)`) instead of `posix.stat_t` which has different field ordering on Linux
- `os_mkdir_recurse` and `os_file_mkdir` use `core:os.make_directory_all` for recursive mkdir -p
- Directory iteration uses a side-table `dir_handle_map[uintptr]rawptr` mapping C `Directory*` pointers to `posix.DIR` handles
- `os_realpath` delegates to `posix.realpath` (libc `realpath`), freeing via `posix.free`
- `os_can_exe` implements the full PATH walk in Odin — stat + access(X_OK) + path splitting
- `os_fopen` reimplements fopen mode string parsing in Odin, then calls `os_open` + `_c_fdopen`
- `os_file_settime` uses `linux.Time_Spec` (not `linux.Timespec`) with `linux.utimensat`
- `posix.chmod`/`posix.mkdir` use `transmute(posix.mode_t)u32(mode)` (mode_t is 4 bytes on Linux)
- All error handlers exhaustively match `os.Error` union variants: `os.Platform_Error`, `os.General_Error`, `io.Error`, `runtime.Allocator_Error`

**Files overridden**: All 45+ symbols from `os/fs.c` Phase B, in addition to the 7 Phase A I/O primitives.

---

To test Odin ported code (klib, dl, time, etc.) against the C entry point (`nvim_bin`), skipping the Odin `main()`:

```bash
# 1. Build Odin ported code as a static library
odin build /home/rc/Projects/neovim/src/odin -build-mode:static \
  -out:/home/rc/Projects/neovim/build/lib/libklib.a

# 2. Optionally strip debug symbols (loses backtrace info)
objcopy --strip-debug /home/rc/Projects/neovim/build/lib/libklib.a \
  /home/rc/Projects/neovim/build/lib/libklib_stripped.a

# 3. Build C binary — CMAKE links libklib.a first, so Odin symbols
#    override any C definitions (linker prefers first symbol)
cmake --build /home/rc/Projects/neovim/build --target nvim_bin
```

**How it works**: `CMakeLists.txt` links `libklib.a` before `libnvim.a` in the `nvim_bin` target. The linker resolves symbols from the first archive that defines them, so Odin's `os_libcall`, `mh_put_*`, `mh_get_*`, etc. override the C versions. The C `main()` runs with Odin-backed maps and subsystems.

**Use case**: Verify that Odin ported code works correctly with the unmodified C entry point, without involving the Odin `main()` startup sequence.

---

## Startup Function Porting Status

### Ported & Wired In (called directly from Odin code)
| Order | Function | Odin Implementation |
|---|---|---|
| 1 | `appname_is_valid()` | `core:os.get_env_buf()` + string checks |
| 2 | `init_startuptime()` | Scans argv for `--startuptime`, calls C `time_init`/`time_start` via FFI |
| 3 | `check_and_set_isatty()` | `core:terminal.is_terminal(os.stdin/stdout/stderr)` |
| 4 | `init_homedir()` | `core:os.get_env("HOME")`, `uv_os_homedir` FFI, `core:os.getwd` → `startup_set_homedir` C setter |
| 5 | `init_path()` | `os.get_executable_path()`, `core:path/filepath.base()` |
| 6 | `highlight_init()` | `mh_put_HlEntry()` via Odin klib — exports `Set(HlEntry) attr_entries` to C |
| 7 | `log_init()` | Odin-native path resolution (XDG, `$NVIM_LOG_FILE`, `$HOME`), `os.open()` via FFI |
| 8 | `set_lang_var()` | `setlocale` via FFI + `set_vim_var_string` — sets v:ctype, v:lang, v:lc_time, v:collate |
| 9 | `init_params()` | Direct struct field assignment |
| 10 | `estack_init()` | `ga_grow()` via FFI + direct struct field assignment on `exestack` |
| 11 | `cmdline_init()` | Trivially ported — C globals are zero-initialized by C runtime before Odin `main()` runs |
| 12 | `init_normal_cmds()` | `sort.quick_sort_proc` on mirrored `NvCmd` struct array via C ptr helpers |

Status: ✅ 12 of 12 startup functions ported, all verified identical behavior with C build.

### Wired In via FFI (formerly blocked by `early_init`)

All 12 startup functions now ported to Odin, none remain wired via C FFI.

### Key Odin core packages for startup porting
- `core:os` — env vars, file I/O, exit, streams, executable path
- `core:strings` — string clone, compare, trim, split
- `core:strconv` — string ↔ int parsing
- `core:time` — wall clock, sleep, duration
- `core:path/filepath` — path join, split, base, dir, ext
- `core:terminal` — is_terminal, terminal size
- `core:slice` — sort, search, reverse, filter

Full reference with all library mappings in `ODIN_PORT.md` §9.2b.

---

## `early_init` — Successfully Broken Apart

The monolithic `early_init()` no longer exists as a single FFI call. It has been replaced with individual FFI calls from Odin's `main()` (`main.odin:344-368`):

```odin
os_hint_priority()          // macOS priority hint (no-op on Linux)
estack_init()               // step 10
cmdline_init()              // step 11
eval_init()                 // init global v: variables
set_vim_var_nr(VV_STARTTIME, os_realtime())
init_path(c_args[0])        // step 5, PORTED to Odin
init_normal_cmds()          // step 12
runtime_init()              // init runtime search path
highlight_init()            // step 6
time_msg("early init", nil)

init_locale()               // set locale
set_init_tablocal()         // set tab-local options (p_ch)
win_alloc_first()           // create first tabpage/window/buffer
time_msg("init first window", nil)

startup_alist_init()        // alist_init(&global_alist); global_alist.id = 0
init_homedir()              // step 4
set_init_1(params.clean)    // set all options to defaults
log_init()                  // step 7
time_msg("inits 1", nil)

set_lang_var()              // step 8
qf_init_stack()             // init quickfix stack
```

**What changed**:
- `startup_alist_init()` wrapper added to `main.c` — calls `alist_init(&global_alist)` then sets `global_alist.id = 0`
- 16 new FFI declarations in `main.odin` for the individual functions
- `init_path` (step 5) now called as Odin version at the natural position inside the sequence
- All 7 previously blocked functions are now individually callable from Odin and ready to port
- 2 have since been ported: `set_lang_var` (step 8) and `init_homedir` (step 4)
- `startup_set_homedir` C setter replaces the `static char *homedir` variable access

---

## Klib Map/Set Infrastructure — Replacing with Odin

The klib hash set/map system (`src/nvim/map_defs.h`, `map.c`, `map_glyph_cache.c`) is a macro-generated open-addressing hash table used across **28 `.c` files** and **9 `.h` files** in the C codebase. It provides **27 distinct types** (11 sets + 16 maps) with **26 function template instantiations**.

### Why Replace

- Macros make the code hard to read, debug, and maintain
- Every type generates ~500 bytes of function code via template includes
- `highlight_init()` is blocked until the `Set(HlEntry)` infrastructure is available in Odin
- An Odin implementation is cleaner, type-safe, and serves as the foundation for porting all other klib-dependent code

### Approach

Reimplement the **exact same open-addressing algorithm** in clean Odin code (not using Odin's built-in `map[T]U`, to maintain binary compatibility). The key requirement: **identical struct layout** for `MapHash`, `Set(T)`, and `Map(T, U)` so that:
- C code reading `_set.keys[i]`, `_set.h.n_keys` directly (11 sites across 4 files) continues to work
- Struct embedding in `buf_T`, `win_T`, `memfile_T` is unchanged
- Zero ABI risk at the C↔Odin boundary

### Klib Algorithm Details

**Data structure:**
- **Open addressing** with **quadratic probing** (step increments by 1 each collision)
- **Power-of-2 table size** — `mask = n_buckets - 1`, so `i = (i + step) & mask`
- **Hash[] array with indirect indexing** — `hash[i]` stores `slot_number + 1` (0 = EMPTY, `0xFFFFFFFF` = TOMBSTONE), real key index = `hash[i] - 1`
- **keys[] and values[]** are dense parallel arrays (indexed by the hash table position) — keys are compacted on delete by swapping the last element in

**MapHash struct layout (28 bytes + pointer):**
```
n_buckets:     u32   // size of hash[] array (power of 2)
size:          u32   // live entries (excludes tombstones)
n_occupied:    u32   // live + tombstone slots
upper_bound:   u32   // floor(n_buckets * 0.77 + 0.5) — triggers rehash
n_keys:        u32   // number of keys in keys[] array
keys_capacity: u32   // allocated capacity of keys[]
hash:          [^]u32  // pointer to hash slot array
```

**Tombstone**: `MH_TOMBSTONE = 0xFFFFFFFF`. Empty slot = 0.

**Rehash trigger**: When `n_occupied >= upper_bound`:
- If `size >= upper_bound * 0.9` (table genuinely full) → grow: allocate new hash array, double `n_buckets`
- If `size < upper_bound * 0.9` (mostly tombstones from deletes) → clean: zero hash, rebuild from existing keys

**Deletion**: Marks slot as `MH_TOMBSTONE`, then swaps `keys[last]` → `keys[k]` (and fixes that key's hash entry to point to `k`). The `values[]` array must also be swapped. This is the root cause of the earlier hang bug (values not swapped) and the key_alloc use-after-free bug (deleted key's data lost after swap).

### C Generation Pattern (for reference)

The original C used a 3-layer X-macro system:
- `map_defs.h:MH_DECLS` — defines set function prototypes per key type
- `map.c` — repeatedly `#include`s `map_key_impl.c.h` and `map_value_impl.c.h` with different `#define KEY_NAME`/`VAL_NAME` tokens
- Template files use token pasting (`KEY_NAME(mh_find_bucket_)` → `mh_find_bucket_uint64_t`)

### Comparison: Current klib (Odin) vs Odin Built-in `map[K]V`

| Feature | Current klib (Odin) | Odin built-in `map[K]V` |
|---|---|---|
| Probing | Quadratic (step: 1, 2, 3, ...) | Linear (Robin Hood) |
| Load factor | 0.77 | 75% |
| Growth | Powers of 2 | Powers of 2 |
| Cache alignment | None | 64-byte `Map_Cell(T)` — no key/value straddles cache line |
| Hash | Per-type DJB2/FNV-mix | FNV-64a with **unique seed per allocation** (splitmix64 from address) |
| Deletion | Swap-last (disk compaction) | Tombstone + **backward-shift deletion** |
| Empty encoding | `hash[i] == 0` | `hash == 0` |
| Tombstone | `0xFFFFFFFF` | MSB set |
| Memory | Separate keys[] + hash[] allocations | Single contiguous allocation (keys + values + hashes + 2 scratch each) |
| Per-type exports | 101 exported symbols | N/A (built-in) |

Odin's built-in **Robin Hood hashing** gives better worst-case probe variance at the cost of scratch storage for swaps during insert. Its **cache-line-aligned `Map_Cell`** padding prevents false sharing and improves linear probe locality. The **per-map seed** provides hash-collision DoS protection.

### Status

- ✅ **`src/odin/klib.odin`** created with generic `MapHash`, `mh_find_bucket`, `mh_get`, `mh_put`, `mh_rehash`, `mh_delete` using Odin's `$T` parametric polymorphism
- ✅ C-callable wrappers exported for all 10 key types (set functions + map functions per value type)
- ✅ `mh_realloc`, `mh_clear`, `pmap_del2` exported from Odin (all C callers now link to Odin)
- ✅ `map.c`, `map_key_impl.c.h`, `map_value_impl.c.h` removed from C build (moved to `bak/`)
- ✅ `map_defs.h` kept as-is — struct definitions + inline helpers that call exported `mh_*` symbols
- ✅ All 16 map-value exports present and linking (previously missing types now all exported)
- ✅ **Fixed ABI bug in `mh_delete_*` wrappers**: Changed `key: T` → `key: ^T` in all 10 wrappers, matching C's `T *key` (`map_defs.h:102`). C passes `&key` (pointer), Odin now reads it correctly.
- ✅ **Refactored 48 map wrappers into 3 generics + 48 one-liners**: `map_put_ref_generic`, `map_ref_generic`, `map_del_generic` handle all 16 value types. Reduced ~1000 lines to ~200.
- ✅ **Fixed Odin compiler type inference**: All 48 wrappers use `vals := &mp.values` intermediate variable. Resolves compiler's inability to deduce `$V` from `&mp.values` for struct-value types (String, StcClick, etc.).
- ✅ **Added `#force_inline`** to all 20 hash/equal functions (hot path).
- ✅ **Ported `highlight_init()`**: Moved `Set(HlEntry) attr_entries` global from C to Odin (`@(export)`). Odin `highlight_init` proc calls `mh_put_HlEntry`. C callers (via `clear_hl_tables`) link to exported symbol.
- ✅ **Added platform conditionals to `hash_path_t`/`equal_path_t`**: `when ODIN_OS` branches for Windows (strip drive letter, case-fold, `path_fnamencmp`), macOS (case-fold, `mb_stricmp`), Linux (byte hash, `strcmp`). **Fixes Linux bug**: `equal_path_t` no longer consults runtime `p_fic` via `path_fnamencmp`.
- ✅ **Ported `os/dl.c` (os_libcall)**: Replaced C's `uv_dlopen`/`uv_dlsym`/`uv_dlclose` with Odin `core:dynlib` (`load_library`/`symbol_address`/`unload_library`). 86-line subsystem, zero Neovim core dependencies, linker prefers Odin symbol.
- ✅ **Ported `os/time.c` (9 of 11 functions)**: `os_hrtime`, `os_realtime`, `os_time`, `os_sleep`, `os_localtime_r`, `os_localtime`, `os_ctime_r`, `os_ctime`, `os_strptime` ported to Odin using `core:time`, `core:sys/posix`, `core:c/libc`. Only `os_delay` and `os_now` (event-loop-dependent) remain in C.
- ✅ Build succeeds via `build.sh`, `--headless --clean -c "qall!"` exits cleanly.
- `Set(glyph)` remains in C (custom implementation in `map_glyph_cache.c`, not template-generated)

### Odin Standard Library Richness (discovered 2025-07)

Exhaustive analysis of `/home/rc/Projects/odin/Odin/core/` reveals that `core:os` is much richer than initially assumed. Key findings:

- **`core:os`**: ~130+ exported functions — covers file I/O, env, processes, dirs, paths, XDG user dirs (13 functions), pipes, temp files, glob, stat, process spawn/wait/kill, PID/UID/GID. **Already wraps most of `os/fileio.c` + `os/env.c` + `os/fs.c` + `os/rand.c` needs.**
- **`core:os` uses raw Linux syscalls** (not libuv). Internally: `os.open` → `linux.open()`, `os.read` → `linux.read()`, `os.write` → `linux.write()`, `os.close` → `linux.close()`. Zero libuv dependency. This enables **zero-FFI porting** of file I/O code.
- **`core:sys/posix`**: ~400 POSIX bindings across 59 files — epoll, pthreads (70+), termios, mmap, signals, sockets, DNS, UUID, fcntl, poll/select, dynamic loading.
- **`core:nbio`**: Async I/O with io_uring/kqueue/IOCP. Has gaps vs libuv (no file watching, process, signal, TTY, DNS). Strategically: use `nbio` for event loop I/O, `core:os` + `posix` for OS integration.
- **`core:container`**: Full data structure library. `xar` (stable-pointer exponential array) is the **key strategic value** — replaces `kvector`/`ga_T` without pointer invalidation. `intrusive/list` maps 1:1 to Neovim's `llist_T`.
- **`core:time/perf`**: High-resolution perf counters — already replaces `profile.c`.
- **`core:os.user_*_dir`**: All XDG directories (`cache_dir`, `state_dir`, `log_dir`, `config_dir`...) — would have simplified `log.odin` XDG resolution.
- **Deep allocator system analysis**: Mapped all 12 Odin allocator types. Neovim's custom arena (`memory.c`, `memory_defs.h`) can be replaced **wholesale** with `core:mem/virtual.Arena` (growing) or `core:mem/Dynamic_Arena` (backing-allocator-based) — no port needed, just substitution. Odin's `context.allocator` is an implicit procedure parameter (not a global), making allocator swapping trivial. See ODIN_PORT.md §9.2b Memory & Allocators for the full type table and replacement patterns.

### Next: Continue subsystem porting (OS layer, Lua integration, event loop)

| # | Task | Effort | Impact |
|---|---|---|---|---|
| 1 | ~~Port `os/fileio.c` to Odin~~ | Low (397 lines, `core:os`) | 🟢 Unblocks 4 callers (shada, eval/fs, getchar, lua/executor) — ✅ Done |
| 2 | ~~Port `os/env.c` Phase A to Odin~~ | Low (220 lines, `core:os`) | 🟢 Reduce C footprint — ✅ Done (9 functions) |
| 3 | ~~Port `os/fs.c` (stat/mkdir/readdir) to Odin~~ | Low (~500 lines, `core:os`) | 🟢 Pervasive file ops — ✅ Done (Phases A+B, 52 total symbols) |
| 4 | **Rewrite `os_fs.odin`** — drop hand-rolled `CStat`, back with `core:os`/`linux.stat`→`uv_stat_t` mapper | Medium | 🟢 Fixes latent `uv_stat_t` ABI bug, removes `clib` stat FFI, then delete `fs.c` |
| 5 | **Rewrite `fileio.odin`** — back `os_open`/`os_read`/`os_write`/`os_fsync` with `core:os` (keep negative-errno ABI), then delete `fileio.c` | Low | 🟢 |
| 6 | **Port `os/env.c` Phase B** (expand_env, home_replace, vim_getenv, vim_setenv_ext, etc.) as pure Odin + `path.c`/`eval` FFI, then delete `env.c` | Medium (750 lines) | 🟡 Vim runtime path expansion — pure string logic + C globals |
| 7 | **Port `signal.c`/`input.c`/`shell.c`/`proc.c`/`pty_proc_*`/`lang.c`/`stdpaths.c`/`users.c`/`mem.c`/`time.c`** to Odin, backing event-loop code with **libuv FFI** (`-luv` already linked; `uv.h` 325 `UV_EXTERN` decls; `uv_signal_t`/`uv_pipe_t`/`uv_process_t`/`uv_fs_t`/`uv_stdio_container_t` are mirrorable plain C structs; `main_loop` is a `foreign _` global) | High | 🟡 Event loop / process / locale / pty — no "never replace", only "which backing" |

---

## Revised Porting Strategy (2026-07)

**Decision: port EVERY `os/` function to Odin. Back it with `core:*` where possible and with libuv/posix FFI where not. Delete the C file once the Odin version links.** Nothing is "never replaceable" — the only question is *which backing* (core:os, core:sys/posix, core:sys/linux, or libuv FFI). Native alternatives to libuv can be investigated later; for now libuv is a plain linkable C library (already linked as `-luv`, `uv_translate_sys_error` already FFI'd in `os_fs.odin`/`fileio.odin`).

### Why this replaces the earlier "reimplement in Odin" approach

The initial ports **reimplemented logic `core:os` already ships**, while hand-preserving Neovim's C ABI. Concrete waste found in `os_fs.odin` (875 lines):
- Manual `CStat`/`CTimespec` structs with `#align(8)` + `clib` FFI `_c_stat`/`_c_lstat`/`_c_fstat` — `core:sys/linux` already provides `linux.stat`/`lstat`/`fstat`, and `core:os` provides `stat`/`lstat`/`fstat`/`File_Info`.
- `_c_rename`/`_c_access`/`_c_getuid`/`_c_fdopen` FFI — `posix.rename`/`access`/`getuid` exist.
- `mkdir_recurse`/`realpath`/`copy_file`/`make_directory_all` already use `core:os` — good pattern, keep.

Even `core:os` calls raw Linux syscalls internally (not libuv), so a `core:os`-backed `os_open` is *removing* a hand-written syscall layer, not adding one.

### ABI invariants every Odin port MUST preserve

1. **Negative-libuv-code convention.** `os_open`/`os_read`/`os_write`/`os_readv`/`file_open` return `int fd` or `< 0` = `-uv_translate_sys_error(errno)`. 23 C callers test `< 0`. Bridge: `uv_translate_sys_error(int) -> int` (libuv symbol, FFI-able).
2. **`xmalloc` ownership for returned strings** (`os_getenv`, `vim_getenv`, `expand_env_save`, `home_replace_save`, `os_get_userdir`). Allocate via memory.odin so C can `xfree`; never Odin's allocator.
3. **`FileInfo`/`FileID` C struct layout** — callers read `file_info->stat.st_dev` / `st_ino`. The C struct (`os/fs_defs.h:48`) wraps **`uv_stat_t`** (NOT raw `struct stat`). `uv_stat_t` uses **uint64_t** for `st_dev, st_mode, st_nlink, st_uid, st_gid, st_rdev, st_ino, st_size, st_blksize, st_blocks, st_flags, st_gen` + `uv_timespec_t st_atim/mtim/ctim/birthtim`. The current `os_fs.odin` `CStat` (raw `struct stat` mirror with `c.ulong`/`c.uint`) is a **latent ABI mismatch** vs the real `uv_stat_t` — fix by declaring `UVStat` to match `uv_stat_t` exactly and populating it from `linux.Stat` (amd64 `_Arch_Stat`: `dev, ino, nlink, mode, uid, gid, rdev, size, blksize, blocks, atime, mtime, ctime` — clean 1:1 source; compose `st_dev` from `Dev`).
4. **`os_chdir` calls `ui_call_chdir`** on success. Keep.
5. **`os_fopen` returns `FILE*`** (fdopen of the fd).

### Backing matrix (which `core:*` / FFI per need)

| Need | Backing |
|---|---|
| open/read/write/close/sync/truncate/seek | `core:os` (or `core:sys/linux` raw) — keep negative-errno ABI |
| stat/lstat/fstat | `core:sys/linux` `linux.stat/lstat/fstat` → `UVStat` mapper (need `st_dev`) |
| mkdir/mkdir_recurse | `core:os.make_directory_all` |
| mkdtemp | `core:os.make_directory_temp` (or `posix.mkdtemp`) |
| remove/rename/rmdir | `core:os.remove` / `posix.rename` |
| copy_file | `core:os.copy_file` |
| chmod/chown/fchown | `posix.chmod`/`chown`/`fchown` |
| access (readable/writable/executable) | `core:sys/linux` `linux.faccessat` / `posix.access` |
| utimensat (file_settime) | `core:os.change_times` or `linux.utimensat` |
| dup/dup3/cloexec | `linux.dup3` / `linux.fcntl` |
| realpath | `core:os.get_absolute_path` (reads `/proc/self/fd`) or `posix.realpath` |
| readlink(/proc/self/exe) | `posix.readlink` (os_exepath) |
| scandir | `posix.opendir`/`readdir` + side-table handle map (keep current) |
| env get/set/unset/lookup | `core:os` (already done in `os_env.odin`) — keep `xmalloc` ownership |
| hostname | `posix.gethostname` or `linux.uname` → `UTS_Name.nodename` |
| getpid/uid/gid | `core:os.get_pid` etc. (done) |
| signal/input/shell/proc/pty (event loop) | **libuv FFI** (`uv_signal_init`, `uv_read_start`, `uv_spawn`, `uv_*` pty) — mirror the `uv_*_t` structs |
| os_now/os_delay (loop-aware) | `uv_now` / `uv_run` FFI, or `core:time` + owned loop |

### Build mechanics

- `NVIM_SOURCES` is a **glob** over `src/nvim/**/*.c` (`CMakeLists.txt:388,431`). To delete a C `os/` file, move it to `bak/` (as done with `map.c`). Linker then sees only the Odin `@(export)` symbol.
- `#pragma weak` is still used as a safety bridge until the C file is physically moved to `bak/`.



## Binary comparison

| Metric | Native nvim | nvim_odin |
|---|---|---|---|
| Size | 14M | 14M |
| Startup | Works | Works |
| Commands | Works | Works |
| Exit code | 0 | 0 |
| Ported to Odin | — | `appname_is_valid`, `init_startuptime`, `check_and_set_isatty`, `init_path`, `init_params`, `set_lang_var`, `init_homedir`, `estack_init`, `cmdline_init`, `init_normal_cmds`, `highlight_init`, `log_init` |
| Wired via FFI (ready to port) | — | none — all 12 startup functions ported |
| Blocked on klib replacement | — | none — klib replacement complete |
