// This target exists only to expose the declarations in include/CIOHIDShim.h to
// Swift. SwiftPM requires a C target to have at least one source file.

#include "include/CIOHIDShim.h"

// Referenced by SMCKit to confirm the shim linked correctly.
int cioihd_shim_available(void) { return 1; }
