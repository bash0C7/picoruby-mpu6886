// MPU6886 - Pure Ruby Implementation
// All functionality is implemented in mrblib/mpu6886.rb
// This file provides dummy C extension entry points for the build system

#include <mrubyc.h>

// ダミーの初期化関数（gemシステムが期待する関数名）
void
mrbc_mpu6886_init(mrbc_vm *vm)
{
  // Pure Ruby実装のため、何もしない
  // 全ての機能はmrblib/mpu6886.rbで実装されている
}

// 必要に応じてfinal関数も定義（通常は不要）
void
mrbc_mpu6886_final(mrbc_vm *vm)
{
  // Pure Ruby実装のため、何もしない
}
