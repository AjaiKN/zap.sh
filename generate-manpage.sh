#!/usr/bin/env bash

cd "$(dirname "$0")" || exit 1

if ! command -v help2man >/dev/null 2>&1 || ! command -v ruby >/dev/null 2>&1; then
	if command -v nix-shell >/dev/null 2>&1; then
		exec nix-shell -p help2man ruby --run "$0"
	fi
fi

mkdir -p ./man/man1 || exit 1

PATH="$PWD/bin:$PATH"
export PATH

commands=(trash)
for c in "${commands[@]}"; do
	outfile=./man/man1/"$c.1"
	help2man --no-info --output="$outfile" "$c"
	# If the only thing that changed is the date, undo the change.
	if git ls-files --error-unmatch "$outfile" &&
			git diff --ignore-matching-lines='^\.TH .* "1" .* "User Commands"$' --exit-code "$outfile" >/dev/null
	then
		git restore "$outfile"
	fi
done
