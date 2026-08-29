---
name: verify-game
description: Test whether a game runs on the current engine and record the result in highball-db with honest provenance. Use when verifying a title, adding or updating a compatibility entry, writing a game recipe, choosing a renderer for a game, or answering whether a specific game works.
---

# Verify a game and record the result

The database is the product. An entry that overstates what was seen is worse than no entry,
because every other claim inherits its credibility.

Environment paths, commands, and traps: [../investigate-issue/reference.md](../investigate-issue/reference.md)

## 1. Check what is already known

Read `../highball-db/db/games/<id>.json` and any existing recipe before testing. If the
database already answers this, verify rather than rediscover, and say which claim you are
re-testing.

Check the anti-cheat data first. A kernel anti-cheat title cannot work under Wine on macOS;
record that and stop rather than spending hours proving it.

## 2. Set the bottle up deliberately

Decide the renderer and dependencies before launching, and change one variable at a time.

After changing a bottle's renderer, restart the bottle. A running Steam client keeps the
environment it started with, so the game inherits the old renderer and you test the wrong
thing.

## 3. Reach the actual goal, not the first screen

A menu is not a verdict. Launchers render while games fail; windows exist while nothing
composites. Play far enough to prove the thing a player wants:

- a level or match actually loads and runs
- the frame rate holds after shader compilation settles
- exiting is clean

Record where it stops if it stops.

## 4. Capture evidence while it runs

- frame rate from the Metal HUD (`bottle set <bottle> hud 1`), not an estimate
- the log footer (`# exit=N … after Ns`) for the run
- a screenshot when the result is visual

## 5. Test the renderers, and record the failures

Try the plausible renderers rather than only the one that worked. Which renderer fails, and
how, is the data nobody else publishes, and it is what makes an entry useful.

## 6. Repeat before believing a good result

A single success that does not reproduce is not a verdict. Run it again from a clean start.
If it only worked once, say so and mark the entry accordingly.

## 7. Write the entry with matching provenance

Pick the status by what was actually observed:

| status | means |
|---|---|
| `verified-local` | someone ran it here, start to finish |
| `reported-upstream` | tested and known broken, with the cause recorded |
| `community` | reported by users, unverified by us |
| `blocked-anticheat` | cannot work, anti-cheat |

`lastVerified` carries date, engine id, macOS version, and chip, because the answer differs
across all four. Notes say what to do, what it costs, and what still fails.

## 8. Ship the fix as data

If the game needs setup to work, put it in a recipe in `../highball-db`, never in Swift.
Prefer steps that persist (config files the game reads) over launch arguments, and prove
persistence by running once without the arguments.

## 9. Claim only what was seen

Write "menus render, sessions crash" rather than "works". If the game was not played, say
which part was exercised. If a number was not measured, leave it out.
