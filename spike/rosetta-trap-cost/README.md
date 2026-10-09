# Rosetta exception cost (Apple Feedback FB25100017)

These three small programs measure what a hardware exception costs in x86_64 code running under Rosetta,
next to the same exception in native Apple silicon code. They back the report we sent Apple, FB25100017,
about the hitch Forza Horizon 6 shows about once a second on every Mac we have heard from.

If you play Forza Horizon 6 and see the hitch, the guide at
https://gethighball.com/docs/rosetta-feedback/ shows how to send Apple a short report that points to ours.
You do not need these programs for that.

## What they measure

- `sigbench` (x86_64, runs under Rosetta) catches `ud2` with a SIGILL handler that steps over it, `int3`
  with SIGTRAP, and a `pthread_kill` round trip.
- `sigbench_arm64` (native) does the same SIGILL round trip with `udf #0`, for comparison.
- `smcbench` (x86_64) writes a byte into a 4 KB page that holds code which already ran, then calls that code.

## Run them

You need the Xcode command line tools (`xcode-select --install`).

```
./build.sh
./sigbench 200000
./sigbench 100000 4
./sigbench_arm64 200000
./sigbench_arm64 200000 4
./smcbench
```

The first number is how many exceptions to time, the second how many threads to keep busy meanwhile, the way
a game keeps the cores busy.

## Results so far

| Mac | macOS | ud2 under Rosetta | int3 under Rosetta | native udf | write into a code page |
|---|---|---|---|---|---|
| Mac mini M4, 32 GB, idle | 27.0 | 14.8 µs | 15.6 µs | 1.5 to 1.8 µs | 11.7 to 12.8 µs |
| Mac mini M4, 4 busy threads | 27.0 | 31.7 µs | 32.8 µs | 1.86 µs | |
| MacBook Pro M1 Pro, idle | 27.0 | 19.8 µs | 22.9 µs | 2.4 µs | 16.9 µs |

A write into a different 4 KB page costs nothing on either Mac.

In the game, the copy protection runs a job about every 1.1 seconds that executes about 2,000 instructions
which trap on purpose, and its handler emulates each one while holding a lock the frame needs. Each trap
costs about 57 µs there, so the job takes about a tenth of a second instead of a few milliseconds on a PC.
Wine's own share of that time is about 5%.

## The report we filed

<details>
<summary>The text of FB25100017, sent to Apple on 9 October 2026 with these programs attached</summary>

#### Title

Rosetta: a trapped x86 instruction costs about 15 µs (1.5 µs natively), which stalls games that emulate instructions in a signal handler

#### Description

x86_64 code running under Rosetta that takes a hardware exception and resumes from a signal handler (ud2 to SIGILL, int3 to SIGTRAP) spends about 15 µs per exception on an M4 Mac mini with macOS 27.0, idle. With four other threads busy, as in any game, it doubles to about 32 µs. The same round trip in native arm64 code (udf #0 to SIGILL) takes 1.8 µs idle and 1.9 µs with four busy threads, so the extra time is in Rosetta's path. In the game, Rosetta's exception server thread (com.apple.rosetta.exceptionserver) is busy in step with the traps. A software signal (pthread_kill, SIGUSR2) costs 7 µs under Rosetta, 16.5 µs with four busy threads.

A second cost adds to it. Writing to any byte of a 4 KB page that holds code which already ran, then running that code, costs about 12 µs per write. A write to another 4 KB page, even inside the same 16 KB host page, costs nothing.

Impact: Forza Horizon 6 (Steam, a Windows game running under Wine through Rosetta) stalls for 100 to 130 ms about once a second. Its copy protection runs a job every 1.1 s that executes about 2,000 instructions which trap on purpose and are emulated by the game's exception handler, and it holds a lock the frame needs for the whole job. Each trap costs about 57 µs here: the exception round trip, one or two of the code page writes above (the handler writes into a page it executes), and the handler's own work. On x86 hardware the same job takes a few milliseconds. Players see a hitch every second on M4 and M5 Macs.

What we ruled out: Wine's own share of the cost is about 5%. The sigaction flags, the signal mask, an alternate signal stack, MAP_JIT and the ROSETTA_* environment variables change nothing. Raising Rosetta's exception server thread (com.apple.rosetta.exceptionserver) and the trapping thread, even to real-time priority, shortens the game's stall by only about 18%.

#### Steps to reproduce

1. Unzip the attachment and run `./build.sh` (Xcode command line tools). Prebuilt binaries are included.
2. Run `./sigbench` (x86_64, runs under Rosetta) and `./sigbench_arm64` (native). Add a second argument for busy threads, for example `./sigbench 100000 4` and `./sigbench_arm64 200000 4`.
3. Run `./smcbench` (x86_64).

#### Expected results

An exception delivered to translated code costs within a small factor of the native round trip. A write to data that shares a 4 KB page with translated code does not cost a full invalidation each time.

#### Actual results

M4 Mac mini (10-core GPU, 32 GB), macOS 27.0, idle:

- ud2 caught by a SIGILL handler that steps over it: 14.8 µs per exception (18.9 µs without an alternate signal stack)
- int3 caught by SIGTRAP: 15.6 µs
- pthread_kill with SIGUSR2: 7.0 µs
- native arm64, udf #0 caught by SIGILL: 1.5 to 1.8 µs (2.4 µs on an M1 Pro)

With busy threads (2026-10-08, same Mac): ud2/SIGILL 31.7 µs with 4 and 27.9 µs with 8 busy threads, int3/SIGTRAP 32.8 and 29.4 µs, pthread_kill 16.5 and 14.8 µs. Native arm64 udf: 1.86 µs with 4 and 2.18 µs with 8.
- smcbench, write one data byte in the 4 KB page of a function that already ran, then call it: 11.7 to 12.8 µs per iteration. The same write in another 4 KB page: 0 µs.

#### Configuration

Mac mini (M4, 2024), 32 GB, macOS 27.0. The game numbers come from Wine 11 (CrossOver 26.3 sources) with Highball, an open source Wine front end.

</details>
