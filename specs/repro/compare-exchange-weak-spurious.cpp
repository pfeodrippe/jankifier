/* RESULTS.md C2: what jank's compare-and-set! does, in C++, on this machine.
 *
 * jank's atom::compare_and_set is one compare_exchange_weak. Compiled for Apple Silicon it's the
 * casal instruction, which can't fail spuriously; compiled for an ARMv8.0 CPU such as the
 * Cortex-A72 (a Raspberry Pi 4) it's ldaxr/stlxr, which fails when another core stores to the
 * same memory in between, even the value already there. Apple Silicon runs both:
 *
 *   clang++ -O2 -std=c++17 -mcpu=apple-m1   compare-exchange-weak-spurious.cpp -o weak-m1  && ./weak-m1
 *   clang++ -O2 -std=c++17 -mcpu=cortex-a72 compare-exchange-weak-spurious.cpp -o weak-a72 && ./weak-a72
 *
 * expected 0 for both; on 2026-11-21: 0 for apple-m1, and for cortex-a72 58520 and 63170 of
 * 2000000 in two runs. */
#include <atomic>
#include <cstdio>
#include <thread>
int main()
{
  std::atomic<long> a{ 0 };
  std::atomic<bool> stop{ false };
  /* Another thread keeps storing the value that's already there. */
  std::thread other{ [&] {
    while(!stop.load(std::memory_order_relaxed))
    {
      long v{ a.load() };
      a.compare_exchange_strong(v, v);
    }
  } };
  long const n{ 2000000 };
  long spurious{};
  for(long i{}; i < n; ++i)
  {
    long const v{ a.load() };
    long expected{ v };
    /* As jank's atom::compare_and_set: one compare_exchange_weak. */
    if(!a.compare_exchange_weak(expected, v) && expected == v)
    {
      ++spurious;
    }
  }
  stop = true;
  other.join();
  std::printf("failures with the expected value in place, of %ld: %ld\n", n, spurious);
}
