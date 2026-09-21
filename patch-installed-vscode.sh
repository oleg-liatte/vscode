#!/usr/bin/env bash
#
# patch-installed-vscode.sh
#
# Rebuilds the VS Code core bundle (minified + NLS-processed, like an
# official build) from the CURRENT state of this repo's sources, and installs
# it in place of the `out` folder of an already-installed stock VS Code.
# Afterwards it recomputes the integrity checksums and patches them into the
# installed product.json, so the "Your Code installation appears to be
# corrupt" warning doesn't show up.
#
# Usage: run from the root of this vscode repo checkout:
#   ./patch-installed-vscode.sh [install-subfolder]
#
# [install-subfolder] is the name of the folder directly under the VS Code
# install base (e.g. '645f29cc31') to patch. If omitted, the script requires
# that exactly one such folder looks like a VS Code install.
#
# Notes:
# - VS Code does NOT need to be closed; only the `out` folder is replaced.
# - Only replaces `resources/app/out` (core bundle). Built-in extensions are
#   untouched.

set -euo pipefail

REPO_ROOT="$(pwd)"
TARGET_SUBFOLDER="${1:-}"

if [[ ! -f "$REPO_ROOT/product.json" || ! -f "$REPO_ROOT/build/next/index.ts" ]]; then
	echo "error: run this script from the root of a vscode repo checkout" >&2
	echo "       (product.json / build/next/index.ts not found in '$REPO_ROOT')" >&2
	exit 1
fi

# --- 1. locate the installed VS Code 'out' folder to override --------------

INSTALL_BASE="${LOCALAPPDATA:-$HOME/AppData/Local}/Programs/Microsoft VS Code"

if [[ ! -d "$INSTALL_BASE" ]]; then
	echo "error: VS Code install base folder not found: '$INSTALL_BASE'" >&2
	exit 1
fi

# Stock Windows installs with versioned updates enabled nest the actual app
# under a commit-hash-named subfolder, e.g.
# ".../Microsoft VS Code/645f29cc31/resources/app".
if [[ -n "$TARGET_SUBFOLDER" ]]; then
	if [[ ! -f "$INSTALL_BASE/$TARGET_SUBFOLDER/resources/app/product.json" ]]; then
		echo "error: '$INSTALL_BASE/$TARGET_SUBFOLDER' does not look like a VS Code install" >&2
		echo "       (no 'resources/app/product.json' found there)" >&2
		exit 1
	fi
	INSTALL_OUT="$INSTALL_BASE/$TARGET_SUBFOLDER/resources/app/out"
else
	CANDIDATES=()
	for d in "$INSTALL_BASE"/*/; do
		if [[ -f "${d}resources/app/product.json" ]]; then
			CANDIDATES+=("$(basename "$d")")
		fi
	done

	if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
		echo "error: no VS Code install found under '$INSTALL_BASE'" >&2
		echo "       (looked for '<subfolder>/resources/app/product.json')" >&2
		exit 1
	fi

	if [[ ${#CANDIDATES[@]} -gt 1 ]]; then
		echo "error: multiple VS Code installs found under '$INSTALL_BASE':" >&2
		for name in "${CANDIDATES[@]}"; do
			marks=""
			if [[ -d "$INSTALL_BASE/$name/resources/app/out.bak" ]]; then
				marks="${marks:+$marks, }out.bak"
			fi
			if [[ -f "$INSTALL_BASE/$name/resources/app/product.json.bak" ]]; then
				marks="${marks:+$marks, }product.json.bak"
			fi
			echo "         $name${marks:+  [has $marks]}" >&2
		done
		echo "       re-run this script with the desired one, e.g.:" >&2
		echo "         $0 ${CANDIDATES[0]}" >&2
		exit 1
	fi

	INSTALL_OUT="$INSTALL_BASE/${CANDIDATES[0]}/resources/app/out"
fi

if ! command -v cygpath >/dev/null 2>&1; then
	echo "error: 'cygpath' not found (expected in a Git Bash / MSYS environment on Windows)" >&2
	exit 1
fi

# Normalize to clean, forward-slash Windows paths (e.g. 'C:/Users/...') so the
# node path.relative()/path.join() calls below see consistent input regardless
# of how bash assembled INSTALL_OUT (LOCALAPPDATA may contain backslashes).
INSTALL_OUT="$(cygpath -m "$INSTALL_OUT")"
REPO_ROOT_WIN="$(cygpath -m "$REPO_ROOT")"

PRODUCT_JSON="$(dirname "$INSTALL_OUT")/product.json"

echo "==> Target install out/: $INSTALL_OUT"

# build/next/index.ts resolves --out via path.join(REPO_ROOT, outDir), which
# does NOT special-case absolute paths (it just concatenates them onto
# REPO_ROOT). So instead of an absolute path, compute the relative path from
# REPO_ROOT to INSTALL_OUT and pass that - path.join() then resolves it back
# to the correct absolute location.
REL_OUT="$(node -e 'console.log(require("path").relative(process.argv[1], process.argv[2]))' "$REPO_ROOT_WIN" "$INSTALL_OUT")"

# --- 2. bundle (minified + NLS) directly into the install's out/ folder ----
#
# bundle() calls cleanDir() on its --out target first (rm -rf + mkdir), so
# building straight into INSTALL_OUT already replaces the old contents - no
# separate rm/cp step needed.

if [[ ! -f "${PRODUCT_JSON}.bak" ]]; then
	echo "==> Backing up ${PRODUCT_JSON}..."
	cp "${PRODUCT_JSON}" "${PRODUCT_JSON}.bak"
fi

if [[ ! -d "${INSTALL_OUT}.bak" ]]; then
	echo "==> Backing up ${INSTALL_OUT}..."
	mv "${INSTALL_OUT}" "${INSTALL_OUT}.bak"
fi

echo "==> Bundling core (minified, NLS) from current sources directly into install..."
node --experimental-strip-types build/next/index.ts bundle --minify --nls --mangle-privates --out "$REL_OUT"

# --- 3. recompute integrity checksums and patch product.json ---------------

echo "==> Patching integrity checksums in product.json..."
node -e '
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const outDir = process.argv[1];
const productJsonPath = process.argv[2];

// Keep this list in sync with computeChecksums() in build/gulpfile.vscode.ts
const files = [
	"vs/base/parts/sandbox/electron-browser/preload.js",
	"vs/workbench/workbench.desktop.main.js",
	"vs/workbench/workbench.desktop.main.css",
	"vs/workbench/api/node/extensionHostProcess.js",
	"vs/code/electron-browser/workbench/workbench.html",
	"vs/code/electron-browser/workbench/workbench.js",
	"vs/sessions/sessions.desktop.main.js",
	"vs/sessions/sessions.desktop.main.css",
	"vs/sessions/electron-browser/sessions.html",
	"vs/sessions/electron-browser/sessions.js",
];

const checksums = {};
for (const f of files) {
	const full = path.join(outDir, f);
	if (!fs.existsSync(full)) {
		console.warn(`  (skipping missing file: ${f})`);
		continue;
	}
	const contents = fs.readFileSync(full);
	checksums[f] = crypto.createHash("sha256").update(contents).digest("base64").replace(/=+$/, "");
}

const json = JSON.parse(fs.readFileSync(productJsonPath, "utf8"));
json.checksums = checksums;
fs.writeFileSync(productJsonPath, JSON.stringify(json, null, "\t"));
console.log(`  patched ${Object.keys(checksums).length} checksums in ${productJsonPath}`);
' "$INSTALL_OUT" "$PRODUCT_JSON"

echo "==> Done. Restart VS Code (reload window or fully relaunch) to pick up the changes."
