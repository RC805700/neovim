package main

import "base:runtime"
import "core:c"
import "core:c/libc"

MH_TOMBSTONE :: u32(0xFFFFFFFF)

UPPER_FILL :: 0.77

roundup32 :: #force_inline proc "contextless" (x: ^u32) {
  x^ -= 1
  x^ |= x^ >> 1
  x^ |= x^ >> 2
  x^ |= x^ >> 4
  x^ |= x^ >> 8
  x^ |= x^ >> 16
  x^ += 1
}

MapHash :: struct {
  n_buckets:     u32,
  size:          u32,
  n_occupied:    u32,
  upper_bound:   u32,
  n_keys:        u32,
  keys_capacity: u32,
  hash:          [^]u32,
}

MHPutStatus :: enum c.int {
  kMHExisting = 0,
  kMHNewKeyDidFit,
  kMHNewKeyRealloc,
}

/// ─── memory (C allocator) ───

@(default_calling_convention = "c")
foreign _ {
  @(link_name = "xcalloc")
  _xcalloc :: proc(nmemb: c.size_t, size: c.size_t) -> rawptr ---
  @(link_name = "xrealloc")
  _xrealloc :: proc(ptr: rawptr, size: c.size_t) -> rawptr ---
  @(link_name = "xfree")
  _xfree :: proc(ptr: rawptr) ---
  @(link_name = "path_fnamencmp")
  _path_fnamencmp :: proc(a, b: cstring, n: c.int) -> c.int ---
}


/// ─── mh_realloc ───

@(export)
mh_realloc :: proc "c" (h: ^MapHash, n_min_buckets: u32) {
  if h.hash != nil {
    _xfree(h.hash)
  }
  n_buckets := n_min_buckets < 16 ? 16 : n_min_buckets
  roundup32(&n_buckets)
  h.hash = ([^]u32)(_xcalloc(c.size_t(n_buckets), c.size_t(size_of(u32))))
  h.n_occupied = 0
  h.size = 0
  h.n_buckets = n_buckets
  h.upper_bound = u32(f64(n_buckets) * UPPER_FILL + 0.5)
}

/// ─── generic set procedures ───
/// Uses $S for the Set struct type, $T for the key type.
/// S must have fields { h: MapHash, keys: [^]T }.

mh_find_bucket :: proc "contextless" (
  set: ^$S,
  key: $T,
  hash: proc "contextless" (_: T) -> u32,
  equal: proc "contextless" (_: T, _: T) -> bool,
  put: bool,
) -> u32 {
  h := cast(^MapHash)set
  step: u32 = 0
  mask := h.n_buckets - 1
  k := hash(key)
  i := k & mask
  last := i
  site := put ? last : MH_TOMBSTONE

  for !mh_is_empty(h, i) {
    if mh_is_del(h, i) {
      if site == last {
        site = i
      }
    } else {
      pos := h.hash[i] - 1
      ks := cast(^S)set
      if equal(ks.keys[pos], key) {
        return i
      }
    }
    step += 1
    i = (i + step) & mask
    if i == last {
      return site
    }
  }

  if site == last {
    site = i
  }
  return site
}

mh_get :: proc "contextless" (
  set: ^$S,
  key: $T,
  hash: proc "contextless" (_: T) -> u32,
  equal: proc "contextless" (_: T, _: T) -> bool,
) -> u32 {
  h := cast(^MapHash)set
  if h.n_buckets == 0 {
    return MH_TOMBSTONE
  }
  idx := mh_find_bucket(set, key, hash, equal, false)
  if idx != MH_TOMBSTONE {
    return h.hash[idx] - 1
  }
  return MH_TOMBSTONE
}

mh_rehash :: proc "contextless" (
  set: ^$S,
  hash: proc "contextless" (_: $T) -> u32,
  equal: proc "contextless" (_: T, _: T) -> bool,
) {
  ks := cast(^S)set
  for k in 0 ..< ks.h.n_keys {
    idx := mh_find_bucket(set, ks.keys[k], hash, equal, true)
    ks.h.hash[idx] = k + 1
  }
  ks.h.n_occupied = ks.h.n_keys
  ks.h.size = ks.h.n_keys
}

mh_put :: proc "contextless" (
  set: ^$S,
  key: $T,
  new: ^MHPutStatus,
  hash: proc "contextless" (_: T) -> u32,
  equal: proc "contextless" (_: T, _: T) -> bool,
  key_size: u32,
) -> u32 {
  h := cast(^MapHash)set

  if h.n_occupied >= h.upper_bound {
    if u64(h.size) >= u64(h.upper_bound) * 9 / 10 {
      mh_realloc(h, h.n_buckets + 1)
    } else {
      libc.memset(h.hash, 0, c.size_t(h.n_buckets) * c.size_t(size_of(u32)))
      h.size = 0
      h.n_occupied = 0
    }
    mh_rehash(set, hash, equal)
  }

  idx := mh_find_bucket(set, key, hash, equal, true)

  if mh_is_either(h, idx) {
    h.size += 1
    if mh_is_empty(h, idx) {
      h.n_occupied += 1
    }

    pos := h.n_keys
    h.n_keys += 1
    if pos >= h.keys_capacity {
      new_cap := h.keys_capacity * 2
      if new_cap < 8 {new_cap = 8}
      h.keys_capacity = new_cap
      ks := cast(^S)set
      new_keys := ([^]u8)(_xrealloc(ks.keys, c.size_t(new_cap) * c.size_t(key_size)))
      ks.keys = ([^]T)(new_keys)
      new^ = .kMHNewKeyRealloc
    } else {
      new^ = .kMHNewKeyDidFit
    }
    ks := cast(^S)set
    ks.keys[pos] = key
    h.hash[idx] = pos + 1
    return pos
  } else {
    new^ = .kMHExisting
    return h.hash[idx] - 1
  }
}

mh_delete :: proc "contextless" (
  set: ^$S,
  key: $T,
  hash: proc "contextless" (_: T) -> u32,
  equal: proc "contextless" (_: T, _: T) -> bool,
) -> (u32, T) {
  h := cast(^MapHash)set
  if h.size == 0 {
    return MH_TOMBSTONE, key
  }
  idx := mh_find_bucket(set, key, hash, equal, false)
  if idx == MH_TOMBSTONE {
    return MH_TOMBSTONE, key
  }
  ks := cast(^S)set
  k := h.hash[idx] - 1
  old_key := ks.keys[k]
  h.hash[idx] = MH_TOMBSTONE
  last := h.n_keys - 1
  h.n_keys = last
  h.size -= 1
  if last != k {
    idx2 := mh_find_bucket(set, ks.keys[last], hash, equal, false)
    h.hash[idx2] = k + 1
    ks.keys[k] = ks.keys[last]
  }
  return k, old_key
}


@(export)
mh_clear :: proc "c" (h: ^MapHash) {
  if h.hash != nil {
    libc.memset(h.hash, 0, c.size_t(h.n_buckets) * c.size_t(size_of(u32)))
    h.size = 0
    h.n_occupied = 0
    h.n_keys = 0
  }
}


/// ─── helpers ───

