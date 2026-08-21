#!/bin/bash
# The test suite. There is no XCTest target: each harness compiles the shipped sources it guards,
# so a harness that stops compiling means a decision leaked out of a pure layer.
#
# Never join a compile and its run with `&&`: `set -e` ignores a failure in a non-final AND-OR list
# member, which is how a suite reports success over a harness that has not compiled in weeks.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

BIN="${TMPDIR:-/tmp}/spare-harness"
mkdir -p "$BIN"

failed=()
ran=0
only="${1:-}"

# `--index` merges each harness's compile command into .compile instead of running anything.
# xcodebuild never compiles the harnesses, so without this nothing in Tests/ resolves in an editor.
# The source lists below are the only copy, which is why this lives here rather than in its own
# script.
emit_db=0
DB="${TMPDIR:-/tmp}/spare-compile-db.json"
if [ "$only" = "--index" ]; then
    emit_db=1
    only=""
    printf '[' > "$DB"
fi

# run <name> <source...> — compile the harness and run it, recording either kind of failure.
run() {
    local name=$1
    shift
    if [ -n "$only" ] && [ "$name" != "$only" ]; then return 0; fi
    ran=$((ran + 1))

    # Absolute paths throughout: sourcekit-lsp resolves the command itself and does not apply
    # `directory` to relative arguments, so a relative path there silently yields no index.
    if [ "$emit_db" -eq 1 ]; then
        local sources=()
        for source in "$@" "Tests/$name.swift"; do sources+=("$PWD/$source"); done
        [ "$ran" -gt 1 ] && printf ',' >> "$DB"
        printf '{"directory":"%s","command":"swiftc -swift-version 6 -sdk %s' \
            "$PWD" "$(xcrun --show-sdk-path --sdk macosx)" >> "$DB"
        printf ' %s' "${sources[@]}" >> "$DB"
        # Claim only the harness itself. The command still lists every shipped source it compiles,
        # so symbols resolve inside the harness — but claiming those sources here would hand them
        # this small command instead of the app's, and `.compile` is last-wins.
        printf '","files":["%s/Tests/%s.swift"]}' "$PWD" "$name" >> "$DB"
        return 0
    fi

    if ! swiftc -swift-version 6 "$@" "Tests/$name.swift" -o "$BIN/$name" 2>&1; then
        printf '\033[31mFAIL\033[0m  %-22s did not compile\n' "$name"
        failed+=("$name")
        return 0
    fi
    if ! "$BIN/$name"; then
        printf '\033[31mFAIL\033[0m  %-22s assertion failed\n' "$name"
        failed+=("$name")
        return 0
    fi
    printf '\033[32mok\033[0m    %-22s\n' "$name"
}

# Harnesses register here, one `run` line per phase that adds a Tests/*.swift.

run app-paths-test Spare/Platform/AppPaths.swift
run clipboard-item-test Spare/Clipboard/Core/ClipboardItem.swift
run capture-policy-test Spare/Clipboard/Core/ClipboardItem.swift \
                        Spare/Clipboard/Core/CapturePolicy.swift
# -lsqlite3: the store links the system dylib, which swiftc does not pick up from the import.
run clipboard-test -lsqlite3 Spare/Clipboard/Core/ClipboardItem.swift \
                             Spare/Clipboard/Core/ClipboardStore.swift
run settings-test Spare/Settings/Settings.swift
# -framework: swiftc links neither AppKit nor ImageIO from the import alone.
run image-thumbnail-test -framework AppKit -framework ImageIO \
                         Spare/Platform/ImageThumbnail.swift
# The list's pure geometry, compiled against the views it actually ships with — a decision that
# leaks into a row view or the store shows up here as a compile failure.
run geometry-test -framework AppKit -framework ImageIO -lsqlite3 \
                  Spare/Design/Theme.swift \
                  Spare/Design/EdgeDissolve.swift \
                  Spare/Design/ThinScroller.swift \
                  Spare/Clipboard/Core/ClipboardItem.swift \
                  Spare/Clipboard/Core/ClipboardStore.swift \
                  Spare/Platform/ImageThumbnail.swift \
                  Spare/Palette/RowViews.swift \
                  Spare/Palette/ListController.swift

# Paster plus Core and the Accessibility check it guards ⌘V with — never the monitor: the write
# seam has to compile without anything that touches `NSPasteboard.general`.
run paster-test -framework AppKit -lsqlite3 \
                Spare/Clipboard/Core/ClipboardItem.swift \
                Spare/Clipboard/Core/ClipboardStore.swift \
                Spare/Clipboard/Core/CapturePolicy.swift \
                Spare/Platform/Permissions.swift \
                Spare/Clipboard/Paster.swift

# Foundation-only, and deliberately so: no -framework here, so a Carbon or AppKit dependency
# creeping into the stored chord shows up as a link failure.
run key-shortcut-test Spare/HotKeys/KeyShortcut.swift

if [ "$emit_db" -eq 1 ]; then
    printf ']\n' >> "$DB"
    [ -f .compile ] || echo '[]' > .compile
    python3 - .compile "$DB" <<'PY'
import json, sys

compile_path, harness_path = sys.argv[1], sys.argv[2]
existing = json.load(open(compile_path))
harnesses = json.load(open(harness_path))
kept = [e for e in existing if not any("/Tests/" in f for f in e.get("files") or [])]
json.dump(kept + harnesses, open(compile_path, "w"), indent=1)
print(f"{len(harnesses)} harness entries indexed into .compile")
PY
    exit 0
fi

if [ "$ran" -eq 0 ]; then
    if [ -n "$only" ]; then
        echo "unknown harness '$only'." >&2
        exit 1
    fi
    echo "no harnesses registered"
    exit 0
fi

if [ ${#failed[@]} -gt 0 ]; then
    printf '\n%d harness(es) failed: %s\n' "${#failed[@]}" "${failed[*]}" >&2
    exit 1
fi
echo
if [ -n "$only" ]; then echo "$only passed."; else echo "All $ran harnesses passed."; fi
