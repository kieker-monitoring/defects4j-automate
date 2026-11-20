#!/bin/bash
#
# Measures the size and overhead of naive state capturing (Kieker branch state-capture) for the failing test of
# selected defects4j bugs (buggy version). For each bug, the failing test is executed in the following modes:
#   uninstrumented  agent attached, but nothing instrumented (KIEKER_SIGNATURES_INCLUDE unset)
#   kieker          method-level tracing without state (OperationExecutionRecords only)
#   state-<depth>   tracing with state capturing for each depth in STATE_DEPTHS
# All modes use the same pom.xml / argLine, so they only differ in the environment variables.
#
# Usage: ./getStateSizes.sh [PROJECT] [BUG_ID ...]
#   Without bug ids, SAMPLE bugs are selected from tracelength.txt, evenly spread over the sorted trace lengths.
#
# Environment variables (with defaults):
#   STATE_AGENT_JAR   ../kieker/build/libs/kieker-2.0.2-bytebuddy.jar (built from branch state-capture)
#   STATE_DEPTHS      "0 1 full"
#   SAMPLE            15
#   REPETITIONS       1
#   RUN_TIMEOUT_S     1800 (per run)
#   MAX_DATA_GB       50 (per run; the run is aborted if Kieker and state data exceed this size)
#   TEST_XMX          4g
#   KEEP_DATA         0 (1: keep trace and state data of each run)
#   RESULT_FILE       statesizes.txt
#
# Output: one line per bug, mode and repetition in RESULT_FILE, e.g.
#   JacksonDatabind 5 com.fasterxml...Test mode=state-1 rep=1 status=finished exit=1 seconds=12.3 maxRssKB=...
#     kiekerBytes=... stateBytes=... stateEntries=... maxEntryBytes=... expandedObjects=... serializationNanos=... failures=...

export PROJECT="${1:-JacksonDatabind}"
shift

source commons.sh

if [ -z "${JAVA_HOME}" ]; then
	echo "\$JAVA_HOME not set"
	exit 1
fi

if [ ! -d "${JAVA_HOME}" ]; then
	echo "\$JAVA_HOME points to invalid directory: ${JAVA_HOME}"
	exit 1
fi

STATE_AGENT_JAR="${STATE_AGENT_JAR:-$(pwd)/kieker-2.0.2-states.jar}"
STATE_DEPTHS="${STATE_DEPTHS:-0 1 full}"
SAMPLE="${SAMPLE:-15}"
REPETITIONS="${REPETITIONS:-1}"
RUN_TIMEOUT_S="${RUN_TIMEOUT_S:-1800}"
MAX_DATA_GB="${MAX_DATA_GB:-50}"
TEST_XMX="${TEST_XMX:-4g}"
KEEP_DATA="${KEEP_DATA:-0}"
RESULT_FILE="${RESULT_FILE:-statesizes.txt}"

if [ ! -f "$STATE_AGENT_JAR" ]; then
	echo "Agent jar $STATE_AGENT_JAR missing; build it in ../kieker (branch state-capture) using ./gradlew bytebuddyJar"
	exit 1
fi
STATE_AGENT_JAR=$(realpath "$STATE_AGENT_JAR")

setKiekerSignatures "$PROJECT"
if [ -z "$KIEKER_SIGNATURES_INCLUDE" ]; then
	echo "No Kieker signatures defined for project $PROJECT"
	exit 1
fi
SIGNATURES="$KIEKER_SIGNATURES_INCLUDE"
unset KIEKER_SIGNATURES_INCLUDE
unset KIEKER_STATE_DEPTH

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

runfolder=$(pwd)/statesizes_$PROJECT
mkdir -p "$runfolder"

# Selects SAMPLE bugs of the project from tracelength.txt, evenly spread over the sorted trace lengths
selectBugs() {
	if [ ! -f tracelength.txt ]; then
		echo "tracelength.txt missing; run ./getCallTreeSizes.sh $PROJECT first or pass bug ids" >&2
		return 1
	fi
	grep "^$PROJECT " tracelength.txt \
		| awk '{split($4, a, "="); if (a[2] > 0) print $2, a[2]}' \
		| sort -k2 -n \
		| awk -v n="$SAMPLE" '{id[NR] = $1} END {
			if (NR <= n) { for (i = 1; i <= NR; i++) print id[i] }
			else if (n == 1) { print id[int((NR + 1) / 2)] }
			else { for (i = 0; i < n; i++) print id[int(i * (NR - 1) / (n - 1)) + 1] }
		}' \
		| sort -n -u
}