mh_is_empty :: #force_inline proc "contextless" (h: ^MapHash, i: u32) -> bool {
  return h.hash[i] == 0
}

mh_is_del :: #force_inline proc "contextless" (h: ^MapHash, i: u32) -> bool {
  return h.hash[i] == MH_TOMBSTONE
}

mh_is_either :: #force_inline proc "contextless" (h: ^MapHash, i: u32) -> bool {
  return h.hash[i] + 1 <= 1
}

/// ─── hash / equal per type ───

hash_uint64_t :: proc "contextless" (key: u64) -> u32 {
  return u32((key >> 33) ~ key ~ (key << 11))
}

equal_uint64_t :: proc "contextless" (a, b: u64) -> bool {return a == b}

hash_uint32_t :: proc "contextless" (key: u32) -> u32 {return key}
equal_uint32_t :: proc "contextless" (a, b: u32) -> bool {return a == b}

hash_int :: proc "contextless" (key: c.int) -> u32 {return u32(key)}
equal_int :: proc "contextless" (a, b: c.int) -> bool {return a == b}

hash_int64_t :: proc "contextless" (key: i64) -> u32 {return hash_uint64_t(u64(key))}
equal_int64_t :: proc "contextless" (a, b: i64) -> bool {return a == b}

hash_ptr_t :: proc "contextless" (key: rawptr) -> u32 {
  return hash_uint64_t(u64(uintptr(key)))
}
equal_ptr_t :: proc "contextless" (a, b: rawptr) -> bool {return a == b}

hash_cstr_t :: proc "contextless" (s: cstring) -> u32 {
  h: u32 = 0
  b := ([^]byte)(s)
  i: u32 = 0
  for b[i] != 0 {
    h = (h << 5) - h + u32(b[i])
    i += 1
  }
  return h
}

equal_cstr_t :: proc "contextless" (a, b: cstring) -> bool {
  return libc.strcmp(a, b) == 0
}

hash_path_t :: proc "contextless" (p: cstring) -> u32 {
  return hash_cstr_t(p)
}

equal_path_t :: proc "contextless" (a, b: cstring) -> bool {
  if a == b {return true}
  if a == nil || b == nil {return false}
  la := libc.strlen(a)
  lb := libc.strlen(b)
  n := la > lb ? la : lb
  return _path_fnamencmp(a, b, c.int(n)) == 0
}

hash_String :: proc "contextless" (s: String) -> u32 {
  h: u32 = 0
  b := ([^]byte)(s.data)
  for i in 0 ..< s.size {
    h = (h << 5) - h + u32(b[i])
  }
  return h
}

equal_String :: proc "contextless" (a, b: String) -> bool {
  if a.size != b.size {return false}
  if a.size == 0 {return true}
  return libc.memcmp(rawptr(a.data), rawptr(b.data), c.size_t(a.size)) == 0
}

hash_HlEntry :: proc "contextless" (ae: HlEntry) -> u32 {
  local := ae
  data := ([^]u8)(&local)
  h: u32 = 0
  for i in 0 ..< size_of(HlEntry) {
    h = (h << 5) - h + u32(data[i])
  }
  return h
}

equal_HlEntry :: proc "contextless" (ae1, ae2: HlEntry) -> bool {
  a := ae1
  b := ae2
  return libc.memcmp(&a, &b, c.size_t(size_of(HlEntry))) == 0
}

hash_ColorKey :: proc "contextless" (key: ColorKey) -> u32 {
  local := key
  data := ([^]u8)(&local)
  h: u32 = 0
  for i in 0 ..< size_of(ColorKey) {
    h = (h << 5) - h + u32(data[i])
  }
  return h
}

equal_ColorKey :: proc "contextless" (ak, bk: ColorKey) -> bool {
  a := ak; b := bk
  return libc.memcmp(&a, &b, c.size_t(size_of(ColorKey))) == 0
}

/// ─── Set type mirrors ───

Set_HlEntry :: struct {
  h:    MapHash,
  keys: [^]HlEntry,
}

Set_uint64_t :: struct {
  h:    MapHash,
  keys: [^]u64,
}

Set_int64_t :: struct {
  h:    MapHash,
  keys: [^]i64,
}

Set_int :: struct {
  h:    MapHash,
  keys: [^]c.int,
}

Set_uint32_t :: struct {
  h:    MapHash,
  keys: [^]u32,
}

Set_cstr_t :: struct {
  h:    MapHash,
  keys: [^]cstring,
}

Set_path_t :: struct {
  h:    MapHash,
  keys: [^]cstring,
}

Set_ptr_t :: struct {
  h:    MapHash,
  keys: [^]rawptr,
}

Set_String :: struct {
  h:    MapHash,
  keys: [^]String,
}

Set_ColorKey :: struct {
  h:    MapHash,
  keys: [^]ColorKey,
}

/// ─── Map type mirrors ───

Map_uint64_t_int :: struct {
  set:    Set_uint64_t,
  values: [^]c.int,
}

Map_uint64_t_ptr_t :: struct {
  set:    Set_uint64_t,
  values: [^]rawptr,
}

Map_uint64_t_MTDamagePair :: struct {
  set:    Set_uint64_t,
  values: [^]MTDamagePair,
}

Map_int_ptr_t :: struct {
  set:    Set_int,
  values: [^]rawptr,
}

Map_int_String :: struct {
  set:    Set_int,
  values: [^]String,
}

Map_int_StcClick :: struct {
  set:    Set_int,
  values: [^]StcClick,
}

Map_int_StcClicks :: struct {
  set:    Set_int,
  values: [^]StcClicks,
}

Map_cstr_t_ptr_t :: struct {
  set:    Set_cstr_t,
  values: [^]rawptr,
}

Map_cstr_t_int :: struct {
  set:    Set_cstr_t,
  values: [^]c.int,
}

Map_ptr_t_ptr_t :: struct {
  set:    Set_ptr_t,
  values: [^]rawptr,
}

Map_uint32_t_ptr_t :: struct {
  set:    Set_uint32_t,
  values: [^]rawptr,
}

Map_uint32_t_uint32_t :: struct {
  set:    Set_uint32_t,
  values: [^]u32,
}

Map_int64_t_ptr_t :: struct {
  set:    Set_int64_t,
  values: [^]rawptr,
}

Map_int64_t_int64_t :: struct {
  set:    Set_int64_t,
  values: [^]i64,
}

Map_String_int :: struct {
  set:    Set_String,
  values: [^]c.int,
}

Map_ColorKey_ColorItem :: struct {
  set:    Set_ColorKey,
  values: [^]ColorItem,
}

/// PMap(type) aliases
PMap_int :: Map_int_ptr_t
PMap_cstr_t :: Map_cstr_t_ptr_t
PMap_ptr_t :: Map_ptr_t_ptr_t
PMap_uint32_t :: Map_uint32_t_ptr_t
PMap_uint64_t :: Map_uint64_t_ptr_t
PMap_int64_t :: Map_int64_t_ptr_t

/// ─── HlEntry exports ───

@(export)
mh_find_bucket_HlEntry :: proc "c" (set: ^Set_HlEntry, key: HlEntry, put: bool) -> u32 {
  return mh_find_bucket(set, key, hash_HlEntry, equal_HlEntry, put)
}

