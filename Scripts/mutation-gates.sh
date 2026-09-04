#!/usr/bin/env bash
#
# ═══════════════════════════════════════════════════════════════════════════
# PROVING THE WARNING GATES CAN ACTUALLY FAIL
# ═══════════════════════════════════════════════════════════════════════════
#
# A gate nobody has seen go red is a hope. Each mutation below reintroduces a
# real defect this repository has already had, rebuilds, and requires the
# result to FAIL. A mutation that leaves the build green is reported as
# INEFFECTIVE rather than as a pass: it means the guarantee is not being
# checked.
#
# Everything happens in a scratch copy. The working tree is never edited, so a
# process killed halfway leaves nothing behind.
#
#   ./Scripts/mutation-gates.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

report() { # name, verdict, guards
  if [ "$2" = "RED" ]; then
    PASS=$((PASS + 1)); printf "  RED    %s\n         guards: %s\n" "$1" "$3"
  else
    FAIL=$((FAIL + 1)); printf "  GREEN  %s  <- INEFFECTIVE\n         guards: %s\n" "$1" "$3"
  fi
}

scratch() { # -> path to a copy of the package sources
  local dir; dir="$(mktemp -d)"
  cp "$REPO/Package.swift" "$dir/"
  cp -R "$REPO/Sources" "$dir/Sources"
  echo "$dir"
}

echo ""
echo "MUTATION GATES"
echo ""

# ── baseline ─────────────────────────────────────────────────────────────
if ! (cd "$REPO" && swift build -Xswiftc -warnings-as-errors >/dev/null 2>&1); then
  echo "  BASELINE IS RED — the unmutated package does not build warning-free."
  echo "  Mutation results would prove nothing."
  exit 1
fi
echo "  baseline: the package builds with -warnings-as-errors"
echo ""

# ── 1. the swallowed track error comes back ──────────────────────────────
D="$(scratch)"
F="$D/Sources/WebmasterIDConformance/main.swift"
if grep -q "group.addTask { try await client.track(.appOpen) }" "$F"; then
  # This is the exact line that blocked CI: `try?` discards a thrown
  # validation error AND leaves an unused `Bool?`, because `track` is
  # @discardableResult.
  perl -0pi -e 's/group\.addTask \{ try await client\.track\(\.appOpen\) \}/group.addTask { try? await client.track(.appOpen) }/' "$F"
  perl -0pi -e 's/try await withThrowingTaskGroup/await withTaskGroup/' "$F"
  perl -0pi -e 's/\n *try await group\.waitForAll\(\)//' "$F"
  if (cd "$D" && swift build -Xswiftc -warnings-as-errors >/dev/null 2>&1); then
    report "the concurrency test swallows a thrown track error" "GREEN" \
           "compiler-native warnings-as-errors"
  else
    report "the concurrency test swallows a thrown track error" "RED" \
           "compiler-native warnings-as-errors"
  fi
else
  report "the concurrency test swallows a thrown track error" "GREEN" "ANCHOR MISSING"
fi
rm -rf "$D"

# ── 2. warnings-as-errors is dropped from the build ──────────────────────
# The same mutation, built WITHOUT the flag: it must pass, which is precisely
# why the flag is the gate rather than the build alone.
D="$(scratch)"
F="$D/Sources/WebmasterIDConformance/main.swift"
perl -0pi -e 's/group\.addTask \{ try await client\.track\(\.appOpen\) \}/group.addTask { try? await client.track(.appOpen) }/' "$F"
perl -0pi -e 's/try await withThrowingTaskGroup/await withTaskGroup/' "$F"
perl -0pi -e 's/\n *try await group\.waitForAll\(\)//' "$F"
if (cd "$D" && swift build >/dev/null 2>&1); then
  report "warnings-as-errors removed, defect restored" "RED" \
         "the defect builds cleanly without the flag — the flag IS the gate"
else
  report "warnings-as-errors removed, defect restored" "GREEN" \
         "the plain build already rejected it, so the flag proves nothing here"
fi
rm -rf "$D"

# ── 3. the workflow's iOS gate is replaced by a macOS build ──────────────
WF="$REPO/.github/workflows/ci.yml"
if grep -q "xcodebuild build" "$WF" \
   && [ "$(grep -c 'xcodebuild build' "$WF")" -ge 2 ] \
   && grep -q "platform=iOS Simulator" "$WF" \
   && grep -q "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES" "$WF" \
   && grep -q -- "-Xswiftc -warnings-as-errors" "$WF"; then
  report "the workflow still compiles for iOS and rejects warnings" "RED" \
         "swift build alone cannot stand in for the iOS gate"
else
  report "the workflow still compiles for iOS and rejects warnings" "GREEN" \
         "the iOS gate or its warning enforcement is missing"
fi

echo ""
echo "  $PASS/$((PASS + FAIL)) mutations behaved as required"
[ "$FAIL" -eq 0 ] || exit 1