# Returns the failing test of the bug from tracelength.txt (determined by getCallTreeSizes.sh)
getKnownTest() {
	local bug_id=$1
	if [ -f tracelength.txt ]; then
		grep "^$PROJECT $bug_id " tracelength.txt | head -n 1 | awk '{print $3}'
	fi
}

# Reads the value of a key from the state summary (key=value pairs separated by spaces)
getSummaryValue() {
	local summary=$1
	local key=$2
	echo "$summary" | tr ' ' '\n' | grep "^$key=" | head -n 1 | cut -d'=' -f2
}

# Runs the test with a time and data size limit; sets RUN_STATUS, RUN_EXIT, RUN_SECONDS and RUN_MAXRSS
runLimited() {
	local logfile=$1
	local datadir=$2
	local max_bytes=$((MAX_DATA_GB * 1024 * 1024 * 1024))
	local rssfile="$runfolder/rss.tmp"
	local endfile="$runfolder/end.tmp"
	rm -f "$rssfile" "$endfile"
	# the end time is written by the child itself, so polling does not affect the measured duration
	local command="cd $PROJECTFOLDER && mvn test -Dtest=$test; rc=\$?; date +%s.%N > $endfile; exit \$rc"

	local start=$(date +%s.%N)
	if [ -x /usr/bin/time ]; then
		setsid /usr/bin/time -f "%M" -o "$rssfile" bash -c "$command" &> "$logfile" &
	else
		setsid bash -c "$command" &> "$logfile" &
	fi
	local pid=$!

	RUN_STATUS=finished
	while kill -0 $pid 2> /dev/null; do
		sleep 2
		local elapsed=$(awk -v s="$start" -v e="$(date +%s.%N)" 'BEGIN {print int(e - s)}')
		if [ "$elapsed" -ge "$RUN_TIMEOUT_S" ]; then
			RUN_STATUS=timeout
		else
			local size=$(du -scb /tmp/kieker-[0-9]* "$datadir" 2> /dev/null | tail -n 1 | cut -f1)
			if [ -n "$size" ] && [ "$size" -gt "$max_bytes" ]; then
				RUN_STATUS=aborted_data_limit
			fi
		fi
		if [ "$RUN_STATUS" != "finished" ]; then
			kill -- -$pid 2> /dev/null
			sleep 5
			kill -9 -- -$pid 2> /dev/null
			break
		fi
	done
	wait $pid 2> /dev/null
	RUN_EXIT=$?
	local end=$(date +%s.%N)
	if [ "$RUN_STATUS" == "finished" ] && [ -s "$endfile" ]; then
		end=$(cat "$endfile")
	fi
	RUN_SECONDS=$(awk -v s="$start" -v e="$end" 'BEGIN {printf "%.2f", e - s}')
	RUN_MAXRSS=NA
	if [ -f "$rssfile" ]; then
		RUN_MAXRSS=$(grep -E '^[0-9]+$' "$rssfile" | tail -n 1)
	fi
}