@(export)
mh_get_HlEntry :: proc "c" (set: ^Set_HlEntry, key: HlEntry) -> u32 {
  return mh_get(set, key, hash_HlEntry, equal_HlEntry)
}

@(export)
mh_rehash_HlEntry :: proc "c" (set: ^Set_HlEntry) {
  mh_rehash(set, hash_HlEntry, equal_HlEntry)
}

@(export)
mh_put_HlEntry :: proc "c" (set: ^Set_HlEntry, key: HlEntry, new: ^MHPutStatus) -> u32 {
  return mh_put(set, key, new, hash_HlEntry, equal_HlEntry, size_of(HlEntry))
}

@(export)
mh_delete_HlEntry :: proc "c" (set: ^Set_HlEntry, key: HlEntry) -> u32 {
  k, _ := mh_delete(set, key, hash_HlEntry, equal_HlEntry); return k
}

/// ─── uint64_t exports (set + maps) ───

@(export)
mh_find_bucket_uint64_t :: proc "c" (set: ^Set_uint64_t, key: u64, put: bool) -> u32 {
  return mh_find_bucket(set, key, hash_uint64_t, equal_uint64_t, put)
}

@(export)
mh_get_uint64_t :: proc "c" (set: ^Set_uint64_t, key: u64) -> u32 {
  return mh_get(set, key, hash_uint64_t, equal_uint64_t)
}

@(export)
mh_rehash_uint64_t :: proc "c" (set: ^Set_uint64_t) {
  mh_rehash(set, hash_uint64_t, equal_uint64_t)
}

@(export)
mh_put_uint64_t :: proc "c" (set: ^Set_uint64_t, key: u64, new: ^MHPutStatus) -> u32 {
  return mh_put(set, key, new, hash_uint64_t, equal_uint64_t, size_of(u64))
}

@(export)
mh_delete_uint64_t :: proc "c" (set: ^Set_uint64_t, key: u64) -> u32 {
  k, _ := mh_delete(set, key, hash_uint64_t, equal_uint64_t); return k
}

@(export)
map_put_ref_uint64_t_int :: proc "c" (
  mp: ^Map_uint64_t_int,
  key: u64,
  key_alloc: ^^u64,
  new_item: ^bool,
) -> ^c.int {
  s := (^Set_uint64_t)(&mp.set)
  st: MHPutStatus
  k := mh_put(s, key, &st, hash_uint64_t, equal_uint64_t, size_of(u64))
  if st == .kMHNewKeyRealloc {
    mp.values = ([^]c.int)(_xrealloc(rawptr(mp.values), c.size_t(s.h.keys_capacity) * size_of(c.int)))
  }
  if st != .kMHExisting {
    if new_item != nil {new_item^ = true}
    mp.values[k] = {}
  } else {
    if new_item != nil {new_item^ = false}
  }
  if key_alloc != nil {
    key_alloc^ = &s.keys[k]
  }
  return &mp.values[k]
}

@(export)
map_ref_uint64_t_int :: proc "c" (mp: ^Map_uint64_t_int, key: u64, key_alloc: ^^u64) -> ^c.int {
  k := mh_get((^Set_uint64_t)(&mp.set), key, hash_uint64_t, equal_uint64_t)
  if k == MH_TOMBSTONE {return nil}
  if key_alloc != nil {
    key_alloc^ = &mp.set.keys[k]
  }
  return &mp.values[k]
}

@(export)
map_del_uint64_t_int :: proc "c" (mp: ^Map_uint64_t_int, key: u64, key_alloc: ^u64) -> c.int {
  set := (^Set_uint64_t)(&mp.set)
  k, old_key := mh_delete(set, key, hash_uint64_t, equal_uint64_t)
  if k == MH_TOMBSTONE {return 0}
  ret_val := mp.values[k]
  if k != (cast(^MapHash)set).n_keys {
    mp.values[k] = mp.values[(cast(^MapHash)set).n_keys]
  }
  if key_alloc != nil {
    key_alloc^ = old_key
  }
  return ret_val
}

@(export)
map_put_ref_uint64_t_ptr_t :: proc "c" (
  mp: ^Map_uint64_t_ptr_t,
  key: u64,
  key_alloc: ^^u64,
  new_item: ^bool,
) -> ^rawptr {
  s := (^Set_uint64_t)(&mp.set)
  st: MHPutStatus
  k := mh_put(s, key, &st, hash_uint64_t, equal_uint64_t, size_of(u64))
  if st == .kMHNewKeyRealloc {
    mp.values = ([^]rawptr)(_xrealloc(rawptr(mp.values), c.size_t(s.h.keys_capacity) * size_of(rawptr)))
  }
  if st != .kMHExisting {
    if new_item != nil {new_item^ = true}
    mp.values[k] = {}
  } else {
    if new_item != nil {new_item^ = false}
  }
  if key_alloc != nil {
    key_alloc^ = &s.keys[k]
  }
  return &mp.values[k]
}

@(export)
map_ref_uint64_t_ptr_t :: proc "c" (mp: ^Map_uint64_t_ptr_t, key: u64, key_alloc: ^^u64) -> ^rawptr {
  k := mh_get((^Set_uint64_t)(&mp.set), key, hash_uint64_t, equal_uint64_t)
  if k == MH_TOMBSTONE {return nil}
  if key_alloc != nil {
    key_alloc^ = &mp.set.keys[k]
  }
  return &mp.values[k]
}

@(export)
map_del_uint64_t_ptr_t :: proc "c" (mp: ^Map_uint64_t_ptr_t, key: u64, key_alloc: ^u64) -> rawptr {
  set := (^Set_uint64_t)(&mp.set)
  k, old_key := mh_delete(set, key, hash_uint64_t, equal_uint64_t)
  if k == MH_TOMBSTONE {return nil}
  ret_val := mp.values[k]
  if k != (cast(^MapHash)set).n_keys {
    mp.values[k] = mp.values[(cast(^MapHash)set).n_keys]
  }
  if key_alloc != nil {
    key_alloc^ = old_key
  }
  return ret_val
}

@(export)
map_put_ref_uint64_t_MTDamagePair :: proc "c" (
  mp: ^Map_uint64_t_MTDamagePair,
  key: u64,
  key_alloc: ^^u64,
  new_item: ^bool,
) -> ^MTDamagePair {
  s := (^Set_uint64_t)(&mp.set)
  st: MHPutStatus
  k := mh_put(s, key, &st, hash_uint64_t, equal_uint64_t, size_of(u64))
  if st == .kMHNewKeyRealloc {
    mp.values = ([^]MTDamagePair)(_xrealloc(rawptr(mp.values), c.size_t(s.h.keys_capacity) * size_of(MTDamagePair)))
  }
  if st != .kMHExisting {
    if new_item != nil {new_item^ = true}
    mp.values[k] = {}
  } else {
    if new_item != nil {new_item^ = false}
  }
  if key_alloc != nil {
    key_alloc^ = &s.keys[k]
  }
  return &mp.values[k]
}

