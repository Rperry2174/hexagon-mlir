//===- RuntimeMutex.h - mutex used by the device runtime ------------------===//
//
// Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
// SPDX-License-Identifier: BSD-3-Clause.
// For more license information:
//   https://github.com/qualcomm/hexagon-mlir/LICENSE.txt
//
//===----------------------------------------------------------------------===//
//
// The runtime modules are linked into every compiled kernel. On the DSP the
// QuRT mutex is used directly so that single-threaded kernels do not acquire a
// dependency on the pthread layer; off-target builds fall back to std::mutex.
// RuntimeMutex satisfies the BasicLockable requirements, so it can be used
// with std::lock_guard.
//
//===----------------------------------------------------------------------===//
#ifndef HEXAGON_BIN_RUNTIME_INCLUDE_RUNTIMEMUTEX_H_
#define HEXAGON_BIN_RUNTIME_INCLUDE_RUNTIMEMUTEX_H_

#if defined(__hexagon__)
#include <qurt_mutex.h>

class RuntimeMutex {
public:
  RuntimeMutex() { qurt_mutex_init(&mutex_); }
  ~RuntimeMutex() { qurt_mutex_destroy(&mutex_); }
  RuntimeMutex(const RuntimeMutex &) = delete;
  RuntimeMutex &operator=(const RuntimeMutex &) = delete;

  void lock() { qurt_mutex_lock(&mutex_); }
  void unlock() { qurt_mutex_unlock(&mutex_); }

private:
  qurt_mutex_t mutex_;
};
#else
#include <mutex>
using RuntimeMutex = std::mutex;
#endif

#endif // HEXAGON_BIN_RUNTIME_INCLUDE_RUNTIMEMUTEX_H_