# Executes the failing test in the given mode and appends the result to RESULT_FILE
measure() {
	local mode=$1
	local rep=$2
	local statedir="$runfolder/state_${bug_id}_${mode}_${rep}"
	rm -rf /tmp/kieker-[0-9]* "$statedir"
	mkdir -p "$statedir"

	unset KIEKER_SIGNATURES_INCLUDE KIEKER_STATE_DEPTH KIEKER_STATE_OUTPUT
	case $mode in
		uninstrumented) ;;
		kieker) export KIEKER_SIGNATURES_INCLUDE="$SIGNATURES" ;;
		state-*)
			export KIEKER_SIGNATURES_INCLUDE="$SIGNATURES"
			export KIEKER_STATE_DEPTH="${mode#state-}"
			export KIEKER_STATE_OUTPUT="$statedir"
			;;
	esac

	echo "Bug $bug_id: running $test in mode $mode (repetition $rep)"
	runLimited "$runfolder/${bug_id}_${mode}_${rep}.txt" "$statedir"

	local kiekerBytes=$(du -scb /tmp/kieker-[0-9]* 2> /dev/null | tail -n 1 | cut -f1)
	local stateBytes=$(du -scb "$statedir" 2> /dev/null | tail -n 1 | cut -f1)
	local summary=""
	local summaryFile=$(ls "$statedir"/kieker-state-*/summary.txt 2> /dev/null | head -n 1)
	if [ -n "$summaryFile" ]; then
		summary=$(cat "$summaryFile")
	fi

	echo "$PROJECT $bug_id $test mode=$mode rep=$rep status=$RUN_STATUS exit=$RUN_EXIT seconds=$RUN_SECONDS maxRssKB=$RUN_MAXRSS" \
		"kiekerBytes=${kiekerBytes:-0} stateBytes=${stateBytes:-0}" \
		"stateEntries=$(getSummaryValue "$summary" entries) maxEntryBytes=$(getSummaryValue "$summary" maxEntryBytes)" \
		"expandedObjects=$(getSummaryValue "$summary" expandedObjects) serializationNanos=$(getSummaryValue "$summary" serializationNanos)" \
		"failures=$(getSummaryValue "$summary" failures)" >> "$RESULT_FILE"

	if [ "$KEEP_DATA" == "1" ]; then
		mkdir -p "$statedir/kieker"
		mv /tmp/kieker-[0-9]* "$statedir/kieker/" 2> /dev/null
	else
		rm -rf /tmp/kieker-[0-9]* "$statedir"
	fi
}

if [ $# -gt 0 ]; then
	BUGS="$*"
else
	BUGS=$(selectBugs) || exit 1
fi
echo "Bugs: $BUGS"

for bug_id in $BUGS
do
	PROJECTFOLDER=/tmp/"$PROJECT"_"$bug_id"_buggy_state
	if [ ! -d $PROJECTFOLDER ]
	then
		defects4j checkout -p $PROJECT -v "$bug_id"b -w $PROJECTFOLDER
		echo "target" >> $PROJECTFOLDER/.gitignore
	fi

	if [ ! -f $PROJECTFOLDER/pom.xml ]; then
		echo "$PROJECT $bug_id - mode=all status=skipped_no_pom" >> "$RESULT_FILE"
		rm -rf $PROJECTFOLDER
		continue
	fi

	fixPomXML $PROJECTFOLDER $bug_id
	sed -i '/<dependencies>/a <dependency><groupId>org.slf4j</groupId><artifactId>slf4j-simple</artifactId><version>2.0.18</version><scope>test</scope></dependency>' $PROJECTFOLDER/pom.xml

	test=$(getKnownTest $bug_id)
	if [ -z "$test" ]; then
		(cd $PROJECTFOLDER/ && mvn clean test) &> $runfolder/before_"$bug_id".txt
		test=$(getTestFromLogfile $runfolder/before_"$bug_id".txt)
	fi
	if [ -z "$test" ]; then
		echo "No failing tests; skipping bug $bug_id"
		echo "$PROJECT $bug_id - mode=all status=skipped_no_failing_test" >> "$RESULT_FILE"
		rm -rf $PROJECTFOLDER
		continue
	fi

	# Same argLine for all modes; modes only differ in environment variables
	editSurefire $PROJECT $PROJECTFOLDER $bug_id "-javaagent:$STATE_AGENT_JAR" "-Dkieker.monitoring.configuration=$(pwd)/kieker-binary.properties -Xmx$TEST_XMX"
	(cd $PROJECTFOLDER && mvn clean test-compile) &> $runfolder/compile_"$bug_id".txt
	# Warm-up (not measured), e.g., for resolving the surefire plugin
	(unset KIEKER_SIGNATURES_INCLUDE KIEKER_STATE_DEPTH; cd $PROJECTFOLDER && mvn test -Dtest=$test) &> $runfolder/warmup_"$bug_id".txt

	for rep in $(seq 1 $REPETITIONS)
	do
		measure uninstrumented $rep
		measure kieker $rep
		for depth in $STATE_DEPTHS
		do
			measure state-$depth $rep
		done
	done
	rm -rf $PROJECTFOLDER
done