@(export)
map_ref_uint64_t_MTDamagePair :: proc "c" (
  mp: ^Map_uint64_t_MTDamagePair,
  key: u64,
  key_alloc: ^^u64,
) -> ^MTDamagePair {
  k := mh_get((^Set_uint64_t)(&mp.set), key, hash_uint64_t, equal_uint64_t)
  if k == MH_TOMBSTONE {return nil}
  if key_alloc != nil {
    key_alloc^ = &mp.set.keys[k]
  }
  return &mp.values[k]
}

@(export)
map_del_uint64_t_MTDamagePair :: proc "c" (
  mp: ^Map_uint64_t_MTDamagePair,
  key: u64,
  key_alloc: ^u64,
) -> MTDamagePair {
  set := (^Set_uint64_t)(&mp.set)
  k, old_key := mh_delete(set, key, hash_uint64_t, equal_uint64_t)
  if k == MH_TOMBSTONE {return {}}
  ret_val := mp.values[k]
  if k != (cast(^MapHash)set).n_keys {
    mp.values[k] = mp.values[(cast(^MapHash)set).n_keys]
  }
  if key_alloc != nil {
    key_alloc^ = old_key
  }
  return ret_val
}

/// ─── cstr_t exports (set + maps) ───

@(export)
mh_find_bucket_cstr_t :: proc "c" (set: ^Set_cstr_t, key: cstring, put: bool) -> u32 {
  return mh_find_bucket(set, key, hash_cstr_t, equal_cstr_t, put)
}

@(export)
mh_get_cstr_t :: proc "c" (set: ^Set_cstr_t, key: cstring) -> u32 {
  return mh_get(set, key, hash_cstr_t, equal_cstr_t)
}

@(export)
mh_rehash_cstr_t :: proc "c" (set: ^Set_cstr_t) {
  mh_rehash(set, hash_cstr_t, equal_cstr_t)
}

@(export)
mh_put_cstr_t :: proc "c" (set: ^Set_cstr_t, key: cstring, new: ^MHPutStatus) -> u32 {
  return mh_put(set, key, new, hash_cstr_t, equal_cstr_t, size_of(cstring))
}

@(export)
mh_delete_cstr_t :: proc "c" (set: ^Set_cstr_t, key: cstring) -> u32 {
  k, _ := mh_delete(set, key, hash_cstr_t, equal_cstr_t); return k
}

@(export)
map_put_ref_cstr_t_ptr_t :: proc "c" (
  mp: ^Map_cstr_t_ptr_t,
  key: cstring,
  key_alloc: ^^cstring,
  new_item: ^bool,
) -> ^rawptr {
  s := (^Set_cstr_t)(&mp.set)
  st: MHPutStatus
  k := mh_put(s, key, &st, hash_cstr_t, equal_cstr_t, size_of(cstring))
  if st == .kMHNewKeyRealloc {
    mp.values = ([^]rawptr)(_xrealloc(rawptr(mp.values), c.size_t(s.h.keys_capacity) * size_of(rawptr)))
  }
  if st != .kMHExisting {
    if new_item != nil {new_item^ = true}
    mp.values[k] = {}
  } else {
    if new_item != nil {new_item^ = false}
  }
  if key_alloc != nil {
    key_alloc^ = &s.keys[k]
  }
  return &mp.values[k]
}

@(export)
map_ref_cstr_t_ptr_t :: proc "c" (
  mp: ^Map_cstr_t_ptr_t,
  key: cstring,
  key_alloc: ^^cstring,
) -> ^rawptr {
  k := mh_get((^Set_cstr_t)(&mp.set), key, hash_cstr_t, equal_cstr_t)
  if k == MH_TOMBSTONE {return nil}
  if key_alloc != nil {
    key_alloc^ = &mp.set.keys[k]
  }
  return &mp.values[k]
}

@(export)
map_del_cstr_t_ptr_t :: proc "c" (
  mp: ^Map_cstr_t_ptr_t,
  key: cstring,
  key_alloc: ^cstring,
) -> rawptr {
  set := (^Set_cstr_t)(&mp.set)
  k, old_key := mh_delete(set, key, hash_cstr_t, equal_cstr_t)
  if k == MH_TOMBSTONE {return nil}
  ret_val := mp.values[k]
  if k != (cast(^MapHash)set).n_keys {
    mp.values[k] = mp.values[(cast(^MapHash)set).n_keys]
  }
  if key_alloc != nil {
    key_alloc^ = old_key
  }
  return ret_val
}

@(export)
map_put_ref_cstr_t_int :: proc "c" (
  mp: ^Map_cstr_t_int,
  key: cstring,
  key_alloc: ^^cstring,
  new_item: ^bool,
) -> ^c.int {
  s := (^Set_cstr_t)(&mp.set)
  st: MHPutStatus
  k := mh_put(s, key, &st, hash_cstr_t, equal_cstr_t, size_of(cstring))
  if st == .kMHNewKeyRealloc {
    mp.values = ([^]c.int)(_xrealloc(rawptr(mp.values), c.size_t(s.h.keys_capacity) * size_of(c.int)))
  }
  if st != .kMHExisting {
    if new_item != nil {new_item^ = true}
    mp.values[k] = {}
  } else {
    if new_item != nil {new_item^ = false}
  }
  if key_alloc != nil {
    key_alloc^ = &s.keys[k]
  }
  return &mp.values[k]
}

@(export)
map_ref_cstr_t_int :: proc "c" (
  mp: ^Map_cstr_t_int,
  key: cstring,
  key_alloc: ^^cstring,
) -> ^c.int {
  k := mh_get((^Set_cstr_t)(&mp.set), key, hash_cstr_t, equal_cstr_t)
  if k == MH_TOMBSTONE {return nil}
  if key_alloc != nil {
    key_alloc^ = &mp.set.keys[k]
  }
  return &mp.values[k]
}

@(export)
map_del_cstr_t_int :: proc "c" (mp: ^Map_cstr_t_int, key: cstring, key_alloc: ^cstring) -> c.int {
  set := (^Set_cstr_t)(&mp.set)
  k, old_key := mh_delete(set, key, hash_cstr_t, equal_cstr_t)
  if k == MH_TOMBSTONE {return 0}
  ret_val := mp.values[k]
  if k != (cast(^MapHash)set).n_keys {
    mp.values[k] = mp.values[(cast(^MapHash)set).n_keys]
  }
  if key_alloc != nil {
    key_alloc^ = old_key
  }
  return ret_val
}

/// ─── int exports (set + maps) ───

@(export)
mh_find_bucket_int :: proc "c" (set: ^Set_int, key: c.int, put: bool) -> u32 {
  return mh_find_bucket(set, key, hash_int, equal_int, put)
}

@(export)
mh_get_int :: proc "c" (set: ^Set_int, key: c.int) -> u32 {
  return mh_get(set, key, hash_int, equal_int)
}

@(export)
mh_rehash_int :: proc "c" (set: ^Set_int) {
  mh_rehash(set, hash_int, equal_int)
}

@(export)
mh_put_int :: proc "c" (set: ^Set_int, key: c.int, new: ^MHPutStatus) -> u32 {
  return mh_put(set, key, new, hash_int, equal_int, size_of(c.int))
}

@(export)
mh_delete_int :: proc "c" (set: ^Set_int, key: c.int) -> u32 {
  k, _ := mh_delete(set, key, hash_int, equal_int); return k
}

