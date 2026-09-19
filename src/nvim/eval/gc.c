#include <stddef.h>

#include "nvim/eval/gc.h"

#include "eval/gc.c.generated.h"  // IWYU pragma: export

#pragma weak gc_first_dict
#pragma weak gc_first_list

/// Head of list of all dictionaries
DLLEXPORT dict_T *gc_first_dict = NULL;
/// Head of list of all lists
DLLEXPORT list_T *gc_first_list = NULL;
