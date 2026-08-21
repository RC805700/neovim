# Odin Port of Neovim — Architecture & Planning Reference

## 1. Executive Summary

This document captures the complete architecture of the Neovim codebase and how it can be incrementally ported to the [Odin programming language](https://odin-lang.org). Odin is chosen for:

- **Performance**: Compiles to native code with data-oriented design, no GC, arena allocators
- **Safety**: Bounds-checked slices, distinct types, no implicit conversions
- **Lua support**: Official `vendor:lua/5.4` bindings ship with the Odin compiler
- **C interop**: `foreign` system for seamless static/library linking

The porting strategy is incremental: start with an Odin entry point that links against compiled C code via a static library, then gradually replace subsystems with Odin equivalents.

---

## 2. Neovim Codebase Overview

### 2.1 Directory Structure

| Directory | Purpose |
|---|---|
| `src/nvim/` | **Main source** — 274+ entries, the core editor (C files) |
| `src/nvim/api/` | RPC API layer (buffer, window, tabpage, ui, vim, autocmd, cmd, options, events, extmark) |
| `src/nvim/api/private/` | Private API internals (dispatch, helpers, converter, validate) |
| `src/nvim/eval/` | Vimscript expression evaluator (funcs, typval, userfunc, vars, encode/decode, gc, executor) |
| `src/nvim/event/` | Libuv-based event loop (loop, multiqueue, stream, socket, proc, rstream/wstream, time, signal) |
| `src/nvim/lua/` | Lua integration (executor, converter, stdlib, treesitter, secure, api_wrappers, spell, xdiff, base64) |
| `src/nvim/tui/` | Built-in terminal UI (tui, input, terminfo, termkey/, ugrid) |
| `src/nvim/os/` | OS abstraction layer (fs, fileio, env, input, signal, time, shell, proc, dl, lang, pty_*, stdpaths) |
| `src/nvim/msgpack_rpc/` | MessagePack RPC (channel, server, packer, unpacker) |
| `src/nvim/vterm/` | Vendored libvterm (terminal emulator) |
| `src/nvim/viml/parser/` | VimL parser |
| `src/nvim/lib/` | Internal library (queue_defs.h) |
| `src/gen/` | **Code generators** — 33 Lua scripts producing C headers |
| `src/xdiff/` | Vendored xdiff (diff algorithm) |
| `src/mpack/` | Vendored MessagePack C library + Lua bindings |
| `src/cjson/` | Vendored Lua CJSON library |
| `src/klib/` | Vendored klib (C containers: kvec, khash, kbtree, etc.) |
| `src/tee/` | `tee` utility |
| `src/xxd/` | `xxd` hex dump utility |
| `runtime/` | Runtime files (Lua modules, Vimscripts, syntax, docs, plugins, colors, queries) |
| `runtime/lua/vim/` | Core Lua stdlib for users (49 items: filetype, fs, lsp, treesitter, diagnostic, ui, keymap, etc.) |
| `runtime/lua/vim/_core/` | **23 internal core modules** embedded inside the binary (defaults, editor, help, options, proc, shared, swapfile, system, etc.) |
| `runtime/lua/vim/lsp/` | LSP client implementation |
| `runtime/lua/vim/treesitter/` | Treesitter integration |
| `test/` | Tests: `test/unit/` (C), `test/functional/` (Lua/Busted), `test/old/` (legacy) |
| `cmake.deps/` | CMake project for external dependencies |
| `cmake/` | CMake helper modules |
| `cmake.config/` | CMake configuration templates |
| `deps/` | Vendored unibilium and utf8proc source |

### 2.2 Key Subsystems

| Subsystem | Path | Description |
|---|---|---|
| **Editor Core** | `src/nvim/*.c` | Buffer management, windows, cursors, marks, undo, folds, options, syntax, highlighting, file I/O, regex, search, spelling, diff, tags, quickfix, signing, text objects, operators, registers, digraphs, keycodes, mouse, status line, messages, menus |
| **Event Loop** | `src/nvim/event/` | libuv-based: Loop, Stream, Socket, Proc, Multiqueue, Time, Signal, Rstream/Wstream |
| **OS Layer** | `src/nvim/os/` | File system, environment, input, signals, time, processes, shell, dynamic loading, locale, PTY, standard paths |
| **TUI** | `src/nvim/tui/` | Built-in terminal UI: tui.c (main driver), input.c, terminfo, ugrid (unified grid), termkey/ |
| **Vimscript** | `src/nvim/eval/` | Expression evaluator, functions, types, user functions, variables, GC, encoding |
| **Lua Integration** | `src/nvim/lua/` | Interpreter management (executor.c), value conversion (converter.c), stdlib, treesitter, API wrappers, secure mode |
| **API** | `src/nvim/api/` | RPC API: buffer operations, window/tabpage, UI events, autocmds, extmarks, options, commands |
| **MessagePack RPC** | `src/nvim/msgpack_rpc/` | Channel, Server, Packer, Unpacker — external UI protocol |
| **Vterm** | `src/nvim/vterm/` | Vendored libvterm — terminal emulation |
| **VimL Parser** | `src/nvim/viml/parser/` | Parser for Vimscript language |
| **Drawing/Redraw** | `src/nvim/` | drawscreen.c, drawline.c, grid.c, highlight.c, popupmenu.c, statusline.c, ui_compositor.c |

---

## 3. Build System

### 3.1 Primary: CMake

`CMakeLists.txt` (365 lines at root) defines the `nvim` project. Key targets:

| Target | Description |
|---|---|
| `nvim` | Full build — binary + runtime |
| `nvim_bin` | The executable only (no runtime) |
| `libnvim` | Static library (`MAKE_LIB` compile definition) |
| `nlua0` | Bootstrap Lua interpreter for code generation |
| `generated-sources` | All generated headers |

Build flow:
```
1. cmake -B build -G Ninja
2. cmake --build build
   a. Build dependencies (cmake.deps) → .deps/usr
   b. Build nlua0 (bootstrap Lua interpreter)
   c. Run code generators via nlua0 → auto/*.generated.h
   d. Build nvim_bin (C executable)
   e. Build runtime (copy files, generate helptags)
   f. Link nvim = nvim_bin + runtime
```

### 3.2 Alternative: Zig Build

`build.zig` (902 lines) and `build.zig.zon` provide a Zig-based build:
- `zig build` — builds the editor, output in `zig-out/bin/nvim`
- `zig build functionaltest` — runs functional tests
- `zig build unittest` — runs unit tests
- `zig build oldtest` — runs legacy tests
- Uses `src/gen/gen_steps.zig` for code generation
- Uses `runtime/gen_runtime.zig` for runtime handling
- Uses `src/nlua0.zig` as bootstrap Lua interpreter

---

## 4. Entry Point & Startup Sequence

### 4.1 Entry Point

**File**: `src/nvim/main.c` (2366 lines), defined at line 253.

Two entry forms depending on build config:
- `int main(int argc, char **argv)` — normal build
- `int nvim_main(int argc, char **argv)` — when `MAKE_LIB` is defined (libnvim)

### 4.2 Complete Startup Sequence (Function-Level)

```
main()  ← src/nvim/main.c:253
  ├─ appname_is_valid()                              — src/nvim/os/stdpaths.c:88
  ├─ init_params(&params, argc, argv)                — src/nvim/main.c:1565
  ├─ init_startuptime(&params)                       — src/nvim/main.c:1580
  ├─ [scan for --clean]
  ├─ event_init()                                    — src/nvim/main.c:155
  │    ├─ loop_init(&main_loop, NULL)                — src/nvim/event/loop.c:15
  │    ├─ env_init()                                 — src/nvim/os/env.c:61
  │    ├─ autocmd_init()                             — src/nvim/autocmd.c:118
  │    ├─ signal_init()                              — src/nvim/os/signal.c:39
  │    ├─ channel_init()                             — src/nvim/channel.c:204
  │    ├─ terminal_init()                            — src/nvim/terminal.c:442
  │    └─ ui_init()                                  — src/nvim/ui.c:121
  │
  ├─ early_init(&params)                             — src/nvim/main.c:192
  │    ├─ os_hint_priority()                         — macOS only, sets task policy
  │    ├─ estack_init()                              — src/nvim/runtime.c:117
  │    ├─ cmdline_init()                             — src/nvim/ex_getln.c:4553
  │    ├─ eval_init()                                — src/nvim/eval.c:204
  │    ├─ set_vim_var_nr(VV_STARTTIME, ...)          — sets v:starttime
  │    ├─ init_path(argv0)                           — src/nvim/main.c:1607
  │    ├─ init_normal_cmds()                         — src/nvim/normal.c:389
  │    ├─ runtime_init()                             — src/nvim/runtime.c:303
  │    ├─ highlight_init()                           — src/nvim/highlight.c:54
  │    ├─ init_locale()                              — src/nvim/os/lang.c:120
  │    ├─ set_init_tablocal()                        — src/nvim/option.c:172
  │    ├─ win_alloc_first()                          — src/nvim/window.c:4327
  │    ├─ alist_init(&global_alist)                  — init arg list
  │    ├─ init_homedir()                             — src/nvim/os/env.c:397
  │    ├─ set_init_1(clean)                          — src/nvim/option.c:343
  │    ├─ log_init()                                 — src/nvim/log.c:112
  │    ├─ set_lang_var()                             — src/nvim/os/lang.c:104
  │    └─ qf_init_stack()                            — src/nvim/quickfix.c:2070
  │
  ├─ set_argv_var(argv, argc)                        — src/nvim/eval.c:5774
  ├─ check_and_set_isatty(&params)                   — src/nvim/main.c:1598
  ├─ command_line_scan(&params)                      — src/nvim/main.c:1090
  ├─ set_argf_var()                                  — src/nvim/main.c:1546
  ├─ nlua_init(argv, argc, lua_arg0)                 — src/nvim/lua/executor.c:938
  ├─ [TUI client startup if use_builtin_ui]          — src/nvim/ui_client.c
  ├─ server_init(params.listen_addr)                 — msgpack_rpc/server.c
  ├─ win_init_size()                                 — src/nvim/window.c:4401
  ├─ default_grid_alloc()                            — src/nvim/drawscreen.c:172
  ├─ set_init_2(headless_mode)                       — src/nvim/option.c:602
  ├─ init_highlight(true, false)                     — src/nvim/highlight.c
  ├─ ui_comp_syn_init()                              — src/nvim/ui_compositor.c:72
  ├─ [remote_ui_wait_for_attach() if embedded]       — src/nvim/api/ui.c:123
  ├─ screenclear()                                   — src/nvim/drawscreen.c
  ├─ win_new_screensize()                            — src/nvim/window.c:5753
  ├─ nlua_init_defaults()                            — src/nvim/lua/executor.c:2435
  ├─ exe_pre_commands(&params)                       — src/nvim/main.c:1968
  ├─ source_startup_scripts(&params)                 — src/nvim/main.c:2212
  │    ├─ do_system_initialization()                 — source $VIMRUNTIME
  │    ├─ do_user_initialization()                   — source init.lua / init.vim
  │    └─ do_exrc_initialization()                   — source .nvim.lua / .exrc
  ├─ load_plugins()                                  — src/nvim/runtime.c:1397
  ├─ set_init_3()                                    — src/nvim/option.c:648
  ├─ shada_read_everything()                         — src/nvim/shada.c
  ├─ create_windows(&params)                         — src/nvim/main.c:1739
  ├─ edit_buffers(&params)                           — src/nvim/main.c:1853
  ├─ exe_commands(&params)                           — src/nvim/main.c:1992
  ├─ [VimEnter autocmds] — EVENT_VIMENTER, UIEnter
  │
  └─ normal_enter(false)                             — src/nvim/normal.c:513
                                                       → enters state_enter()
                                                       → dispatches input forever
                                                       → NEVER RETURNS
```

Exit functions:
- `getout(int)` — src/nvim/main.c:739 — orderly exit with autocmds, ShaDa write, calls `os_exit()`
- `os_exit(int)` — src/nvim/main.c:692 — event teardown, memfile close, `exit(r)`
- `preserve_exit(errmsg)` — src/nvim/main.c:876 — emergency exit for deadly signals

### 4.3 Startup Dependency Graph

```
main()
  │
  ├── appname_is_valid()          [dep: $NVIM_APPNAME env]
  ├── init_params()               [no deps]
  │
  ├── event_init()                [no deps → creates main_loop]
  │    └── autocmd_init()         [dep: main_loop.events]
  │    └── signal_init()          [dep: main_loop]
  │    └── channel_init()         [dep: main_loop.events]
  │    └── terminal_init()        [dep: main_loop]
  │
  ├── early_init()
  │    ├── eval_init()            [no deps → sets up v: vars]
  │    ├── init_path()            [no deps → sets v:progpath]
  │    ├── init_locale()          [no deps]
  │    ├── set_init_tablocal()    [no deps → sets p_ch]
  │    ├── win_alloc_first()      [dep: p_ch → creates curwin/curbuf/first_tabpage]
  │    ├── init_homedir()         [no deps]
  │    ├── set_init_1()           [dep: homedir, curwin/curbuf → all options]
  │    └── qf_init_stack()        [dep: option defaults]
  │
  ├── command_line_scan()         [dep: global_alist, options, v: vars → parses all CLI]
  ├── nlua_init()                 [dep: eval_init, runtime_init, main_loop]
  │
  ├── source_startup_scripts()    [dep: everything so far]
  ├── load_plugins()              [dep: p_rtp set by set_init_1]
  │
  └── normal_enter()              [dep: EVERYTHING → NEVER RETURNS]
```

**Key insight**: The dependency chain is strictly linear. Each phase depends on all prior phases. The critical chain is:
1. `event_init()` → enables event loop, signals, channels
2. `early_init()` → creates first win/buf/tabpage, options, eval
3. `command_line_scan()` → populates arg list from CLI
4. `nlua_init()` → bootstraps Lua runtime
5. `source_startup_scripts()` → user config
6. `normal_enter()` → infinite input loop (never returns)

This linearity makes the incremental porting approach viable — port one init function at a time from C to Odin.

---

## 5. Lua Integration

### 5.1 Core Lua Files (src/nvim/lua/)

| File | Lines | Purpose |
|---|---|---|
| `executor.c` | 2462 | Core interpreter: nlua_init, nlua_exec, nlua_call_typval, Lua refs, API function bindings |
| `converter.c` | 1246 | Lua value ↔ Vim typval_T conversion |
| `stdlib.c` | — | vim.* stdlib functions |
| `treesitter.c` | — | Tree-sitter Lua API |
| `api_wrappers.c` | — | vim.api.* wrappers |
| `secure.c` | — | Lua sandboxing |
| `spell.c` | — | Spell-checking for Lua |
| `xdiff.c` | — | Diff algorithm for Lua |
| `base64.c` | — | Base64 for Lua |

### 5.2 Lua Runtime

- **Embedded modules**: `vim_module.generated.h` — compiled Lua bytecode blobs from `runtime/lua/vim/_core/*.lua` (23 modules) embedded as C string literals
- **File-system modules**: `vim.lsp`, `vim.treesitter`, `vim.diagnostic` loaded at runtime
- **Bootstrap interpreter** (`nlua0`): A minimal Lua interpreter with mpack, lpeg, luv used for code generation *before* nvim_bin is compiled
- **Default runtime**: LuaJIT (with Lua 5.2 fallback). Can be compiled with PUC Lua via `-DPREFER_LUA=ON`

### 5.3 Lua ↔ C Interface

- `nlua_add_api_functions()` (generated by `gen_api_dispatch.lua`) registers `vim.api.*` functions
- `nlua_exec()` evaluates Lua from C (return modes: kRetObject, kRetNilBool, kRetLuaref, kRetMulti)
- `nlua_call_typval()` calls Lua functions from Vimscript with typval arguments
- `lua/executor.h` provides macros for entering/leaving the active Lua state

---

## 6. External Dependencies

### 6.1 Runtime Libraries

| Library | Version | Purpose | Bundled |
|---|---|---|---|
| **libuv** | ≥1.28.0 | Event loop, async I/O | Yes |
| **LuaJIT** (or Lua 5.1) | — | Lua runtime | Yes |
| **luv** | ≥1.43.0 | Lua libuv bindings | Yes |
| **liblpeg** | — | Lua pattern matching | Yes |
| **tree-sitter** | ≥0.25.0 | Incremental parsing | Yes |
| **libutf8proc** | — | UTF-8 processing | Yes |
| **unibilium** | ≥2.0 | Terminfo database | Yes |
| **libiconv** | — | Encoding conversion | Win only |
| **libintl** (gettext) | — | i18n | Optional |
| **wasmtime** | ≥36.0 | WASM for TS parsers | Optional |
| **pthread** | — | Threading (POSIX) | System |
| **util** | — | libutil (forkpty) | System |

### 6.2 Vendored Libraries

| Library | Path | Purpose |
|---|---|---|
| **xdiff** | `src/xdiff/` | Diff algorithm (from git) |
| **mpack** | `src/mpack/` | MessagePack C library |
| **cjson** | `src/cjson/` | Lua CJSON |
| **klib** | `src/klib/` | C containers: kvec, khash, kbtree |
| **libvterm** | `src/nvim/vterm/` | Terminal emulation |

---

## 7. Code Generation Pipeline

Neovim generates ~55+ C header files from **33 Lua scripts** in `src/gen/`. This runs during the build **before** nvim_bin is compiled, using the bootstrap `nlua0` interpreter.

### 7.1 Key Generators

| Script | Input | Output |
|---|---|---|
| `gen_api_dispatch.lua` | `api/*.h`, `dispatch_deprecated.lua` | `api/private/dispatch_wrappers.generated.h`, `lua_api_c_bindings.generated.h`, `exported_funcs_metadata.mpack` |
| `gen_api_ui_events.lua` | `api/ui_events.in.h` | `ui_events_call.generated.h`, `ui_events_remote.generated.h`, `ui_events_client.generated.h` |
| `gen_eval.lua` | `eval.lua` | `funcs.generated.h`, `funcs_data.mpack` |
| `gen_ex_cmds.lua` | `ex_cmds.lua` | `ex_cmds_enum.generated.h`, `ex_cmds_defs.generated.h` |
| `gen_events.lua` | `auevents.lua` | `auevents_enum.generated.h`, `auevents_name_map.generated.h` |
| `gen_keycodes.lua` | `keycodes.lua` | `keycode_names.generated.h` |
| `gen_options.lua` | `options.lua` | `options.generated.h`, `options_enum.generated.h`, `options_map.generated.h`, `option_vars.generated.h` |
| `gen_declarations.lua` | Every `.c` and `.h` file | Per-file `.c.generated.h` and `.h.generated.h` |
| `gen_char_blob.lua` | Core Lua runtime modules | `lua/vim_module.generated.h` (bytecode blobs) |
| `gen_vimvim.lua` | funcs_data.mpack, options.lua | `runtime/syntax/vim/generated.vim` |

**Important for porting**: The code generation pipeline must be preserved regardless of the main binary's implementation language. The generators produce C headers that both C and Odin code need.

---

## 8. Odin Capabilities

### 8.1 Lua 5.4 Bindings (`vendor:lua/5.4`)

Odin ships official Lua 5.4 bindings as `vendor:lua/5.4`. Key points:

- **Single file**: `lua.odin` contains all bindings (lua.h, lauxlib.h, lualib.h, luaconf.h)
- **Static linking** (default): Links against prebuilt `liblua54.a` (Linux amd64) or `lua54dll.lib` (Windows)
- **Dynamic linking**: Pass `-define:LUA_SHARED=true` to `odin build`
- **Full Lua C API**: All major functions mapped (`lua_newstate`, `lua_pcallk`, `lua_pushstring`, etc.)
- **Custom allocator support**: `lua_newstate` accepts `Alloc` callback
- **Convenience wrappers**: `L_dostring`, `L_dofile`, `pop`, `newtable` as Odin inline procs

Basic usage:
```odin
package main
import "vendor:lua/5.4"

main :: proc() {
    L := lua_5_4.L_newstate()
    defer lua_5_4.close(L)
    lua_5_4.L_openlibs(L)
    lua_5_4.L_dostring(L, `print("Hello from Odin + Lua!")`)
}
```

Registering an Odin function for Lua:
```odin
my_func :: proc "c" (L: ^lua_5_4.State) -> i32 {
    arg := lua_5_4.L_checkstring(L, 1)
    lua_5_4.pushstring(L, "hello: " + string(arg))
    return 1
}
// Register:
lua_5_4.pushcfunction(L, lua_5_4.CFunction(my_func))
lua_5_4.setglobal(L, "my_func")
```

### 8.2 C Foreign Function Interface

Odin's `foreign` system provides seamless C interop:

```odin
// Declare a library
foreign import mylib "path/to/libmylib.a"

// Declare procedures from the library
foreign mylib {
    @(link_prefix="my_")
    do_something :: proc(x: i32) -> i32 ---
}
```

Key attributes:
- `@(link_prefix="xxx")` — strip prefix from symbol names
- `@(link_name="real_name")` — override symbol name
- `@(link_suffix="xxx")` — append suffix
- Default calling convention is `"c"` (cdecl)
- `---` suffix required on foreign procedure declarations
- `#c_vararg` for C varargs (`printf`-style)

Exporting Odin to C:
```odin
@(export)
my_callback :: proc "c" (value: i32) -> i32 { return value * 2 }
```

### 8.3 Build System

Odin itself is the build system — no Makefile/CMake needed:

```bash
odin build .                    # Build directory as package
odin build . -out:nvim          # Custom output name
odin run .                      # Build and run
odin build . -debug             # Debug build
odin build . -o:speed           # Optimize for speed
odin build . -o:size            # Optimize for size
```

Linker integration:
- Static libraries declared via `foreign import` are automatically linked
- `-extra-linker-flags:<flags>` passes flags directly to the linker
- `-lib-path:<dir>` adds library search directory
- `-collection:<name>=<path>` registers custom collections

### 8.4 Memory Management

Odin uses explicit allocators (no GC):

| Allocator | Use Case |
|---|---|
| `context.allocator` (heap) | General-purpose (default) |
| `arena_allocator` | Batch allocations — free all at once |
| `scratch_allocator` | Short-lived temporary data |
| `tracking_allocator` | Debug memory leak detection |
| `pool_allocator` | Fixed-size object reuse |

Tracking allocator pattern:
```odin
import "core:mem"
when ODIN_DEBUG {
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    context.allocator = mem.tracking_allocator(&track)
    defer {
        for _, entry in track.allocation_map {
            fmt.eprintf("Leak: %v bytes @ %v\n", entry.size, entry.location)
        }
        mem.tracking_allocator_destroy(&track)
    }
}
```

### 8.5 Core Library Equivalents

| C / Neovim | Odin Equivalent |
|---|---|
| `malloc`/`free` | `context.allocator` + `new`/`make`/`delete` |
| `string.h` | `core:strings` |
| `stdio.h` | `core:fmt`, `core:os` |
| `stdlib.h` | `core:mem`, `core:os` |
| `math.h` | `core:math` |
| `pthread` | `core:thread`, `core:sync` |
| `time.h` | `core:time` |
| `ctype.h` | `core:unicode` |
| JSON | `core:encoding/json` |
| Base64 | `core:encoding/base64` |
| Hex | `core:encoding/hex` |
| Opaque `void*` | `rawptr` |
| `size_t` | `c.size_t` or `int` |

---

## 9. Incremental Porting Plan

### 9.1 Strategy

Build all existing C code as a static library (`libnvim_full.a`). Link it from an Odin entry point. Gradually replace individual C subsystems by:
1. Writing the Odin implementation with the same C ABI
2. Compiling it to a `.o` file
3. Overriding the C symbol at link time (linker prefers Odin's symbol)
4. Testing with the existing test suite

### 9.2 Phase 0: Build Integration (1-2 weeks)

**Goal**: Produce a working `nvim` binary with Odin's `main()` calling each C init function individually via FFI.

**Why not call `nvim_main()` monolithically?**
Because granular FFI calls let us port any single startup function to Odin independently. The dependency chain is strictly linear, so we can replace `event_init()` with an Odin version while still calling the rest via FFI.

**Steps**:
1. Create `src/odin/` directory for Odin source
2. Create a CMake custom target that compiles all C source into `libnvim_full.a`
3. Write `src/odin/main.odin`:
   ```odin
   package main

   import "core:os"
   import "core:c"

   foreign import nvim "libnvim_full.a"

   @(link_prefix="")
   foreign nvim {
       // Startup sequence — each step callable individually
       event_init :: proc() ---
       early_init :: proc(params: ^Mparm) ---
       command_line_scan :: proc(params: ^Mparm) ---
       nlua_init :: proc(argv: [^]cstring, argc: c.int, lua_arg0: c.int) ---
       server_init :: proc(listen_addr: cstring) ---
       source_startup_scripts :: proc(params: ^Mparm) ---
       load_plugins :: proc() ---
       normal_enter :: proc(noexmode: bool) ---  // never returns

       // Exit
       os_exit :: proc(r: c.int) ---  // never returns
   }

   // mparm_T mirrors the C struct — all fields must match layout
   Mparm :: struct {
       argc:            c.int,
       argv:            [^]cstring,
       use_vimrc:       cstring,
       clean:           bool,
       n_commands:      c.int,
       commands:        [10]cstring,
       cmds_tofree:     [10]cstring,
       n_pre_commands:  c.int,
       pre_commands:    [10]cstring,
       luaf:            cstring,
       lua_arg0:        c.int,
       edit_type:       c.int,
       tagname:         cstring,
       use_ef:          cstring,
       input_istext:    bool,
       no_swap_file:    c.int,
       use_debug_break_level: c.int,
       window_count:    c.int,
       window_layout:   c.int,
       diff_mode:       c.int,
       listen_addr:     cstring,
       remote:          c.int,
       server_addr:     cstring,
       scriptin:        cstring,
       scriptout:       cstring,
       scriptout_append: bool,
       had_stdin_file:  bool,
   }

   main :: proc() {
       args := os.args
       c_args := make([^]cstring, len(args))
       for a, i in args {
           c_args[i] = cstring(a)
       }
       defer delete(c_args)

       // Build mparm_T by calling C's init_params via FFI
       // (Or port init_params to Odin first — it just copies argc/argv)
       params: Mparm
       // init_params(&params, c.int(len(args)), c_args) — if we leave it in C

       // Startup sequence — identical to C's main()
       event_init()
       // early_init(&params)   ← port this to Odin next!
       command_line_scan(&params)
       nlua_init(c_args, c.int(len(args)), 0)
       server_init(params.listen_addr)
       source_startup_scripts(&params)
       load_plugins()
       normal_enter(false)  // NEVER RETURNS — this is the editor
   }
   ```
4. Write build script: run CMake generators → compile C lib → `odin build . -out:nvim`
5. Verify: `./nvim --version`, `./nvim -c "checkhealth"`, run test suite

**Deliverable**: Neovim binary running from Odin entry point, 100% C internals called via granular FFI.

### 9.2a Startup Function Porting Order (Phase 0-1)

Once Phase 0 links successfully, port these startup functions one at a time from C to Odin.
Each port replaces a C FFI call with native Odin code:

| Order | Function | C File | Why Easy | Odin Alternative | Status |
|---|---|---|---|---|---|---|
| 1 | `appname_is_valid()` | `os/stdpaths.c` | Pure string check against `$NVIM_APPNAME` | `core:os.get_env_buf()` + string checks | ✅ Ported |
| 2 | `init_startuptime()` | `main.c:1580` | Scans argv for `--startuptime` | `core:time` + FFI `time_init`/`time_start` | ✅ Ported |
| 3 | `check_and_set_isatty()` | `main.c:1598` | Wraps `isatty()` on 3 fds | `core:terminal.is_terminal()` | ✅ Ported |
| 4 | `init_homedir()` | `os/env.c:397` | Reads `$HOME` env var, fallback to libuv/CWD | `core:os.get_env("HOME")`, `uv_os_homedir` FFI, `core:os.getwd` → `startup_set_homedir` | ✅ Ported |
| 5 | `init_path()` | `main.c:1607` | Path from `argv[0]`, sets v:progpath/progname | `os.get_executable_path()`, `core:path/filepath` | ✅ Ported |
| 6 | `highlight_init()` | `highlight.c:54` | Adds sentinel entry to `attr_entries` | `mh_put_HlEntry()` via Odin klib | ✅ Ported (klib unblocked) |
| 7 | `log_init()` | `log.c:112` | Opens log from `$NVIM_LOG_FILE` | `core:os` env/file ops, libc `fopen` FFI | ✅ Ported |
| 8 | `set_lang_var()` | `os/lang.c:104` | Sets `v:lang`, `v:ctype` from locale | `setlocale` FFI + `set_vim_var_string` | ✅ Ported |
| 9 | `init_params()` | `main.c:1565` | Copies `argc`/`argv` into struct | Direct struct field assignment | ✅ Ported |
| 10 | `estack_init()` | `runtime.c:117` | Pre-alloc 10 entries in exec stack | `ga_grow()` FFI + direct struct fields on `exestack` | ✅ Ported |
| 11 | `cmdline_init()` | `ex_getln.c:4553` | Zeroes `ccline` struct | `memset` FFI + `startup_cmdline_ccline_ptr/size` helpers | ✅ Ported |
| 12 | `init_normal_cmds()` | `normal.c:389` | Sorts `nv_cmd_idx[]` lookup table | `sort.quick_sort_proc` + `NvCmd` struct mirror + C ptr helpers | ✅ Ported |

**Progress**: 12 of 12 ported. All startup functions now have Odin implementations.

### 9.2c Klib Map/Set Infrastructure — Replacing with Odin

The klib hash set/map system (`src/nvim/map_defs.h`, `map.c`, `map_glyph_cache.c`) is a macro-generated open-addressing hash table used across **28 `.c` files** and **9 `.h` files**. It defines **27 distinct types** (11 sets + 16 maps) with **26 function template instantiations**.

**Status**: ✅ Generic algorithm implemented in `src/odin/klib.odin`. All exports present and linking, ABI bugs fixed, 48 map wrappers refactored into 3 generics, build passes.

See `PHASE0_FINDINGS.md` §Klib Map/Set Infrastructure for full details.

**Why replace**:
- Macros make code hard to read, debug, and maintain
- Every type generates ~500 bytes of function code via `#include` templates
- `highlight_init()` was blocked until the `Set(HlEntry)` infrastructure was available in Odin — ported as soon as klib was ready
- Foundation for porting all other klib-dependent subsystems to Odin over time

**Approach**: Reimplement exact same open-addressing algorithm in clean Odin code (`src/odin/klib.odin`), maintaining **identical struct layout** for `MapHash`, `Set(T)`, `Map(T, U)` to preserve:
- Direct field accesses (`_set.keys[i]`, `_set.h.n_keys`) — 11 sites in 4 files
- Struct embedding in `buf_T`, `win_T`, `memfile_T`
- Zero ABI risk at the C↔Odin boundary

Export C-callable functions for each concrete type. C's `map_defs.h` inline helpers call the `mh_*` symbols (now provided by Odin). Stripped generated template includes from C build entirely.

#### Odin's Built-in `map[K]V` (Reference for Future Work)

Odin's native hash map uses a **different, more advanced algorithm** than klib's quadratic-probing open addressing:

| Feature | Current klib (Odin) | Odin built-in `map[K]V` |
|---|---|---|
| Probing | Quadratic (step: 1, 2, 3, ...) | Linear (Robin Hood) |
| Load factor | 0.77 (`UPPER_FILL`) | 75% (`MAP_LOAD_FACTOR :: 75`) |
| Capacity growth | Powers of 2 | Powers of 2 |
| Cache alignment | None | 64-byte `Map_Cell(T)` — no key/value straddles a cache line |
| Hash | Per-type DJB2/FNV-mix | Per-allocation seeded FNV-64a (splitmix64 from address) |
| Deletion | Swap-last (keys[] compaction) | Tombstone + backward-shift deletion |
| Empty encoding | `hash[i] == 0` | `hash == 0` |
| Tombstone encoding | `hash[i] == MH_TOMBSTONE (0xFFFFFFFF)` | MSB set |
| Resize trigger | `n_occupied >= upper_bound` | `len >= 75% capacity` |
| Per-type exports | 101 exported symbols | N/A (built-in) |

The built-in's **Robin Hood hashing** gives better worst-case probe variance at the cost of needing scratch storage (2 key + 2 value slots) for swapping entries during insert. Its **cache-line-aligned `Map_Cell`** padding prevents false sharing and improves linear-probe performance. If klib's ABI constraint were lifted (i.e., C code using direct field access gets ported too), the built-in `map[K]V` or a Robin Hood reimplementation would be the better long-term choice.

#### Known klib Improvement Opportunities

| # | Issue | Fix | Status |
|---|---|---|---|
| 🔴 | `mh_delete_*` ABI mismatch (value vs pointer) | Change `key: T` → `key: ^T` in all 10 wrappers | ✅ Fixed |
| 🟡 | 1000-line boilerplate (48 map functions) | Build-time code generator from a type table | ✅ Refactored to 3 generics + 48 wrappers |
| 🟢 | No `#force_inline` on hash/equal functions | Add `#force_inline` to all 20 (hot path) | ✅ Fixed |
| 🟢 | `hash_path_t` lacks platform conditionals | Add `BACKSLASH_IN_FILENAME`/`CASE_INSENSITIVE_FILENAME` branches | ✅ Fixed |

See `PHASE0_FINDINGS.md` §Klib Map/Set Infrastructure for full details.

### 9.2b Odin Core Library Reference for Porting

Below is a comprehensive reference of Odin's standard libraries mapped to Neovim's C subsystems. Organized by category for quick lookup during porting.

#### Strings & Text

| Odin Package | What It Provides | Replaces C File/Pattern |
|---|---|---|
| `core:strings` | Builder, clone, contains, trim, split, join, replace, to_upper/lower, has_prefix/suffix | `strings.c`, `misc1.c` helpers |
| `core:strconv` | `parse_int/uint/float`, `append_int/float`, `itoa` | `vim_str2nr`, `sprintf` number formatting |
| `core:text/regex` | Full regex engine (parser, compiler, optimizer, VM) | `regexp.c`, `regexp_nfa.c` |
| `core:text/match` | Lua-style simple pattern matching (not full regex) | Lightweight pattern needs |
| `core:text/scanner` | UTF-8 text scanner/tokenizer | `getchar.c` helpers, input scanning |
| `core:text/i18n` | Internationalization, plural forms, translation catalogs | `locale.c` i18n helpers |
| `core:unicode` | Unicode classification, case folding, properties | `charset.c`, Unicode tables |
| `core:unicode/utf8` | UTF-8 encode/decode | `utf8.c` |
| `core:bytes` | Byte slice buffer, reader, clone, contains, replace | `bytebuf.c` or raw `char_u` operations |
| `core:bytes/buffer` | Dynamic byte buffer (read/write/seek) | `growarray` patterns |

#### Data Structures

| Odin Feature | What It Provides | Replaces C File/Pattern | Strategic Value |
|---|---|---|---|---|
| `map[K]V` (built-in) | Hash map with any comparable key type | `khash.h` inline hashtables, `hashtab.c` | 🔵 Future — needs ABI drop |
| `map[T]struct{}` (built-in) | Hash set idiom | `khash` set variants | 🔵 Future — needs ABI drop |
| `[dynamic]T` (built-in) | Dynamic/auto-resizing array | `kvec.h` dynamic vectors, `ga_init/grow` | 🟢 Direct `ga_T` replacement |
| `core:slice` | Sort, search, reverse, dedup, filter, clone | Manual array ops throughout | 🟢 Utility for all ports |
| `core:sort` | Generic sort interface | `sort.c`, manual qsort calls | 🟢 Direct replacement |
| `core:container/queue` | Ring-buffer double-ended queue (O(1) push/pop both ends) | Manual ring buffers | 🟢 No Neovim equivalent — new capability |
| `core:container/priority_queue` | Binary heap with `fix()` for dynamic priority updates | Manual heap patterns | 🟢 Neovim has no generic heap |
| `core:container/avl` | Self-balancing BST, strict O(log n) | `kbtree.h` or custom trees | 🟡 Niche — single-value ordered set |
| `core:container/rbtree` | **Key-value** RB tree, ordered traversal | `rbtree.h` (hev_key_entry only) | 🟢 Replaces `rbtree.h` event loop map |
| `core:container/lru` | LRU cache with eviction callback, O(1) get/set | Manual LRU patterns | 🟢 Neovim has no LRU cache |
| `core:container/handle_map` | Generational index (stable handles, dangling detection) | `map_uint64_t` for buf/win/tab handles | 🟢 Safety improvement for handle system |
| `core:container/bit_array` | Dynamic bitset with negative-index support, iterators | `uint64_t` bitfields, `kbtree_t` sparse sets | 🟢 Replaces ad-hoc bitsets |
| `core:container/small_array` | Fixed-capacity array with full push/pop/insert/remove API | C fixed arrays + manual len | 🟢 Stack-allocated dynamic arrays |
| `core:container/xar` | **Exponential array — stable pointers** (never moves elements) | `kvector` (reallocates, invalidates ptrs) | 🟢 **Key strategic value** — solves pointer stability |
| `core:container/intrusive/list` | Intrusive doubly-linked list, `container_of` iterators | `llist_T` in memfile.c, buf_T/win_T | 🟢 **Direct 1:1** — pervasive in Neovim |
| `core:container/pool` | Thread-safe object pool with virtual-memory arena | No generic pool in Neovim | 🟢 High-performance allocation |
| `core:container/topological_sort` | Kahn's algorithm with cycle detection | None | 🟢 New capability |

**Key strategic insight for `xar`**: `kvector`/`ga_T`/`[dynamic]T` all reallocate and invalidate pointers to elements. `xar.Array` uses geometric chunk growth — once an element is allocated, its address never changes. This is critical for Neovim patterns where a pointer to a struct field is stored (e.g., `curbuf` points into the buffer array, `buf_T.prev/next` are intrusive list links). Replacing `kvector` with `xar` eliminates a class of use-after-free and pointer-staleness bugs.

#### OS & System — `core:os`

**`core:os`** (~130+ exported functions) is the primary OS abstraction layer. It covers file I/O, env vars, processes, directories, paths, XDG user dirs, pipes, temp files, and globbing — all cross-platform with minimal C FFI.

**Critical discovery: `core:os` uses raw Linux syscalls, not libuv.** Internally, `os.open` calls `linux.open()` (raw syscall), `os.read` calls `linux.read()`, `os.write` calls `linux.write()` in a retry-loop, and `os.close` calls `linux.close()`. There is zero libuv dependency. This is a pure-Odin implementation backed by `core:sys/posix` and `core:sys/linux`. This means porting `fileio.c` to Odin requires **zero FFI to C** for I/O operations — just `core:os.open/read/write/close/sync`.

##### File I/O

| Function Group | Odin API | Replaces |
|---|---|---|
| Open/create/close | `os.open/create/close/clone` | `os_open`, `mch_open` |
| Read/write | `os.read/write/read_at/write_at` | `os_read`, `os_write`, `pread`, `pwrite` |
| Seek/size/sync/truncate | `os.seek/file_size/sync/flush/truncate` | `lseek`, `ftruncate`, `fsync` |
| Entire file | `os.read_entire_file/write_entire_file` | `os_read_file`, file slurp patterns |
| Utility writes | `os.write_string/write_byte/write_rune/write_ptr/read_ptr` | `fprintf`, `putc` patterns |
| Pipes | `os.pipe/pipe_has_data` | `uv_pipe_open`, `pipe()` |

##### File System Operations

| Function | Odin API | Replaces |
|---|---|---|
| Remove/rename | `os.remove/rename` | `os_remove`, `mch_remove` |
| Links | `os.link/symlink/read_link` | `mch_link`, `os_readlink` |
| Copy | `os.copy_file` | `copy_file` |
| Permissions | `os.change_mode/fchange_mode/change_owner` | `chmod`, `chown` |
| Working dir | `os.get_working_directory/set_working_directory` | `os_dirname`, `mch_chdir` |
| Existence | `os.exists/is_file/is_directory` | `os_isdir`, path checks |
| Temp files | `os.create_temp_file/make_directory_temp/temp_directory` | `mch_tempnam` |
| User dirs | `os.user_home_dir/cache_dir/data_dir/state_dir/log_dir/config_dir/documents_dir/downloads_dir/...` (13 XDG functions) | `os_get_userhome`, custom XDG resolution |
| Stat | `os.stat/lstat/fstat/same_file/modification_time` | `os_stat`, `mch_stat` |
| Directory read | `os.read_directory/read_directory_iterator/walker` | `opendir`/`readdir` patterns |
| Path predicates | `os.is_path_separator/is_absolute_path/are_paths_identical` | `vim_ispathsep`, `pathcmp` |
| Path decomposition | `os.split_path/base/dir/stem/ext/volume_name/split_filename` | `path_tail`, `path_dirname` |
| Path construction | `os.join_path/join_filename/clean_path/replace_path_separators` | `concat_fnames`, `simplify_path` |
| Absolute/relative | `os.get_absolute_path/get_relative_path` | `FullName_save`, `shortpath` |
| Glob | `os.glob/match/split_path_list` | `expand_wildcards` |
| Executable path | `os.get_executable_path/get_executable_directory` | executable detection |

##### Environment Variables

| Function | Odin API | Replaces |
|---|---|---|
| Get (alloc) | `os.get_env_alloc(key, allocator) -> string` | `os_getenv` (xmalloc'd) |
| Get (buf) | `os.get_env_buf(buf, key) -> string` | `os_getenv_buf` (fixed buf) |
| Lookup (found flag) | `os.lookup_env_alloc/lookup_env_buf -> (value, found)` | `os_env_exists` |
| Set/unset | `os.set_env/unset_env` | `os_setenv`, `os_unsetenv` |
| Clear all | `os.clear_env` | — |
| Enumerate | `os.environ(allocator) -> []string` | `os_getenvname_at_index`, environ |
| Placeholder expansion | `os.replace_environment_placeholders(path) -> string` | `expand_env` ($VAR expansion only) |

##### Process Management

| Function | Odin API | Replaces |
|---|---|---|
| PID/UID/GID | `os.get_pid/get_ppid/get_uid/get_euid/get_gid/get_egid` | `os_get_pid`, `mch_get_user` |
| CPU cores | `os.get_processor_core_count` | `mch_ncpu` |
| Spawn | `os.process_start(desc) -> Process` | `uv_spawn`, `mch_call_shell` |
| Capture output | `os.process_exec(desc) -> (state, stdout, stderr)` | `system` capture |
| Wait/kill/terminate | `os.process_wait/kill/terminate` | `uv_process_kill`, `mch_kill` |
| Process info | `os.process_info/current_process_info/free_process_info` | /proc queries |
| Process list | `os.process_list -> []int` (all PIDs) | — |
| Exit | `os.exit(code) -> !` | `os_exit`, `getout` |

##### Other OS Packages

| Package | What It Provides | Replaces |
|---|---|---|
| `core:time` | `now()`, `sleep()`, `Duration`, formatting, tick | `os/time.c`, `time.c`, `uv_now()` |
| `core:time/datetime` | Calendar date/time, proleptic Gregorian | `strftime` patterns, date formatting |
| `core:time/perf` | High-resolution perf counters (`start/stop/counts/diff`) | `profile.c` |
| `core:dynlib` | `load_library/symbol_address/unload_library` | `os/dl.c` ✅ Ported |
| `core:terminal` | `is_terminal`, color depth, raw mode, size queries | `os/input.c`, `tui/input.c` |
| `core:flags` | Command-line parser from struct tags | `command_line_scan()` |
| `core:sync` | Mutex, semaphore, waitgroup, atomic, futex | `uv_mutex_*`, manual locking |
| `core:thread` | Thread creation, thread pools | `uv_thread_*` |
| `core:sys/info` | Runtime CPU/platform detection | `machine.h` |
| `core:sys/posix` | **~400 POSIX bindings** — see below | Full OS layer |

##### `core:sys/posix` — Comprehensive POSIX Bindings

Odin ships exhaustive POSIX libc bindings across 59 files. Key categories:

| Category | Count | Key Functions |
|---|---|---|
| **File I/O** | 20+ | `open/read/write/close/lseek/pread/pwrite/dup/dup2/pipe/fsync/ftruncate/access` |
| **Vectored I/O** | 2 | `readv/writev` (sys_uio) |
| **File system** | 25+ | `stat/lstat/fstat/mkdir/mkfifo/chmod/fchmod/chown/fchown/lchown/umask/utimensat/futimens` |
| **Directories** | 8 | `opendir/readdir/readdir_r/closedir/rewinddir/seekdir/telldir` |
| **Memory mapping** | 15+ | `mmap/munmap/mprotect/msync/madvise/mlock/munlock/mlockall/munlockall/shm_open/shm_unlink` |
| **Process** | 15+ | `fork/execve/execvp/wait/waitpid/waitid/posix_spawn/posix_spawnp` |
| **Signals** | 15+ | `signal/raise/kill/sigaction/sigemptyset/sigfillset/sigaddset/sigdelset/sigismember/sigprocmask/sigsuspend/sigpending/sigwait` |
| **Time** | 25+ | `clock_gettime/clock_getres/clock_settime/gettimeofday/nanosleep/time/localtime_r/gmtime_r/strptime/strftime/ctime_r/asctime/timespec_get` |
| **Sockets** | 25+ | `socket/bind/listen/accept/connect/send/recv/sendto/recvfrom/sendmsg/recvmsg/shutdown/getsockopt/setsockopt/getsockname/getpeername/socketpair` |
| **Terminal** | 15+ | `tcgetattr/tcsetattr/cfmakeraw/tcsendbreak/tcdrain/tcflush/tcflow/cfgetispeed/cfsetispeed` |
| **Poll/Select** | 5 | `poll/select/pselect/epoll_create/epoll_ctl/epoll_wait/epoll_pwait` |
| **Fcntl** | 5 | `fcntl/open/creat` with all `F_*`/`O_*` constants |
| **Resource** | 8 | `getrlimit/setrlimit/getrusage/getpriority/setpriority` |
| **DNS** | 4 | `getaddrinfo/freeaddrinfo/gai_strerror/getnameinfo` |
| **Pthread** | 70+ | Full `pthread_create/join/detach/mutex_*/cond_*/rwlock_*/spin_*/barrier_*/key_*/atfork` |
| **Dynamic loading** | 4 | `dlopen/dlsym/dlclose/dlerror` |
| **Passwd/Group** | 8 | `getpwuid/getpwnam/getpwuid_r/getpwnam_r/getgrgid/getgrnam/getgrgid_r/getgrnam_r` |
| **UUID** | 15+ | `uuid_generate/uuid_parse/uuid_unparse/uuid_compare/uuid_is_null/uuid_clear/uuid_copy/uuid_time` |
| **Locale/i18n** | 5 | `setlocale/localeconv/nl_langinfo/iconv_open/iconv/iconv_close` |
| **Errno** | Full | All 70+ POSIX errno values, `errno()` get/set |
| **Signal numbers** | Full | All standard signal numbers (SIG*), `Signal` enum |
| **FNMatch/Glob** | 4 | `fnmatch/glob/globfree` |
| **Uname/Sysinfo** | 5 | `uname/sysconf/pathconf/confstr/sysinfo` |
| **SysV IPC** | 15+ | `msgget/msgctl/msgsnd/msgrcv/semget/semctl/semop/semtimedop/shmget/shmat/shmdt/shmctl` |
| **Stdio** | 30+ | `fopen/fclose/fread/fwrite/fprintf/fscanf/fseek/ftell/fflush/popen/pclose/tmpfile/tmpnam` |
| **Stdlib** | 30+ | `malloc/free/calloc/realloc/abort/atexit/exit/getenv/putenv/system/qsort/bsearch/strtol/strtod` |
| **String** | 25+ | `memcpy/memmove/strcpy/strncpy/strcmp/strncmp/strcat/strchr/strrchr/strstr/strdup/strndup/strerror/strtok` |
| **Errno names** | Full | All `E*` constants |

Note: `core:os` already wraps most of these in a cross-platform API and uses **raw syscalls** (not libuv). Use `core:sys/posix` directly only for operations `core:os` doesn't cover (epoll, pthreads, signals, etc.) or when low-level control is needed.

**Important**: Because `core:os` uses raw syscalls directly (`linux.open`, `linux.read`, `linux.write`, `linux.close`), the `fileio.c` port can use `core:os` for all I/O operations with **zero C FFI**. Combined with Odin-native `make`/`delete` for buffer allocation, the entire `fileio.odin` depends on zero C functions — no `alloc_block`, no `free_block`, no `os_open`/`os_read`/`os_write` call wrappers.

#### Memory & Allocators

Odin's allocator system is a unified **interface dispatch** pattern. Every allocator is a struct with a `procedure` field (dispatch proc) and a `data` field (opaque state):

```odin
Allocator :: struct {
    procedure: Allocator_Proc,  // single proc handles Alloc/Free/Resize/FreeAll/...
    data:      rawptr,          // per-allocator instance data
}
```

The `context` struct carries **two** allocators — `context.allocator` (primary) and `context.temp_allocator` (scratch). `context` is an **implicit procedure parameter** (not a global, not thread-local) — automatically threaded through every non-`"contextless"` call. Simple swap:

```odin
arena: mem.virtual.Arena
virtual.arena_init_growing(&arena)
context.allocator = virtual.arena_allocator(&arena)
defer virtual.arena_destroy(&arena)
// All make/new/alloc now use the growing arena
```

| Odin Feature | What It Provides | Replaces C File/Pattern |
|---|---|---|
| `context.allocator` | Implicit proc-parameter allocator (default: `heap_allocator`) | All `xmalloc`/`xfree` |
| `context.temp_allocator` | Second allocator for scratch work (default: 4 MiB arena) | `alloc_block` scratch patterns |
| `new(T)` / `make([]T, n)` (built-in) | Heap allocation via `context.allocator` | `alloc()` / `xmalloc()` |
| `core:mem` | Allocator interface, copy, fill, zero, compare, alignment | `memcpy/memset/memcmp` |
| `core:mem/virtual` | Virtual-memory arena (growing/static/buffer) | `memory.c` entire arena system |
| `core:mem/allocators` | Arena, Dynamic_Arena, Scratch, Stack, Buddy, Pool | Custom allocators |
| `core:mem/tracking_allocator` | Leak detection via backing allocator wrapper | `alloc.c` debugging aids |
| `core:mem/tlsf` | O(1) TLSF real-time allocator | Specialized allocation |
| `core:mem/mutex_allocator` | Thread-safety wrapper | `uv_mutex_*` patterns |
| `core:mem/rollback_stack_allocator` | Growable LIFO with out-of-order free via rollback | Complex lifetime patterns |

##### Allocator Reference

| Allocator | Grows? | Free Individual? | Free All? | Overhead | Use Case |
|---|---|---|---|---|---|
| `mem.Arena` (buffer) | No | No | Yes (reset offset) | 0 bytes | Frame-local fixed-size pool |
| `mem.Dynamic_Arena` | **Yes** via backing allocator | No | Yes (reset or destroy) | ~0 + block metadata | Many small allocs, unknown lifetime |
| `mem.virtual.Arena` (Growing) | **Yes** via chained vm blocks | No | Yes (arena_destroy) | Virtual page granularity | Large/long-lived allocations |
| `mem.virtual.Arena` (Static) | No (single reservation) | No | Yes | Page granularity | Known max size, sparse commit |
| `mem.virtual.Arena` (Buffer) | No (user buffer) | No | Yes | 0 bytes | Wrapping existing memory |
| `mem.Scratch` | No (wraps to backup) | Partial (last + leaked) | Yes | 0 bytes | Ring-buffer, overwrite semantics |
| `mem.Stack` | No | LIFO only | Yes | ~8 bytes/alloc | Strict LIFO lifetime |
| `mem.Buddy` | No | Yes (coalescing) | Yes | ~8 bytes/block | Fixed buffer, frag-resistant |
| `mem.Rollback_Stack` | **Yes** via block allocator | Yes (rollback) | Yes | 8 bytes/alloc | Multi-block LIFO, O(1) alloc |
| `mem.Pool` | No | Yes | No | Fixed | Fixed-size objects |
| TLSF (`mem_tlsf.Allocator`) | **Yes** via backing allocator | Yes | No | ~8 bytes + bitmap | O(1) real-time, low fragmentation |
| `mem.Tracking` | Delegates to backing | Delegates | Delegates | map entry/alloc | Debug/leak detection |
| `mem.Mutex` | Delegates to backing | Delegates | Delegates | mutex/call | Thread-safety wrapper |
| `mem.Compat` | Delegates to backing | Delegates | Delegates | max(align, 16)/alloc | Wrapper for realloc compat |
| `heap_allocator` (default) | Yes (OS) | Yes | No | OS-dependent | General purpose |

##### Replacing Neovim's Arena Allocator

Neovim's custom arena (`memory.c`, `memory_defs.h`) can be replaced **wholesale** with Odin equivalents — no port needed, just substitution:

| Neovim Component | Odin Replacement | Notes |
|---|---|---|
| `ARENA_BLOCK_SIZE` (4096) | Configurable at init | `virtual.Arena` has no fixed block concept |
| `Arena` struct (`cur_blk`, `pos`, `size`) | `virtual.Arena` or `Dynamic_Arena` | Same bump-alloc + grow semantics |
| `alloc_block()` / `free_block()` | `make([]u8, n)` / `delete` or via arena | No freelist needed with growing arena |
| `arena_alloc(&a, size, align)` | `virtual.arena_alloc(&a, size, align)` | Same signature, same semantics |
| `arena_alloc_block()` | Automatic (arena grows transparently) | No explicit block management |
| `arena_finish()` / `arena_mem_free()` | `arena_destroy()` | Single call, freeing happens at end |
| `arena_alloc(NULL, size, align)` (heap fallback) | `context.allocator` or `heap_allocator()` | Built-in, no special case needed |
| `consumed_blk` linked list | Internal to virtual.Arena | Managed automatically |
| `arena_reuse_blk` freelist | Not needed | Growing arena reuses vm pages |
| `arena_temp` markers | `arena_temp_begin`/`arena_temp_end` | Same feature, same pattern |

**Key insight**: Porting Neovim's arena to Odin is **not necessary** — Odin's `virtual.Arena` (growing) and `Dynamic_Arena` (backing-allocator-based) already cover both use cases. The 6 standalone `alloc_block()` callers (`fileio.c`, `rstream.c`, `eval/funcs.c`, `api/ui.c`, `channel.c`) can be ported individually, each using `make`/`delete` or their own local arena.

##### Allocator Code Patterns

```odin
// Heap allocation (default)
ptr := new(int)
ptr^ = 42
free(ptr)
slice := make([]u8, 4096)
delete(slice)

// Arena (buffer-based, fixed size)
buffer := make([]u8, 1 * mem.Megabyte)
arena: mem.Arena
mem.arena_init(&arena, buffer)
context.allocator = mem.arena_allocator(&arena)
defer free_all(context.allocator)       // reset offset
// or: defer mem.arena_destroy(&arena)  // also frees buffer

// Growing arena (virtual memory, auto-grows)
varena: mem.virtual.Arena
mem.virtual.arena_init_growing(&varena)
defer mem.virtual.arena_destroy(&varena)
context.allocator = mem.virtual.arena_allocator(&varena)

// Scratch allocator (wrap-around temp)
scratch: mem.Scratch
mem.scratch_init(&scratch, 4 * mem.Megabyte, context.allocator)
defer mem.scratch_destroy(&scratch)
context.allocator = mem.scratch_allocator(&scratch)

// Leak detection (wraps any allocator)
track: mem.Tracking_Allocator
mem.tracking_allocator_init(&track, context.allocator)
defer mem.tracking_allocator_destroy(&track)
context.allocator = mem.tracking_allocator(&track)
for _, leak in track.allocation_map {
    fmt.eprintf("Leak: %v bytes at %v\n", leak.size, leak.location)
}

// Temp marker on arena (save/rollback)
tmp := mem.begin_arena_temp_memory(&arena)
// ... allocations that should be rolled back ...
mem.end_arena_temp_memory(tmp)  // restores arena offset

// Wrapping a C allocator (for FFI interop)
c_alloc_proc :: proc(data: rawptr, mode: Allocator_Mode,
                     size, alignment: int,
                     old_memory: rawptr, old_size: int,
                     loc := #caller_location) -> ([]byte, Allocator_Error) {
    switch mode {
    case .Alloc:
        ptr := c_malloc(size)
        return byte_slice(ptr, size), nil if ptr != nil else nil, .Out_Of_Memory
    case .Free:
        c_free(old_memory)
        return nil, nil
    // ...
    }
}
c_alloc := Allocator{procedure = c_alloc_proc, data = nil}

// Using context.temp_allocator for scratch data
temp := context.temp_allocator
scratch_buf := make([]u8, 256, temp)
defer free_all(temp)
```

#### Encoding & Serialization

| Odin Package | What It Provides | Replaces C File/Pattern |
|---|---|---|
| `core:encoding/base64` | Base64 encode/decode (RFC 4648) | `base64.c` |
| `core:encoding/json` | JSON encoder/decoder | `json.c` (eval JSON, API JSON) |
| `core:encoding/csv` | CSV reader/writer | CSV file handling |
| `core:encoding/ini` | INI reader/writer | Config file parsing |
| `core:encoding/cbor` | CBOR binary format | Binary serialization |
| `core:encoding/hex` | Hex encode/decode | `xxd`-like patterns |
| `core:encoding/varint` | Variable-length integer encoding | Binary protocol encoding |
| `core:encoding/uuid` | UUID generation/parsing | UUID creation |
| `core:encoding/pem` | PEM format encode/decode | Key/cert storage |

#### Hashing & Crypto

| Odin Package | What It Provides | Replaces C File/Pattern |
|---|---|---|
| `core:hash` | Adler-32, CRC-16/32/64 | `sha256.c`, crc32 usage |
| `core:hash/xxhash` | xxHash (fast, non-crypto) | Hashing for hashtables, bloom filters |
| `core:crypto/sha2` | SHA-224/256/384/512 | `sha256.c` |
| `core:crypto/hmac` | HMAC | Keyed hash authentication |

#### Math

| Odin Package | What It Provides | Replaces C File/Pattern |
|---|---|---|
| `core:math` | Trig, constants, abs, min, max, floor, ceil, round | `math.h` usage |
| `core:math/bits` | Popcount, leading/trailing zeros, rotate, byteswap | Bitwise operations |
| `core:math/big` | Big integers, rationals | `eval` big number support |
| `core:math/rand` | Random numbers (PCG, xoshiro256**, etc.) | `os/rand.c`, `uv_random` |

#### Terminal / UI

| Odin Package | What It Provides | Replaces C File/Pattern |
|---|---|---|
| `core:terminal` | Color depth, cursor control, raw mode, terminal size | `tui/input.c`, `tui/tui.c` terminal queries |
| `core:fmt` | `printf`/`sprintf`-style formatting | `vim_snprintf`, `msg()` output |

#### Compression

| Odin Package | What It Provides | Replaces C File/Pattern |
|---|---|---|
| `core:compress/gzip` | GZIP decompression (RFC 1952) | Undo file compression |
| `core:compress/zlib` | ZLIB decompression (RFC 1950) | Undo file compression |

#### Networking

| Odin Package | What It Provides | Replaces C File/Pattern |
|---|---|---|
| `core:net` | TCP/UDP sockets, DNS, addresses | `channel.c` socket I/O, `tcp_*` |
| `core:nbio` | Non-blocking I/O, polling, timers, async ops | `event/` loop multiqueue |
| `vendor:curl` | HTTP client (libcurl bindings) | `url.c`, HTTP requests |

#### Scripting (Phase 2)

| Odin Package | What It Provides | Replaces C File/Pattern |
|---|---|---|
| `vendor:lua/5.4` | Lua 5.4 bindings (ships with Odin compiler) | LuaJIT 5.1 |
| `vendor:lua/5.4/lua` | The actual Lua library (`liblua54.a`) | `libluajit.a` |

#### Not Available / Gaps

##### `core:nbio` vs libuv feature comparison

`core:nbio` is Odin's native async I/O framework (~10,500 lines, 19 files). It uses the best platform mechanism: **io_uring** on Linux, **kqueue** on BSD/macOS, **IOCP** on Windows. It is callback-driven with ahead-of-time `prep`/`exec` split for zero-alloc hot paths.

###### What nbio provides (can replace libuv for)

| Feature | nbio | Status |
|---|---|---|
| TCP accept/connect/send/recv | ✅ `nbio.accept/dial/recv/send` with vectored I/O | Ready |
| UDP send/recv | ✅ `nbio.send/recv` with `endpoint` field | Ready |
| File read/write (async, positional) | ✅ `nbio.read/write` (pread/pwrite semantics) | Ready |
| Zero-copy sendfile | ✅ `nbio.sendfile` with optional progress callbacks | Ready |
| Timers / next-tick | ✅ `nbio.timeout/next_tick` | Ready |
| Open file (async) | ✅ `nbio.open` (io_uring `openat` on Linux) | Limited |
| Stat (async) | ✅ `nbio.stat` (io_uring `statx` on Linux) | Limited |
| Polymorphic callbacks | ✅ Type-safe `poly/poly2/poly3` with compile-time size check | Superior to libuv |
| Vectored I/O | ✅ All recv/send support `[][]byte` | Superior |
| Composite ops | ✅ `read_entire_file` chains open+stat+read+close | Superior |
| Cross-thread submission | ✅ Lock-free MPSC queue | Superior |
| io_uring on Linux | ✅ Native, with configurable queue size | Superior |

###### What nbio is missing (libuv features with no nbio equivalent)

| Missing Feature | libuv API | Neovim Usage | Fallback Strategy |
|---|---|---|---|
| **File watching** | `uv_fs_event_t` (inotify/FSEvents/RDCW), `uv_fs_poll_t` | `src/nvim/watcher.c` — `dirwatcher` uses `uv_fs_event_t` | Keep C FFI for file watching |
| **Process spawning** | `uv_process_t`, `uv_spawn`, pipe stdin/stdout/stderr | `os/shell.c`, `os/proc.c` — shell commands, job control | Use `core:os.process_start` instead |
| **Signal handling** | `uv_signal_t` | `os/signal.c` — SIGWINCH, SIGTERM, etc. | Use `posix.sigaction` directly |
| **TTY handling** | `uv_tty_t` with raw mode, resize events | `tui/input.c`, `tui/tui.c` | Use `posix.tcgetattr/tcsetattr` |
| **DNS resolution** | `uv_getaddrinfo` (thread pool) | Channel/server initialization | Use `posix.getaddrinfo` (sync) |
| **Getaddrinfo** | `uv_getaddrinfo` | `channel.c` | Sync `posix.getaddrinfo` or thread pool |
| **Named pipes** | `uv_pipe_t` | IPC, `--listen`/`--server` | Use `posix.socket(AF_UNIX)` |
| **Thread pool / work queue** | `uv_queue_work` | `unibi_from_term` parsing | Use `core:thread` or `core:thread/pool` |
| **Idle/prepare/check handles** | `uv_idle_t`, `uv_prepare_t`, `uv_check_t` | Event loop phases | Use `nbio.next_tick` |
| **Handle close guarantee** | `uv_close` runs callback after resources freed | Cleanup patterns | `nbio.remove` requires same thread |
| **Dynamic buffer allocation** | `uv_alloc_cb` | Read callbacks | Caller must pre-allocate |
| **Comprehensive error codes** | ~80 error constants | Pervasive | ~10 `FS_Error` values |

**Summary**: `core:nbio` can replace libuv for **I/O operations** (TCP, UDP, file, timer), but has gaps for **OS integration** (process, signal, TTY, file watching, DNS). The port strategy is: use `nbio` for the event loop core and async I/O, use `core:os` + `core:sys/posix` for process/signal/TTY, and keep C FFI for file watching and DNS.

##### Other Gaps

| Missing Feature | Current C Dependency | Mitigation |
|---|---|---|
| `vendor:libtermkey` bindings | `tui/input.c`, terminal key encoding | Write foreign bindings; or port to `core:terminal` |
| `vendor:unibilium` bindings | Terminfo database access | Write foreign bindings; or read terminfo directly |
| `vendor:libvterm` bindings | Terminal emulation for TUI | Write foreign bindings; or port to `core:terminal` |
| LuaJIT FFI (`ffi.*`) | `noice.nvim` and user plugins | Provide `vim.ffi` shim via Odin's C interop |
| LuaJIT bytecode | Embedded `vim_module.generated.h` | Regenerate with Lua 5.4 bytecode |

#### Quick Reference: Startup Functions (Phase 0-1)

| Function | C File | What It Does | Odin Code |
|---|---|---|---|
| `appname_is_valid()` | `os/stdpaths.c` | Check `$NVIM_APPNAME` | `core:os.get_env("NVIM_APPNAME")` then `== "nvim"` |
| `init_startuptime()` | `main.c` | Wall clock `uint64_t` | `core:time.now()` → `core:time.duration_nanoseconds()` |
| `check_and_set_isatty()` | `main.c` | `isatty()` on 3 FDs | `core:terminal.is_terminal(handle)` |
| `init_homedir()` | `os/env.c` | Read `$HOME` | `core:os.get_env("HOME")`, `uv_os_homedir` FFI, `core:os.getwd` |
| `init_path()` | `main.c` | Path from `argv[0]` | `core:path/filepath.dir()` and `core:path/filepath.join()` |
| `highlight_init()` | `highlight.c` | Sentinel entry | Requires klib map/set in Odin — see §9.2c |
| `log_init()` | `log.c` | Open log file | `core:log` logger or `core:os.open()` |
| `set_lang_var()` | `os/lang.c` | Set `v:lang` | `core:os.get_env("LANG")`, assign via FFI |
| `init_params()` | `main.c` | Copy argc/argv | Direct struct field assignment |
| `estack_init()` | `runtime.c` | Pre-alloc execution stack | `make([]Entry, 0, 10)` |
| `cmdline_init()` | `ex_getln.c` | Zero cmdline struct | `cmdline: Cmdline{}` or zero struct |
| `init_normal_cmds()` | `normal.c` | Sort command table | `sort.quick(commands[:])` or `slice.sort(commands[:])` |

**Verification after each port**: `./nvim --version`, `./nvim -c "q"`, `make test` (functional tests only).

### 9.3 Phase 1: Port Standalone Utilities

| C File | Odin Replacement | Lines | Effort | Status |
|---|---|---|---|---|
| `src/nvim/os/fileio.c` | `core:os.open/read/write/close/sync` + `posix.readv` + alloc via `make`/`delete` | 397 | Low | **Next up** — zero FFI to C |
| `src/nvim/os/env.c` P1 — env access | `core:os.get_env/set_env/unset_env/lookup_env/environ` | 220 | Low | ✅ Ported (Phase A) |
| `src/nvim/os/env.c` P2 — homedir/pid/hostname | `core:os.get_pid/user_home_dir` + `posix.uname` | 110 | Low | ✅ Ported (Phase A) |
| `src/nvim/os/env.c` P3 — expand_env/home_replace/vim_getenv | `core:os.replace_environment_placeholders` + manual | 750 | Medium | Phase B — pending |
| `src/nvim/os/time.c` | `core:time` + `core:sys/posix` + `core:c/libc` | 216 | Low | ✅ Ported (9 of 11) |
| `src/nvim/os/dl.c` | `core:dynlib` (`load_library`/`symbol_address`/`unload_library`) | 86 | Low | ✅ Ported |
| `src/nvim/os/fs.c` (stat/mkdir/readdir/unlink/rename) | `core:os.stat/lstat/readdir/mkdir/remove/rename/exists` | ~500 | Low | ✅ Ported (52 symbols, Phases A+B) |
| `src/nvim/base64.c` | `core:encoding/base64` | 67 | Trivial | Ready |
| `src/nvim/os/rand.c` | `core:math/rand` (PCG, xoshiro256**) | ~100 | Low | Ready |
| `src/nvim/map_defs.h` / `map.c` (klib) | Odin `src/odin/klib.odin` → same algorithm, C-callable exports | 28 files | Critical | ✅ Ported |

**Strategy per file**:
1. Identify the C file's public API (functions, globals)
2. Write Odin file with exact same ABI (same function names, calling convention)
3. Remove the C `.o` from the static library link step
4. Add the Odin `.o` to the link step instead
5. Run test suite — all tests should pass

### 9.4 Phase 2: Lua Integration (months)

**Challenge**: Neovim uses **LuaJIT** (Lua 5.1 API). Odin ships **Lua 5.4** bindings (`vendor:lua/5.4`).
The migration requires patching C code, regenerating bytecode, and recompiling bundled Lua C modules.

#### 9.4a LuaJIT Dependency Depth — What Actually Breaks

**Critical finding: Neovim's own runtime (`runtime/lua/vim/`) uses ZERO LuaJIT FFI.**

The runtime uses `vim.*` C-provided functions and the RPC API exclusively. The FFI dependency is:

| Feature | Runtime Usage | Test Usage | Impact |
|---|---|---|---|
| `require('ffi')` | **None** (0 files) | Heavy (~100+ call sites in `test/unit/`) | Core OK, all unit tests need migration |
| `require('bit')` | 11 runtime files | 4 test files | **Already handled**: `bit.c` (Mike Pall's BitOp) is compiled when `PREFER_LUA=ON` |
| `jit.*` modules | **None** (0 files) | 2 test files | Need stub modules (`jit.profile`, `jit.util`) |
| `table.new` / `table.clear` | Fallback shim exists at `runtime/lua/vim/_core/table.lua` | — | **Already handled**: graceful fallback to pure Lua |
| **Bytecode** | `vim_module.generated.h` contains LuaJIT bytecode | — | Must regenerate with Lua 5.4 bytecode |

#### 9.4b C API Migration — Exact Files & Line Numbers

6 C files use Lua 5.1 C APIs that were **removed or changed** in Lua 5.4:

| C API Change | File | Line(s) | Replacement |
|---|---|---|---|
| `luaL_register()` → removed in Lua 5.3 | `src/bit.c` | 176 | `luaL_setfuncs()` |
| `luaL_register()` → removed in Lua 5.3 | `src/nvim/lua/stdlib.c` | 731 | `luaL_setfuncs()` |
| `luaL_register()` → removed in Lua 5.3 | `src/nvim/lua/spell.c` | 105 | `luaL_setfuncs()` |
| `luaL_register()` → removed in Lua 5.3 | `src/nvim/lua/base64.c` | 67 | `luaL_setfuncs()` |
| `luaL_register()` → removed in Lua 5.3 | `src/nvim/lua/treesitter.c` | 1780 | `luaL_setfuncs()` |
| `luaL_register()` → removed in Lua 5.3 | `src/mpack/lmpack.c` | 1179, 1185, 1191, 1215 | `luaL_setfuncs()` (mpack already has a compat shim at line 52) |
| `luaL_checkint()` → removed in Lua 5.3 | `src/nvim/lua/treesitter.c` | 835-840 | `luaL_checkinteger()` |
| `lua_objlen()` → removed in Lua 5.2 | `src/mpack/lmpack.c` | 217 | `lua_rawlen()` |
| `lua_objlen()` → removed in Lua 5.2 | `src/nvim/lua/xdiff.c` | 62 | `lua_rawlen()` |
| `lua_objlen()` → removed in Lua 5.2 | `src/nvim/lua/treesitter.c` | 636, 698, 1257, 1546 | `lua_rawlen()` |
| `luaL_prepbuffer()` → deprecated in 5.4 | `src/mpack/lmpack.c` | 782, 809, 1114, 1132 | `luaL_prepbuffsize()` |
| `luaL_prepbuffer()` → deprecated in 5.4 | `src/nvim/lua/xdiff.c` | 115 | `luaL_prepbuffsize()` |
| `luaL_Buffer` struct layout changed | `src/mpack/lmpack.c` | 773, 1093 | Stack-allocated buffer size adjustment |
| `luaL_Buffer` struct layout changed | `src/nvim/lua/xdiff.c` | 110, 308 | Stack-allocated buffer size adjustment |

**Estimated C patching effort**: 2-4 weeks for a developer familiar with both Lua API versions.

**Existing compat layers in bundled code** (already have `LUA_VERSION_NUM` guards):
- `src/cjson/lua_cjson.c` — handles 5.1-5.3+ differences (lua_objlen, lua_geti, lua_isinteger)
- `src/mpack/lmpack.c` — handles `luaL_register` → `luaL_setfuncs`, `lua_objlen` → `lua_rawlen`
- `src/bit.c` — handles `lua_tonumber` vs `luaL_checknumber` for <5.2

#### 9.4c How `vim.uv` Works (Key Architectural Insight)

`vim.uv` is implemented via the **luv** C library, **NOT via LuaJIT FFI**.

```
nvim C code → luaL_openlibs → luaopen_luv(L) → registers vim.uv table
             ↓
          luv C library (compiled against any Lua engine via lua_compat53)
             ↓
          libuv C library (event loop)
```

From `src/nvim/lua/executor.c:698-720`:
```c
luv_set_loop(lstate, &main_loop.uv);     // Share Neovim's event loop
luaopen_luv(lstate);                      // Open luv C bindings
lua_setfield(lstate, -3, "uv");           // vim.uv = luv module
```

luv uses `lua_compat53` to bridge API gaps and compiles against whatever Lua engine is selected. **No migration issue** — just recompile luv against Lua 5.4.

#### 9.4d Build System: Missing Lua 5.4 Support

Neovim's CMake build currently supports:
- `PREFER_LUA=ON` → finds and links PUC **Lua 5.1** (exact version match)
- Default → LuaJIT

**What needs adding for Lua 5.4**:
1. `cmake.deps/cmake/BuildLua54.cmake` — download/build recipe for Lua 5.4
2. `src/nvim/CMakeLists.txt` — Lua 5.4 detection path (find `lua5.4` / `liblua54`)
3. Updated `BuildLuv.cmake` — ensure lua_compat53 paths work with 5.4
4. `src/gen/gen_char_blob.lua` or equivalent — generate Lua 5.4 bytecode instead of LuaJIT bytecode

**With Odin**: Since we use `vendor:lua/5.4` (which links its own `liblua54.a`), we skip the CMake build recipe entirely. The Lua 5.4 library comes from the Odin compiler. We just need to:
1. Recompile bundled C libraries (luv, lpeg, mpack, cjson, bit) against Odin's `liblua54.a`
2. Generate Lua 5.4 bytecode for embedded modules

#### 9.4e Migrating `nlua_*` Interface to Odin

Instead of patching 6 C files for Lua 5.4 compat, we **replace the C executor with Odin** using `vendor:lua/5.4`. Odin's bindings already present the Lua 5.4 C API.

**Port these C files to Odin**:

| C File | Odin Replacement | Complexity | Notes |
|---|---|---|---|
| `src/nvim/lua/executor.c` | `src/odin/lua/executor.odin` | High (~2500 lines) | Core: nlua_init, nlua_exec, nlua_call_typval, Lua refs, API dispatch |
| `src/nvim/lua/converter.c` | `src/odin/lua/converter.odin` | High (~1250 lines) | Lua ↔ typval_T conversion |
| `src/nvim/lua/stdlib.c` | `src/odin/lua/stdlib.odin` | Medium | vim.* table population |
| `src/nvim/lua/secure.c` | `src/odin/lua/secure.odin` | Low | Sandboxing |
| `src/nvim/lua/base64.c` | `core:encoding/base64` | Trivial | |

**Key addition: `vim.ffi` shim for backward compat**.
Since Odin has excellent C interop, we can provide an FFI-like mechanism:
```odin
// In vim.ffi.odin — provides `vim.ffi` for Lua plugins
@(export)
luaopen_vim_ffi :: proc "c" (L: ^lua_5_4.State) -> c.int {
    // Register: vim.ffi.cdef, vim.ffi.new, vim.ffi.C, etc.
    // Delegate to Odin's foreign import system or libffi
}
```
This lets existing plugins that call `require('ffi')` keep working.

#### 9.4f Migration Steps Summary

```
1. Recompile luv/lpeg/mpack/cjson against vendor:lua/5.4's liblua54.a
2. Generate Lua 5.4 bytecode for embedded modules → vim_module.generated.h
3. Write Odin executor.odin (replaces executor.c)
4. Write Odin converter.odin (replaces converter.c)
5. Write Odin stdlib.odin (replaces stdlib.c)
6. Provide jit.* stub modules for test compatibility
7. Optionally provide vim.ffi shim via Odin FFI
8. Replace C .o files with Odin .o at link time
9. Run functional test suite
```

### 9.5 Phase 3: Event Loop (months)

**Challenge**: No official Odin `vendor:libuv` bindings exist.

**Approach**:
1. Write Odin foreign bindings for libuv in `src/odin/uv/uv.odin`
2. Port `src/nvim/event/` files one by one:
   - `loop.odin` — wraps libuv loop
   - `stream.odin` — wraps libuv streams
   - `socket.odin` — wraps libuv TCP handles
   - `proc.odin` — wraps libuv process management
   - `multiqueue.odin` — Odin-native implementation
   - `time.odin` — `core:time` + libuv timer
   - `signal.odin` — `core:os` signal handling
3. Each ported file replaces its C counterpart at link time

### 9.6 Phase 4+: Core Editor Subsystems

**Porting order** (least to most interconnected):

```
1. register.c, mark.c, digraph.c          ─ data containers
2. undo.c, fold.c                         ─ structured state machines
3. search.c, spell.c                      ─ algorithmic
4. option.c                               ─ key-value with callbacks
5. buffer.c, window.c                     ─ core data model
6. screen.c, drawline.c, grid.c           ─ rendering
7. eval/                                   ─ Vimscript engine (tightly coupled)
8. Everything else
```

Each subsystem port follows the same pattern:
1. Map the C structs to Odin structs
2. Port pure functions with no side effects first
3. Port functions that depend on global state
4. Replace C `.o` with Odin `.o` at link time
5. Run full test suite

### 9.7 Odin Source Layout

```
src/odin/
├── main.odin                     ─ Entry point
├── klib.odin                     ─ klib hash set/map replacement (C-callable exports)
├── build.sh                      ─ Build orchestrator
├── lua/
│   ├── executor.odin             ─ Lua interpreter management
│   ├── converter.odin            ─ Lua ↔ Vim value conversion
│   ├── stdlib.odin               ─ vim.* stdlib
│   └── secure.odin               ─ Sandboxing
├── uv/
│   └── uv.odin                   ─ libuv foreign bindings
├── event/
│   ├── loop.odin                 ─ Event loop
│   ├── stream.odin               ─ I/O streams
│   ├── socket.odin               ─ Networking
│   ├── proc.odin                 ─ Process management
│   ├── multiqueue.odin           ─ Event queue
│   ├── time.odin                 ─ Timers
│   └── signal.odin               ─ Signals
├── os/
│   ├── fs.odin                   ─ File system
│   ├── env.odin                  ─ Environment
│   ├── time.odin                 ─ Time utilities
│   └── dl.odin                   ─ Dynamic loading
└── tui/
    ├── tui.odin                  ─ Terminal UI driver
    ├── input.odin                ─ Terminal input
    ├── terminfo.odin             ─ Terminfo handling
    └── ugrid.odin               ─ Unified grid
```

---

## 10. Key Risks & Open Questions

| Risk | Impact | Mitigation |
|---|---|---|
| **LuaJIT vs Lua 5.4** | Core runtime uses **zero FFI** — all `vim.*` APIs and `vim.uv` go through C, not FFI. 6 C files use deprecated Lua 5.1 APIs (`luaL_register`, `luaL_checkint`, `lua_objlen`, `luaL_prepbuffer`). Embedded bytecode in `vim_module.generated.h` must be regenerated. Unit tests (~100+ FFI call sites) break completely. | Use Odin's `vendor:lua/5.4` which skips C API compat issues. Recompile luv/lpeg/mpack/cjson against 5.4. Regenerate bytecode. Provide optional `vim.ffi` shim via Odin's C FFI. Run functional tests only (skip unit tests). |
| **No vendor:libuv** | Must write and maintain libuv bindings | libuv C API is stable; ~100 functions to bind |
| **Code generation** | ~55 generated headers must be available for Odin compilation | Preserve existing Lua→C pipeline; generated files are just C headers Odin can `foreign import` against |
| **Global state** | ~2000+ global variables in Neovim make porting difficult | Port subsystem by subsystem; use Odin `package` globals as bridge, then refactor into struct-scoped state |
| **Test suite assumes C** | Unit tests test C functions directly; they won't work for Odin ports | Functional tests (busted/Lua) work regardless; write new Odin unit tests as needed |
| **Linking conflicts** | C and Odin both define `malloc` etc. | Use Odin's `-no-crt` flag or ensure CRT is only linked once |
| **Platform support** | Odin prebuilt `liblua54.a` only for linux/amd64 and Windows | Build Lua 5.4 from source for other platforms |
| **Performance regression** | Odin code may not match hand-tuned C initially | Profile after each port; Odin's data-oriented design can exceed C in many cases |

---

## 11. External References

**Neovim**:
- Source: https://github.com/neovim/neovim
- Build docs: https://github.com/neovim/neovim/blob/master/BUILD.md
- API docs: https://neovim.io/doc/user/api.html
- Lua guide: https://neovim.io/doc/user/lua-guide.html

**Odin**:
- Language docs: https://odin-lang.org/docs/overview/
- Standard library: https://pkg.odin-lang.org/
- Lua vendor package: https://pkg.odin-lang.org/vendor/lua/5.4/
- Vendor library list: https://pkg.odin-lang.org/vendor/

**C interop**:
- Odin FFI docs: https://odin-lang.org/docs/overview/#foreign-system
- Embedding C in Odin: https://glennyonemitsu.com/post/embedding-c-in-odin.html
- Embedding Lua in Odin: https://glennyonemitsu.com/post/embedding-lua-in-odin.html
- odin-c-bindgen: https://github.com/karl-zylinski/odin-c-bindgen

---

## Appendix A: Quick Start for Phase 0

### Check prerequisites
```bash
odin version      # Should show Odin version
cmake --version   # Should show 3.16+
which ninja       # Should be available
```

### Try a minimal Odin + Lua test
```bash
mkdir -p /tmp/odin_lua_test
cat > /tmp/odin_lua_test/main.odin << 'EOF'
package main
import "vendor:lua/5.4"
main :: proc() {
    L := lua_5_4.L_newstate()
    defer lua_5_4.close(L)
    lua_5_4.L_openlibs(L)
    lua_5_4.L_dostring(L, `print("Odin + Lua 5.4 works!")`)
}
EOF
cd /tmp/odin_lua_test && odin run .
```

### Build existing Neovim (verify it builds cleanly)
```bash
cd /home/rc/Projects/neovim
make CMAKE_BUILD_TYPE=Debug
./build/bin/nvim --version
```

### Create Odin sidecar project
```bash
mkdir -p /home/rc/Projects/neovim/src/odin
```