@(export)
map_put_ref_int_ptr_t :: proc "c" (
  mp: ^Map_int_ptr_t,
  key: c.int,
  key_alloc: ^^c.int,
  new_item: ^bool,
) -> ^rawptr {
  s := (^Set_int)(&mp.set)
  st: MHPutStatus
  k := mh_put(s, key, &st, hash_int, equal_int, size_of(c.int))
  if st == .kMHNewKeyRealloc {
    mp.values = ([^]rawptr)(_xrealloc(rawptr(mp.values), c.size_t(s.h.keys_capacity) * size_of(rawptr)))
  }
  if st != .kMHExisting {
    if new_item != nil {new_item^ = true}
    mp.values[k] = {}
  } else {
    if new_item != nil {new_item^ = false}
  }
  if key_alloc != nil {
    key_alloc^ = &s.keys[k]
  }
  return &mp.values[k]
}

@(export)
map_ref_int_ptr_t :: proc "c" (mp: ^Map_int_ptr_t, key: c.int, key_alloc: ^^c.int) -> ^rawptr {
  k := mh_get((^Set_int)(&mp.set), key, hash_int, equal_int)
  if k == MH_TOMBSTONE {return nil}
  if key_alloc != nil {
    key_alloc^ = &mp.set.keys[k]
  }
  return &mp.values[k]
}

@(export)
map_del_int_ptr_t :: proc "c" (mp: ^Map_int_ptr_t, key: c.int, key_alloc: ^c.int) -> rawptr {
  set := (^Set_int)(&mp.set)
  k, old_key := mh_delete(set, key, hash_int, equal_int)
  if k == MH_TOMBSTONE {return nil}
  ret_val := mp.values[k]
  if k != (cast(^MapHash)set).n_keys {
    mp.values[k] = mp.values[(cast(^MapHash)set).n_keys]
  }
  if key_alloc != nil {
    key_alloc^ = old_key
  }
  return ret_val
}

/// ─── ptr_t exports (set + maps) ───

@(export)
mh_find_bucket_ptr_t :: proc "c" (set: ^Set_ptr_t, key: rawptr, put: bool) -> u32 {
  return mh_find_bucket(set, key, hash_ptr_t, equal_ptr_t, put)
}

@(export)
mh_get_ptr_t :: proc "c" (set: ^Set_ptr_t, key: rawptr) -> u32 {
  return mh_get(set, key, hash_ptr_t, equal_ptr_t)
}

@(export)
mh_rehash_ptr_t :: proc "c" (set: ^Set_ptr_t) {
  mh_rehash(set, hash_ptr_t, equal_ptr_t)
}

@(export)
mh_put_ptr_t :: proc "c" (set: ^Set_ptr_t, key: rawptr, new: ^MHPutStatus) -> u32 {
  return mh_put(set, key, new, hash_ptr_t, equal_ptr_t, size_of(rawptr))
}

@(export)
mh_delete_ptr_t :: proc "c" (set: ^Set_ptr_t, key: rawptr) -> u32 {
  k, _ := mh_delete(set, key, hash_ptr_t, equal_ptr_t); return k
}

@(export)
map_put_ref_ptr_t_ptr_t :: proc "c" (
  mp: ^Map_ptr_t_ptr_t,
  key: rawptr,
  key_alloc: ^^rawptr,
  new_item: ^bool,
) -> ^rawptr {
  s := (^Set_ptr_t)(&mp.set)
  st: MHPutStatus
  k := mh_put(s, key, &st, hash_ptr_t, equal_ptr_t, size_of(rawptr))
  if st == .kMHNewKeyRealloc {
    mp.values = ([^]rawptr)(_xrealloc(rawptr(mp.values), c.size_t(s.h.keys_capacity) * size_of(rawptr)))
  }
  if st != .kMHExisting {
    if new_item != nil {new_item^ = true}
    mp.values[k] = {}
  } else {
    if new_item != nil {new_item^ = false}
  }
  if key_alloc != nil {
    key_alloc^ = &s.keys[k]
  }
  return &mp.values[k]
}

@(export)
map_ref_ptr_t_ptr_t :: proc "c" (mp: ^Map_ptr_t_ptr_t, key: rawptr, key_alloc: ^^rawptr) -> ^rawptr {
  k := mh_get((^Set_ptr_t)(&mp.set), key, hash_ptr_t, equal_ptr_t)
  if k == MH_TOMBSTONE {return nil}
  if key_alloc != nil {
    key_alloc^ = &mp.set.keys[k]
  }
  return &mp.values[k]
}

@(export)
map_del_ptr_t_ptr_t :: proc "c" (mp: ^Map_ptr_t_ptr_t, key: rawptr, key_alloc: ^rawptr) -> rawptr {
  set := (^Set_ptr_t)(&mp.set)
  k, old_key := mh_delete(set, key, hash_ptr_t, equal_ptr_t)
  if k == MH_TOMBSTONE {return nil}
  ret_val := mp.values[k]
  if k != (cast(^MapHash)set).n_keys {
    mp.values[k] = mp.values[(cast(^MapHash)set).n_keys]
  }
  if key_alloc != nil {
    key_alloc^ = old_key
  }
  return ret_val
}

/// ─── ColorKey exports (set + map) ───

@(export)
mh_find_bucket_ColorKey :: proc "c" (set: ^Set_ColorKey, key: ColorKey, put: bool) -> u32 {
  return mh_find_bucket(set, key, hash_ColorKey, equal_ColorKey, put)
}

@(export)
mh_get_ColorKey :: proc "c" (set: ^Set_ColorKey, key: ColorKey) -> u32 {
  return mh_get(set, key, hash_ColorKey, equal_ColorKey)
}

@(export)
mh_rehash_ColorKey :: proc "c" (set: ^Set_ColorKey) {
  mh_rehash(set, hash_ColorKey, equal_ColorKey)
}

@(export)
mh_put_ColorKey :: proc "c" (set: ^Set_ColorKey, key: ColorKey, new: ^MHPutStatus) -> u32 {
  return mh_put(set, key, new, hash_ColorKey, equal_ColorKey, size_of(ColorKey))
}

@(export)
mh_delete_ColorKey :: proc "c" (set: ^Set_ColorKey, key: ColorKey) -> u32 {
  k, _ := mh_delete(set, key, hash_ColorKey, equal_ColorKey); return k
}

@(export)
map_put_ref_ColorKey_ColorItem :: proc "c" (
  mp: ^Map_ColorKey_ColorItem,
  key: ColorKey,
  key_alloc: ^^ColorKey,
  new_item: ^bool,
) -> ^ColorItem {
  s := (^Set_ColorKey)(&mp.set)
  st: MHPutStatus
  k := mh_put(s, key, &st, hash_ColorKey, equal_ColorKey, size_of(ColorKey))
  if st == .kMHNewKeyRealloc {
    mp.values = ([^]ColorItem)(_xrealloc(rawptr(mp.values), c.size_t(s.h.keys_capacity) * size_of(ColorItem)))
  }
  if st != .kMHExisting {
    if new_item != nil {new_item^ = true}
    mp.values[k] = {}
  } else {
    if new_item != nil {new_item^ = false}
  }
  if key_alloc != nil {
    key_alloc^ = &s.keys[k]
  }
  return &mp.values[k]
}

