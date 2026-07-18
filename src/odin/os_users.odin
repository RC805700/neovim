package main

import "core:c"
import "base:runtime"
import "core:sys/posix"
import "core:c/libc"

// C globals / helpers accessed by Odin
foreign _ {
	@(link_name = "xstrlcpy")
	_xstrlcpy :: proc(dst: cstring, src: cstring, dsize: c.size_t) -> c.size_t ---

	@(link_name = "ga_init")
	_ga_init :: proc(gap: ^Garray, itemsize: c.int, growsize: c.int) ---

	@(link_name = "ga_clear")
	_ga_clear :: proc(gap: ^Garray) ---

	@(link_name = "ga_clear_strings")
	_ga_clear_strings :: proc(gap: ^Garray) ---
}

// All user names (for ~user completion as done by shell).
ga_users: Garray = {ga_len = 0, ga_maxlen = 0, ga_itemsize = 0, ga_growsize = 1, ga_data = nil}

_cstr_empty :: proc(s: cstring) -> bool {
	return s == nil || ([^]byte)(s)[0] == 0
}

// Add a user name to the list of users in garray_T *users.
// Do nothing if user name is NULL or empty.
add_user :: proc(users: ^Garray, user: cstring, need_copy: bool) {
	context = runtime.default_context()
	user_copy := (user != nil && need_copy) ? _xstrdup(user) : user
	if user_copy == nil || _cstr_empty(user_copy) {
		if need_copy {
			xfree(rawptr(user_copy))
		}
		return
	}
	// GA_APPEND(char *, users, user_copy)
	ga_grow(users, 1)
	arr := ([^]cstring)(users.ga_data)
	arr[users.ga_len] = user_copy
	users.ga_len += 1
}

// Initialize users garray and fill it with os usernames.
// Return Ok for success, FAIL for failure.
@(export)
os_get_usernames :: proc "c" (users: ^Garray) -> c.int {
	context = runtime.default_context()
	if users == nil {
		return FAIL
	}
	_ga_init(users, c.int(size_of(cstring)), 20)

	posix.setpwent()
	for {
		pw := posix.getpwent()
		if pw == nil {
			break
		}
		add_user(users, pw.pw_name, true)
	}
	posix.endpwent()

	user_env := os_getenv_noalloc("USER")
	if user_env != nil && !_cstr_empty(user_env) {
		arr := ([^]cstring)(users.ga_data)
		found := false
		for i in 0 ..< users.ga_len {
			if libc.strcmp(arr[i], user_env) == 0 {
				found = true
				break
			}
		}
		if !found {
			pw := posix.getpwnam(user_env)
			if pw != nil {
				add_user(users, pw.pw_name, true)
			}
		}
	}

	return OK
}

// Gets the username that owns the current Nvim process.
@(export)
os_get_username :: proc "c" (s: cstring, len: c.size_t) -> c.int {
	return os_get_uname(c.uint(posix.getuid()), s, len)
}

// Gets the username associated with `uid`.
@(export)
os_get_uname :: proc "c" (uid: c.uint, s: cstring, len: c.size_t) -> c.int {
	context = runtime.default_context()
	pw := posix.getpwuid(posix.uid_t(uid))
	if pw != nil && pw.pw_name != nil && !_cstr_empty(pw.pw_name) {
		_xstrlcpy(s, pw.pw_name, len)
		return OK
	}
	// snprintf(s, len, "%d", (int)uid)
	dp := ([^]byte)(s)
	n := uid
	if n == 0 {
		dp[0] = '0'
		dp[1] = 0
	} else {
		buf: [32]byte
		i := 0
		tmp := n
		for tmp > 0 {
			buf[i] = byte('0' + (tmp % 10))
			tmp /= 10
			i += 1
		}
		for j := 0; j < i; j += 1 {
			dp[j] = buf[i - 1 - j]
		}
		dp[i] = 0
	}
	return FAIL
}

// Gets the user directory for the given username, or NULL on failure.
// Caller must free() the returned string.
@(export)
os_get_userdir :: proc "c" (name: cstring) -> cstring {
	context = runtime.default_context()
	if _cstr_empty(name) {
		return nil
	}
	pw := posix.getpwnam(name)
	if pw != nil {
		return _xstrdup(pw.pw_dir)
	}
	return nil
}

@(export)
free_users :: proc "c" () {
	_ga_clear_strings(&ga_users)
}

// Find all user names for user completion. Done only once and then cached.
did_init_users := false

init_users :: proc() {
	if did_init_users {
		return
	}
	did_init_users = true
	context = runtime.default_context()
	os_get_usernames(&ga_users)
}

@(export)
get_users :: proc "c" (xp: rawptr, idx: c.int) -> cstring {
	context = runtime.default_context()
	init_users()
	if idx < ga_users.ga_len {
		arr := ([^]cstring)(ga_users.ga_data)
		return arr[idx]
	}
	return nil
}

@(export)
match_user :: proc "c" (name: cstring) -> c.int {
	context = runtime.default_context()
	n := libc.strlen(name)
	result: c.int = 0

	init_users()
	arr := ([^]cstring)(ga_users.ga_data)
	for i in 0 ..< ga_users.ga_len {
		if libc.strcmp(arr[i], name) == 0 {
			return 2
		}
		if libc.strncmp(arr[i], name, n) == 0 {
			result = 1
		}
	}
	return result
}
