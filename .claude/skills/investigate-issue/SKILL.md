---
name: investigate-issue
description: Investigate a reported Highball bug end to end - reproduce it locally, verify the cause, fix it at the right layer, prove the fix, then reply. Use when looking into a GitHub issue, a user's install or crash report, or unexplained bottle, engine, or recipe behaviour.
---

# Investigate a reported bug

Work the gates in order. Each exists because skipping it once produced a wrong fix or a
false claim to a user. Skip a gate only deliberately, and say so.

Environment paths, commands, and known traps: [reference.md](reference.md)

## 1. Read the whole thread first

Read every comment, including your own earlier replies, before forming a theory. Check
whether the lead you are about to raise was already tried and ruled out in that thread.

## 2. Find the decisive evidence

Identify the one line that separates working from broken. Quote it.

If the report's log cannot distinguish success from failure, that is finding #1: fix the
diagnostics before chasing the bug. Wine logs end with `# exit=N (…) after Ns`; a log
without that line predates the fix and cannot tell you the outcome.

## 3. Reproduce locally before theorising

Reproduce the failure on this machine, then confirm the reproduction matches the report
line for line. A reproduction you cannot match is a different bug.

If it will not reproduce, that is data: name the variable that differs (macOS build, chip,
engine id, bottle state) and verify it rather than assuming it. Compare exact versions, not
labels - a CI runner labelled for a major version may be several point releases behind.

## 4. Verify the load-bearing claim yourself

Every fix rests on one factual claim. Test that claim directly before building on it:

- exit codes: run the failing command and read the number, do not infer it
- env vars and flags: grep the actual shipped binary for the string
- file contents: hash them against a known-good copy

Research and agents are leads, not evidence. Confirm the claim in this repo, on this engine.

## 5. Try to refute your own hypothesis

Actively look for the datapoint that kills it. Check whether CI, another machine, or
another user contradicts the pattern. Two datapoints are a coincidence.

State the hypothesis you killed. A dead theory reported early is cheaper than a wrong fix
shipped late.

## 6. Fix at the right layer

- App and Kit: general mechanisms only - step types, classifiers, gates, diagnostics.
- highball-db: everything specific to one game, launcher, or vendor.

If the fix needs a game's name in Swift, it is in the wrong layer. Keep a hardcoded
fallback only when removing it would regress users who cannot reach the new path, and
write down the condition for removing it later.

## 7. Prove it end to end

Reproduce the broken state, apply the fix, show the failure gone, and show the user's
actual goal working (the install completes, the game launches). Run the full test suite.

Also test what does *not* work, so the fix ships without folklore attached.

## 8. Report two numbers, never one

These are different questions and often have very different answers:

1. Is the diagnosis correct?
2. Can the user use the app again after this ships?

Detection is not a cure. A change that turns a silent failure into a clear message is
worth shipping and still leaves the user stuck. Say so plainly, then go build the cure.

## 9. Ship before saying it is fixed

Release first, so the reply says "update and try" rather than promising a future version.

In the reply: name the cause in plain words, say it is our bug when it is, give the exact
action to take, and ask for one specific thing if confirmation is still needed. No
overclaiming - if you have not proven it fixes *their* case, say that.

Leave the issue open until the reporter confirms.
