# Large shareable objects made in a non-main Ractor are never freed

## Environment

ruby 4.1.0dev (2026-10-03T08:20:45Z master 9b8b0ae443) +PRISM [x86_64-linux], Linux, default GC.

## Description

Since per-Ractor GC (https://github.com/ruby/ruby/pull/18194), unreachable shareable objects
made in a non-main Ractor are only freed by a global GC, and nothing triggers one when the
objects are few but large. Memory grows without bound until something calls `GC.start`.

## Reproduction

```ruby
Ractor.new { loop { Ractor.make_shareable("x" * 65_536); sleep 0.001 } }
loop { sleep 1; puts File.read("/proc/self/status")[/VmRSS.*/] }
```

RSS grows by about 60 MB a second, the rate at which the strings are made, and never comes
back down:

```
VmRSS:	   76692 kB
VmRSS:	  136500 kB
VmRSS:	  196356 kB
VmRSS:	  256152 kB
VmRSS:	  316076 kB
```

After 30 seconds RSS is 1.7 GB (1,815,832 kB), and `GC.stat(:global_gc_count)` is still 0.

- Without `Ractor.make_shareable`, or with only `#freeze`, the same loop stays flat.
- `Ractor.shareable?` on a deeply frozen object has the same effect as `Ractor.make_shareable`,
  since it sets the same flag.
- In the main Ractor the same loop stays flat.

## Expected

Unreachable shareable objects are reclaimed when the memory they hold grows, as they are in
the main Ractor and on Ruby 4.0.6, where the same script stays at 79 MB.

## Cause, as far as I can tell

The description of #18194 says every shareable object is pinned by the local mark and "only
a global GC can decide a shareable object is dead". The global GC triggers are an explicit full
`GC.start`, shareable-object population growth, and accumulated pages of dead Ractors. The
worker Ractor's local GCs do run (25 in 8 seconds, 9 of them major), but cannot free these objects,
and a few thousand of them never grow the population enough for a global GC. The bytes they
hold are not counted anywhere that triggers one.

## Impact

A cache shared between Ractors is exactly this pattern, because its entries have to be
shareable. An HTTP gateway caching 1,000 responses of 64 KB with a one-second TTL, served by
four worker Ractors at 40,000 requests a second, peaked at 698 MB of PSS within 10 seconds
and kept growing; with the workaround below it peaked at 207 MB. Four forked processes, each
holding a full copy of the cache, needed 681 MB.

## Workaround

A thread in the main Ractor that forces a global GC:

```ruby
Thread.new { loop { sleep 1; GC.start } }
```

This keeps the reproduction flat at about 80 MB, at the cost of a stop-the-world pause every
second. In the gateway above, p99 latency rose from 1.5 to 2.7 ms with four Ractors and
from 1.5 to 5.2 ms with eight; holding 10,000 connections with 50 ms of upstream latency,
p99 rose from 131 to 195 ms.

## Suggestion

Count the malloc'd memory of objects that become shareable toward the global GC trigger, the
way `malloc_increase` triggers a local GC.
