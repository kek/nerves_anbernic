#!/bin/bash
#
# Decide whether a set of changed files can possibly change the built system.
#
#   build-needed.sh <mix.exs> < list-of-changed-paths
#
# Prints "true" or "false" on stdout and the reason on stderr.
#
# The artifact checksum is computed from exactly one list -- checksum_files() in
# mix.exs, which mix.exs hands to Nerves as nerves_package[:checksum]. A push
# that touches nothing in that list cannot produce a different artifact, so
# building is three and a half hours spent confirming a byte-identical result.
#
# The list is read out of mix.exs rather than restated here. Restating it would
# be a second copy to keep in step, and the failure mode of drift is the bad
# direction: a file quietly dropped from this copy means a real change gets
# skipped and an unverified image ships. Reading the real list means adding a
# path to checksum_files() also protects it here, with nothing to remember.
#
# Conservative everywhere it cannot be sure: an unparseable mix.exs, an empty
# list, or anything unrecognised builds. A wrong "true" costs time. A wrong
# "false" ships an image nothing checked.
#
set -euo pipefail

MIX_EXS=${1:?usage: build-needed.sh <mix.exs> < changed-paths}

decide() { # decide <true|false> <reason>
    echo "$2" >&2
    echo "$1"
    exit 0
}

# Pull the quoted entries out of the checksum_files/0 body. Comments inside the
# list are skipped so that a commented-out path is not read as a live one.
patterns=$(
    awk '
        /^  defp checksum_files do/ { inside = 1; next }
        inside && /^  end/          { exit }
        inside {
            line = $0
            sub(/#.*$/, "", line)
            while (match(line, /"[^"]+"/)) {
                print substr(line, RSTART + 1, RLENGTH - 2)
                line = substr(line, RSTART + RLENGTH)
            }
        }
    ' "$MIX_EXS"
)

if [ -z "$patterns" ]; then
    decide true "could not read checksum_files() from $MIX_EXS, so building to be safe"
fi

# A sanity gate on the parse itself, for the same reason the GPU checker has
# one: a parser that silently returns a short list would answer "false" for
# everything and look like a working optimisation. These three have been in the
# list since the first commit and their absence means the parse is wrong, not
# that the project stopped depending on them.
for required in linux mix.exs VERSION; do
    if ! printf '%s\n' "$patterns" | grep -qxF "$required"; then
        decide true "parsed checksum_files() has no '$required' entry, so the parse is wrong; building to be safe"
    fi
done

changed=$(cat)

if [ -z "${changed//[[:space:]]/}" ]; then
    decide false "no files changed"
fi

while IFS= read -r file; do
    [ -n "$file" ] || continue
    while IFS= read -r pattern; do
        [ -n "$pattern" ] || continue

        case "$pattern" in
            *[\*\?\[]*)
                # A glob entry such as "LICENSES/*". Matched with the shell's
                # own pattern matching, whose * crosses / -- deliberately a
                # superset, since erring wide only costs a build.
                # shellcheck disable=SC2254
                case "$file" in
                    $pattern) decide true "$file is in checksum_files() (matched $pattern)" ;;
                esac
                ;;
            *)
                # A plain file or a directory. "linux" must match linux/x but
                # not linuxfoo/x, so the prefix test needs the separator.
                if [ "$file" = "$pattern" ] || [ "${file#"$pattern"/}" != "$file" ]; then
                    decide true "$file is in checksum_files() (matched $pattern)"
                fi
                ;;
        esac
    done <<< "$patterns"
done <<< "$changed"

decide false "nothing changed that feeds the artifact checksum"