@(export)
map_ref_ColorKey_ColorItem :: proc "c" (
  mp: ^Map_ColorKey_ColorItem,
  key: ColorKey,
  key_alloc: ^^ColorKey,
) -> ^ColorItem {
  k := mh_get((^Set_ColorKey)(&mp.set), key, hash_ColorKey, equal_ColorKey)
  if k == MH_TOMBSTONE {return nil}
  if key_alloc != nil {
    key_alloc^ = &mp.set.keys[k]
  }
  return &mp.values[k]
}

@(export)
map_del_ColorKey_ColorItem :: proc "c" (
  mp: ^Map_ColorKey_ColorItem,
  key: ColorKey,
  key_alloc: ^ColorKey,
) -> ColorItem {
  set := (^Set_ColorKey)(&mp.set)
  k, old_key := mh_delete(set, key, hash_ColorKey, equal_ColorKey)
  if k == MH_TOMBSTONE {return {}}
  ret_val := mp.values[k]
  if k != (cast(^MapHash)set).n_keys {
    mp.values[k] = mp.values[(cast(^MapHash)set).n_keys]
  }
  if key_alloc != nil {
    key_alloc^ = old_key
  }
  return ret_val
}

/// ─── String exports (set + map) ───

@(export)
mh_find_bucket_String :: proc "c" (set: ^Set_String, key: String, put: bool) -> u32 {
  return mh_find_bucket(set, key, hash_String, equal_String, put)
}

@(export)
mh_get_String :: proc "c" (set: ^Set_String, key: String) -> u32 {
  return mh_get(set, key, hash_String, equal_String)
}

@(export)
mh_rehash_String :: proc "c" (set: ^Set_String) {
  mh_rehash(set, hash_String, equal_String)
}

@(export)
mh_put_String :: proc "c" (set: ^Set_String, key: String, new: ^MHPutStatus) -> u32 {
  return mh_put(set, key, new, hash_String, equal_String, size_of(String))
}

@(export)
mh_delete_String :: proc "c" (set: ^Set_String, key: String) -> u32 {
  k, _ := mh_delete(set, key, hash_String, equal_String); return k
}

/// ─── String maps ───

@(export)
map_put_ref_String_int :: proc "c" (
  mp: ^Map_String_int,
  key: String,
  key_alloc: ^^String,
  new_item: ^bool,
) -> ^c.int {
  s := (^Set_String)(&mp.set)
  st: MHPutStatus
  k := mh_put(s, key, &st, hash_String, equal_String, size_of(String))
  if st == .kMHNewKeyRealloc {
    mp.values = ([^]c.int)(_xrealloc(rawptr(mp.values), c.size_t(s.h.keys_capacity) * size_of(c.int)))
  }
  if st != .kMHExisting {
    if new_item != nil {new_item^ = true}
    mp.values[k] = {}
  } else {
    if new_item != nil {new_item^ = false}
  }
  if key_alloc != nil {
    key_alloc^ = &s.keys[k]
  }
  return &mp.values[k]
}

@(export)
map_ref_String_int :: proc "c" (mp: ^Map_String_int, key: String, key_alloc: ^^String) -> ^c.int {
  k := mh_get((^Set_String)(&mp.set), key, hash_String, equal_String)
  if k == MH_TOMBSTONE {return nil}
  if key_alloc != nil {
    key_alloc^ = &mp.set.keys[k]
  }
  return &mp.values[k]
}

@(export)
map_del_String_int :: proc "c" (mp: ^Map_String_int, key: String, key_alloc: ^String) -> c.int {
  set := (^Set_String)(&mp.set)
  k, old_key := mh_delete(set, key, hash_String, equal_String)
  if k == MH_TOMBSTONE {return 0}
  ret_val := mp.values[k]
  if k != (cast(^MapHash)set).n_keys {
    mp.values[k] = mp.values[(cast(^MapHash)set).n_keys]
  }
  if key_alloc != nil {
    key_alloc^ = old_key
  }
  return ret_val
}

/// ─── pmap_del2 ───

@(export)
pmap_del2 :: proc "c" (mp: ^PMap_cstr_t, key: cstring) {
  key_alloc: cstring
  val := map_del_cstr_t_ptr_t(mp, key, &key_alloc)
  _xfree(rawptr(key_alloc))
  _xfree(val)
}


/// ─── int exports (maps for StcClick / StcClicks / String) ───

@(export)
map_put_ref_int_String :: proc "c" (
  mp: ^Map_int_String,
  key: c.int,
  key_alloc: ^^c.int,
  new_item: ^bool,
) -> ^String {
  s := (^Set_int)(&mp.set)
  st: MHPutStatus
  k := mh_put(s, key, &st, hash_int, equal_int, size_of(c.int))
  if st == .kMHNewKeyRealloc {
    mp.values = ([^]String)(_xrealloc(rawptr(mp.values), c.size_t(s.h.keys_capacity) * size_of(String)))
  }
  if st != .kMHExisting {
    if new_item != nil {new_item^ = true}
    mp.values[k] = {}
  } else {
    if new_item != nil {new_item^ = false}
  }
  if key_alloc != nil {
    key_alloc^ = &s.keys[k]
  }
  return &mp.values[k]
}

@(export)
map_ref_int_String :: proc "c" (mp: ^Map_int_String, key: c.int, key_alloc: ^^c.int) -> ^String {
  k := mh_get((^Set_int)(&mp.set), key, hash_int, equal_int)
  if k == MH_TOMBSTONE {return nil}
  if key_alloc != nil {
    key_alloc^ = &mp.set.keys[k]
  }
  return &mp.values[k]
}

@(export)
map_del_int_String :: proc "c" (mp: ^Map_int_String, key: c.int, key_alloc: ^c.int) -> String {
  set := (^Set_int)(&mp.set)
  k, old_key := mh_delete(set, key, hash_int, equal_int)
  if k == MH_TOMBSTONE {return {}}
  ret_val := mp.values[k]
  if k != (cast(^MapHash)set).n_keys {
    mp.values[k] = mp.values[(cast(^MapHash)set).n_keys]
  }
  if key_alloc != nil {
    key_alloc^ = old_key
  }
  return ret_val
}

@(export)
map_put_ref_int_StcClick :: proc "c" (
  mp: ^Map_int_StcClick,
  key: c.int,
  key_alloc: ^^c.int,
  new_item: ^bool,
) -> ^StcClick {
  s := (^Set_int)(&mp.set)
  st: MHPutStatus
  k := mh_put(s, key, &st, hash_int, equal_int, size_of(c.int))
  if st == .kMHNewKeyRealloc {
    mp.values = ([^]StcClick)(_xrealloc(rawptr(mp.values), c.size_t(s.h.keys_capacity) * size_of(StcClick)))
  }
  if st != .kMHExisting {
    if new_item != nil {new_item^ = true}
    mp.values[k] = {}
  } else {
    if new_item != nil {new_item^ = false}
  }
  if key_alloc != nil {
    key_alloc^ = &s.keys[k]
  }
  return &mp.values[k]
}

