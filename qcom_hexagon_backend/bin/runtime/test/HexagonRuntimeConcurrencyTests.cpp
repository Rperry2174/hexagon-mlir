//===- HexagonRuntimeConcurrencyTests.cpp - multi-threaded runtime tests --===//
//
// Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
// SPDX-License-Identifier: BSD-3-Clause.
// For more license information:
//   https://github.com/qualcomm/hexagon-mlir/LICENSE.txt
//
//===----------------------------------------------------------------------===//
//
// With threaded SPMD dispatch (ThreadManager::exec) every program instance of
// a kernel runs on its own QuRT thread and calls the runtime entry points
// (hexagon_runtime_alloc/free_*_dsp, hexagon_runtime_dma_start/wait)
// concurrently. These tests drive the runtime the same way and check that
// allocations never overlap, memory is fully returned, and DMA copies land in
// the right destination.
//
//===----------------------------------------------------------------------===//

#include "HexagonCAPI.h"
#include "HexagonResources.h"
#include "RuntimeDMA.h"

#include <atomic>
#include <cstdint>
#include <cstring>
#include <gtest/gtest.h>
#include <mutex>
#include <set>
#include <thread>
#include <vector>

namespace {

constexpr int kNumThreads = 4;
constexpr int kAllocItersPerThread = 500;
// DMA bookkeeping races are intermittent; use enough iterations to make the
// window practically certain to be hit when the runtime state is shared.
constexpr int kDmaItersPerThread = 2000;

class HexagonRuntimeConcurrencyTest : public ::testing::Test {
public:
  static void SetUpTestSuite() { AllocateHexagonResources(); }
  static void TearDownTestSuite() { DeallocateHexagonResources(); }
};

// Each "program instance" allocates a VTCM tile and a DDR crouton buffer,
// writes a thread-unique pattern into the tile, verifies it is still intact
// and frees both, exactly like the code emitted for hexagonmem.alloc/dealloc.
void allocFreeInstance(int pid, size_t tileBytes, std::mutex &liveMutex,
                       std::set<void *> &live, std::atomic<int> &duplicates,
                       std::atomic<int> &corruptions) {
  for (int it = 0; it < kAllocItersPerThread; ++it) {
    uint8_t *tile = static_cast<uint8_t *>(hexagon_runtime_alloc_1d_dsp(
        tileBytes, /*alignment=*/2048, /*isVtcm=*/true));
    void *ddr =
        hexagon_runtime_alloc_2d_dsp(/*numBlocks=*/2, /*blockSize=*/2048,
                                     /*alignment=*/2048,
                                     /*isVtcm=*/false);
    ASSERT_NE(tile, nullptr);
    ASSERT_NE(ddr, nullptr);
    {
      std::lock_guard<std::mutex> lock(liveMutex);
      if (!live.insert(tile).second)
        ++duplicates;
    }
    uint8_t value = static_cast<uint8_t>(0x10 + pid);
    std::memset(tile, value, tileBytes);
    std::this_thread::yield();
    for (size_t i = 0; i < tileBytes; i += 64) {
      if (tile[i] != value) {
        ++corruptions;
        break;
      }
    }
    {
      std::lock_guard<std::mutex> lock(liveMutex);
      live.erase(tile);
    }
    hexagon_runtime_free_1d_dsp(tile);
    hexagon_runtime_free_2d_dsp(ddr);
  }
}

TEST_F(HexagonRuntimeConcurrencyTest, ConcurrentAllocFree) {
  VtcmPool *pool = HexagonAPI::Global()->getVtcmPool();
  const size_t tileBytes = 64 * 1024;
  const size_t allocationsBefore = pool->getNumAllocations();
  const size_t freeBefore = pool->getTotalFree();

  std::mutex liveMutex;
  std::set<void *> live;
  std::atomic<int> duplicates{0};
  std::atomic<int> corruptions{0};

  std::vector<std::thread> threads;
  for (int pid = 0; pid < kNumThreads; ++pid)
    threads.emplace_back(allocFreeInstance, pid, tileBytes, std::ref(liveMutex),
                         std::ref(live), std::ref(duplicates),
                         std::ref(corruptions));
  for (auto &thread : threads)
    thread.join();

  EXPECT_EQ(duplicates.load(), 0);
  EXPECT_EQ(corruptions.load(), 0);
  EXPECT_EQ(pool->getNumAllocations(), allocationsBefore);
  EXPECT_EQ(pool->getTotalFree(), freeBefore);
  EXPECT_EQ(pool->getTotalAllocated() + pool->getTotalFree(),
            pool->getTotalSize());
}

// Each thread issues its own dma_start/dma_wait pairs, as the code emitted
// for memref.dma_start/dma_wait does inside every program instance.
void dmaInstance(int pid, size_t bytes, std::atomic<int> &failures,
                 std::atomic<int> &badCopies) {
  using namespace hexagon::userdma;
  std::vector<uint8_t> src(bytes);
  std::vector<uint8_t> dst(bytes);
  for (int it = 0; it < kDmaItersPerThread; ++it) {
    uint8_t value = static_cast<uint8_t>(pid * 16 + (it & 15));
    std::memset(src.data(), value, bytes);
    std::memset(dst.data(), 0, bytes);
    DMAStatus status;
    uint32_t token = hexagon_runtime_dma_start(src.data(), DDR, dst.data(), DDR,
                                               bytes, false, false, &status);
    if (status != DMASuccess) {
      ++failures;
      continue;
    }
    hexagon_runtime_dma_wait(token);
    if (std::memcmp(src.data(), dst.data(), bytes) != 0)
      ++badCopies;
  }
}

TEST_F(HexagonRuntimeConcurrencyTest, ConcurrentDmaStartWait) {
  std::atomic<int> failures{0};
  std::atomic<int> badCopies{0};

  std::vector<std::thread> threads;
  for (int pid = 0; pid < kNumThreads; ++pid)
    threads.emplace_back(dmaInstance, pid, /*bytes=*/4096, std::ref(failures),
                         std::ref(badCopies));
  for (auto &thread : threads)
    thread.join();

  EXPECT_EQ(failures.load(), 0);
  EXPECT_EQ(badCopies.load(), 0);
}

} // namespace
