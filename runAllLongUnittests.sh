#!/bin/bash
#
# Runs getStateSizes.sh for all bugs whose failing test has a trace length in the upper half of its project
# (TraceLength >= median of the project in tracelength.txt).
#
# Usage: ./runAllLongUnittests.sh [PROJECT ...]
#   Without arguments, all projects contained in the tracelength file are used.
#
# Environment variables (with defaults):
#   TRACELENGTH_FILE  tracelength.txt  (getStateSizes.sh reads ./tracelength.txt for the failing test,
#                                       so it is copied there if missing)
#   SELECTION         project          (project: upper half per project; global: upper half over all projects)
#   SKIP_EXISTING     1                (1: skip bugs that already have results in RESULT_FILE)
#   RESULT_FILE       statesizes.txt
#   DRY_RUN           0                (1: only print the selected bugs)
# All other variables (STATE_DEPTHS, REPETITIONS, RUN_TIMEOUT_S, MAX_DATA_GB, ...) are passed to getStateSizes.sh.

TRACELENGTH_FILE="${TRACELENGTH_FILE:-tracelength.txt}"
SELECTION="${SELECTION:-project}"
SKIP_EXISTING="${SKIP_EXISTING:-1}"
DRY_RUN="${DRY_RUN:-0}"
export RESULT_FILE="${RESULT_FILE:-statesizes.txt}"

if [ ! -f "$TRACELENGTH_FILE" ]; then
	echo "$TRACELENGTH_FILE missing; run ./getCallTreeSizes.sh <PROJECT> first or set TRACELENGTH_FILE"
	exit 1
fi
if [ ! -f tracelength.txt ]; then
	cp "$TRACELENGTH_FILE" tracelength.txt
fi

if [ $# -gt 0 ]; then
	PROJECTS="$*"
else
	PROJECTS=$(awk '{print $1}' "$TRACELENGTH_FILE" | sort -u)
fi

# Prints "PROJECT BUG_ID TRACELENGTH" for all bugs in the upper half (TraceLength >= median),
# either per project or over all given projects
selectLongBugs() {
	for project in $PROJECTS; do
		grep "^$project " "$TRACELENGTH_FILE" \
			| awk '{split($4, a, "="); if (a[2] > 0) print $1, $2, a[2]}'
	done \
		| sort -k1,1 -k2,2n -k3,3nr | awk '!seen[$1" "$2]++' \
		| awk -v mode="$SELECTION" '{
			p[NR] = $1; b[NR] = $2; l[NR] = $3
			key = (mode == "global") ? "all" : $1
			n[key]++; vals[key, n[key]] = $3
		} END {
			for (key in n) {
				m = n[key]
				for (i = 1; i <= m; i++) s[i] = vals[key, i]
				# insertion sort, the number of bugs per project is small
				for (i = 2; i <= m; i++) { v = s[i]; j = i - 1; while (j > 0 && s[j] > v) { s[j + 1] = s[j]; j-- } s[j + 1] = v }
				median[key] = (m % 2) ? s[(m + 1) / 2] : (s[m / 2] + s[m / 2 + 1]) / 2
			}
			for (i = 1; i <= NR; i++) {
				key = (mode == "global") ? "all" : p[i]
				if (l[i] >= median[key]) print p[i], b[i], l[i]
			}
		}' \
		| sort -k1,1 -k3,3n
}

alreadyMeasured() {
	[ "$SKIP_EXISTING" == "1" ] && [ -f "$RESULT_FILE" ] && grep -q "^$1 $2 " "$RESULT_FILE"
}

selected=$(selectLongBugs)
echo "Selected $(echo "$selected" | grep -c .) bugs (selection: $SELECTION):"
echo "$selected" | awk '{print $1}' | sort | uniq -c

echo "$selected" | while read -r project bug length; do
	[ -z "$project" ] && continue
	if alreadyMeasured "$project" "$bug"; then
		echo "Skipping $project $bug (already in $RESULT_FILE)"
		continue
	fi
	echo "Project: $project Bug: $bug TraceLength: $length"
	if [ "$DRY_RUN" != "1" ]; then
		./getStateSizes.sh "$project" "$bug" < /dev/null
	fi
done
