// MPU6886 - Pure Ruby Implementation
// All functionality is implemented in mrblib/mpu6886.rb
// This file provides dummy C extension entry points for the build system

#include <mrubyc.h>

// Dummy initialization function (expected by gem system)
void
mrbc_mpu6886_init(mrbc_vm *vm)
{
  // Nothing to do for pure Ruby implementation
  // All functionality is implemented in mrblib/mpu6886.rb
}

// Define final function if needed (usually not required)
void
mrbc_mpu6886_final(mrbc_vm *vm)
{
  // Nothing to do for pure Ruby implementation
}
