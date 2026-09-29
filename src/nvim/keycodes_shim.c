// keycodes_shim.c: hosts the GENERATED key-names table + gperf hash for the
// Odin port (src/odin/keycodes.odin). Generated DATA stays in C (funcs_shim.c
// precedent); all lookup LOGIC is Odin. Auto-globbed into libnvim.

#include <stdbool.h>
#include <stddef.h>

#include "nvim/api/private/defs.h"
#include "nvim/keycodes.h"
#include "nvim/strings.h"

#include "keycode_names.generated.h"

// Number of entries in key_names_table.
int nvim_odin_key_names_count(void)
{
  return (int)(sizeof(key_names_table) / sizeof(key_names_table[0]));
}

// Per-index access for find_special_key_in_table's linear walk.
// Sets *is_alt, *name_data, *name_size; returns the key code.
int nvim_odin_key_at(int idx, bool *is_alt, const char **name_data, size_t *name_size)
{
  *is_alt = key_names_table[idx].is_alt;
  *name_data = key_names_table[idx].name.data;
  *name_size = key_names_table[idx].name.size;
  return key_names_table[idx].key;
}

// Generated perfect-hash lookup for get_special_key_code.
int nvim_odin_key_code_hash(const char *name, size_t len)
{
  return get_special_key_code_hash(name, len);
}
