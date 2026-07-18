package main

import "core:c"

foreign _ {
	@(link_name = "uv_get_total_memory")
	_uv_get_total_memory :: proc() -> u64 ---
}

@(export)
os_get_total_mem_kib :: proc "c" () -> u64 {
	return _uv_get_total_memory() / 1024
}