@(export)
map_ref_int_StcClick :: proc "c" (mp: ^Map_int_StcClick, key: c.int, key_alloc: ^^c.int) -> ^StcClick {
  k := mh_get((^Set_int)(&mp.set), key, hash_int, equal_int)
  if k == MH_TOMBSTONE {return nil}
  if key_alloc != nil {
    key_alloc^ = &mp.set.keys[k]
  }
  return &mp.values[k]
}

@(export)
map_del_int_StcClick :: proc "c" (mp: ^Map_int_StcClick, key: c.int, key_alloc: ^c.int) -> StcClick {
  set := (^Set_int)(&mp.set)
  k, old_key := mh_delete(set, key, hash_int, equal_int)
  if k == MH_TOMBSTONE {return {}}
  ret_val := mp.values[k]
  if k != (cast(^MapHash)set).n_keys {
    mp.values[k] = mp.values[(cast(^MapHash)set).n_keys]
  }
  if key_alloc != nil {
    key_alloc^ = old_key
  }
  return ret_val
}

@(export)
map_put_ref_int_StcClicks :: proc "c" (
  mp: ^Map_int_StcClicks,
  key: c.int,
  key_alloc: ^^c.int,
  new_item: ^bool,
) -> ^StcClicks {
  s := (^Set_int)(&mp.set)
  st: MHPutStatus
  k := mh_put(s, key, &st, hash_int, equal_int, size_of(c.int))
  if st == .kMHNewKeyRealloc {
    mp.values = ([^]StcClicks)(_xrealloc(rawptr(mp.values), c.size_t(s.h.keys_capacity) * size_of(StcClicks)))
  }
  if st != .kMHExisting {
    if new_item != nil {new_item^ = true}
    mp.values[k] = {}
  } else {
    if new_item != nil {new_item^ = false}
  }
  if key_alloc != nil {
    key_alloc^ = &s.keys[k]
  }
  return &mp.values[k]
}

@(export)
map_ref_int_StcClicks :: proc "c" (mp: ^Map_int_StcClicks, key: c.int, key_alloc: ^^c.int) -> ^StcClicks {
  k := mh_get((^Set_int)(&mp.set), key, hash_int, equal_int)
  if k == MH_TOMBSTONE {return nil}
  if key_alloc != nil {
    key_alloc^ = &mp.set.keys[k]
  }
  return &mp.values[k]
}

@(export)
map_del_int_StcClicks :: proc "c" (mp: ^Map_int_StcClicks, key: c.int, key_alloc: ^c.int) -> StcClicks {
  set := (^Set_int)(&mp.set)
  k, old_key := mh_delete(set, key, hash_int, equal_int)
  if k == MH_TOMBSTONE {return {}}
  ret_val := mp.values[k]
  if k != (cast(^MapHash)set).n_keys {
    mp.values[k] = mp.values[(cast(^MapHash)set).n_keys]
  }
  if key_alloc != nil {
    key_alloc^ = old_key
  }
  return ret_val
}

/// ─── int64_t exports (set + maps) ───

@(export)
mh_find_bucket_int64_t :: proc "c" (set: ^Set_int64_t, key: i64, put: bool) -> u32 {
  return mh_find_bucket(set, key, hash_int64_t, equal_int64_t, put)
}

@(export)
mh_get_int64_t :: proc "c" (set: ^Set_int64_t, key: i64) -> u32 {
  return mh_get(set, key, hash_int64_t, equal_int64_t)
}

@(export)
mh_rehash_int64_t :: proc "c" (set: ^Set_int64_t) {
  mh_rehash(set, hash_int64_t, equal_int64_t)
}

@(export)
mh_put_int64_t :: proc "c" (set: ^Set_int64_t, key: i64, new: ^MHPutStatus) -> u32 {
  return mh_put(set, key, new, hash_int64_t, equal_int64_t, size_of(i64))
}

@(export)
mh_delete_int64_t :: proc "c" (set: ^Set_int64_t, key: i64) -> u32 {
  k, _ := mh_delete(set, key, hash_int64_t, equal_int64_t); return k
}

@(export)
map_put_ref_int64_t_int64_t :: proc "c" (
  mp: ^Map_int64_t_int64_t,
  key: i64,
  key_alloc: ^^i64,
  new_item: ^bool,
) -> ^i64 {
  s := (^Set_int64_t)(&mp.set)
  st: MHPutStatus
  k := mh_put(s, key, &st, hash_int64_t, equal_int64_t, size_of(i64))
  if st == .kMHNewKeyRealloc {
    mp.values = ([^]i64)(_xrealloc(rawptr(mp.values), c.size_t(s.h.keys_capacity) * size_of(i64)))
  }
  if st != .kMHExisting {
    if new_item != nil {new_item^ = true}
    mp.values[k] = {}
  } else {
    if new_item != nil {new_item^ = false}
  }
  if key_alloc != nil {
    key_alloc^ = &s.keys[k]
  }
  return &mp.values[k]
}

@(export)
map_ref_int64_t_int64_t :: proc "c" (mp: ^Map_int64_t_int64_t, key: i64, key_alloc: ^^i64) -> ^i64 {
  k := mh_get((^Set_int64_t)(&mp.set), key, hash_int64_t, equal_int64_t)
  if k == MH_TOMBSTONE {return nil}
  if key_alloc != nil {
    key_alloc^ = &mp.set.keys[k]
  }
  return &mp.values[k]
}

@(export)
map_del_int64_t_int64_t :: proc "c" (mp: ^Map_int64_t_int64_t, key: i64, key_alloc: ^i64) -> i64 {
  set := (^Set_int64_t)(&mp.set)
  k, old_key := mh_delete(set, key, hash_int64_t, equal_int64_t)
  if k == MH_TOMBSTONE {return 0}
  ret_val := mp.values[k]
  if k != (cast(^MapHash)set).n_keys {
    mp.values[k] = mp.values[(cast(^MapHash)set).n_keys]
  }
  if key_alloc != nil {
    key_alloc^ = old_key
  }
  return ret_val
}

@(export)
map_put_ref_int64_t_ptr_t :: proc "c" (
  mp: ^Map_int64_t_ptr_t,
  key: i64,
  key_alloc: ^^i64,
  new_item: ^bool,
) -> ^rawptr {
  s := (^Set_int64_t)(&mp.set)
  st: MHPutStatus
  k := mh_put(s, key, &st, hash_int64_t, equal_int64_t, size_of(i64))
  if st == .kMHNewKeyRealloc {
    mp.values = ([^]rawptr)(_xrealloc(rawptr(mp.values), c.size_t(s.h.keys_capacity) * size_of(rawptr)))
  }
  if st != .kMHExisting {
    if new_item != nil {new_item^ = true}
    mp.values[k] = {}
  } else {
    if new_item != nil {new_item^ = false}
  }
  if key_alloc != nil {
    key_alloc^ = &s.keys[k]
  }
  return &mp.values[k]
}

@(export)
map_ref_int64_t_ptr_t :: proc "c" (mp: ^Map_int64_t_ptr_t, key: i64, key_alloc: ^^i64) -> ^rawptr {
  k := mh_get((^Set_int64_t)(&mp.set), key, hash_int64_t, equal_int64_t)
  if k == MH_TOMBSTONE {return nil}
  if key_alloc != nil {
    key_alloc^ = &mp.set.keys[k]
  }
  return &mp.values[k]
}

@(export)
map_del_int64_t_ptr_t :: proc "c" (mp: ^Map_int64_t_ptr_t, key: i64, key_alloc: ^i64) -> rawptr {
  set := (^Set_int64_t)(&mp.set)
  k, old_key := mh_delete(set, key, hash_int64_t, equal_int64_t)
  if k == MH_TOMBSTONE {return nil}
  ret_val := mp.values[k]
  if k != (cast(^MapHash)set).n_keys {
    mp.values[k] = mp.values[(cast(^MapHash)set).n_keys]
  }
  if key_alloc != nil {
    key_alloc^ = old_key
  }
  return ret_val
}

/// ─── uint32_t exports (set + maps) ───

@(export)
mh_find_bucket_uint32_t :: proc "c" (set: ^Set_uint32_t, key: u32, put: bool) -> u32 {
  return mh_find_bucket(set, key, hash_uint32_t, equal_uint32_t, put)
}

@(export)
mh_get_uint32_t :: proc "c" (set: ^Set_uint32_t, key: u32) -> u32 {
  return mh_get(set, key, hash_uint32_t, equal_uint32_t)
}

@(export)
mh_rehash_uint32_t :: proc "c" (set: ^Set_uint32_t) {
  mh_rehash(set, hash_uint32_t, equal_uint32_t)
}

@(export)
mh_put_uint32_t :: proc "c" (set: ^Set_uint32_t, key: u32, new: ^MHPutStatus) -> u32 {
  return mh_put(set, key, new, hash_uint32_t, equal_uint32_t, size_of(u32))
}

@(export)
mh_delete_uint32_t :: proc "c" (set: ^Set_uint32_t, key: u32) -> u32 {
  k, _ := mh_delete(set, key, hash_uint32_t, equal_uint32_t); return k
}

@(export)
map_put_ref_uint32_t_ptr_t :: proc "c" (
  mp: ^Map_uint32_t_ptr_t,
  key: u32,
  key_alloc: ^^u32,
  new_item: ^bool,
) -> ^rawptr {
  s := (^Set_uint32_t)(&mp.set)
  st: MHPutStatus
  k := mh_put(s, key, &st, hash_uint32_t, equal_uint32_t, size_of(u32))
  if st == .kMHNewKeyRealloc {
    mp.values = ([^]rawptr)(_xrealloc(rawptr(mp.values), c.size_t(s.h.keys_capacity) * size_of(rawptr)))
  }
  if st != .kMHExisting {
    if new_item != nil {new_item^ = true}
    mp.values[k] = {}
  } else {
    if new_item != nil {new_item^ = false}
  }
  if key_alloc != nil {
    key_alloc^ = &s.keys[k]
  }
  return &mp.values[k]
}

@(export)
map_ref_uint32_t_ptr_t :: proc "c" (mp: ^Map_uint32_t_ptr_t, key: u32, key_alloc: ^^u32) -> ^rawptr {
  k := mh_get((^Set_uint32_t)(&mp.set), key, hash_uint32_t, equal_uint32_t)
  if k == MH_TOMBSTONE {return nil}
  if key_alloc != nil {
    key_alloc^ = &mp.set.keys[k]
  }
  return &mp.values[k]
}

@(export)
map_del_uint32_t_ptr_t :: proc "c" (mp: ^Map_uint32_t_ptr_t, key: u32, key_alloc: ^u32) -> rawptr {
  set := (^Set_uint32_t)(&mp.set)
  k, old_key := mh_delete(set, key, hash_uint32_t, equal_uint32_t)
  if k == MH_TOMBSTONE {return nil}
  ret_val := mp.values[k]
  if k != (cast(^MapHash)set).n_keys {
    mp.values[k] = mp.values[(cast(^MapHash)set).n_keys]
  }
  if key_alloc != nil {
    key_alloc^ = old_key
  }
  return ret_val
}

@(export)
map_put_ref_uint32_t_uint32_t :: proc "c" (
  mp: ^Map_uint32_t_uint32_t,
  key: u32,
  key_alloc: ^^u32,
  new_item: ^bool,
) -> ^u32 {
  s := (^Set_uint32_t)(&mp.set)
  st: MHPutStatus
  k := mh_put(s, key, &st, hash_uint32_t, equal_uint32_t, size_of(u32))
  if st == .kMHNewKeyRealloc {
    mp.values = ([^]u32)(_xrealloc(rawptr(mp.values), c.size_t(s.h.keys_capacity) * size_of(u32)))
  }
  if st != .kMHExisting {
    if new_item != nil {new_item^ = true}
    mp.values[k] = {}
  } else {
    if new_item != nil {new_item^ = false}
  }
  if key_alloc != nil {
    key_alloc^ = &s.keys[k]
  }
  return &mp.values[k]
}

@(export)
map_ref_uint32_t_uint32_t :: proc "c" (mp: ^Map_uint32_t_uint32_t, key: u32, key_alloc: ^^u32) -> ^u32 {
  k := mh_get((^Set_uint32_t)(&mp.set), key, hash_uint32_t, equal_uint32_t)
  if k == MH_TOMBSTONE {return nil}
  if key_alloc != nil {
    key_alloc^ = &mp.set.keys[k]
  }
  return &mp.values[k]
}

@(export)
map_del_uint32_t_uint32_t :: proc "c" (mp: ^Map_uint32_t_uint32_t, key: u32, key_alloc: ^u32) -> u32 {
  set := (^Set_uint32_t)(&mp.set)
  k, old_key := mh_delete(set, key, hash_uint32_t, equal_uint32_t)
  if k == MH_TOMBSTONE {return 0}
  ret_val := mp.values[k]
  if k != (cast(^MapHash)set).n_keys {
    mp.values[k] = mp.values[(cast(^MapHash)set).n_keys]
  }
  if key_alloc != nil {
    key_alloc^ = old_key
  }
  return ret_val
}

/// ─── path_t exports (set only) ───

@(export)
mh_find_bucket_path_t :: proc "c" (set: ^Set_path_t, key: cstring, put: bool) -> u32 {
  return mh_find_bucket(set, key, hash_path_t, equal_path_t, put)
}

@(export)
mh_get_path_t :: proc "c" (set: ^Set_path_t, key: cstring) -> u32 {
  return mh_get(set, key, hash_path_t, equal_path_t)
}

@(export)
mh_rehash_path_t :: proc "c" (set: ^Set_path_t) {
  mh_rehash(set, hash_path_t, equal_path_t)
}

@(export)
mh_put_path_t :: proc "c" (set: ^Set_path_t, key: cstring, new: ^MHPutStatus) -> u32 {
  return mh_put(set, key, new, hash_path_t, equal_path_t, size_of(cstring))
}

@(export)
mh_delete_path_t :: proc "c" (set: ^Set_path_t, key: cstring) -> u32 {
  k, _ := mh_delete(set, key, hash_path_t, equal_path_t); return k
}
