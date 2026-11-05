#!/bin/sh
# Non-interactive strategy search for the running nfqws2 service.
# YouTube hostnames only. TLS and QUIC stay separate profiles.
# Success is blockcheck2's curl result (exit 0, plus HTTP 400 / foreign redirect).
# One curl pass is not a browser result. The run never writes NFQWS2_OPT;
# only the save command does, and it rewrites NFQWS2_OPT and NFQWS2_ENABLE.

EXEDIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
ZAPRET_BASE=${ZAPRET_BASE:-$EXEDIR}
ZAPRET_CONFIG=${ZAPRET_CONFIG:-$ZAPRET_BASE/config}
RUNDIR=${PICKER_RUNDIR:-/var/run/zapret2-picker}
HITS="$RUNDIR/hits"
LOG="$RUNDIR/log"
STATE="$RUNDIR/state"
SUMMARY="$RUNDIR/summary.txt"
OPTFILE="$RUNDIR/opt.txt"
NOTEFILE="$RUNDIR/notes.txt"

umask 022

# Fixed set. blockcheck skips a host that already answers with no bypass.
YOUTUBE_DOMAINS="www.youtube.com youtu.be i.ytimg.com googlevideo.com youtubei.googleapis.com"

die()
{
	echo "$*" >&2
	exit 1
}

valid_domain()
{
	# host or host/path. No shell metacharacters.
	printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9.-]+(/[A-Za-z0-9._~%-]*)*$'
}

parse_start_args()
{
	DOMAINS=$YOUTUBE_DOMAINS
	IPVS=4
	ENABLE_HTTP=0
	ENABLE_TLS12=1
	ENABLE_TLS13=1
	ENABLE_QUIC=1
	PASSES=3
	while [ $# -gt 0 ]; do
		case $1 in
			--domains|--http|--repeats)
				shift 2
				;;
			--ipvs)
				IPVS=$2
				shift 2
				;;
			--tls12)
				ENABLE_TLS12=$2
				shift 2
				;;
			--tls13)
				ENABLE_TLS13=$2
				shift 2
				;;
			--quic)
				ENABLE_QUIC=$2
				shift 2
				;;
			--passes)
				PASSES=$2
				shift 2
				;;
			*)
				die "unknown argument: $1"
				;;
		esac
	done
	case $IPVS in
		4|6|46) ;;
		*) die "ip version must be 4, 6 or 46" ;;
	esac
	case $ENABLE_TLS12 in 0|1) ;; *) die "tls12 must be 0 or 1" ;; esac
	case $ENABLE_TLS13 in 0|1) ;; *) die "tls13 must be 0 or 1" ;; esac
	case $ENABLE_QUIC in 0|1) ;; *) die "quic must be 0 or 1" ;; esac
	case $PASSES in
		2|3) ;;
		*) die "passes must be 2 or 3" ;;
	esac
	for d in $DOMAINS; do
		valid_domain "$d" || die "bad domain: $d"
	done
}

picker_running()
{
	[ -f "$RUNDIR/pid" ] || return 1
	pid=$(cat "$RUNDIR/pid" 2>/dev/null) || return 1
	[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

cmd_candidates()
{
	# $1 http|tls|quic  $2 cheap|mid|last|all
	kind=$1
	fam=${2:-all}
	IPV=${IPV:-4}
	IPVV=
	[ "$IPV" = 6 ] && IPVV=6
	# shellcheck disable=SC1091
	. "$ZAPRET_BASE/blockcheck2.d/picker/candidates.inc"
	case $kind in
		http|tls|quic) ;;
		*) die "candidates: http, tls or quic" ;;
	esac
	case $fam in
		cheap|mid|last) picker_lines_${kind}_$fam ;;
		all) picker_lines_$kind ;;
		*) die "family must be cheap, mid, last or all" ;;
	esac
}

# Replace only NFQWS2_OPT and NFQWS2_ENABLE. Other lines are copied through,
# including a multiline NFQWS2_OPT assignment.
picker_write_config()
{
	opt=$1
	en=${2:-1}
	cfg=$ZAPRET_CONFIG
	[ -f "$cfg" ] || die "no config: $cfg"
	case $opt in
		*\"*|*\'*|*\$*|\`*) die "strategy contains a character the config writer refuses" ;;
	esac
	cfgnew="$cfg.picker.$$"
	NFQWS2_OPT_NEW=$opt NFQWS2_ENABLE_NEW=$en awk '
		BEGIN {
			opt = ENVIRON["NFQWS2_OPT_NEW"]
			en = ENVIRON["NFQWS2_ENABLE_NEW"]
			state = 0
			seen_opt = 0
			seen_en = 0
		}
		state == 1 {
			if ($0 ~ /"$/) state = 0
			next
		}
		/^#*[[:space:]]*NFQWS2_OPT="/ {
			print "NFQWS2_OPT=\"" opt "\""
			seen_opt = 1
			rest = $0
			sub(/^[^"]*"/, "", rest)
			if (rest !~ /"/) state = 1
			next
		}
		/^#*[[:space:]]*NFQWS2_OPT=/ {
			print "NFQWS2_OPT=\"" opt "\""
			seen_opt = 1
			next
		}
		/^#*[[:space:]]*NFQWS2_ENABLE=/ {
			print "NFQWS2_ENABLE=" en
			seen_en = 1
			next
		}
		{ print }
		END {
			if (!seen_opt) print "NFQWS2_OPT=\"" opt "\""
			if (!seen_en) print "NFQWS2_ENABLE=" en
		}
	' "$cfg" >"$cfgnew" || die "config rewrite failed"
	mv "$cfgnew" "$cfg"
}

# Read hits. Print the NFQWS2_OPT value on stdout.
# Notes are written to $NOTEFILE when that variable is set.
# agree() sets $agreed in the current shell. It is not called in a subshell,
# otherwise the notes would be discarded.
picker_build_opt()
{
	hits=$1
	[ -f "$hits" ] || die "no results"
	# shellcheck disable=SC1091
	. "$ZAPRET_BASE/blockcheck2.d/picker/candidates.inc"
	work=$(mktemp -d "${TMPDIR:-/tmp}/zapret2-picker.XXXXXX") || die "mktemp"
	while read -r proto ip dom line; do
		[ -n "$proto" ] || continue
		printf '%s\n' "$line" >>"$work/$proto.$ip.$dom"
		grep -qx "$dom" "$work/$proto.$ip.doms" 2>/dev/null || printf '%s\n' "$dom" >>"$work/$proto.$ip.doms"
	done <"$hits"

	notes=""
	opt=""
	agreed=""
	add_profile()
	{
		[ -n "$opt" ] && opt="$opt --new "
		opt="$opt$1"
	}
	agree()
	{
		# $1 proto $2 ip. Sets $agreed to the shared line with the lowest cost.
		# A domain may have several stable lines. Domains that already opened
		# without bypass are absent from this list and do not constrain it.
		agreed=""
		list="$work/$1.$2.doms"
		[ -f "$list" ] || return 1
		common="$work/$1.$2.common"
		: >"$common"
		first=1
		while read -r dom; do
			[ -n "$dom" ] || continue
			file="$work/$1.$2.$dom"
			if [ ! -s "$file" ] || { [ "$(grep -c . "$file")" -eq 1 ] && grep -qx '-' "$file"; }; then
				notes="$notes$1 ipv$2: $dom did not pass.
"
				return 1
			fi
			if [ "$first" = 1 ]; then
				cat "$file" >"$common"
				first=0
			else
				nextf="$work/$1.$2.next"
				: >"$nextf"
				while read -r line; do
					[ -n "$line" ] || continue
					grep -Fx -e "$line" "$file" >/dev/null && printf '%s\n' "$line" >>"$nextf"
				done <"$common"
				mv "$nextf" "$common"
			fi
		done <"$list"
		best=""
		bestcost=999999
		while read -r line; do
			[ -n "$line" ] || continue
			[ "$line" = "-" ] && continue
			cost=$(picker_line_cost "$line")
			if [ "$cost" -lt "$bestcost" ]; then
				best=$line
				bestcost=$cost
			fi
		done <"$common"
		if [ -z "$best" ]; then
			notes="$notes$1 ipv$2: no line passed for every tested domain.
"
			return 1
		fi
		agreed=$best
		return 0
	}

	for ip in 4 6; do
		if agree http "$ip"; then
			add_profile "--filter-l3=ipv$ip --filter-tcp=80 --filter-l7=http <HOSTLIST> $agreed"
		fi
	done

	for ip in 4 6; do
		t12=""
		t13=""
		if [ -f "$work/tls12.$ip.doms" ]; then
			if agree tls12 "$ip"; then
				t12=$agreed
			fi
		fi
		if [ -f "$work/tls13.$ip.doms" ]; then
			if agree tls13 "$ip"; then
				t13=$agreed
			fi
		fi
		chosen=""
		if [ -n "$t12" ] && [ -n "$t13" ]; then
			if [ "$t12" = "$t13" ]; then
				chosen=$t12
			else
				chosen=$t12
				notes="$notes""tls ipv$ip: TLS 1.2 and TLS 1.3 passed on different lines. The TLS 1.2 line is the one written. nfqws2 cannot filter ClientHello by the negotiated version, so the other line is not a second TLS profile.
"
			fi
		elif [ -n "$t12" ]; then
			chosen=$t12
			[ -f "$work/tls13.$ip.doms" ] && notes="$notes""tls ipv$ip: TLS 1.3 did not pass. The TLS 1.2 line is written alone.
"
		elif [ -n "$t13" ]; then
			chosen=$t13
			[ -f "$work/tls12.$ip.doms" ] && notes="$notes""tls ipv$ip: TLS 1.2 did not pass. The TLS 1.3 line is written alone.
"
		fi
		if [ -n "$chosen" ]; then
			add_profile "--filter-l3=ipv$ip --filter-tcp=443 --filter-l7=tls <HOSTLIST> $chosen"
		fi
	done

	for ip in 4 6; do
		if agree quic "$ip"; then
			add_profile "--filter-l3=ipv$ip --filter-udp=443 --filter-l7=quic <HOSTLIST_NOAUTO> $agreed"
		fi
	done

	# filter-l3 stays on every profile from this run. An IP version that was
	# not tested, or that needed a different line, is not folded into the other.
	printf '%s\n' "$opt"
	if [ -n "$NOTEFILE" ]; then
		printf '%s' "$notes" >"$NOTEFILE"
	fi
	rm -rf "$work"
}

cmd_run()
{
	parse_start_args "$@"
	mkdir -p "$RUNDIR"
	: >"$HITS"
	: >"$LOG"
	: >"$SUMMARY"
	: >"$OPTFILE"
	: >"$NOTEFILE"
	echo running >"$STATE"
	echo $$ >"$RUNDIR/pid"

	was=0
	if [ -x /etc/init.d/zapret2 ] && /etc/init.d/zapret2 status >/dev/null 2>&1; then
		was=1
		/etc/init.d/zapret2 stop
	fi
	restore_svc()
	{
		if [ "$was" = 1 ] && [ -x /etc/init.d/zapret2 ]; then
			/etc/init.d/zapret2 start
		fi
	}
	trap 'restore_svc; echo error >"$STATE"' INT TERM

	echo "curl exit 0 is one pass. It is not a browser, not Kyber, not ECH, not a long download."
	echo "A domain that already opens is not searched."
	echo "Families: fake and split, then TTL and blob, then wssize and ipfrag."
	echo "Up to $PASSES passes are kept, then the shortlist is retested $PASSES times."
	echo "NFQWS2_OPT is not written by the test."
	echo "domains=$DOMAINS ip=$IPVS tls12=$ENABLE_TLS12 tls13=$ENABLE_TLS13 quic=$ENABLE_QUIC passes=$PASSES"

	(
		cd "$ZAPRET_BASE" || exit 1
		BATCH=1 \
		TEST=picker \
		DOMAINS="$DOMAINS" \
		IPVS="$IPVS" \
		ENABLE_HTTP=0 \
		ENABLE_HTTPS_TLS12="$ENABLE_TLS12" \
		ENABLE_HTTPS_TLS13="$ENABLE_TLS13" \
		ENABLE_HTTP3="$ENABLE_QUIC" \
		REPEATS=1 \
		SCANLEVEL=quick \
		SKIP_IPBLOCK=1 \
		PICKER_HITS="$HITS" \
		PICKER_KEEP="$PASSES" \
		PICKER_RETEST="$PASSES" \
		ZAPRET_BASE="$ZAPRET_BASE" \
		ZAPRET_CONFIG="$ZAPRET_CONFIG" \
		sh "$ZAPRET_BASE/blockcheck2.sh"
	) </dev/null >"$LOG" 2>&1
	code=$?

	if [ -s "$HITS" ]; then
		NOTEFILE="$NOTEFILE" picker_build_opt "$HITS" >"$OPTFILE" || true
	fi
	{
		echo "blockcheck exit $code"
		echo "A curl pass is not the site opening in a browser."
		echo "NFQWS2_OPT was not written. The save button writes it."
		if grep -q "working without bypass" "$LOG" 2>/dev/null; then
			echo "At least one domain already opened with no bypass, so it was not searched."
		fi
		echo
		if [ -s "$NOTEFILE" ]; then
			cat "$NOTEFILE"
			echo
		fi
		if [ -s "$OPTFILE" ]; then
			echo "Proposed NFQWS2_OPT (not applied yet):"
			cat "$OPTFILE"
		else
			echo "No line passed. NFQWS2_OPT was not changed."
		fi
	} >"$SUMMARY"

	restore_svc
	trap - INT TERM
	if [ "$code" = 0 ]; then
		echo done >"$STATE"
	else
		echo error >"$STATE"
	fi
	rm -f "$RUNDIR/pid"
	return "$code"
}

cmd_start_bg()
{
	parse_start_args "$@"
	mkdir -p "$RUNDIR"
	if picker_running; then
		die "picker is already running"
	fi
	# Re-exec the checked arguments. The child does not parse the raw client string twice.
	launcher=setsid
	command -v setsid >/dev/null 2>&1 || launcher=
	# shellcheck disable=SC2086
	$launcher "$0" run \
		--ipvs "$IPVS" \
		--tls12 "$ENABLE_TLS12" \
		--tls13 "$ENABLE_TLS13" \
		--quic "$ENABLE_QUIC" \
		--passes "$PASSES" \
		</dev/null >/dev/null 2>&1 &
	echo $! >"$RUNDIR/pid"
	echo running >"$STATE"
	echo started
}

cmd_status()
{
	state=idle
	[ -f "$STATE" ] && state=$(cat "$STATE")
	if picker_running; then
		state=running
	fi
	echo "state=$state"
	echo "--- summary ---"
	[ -f "$SUMMARY" ] && cat "$SUMMARY"
	echo "--- opt ---"
	[ -f "$OPTFILE" ] && cat "$OPTFILE"
	echo "--- log ---"
	if [ -f "$LOG" ]; then
		tail -n 80 "$LOG"
	fi
}

cmd_apply()
{
	[ -s "$OPTFILE" ] || die "nothing to apply"
	opt=$(cat "$OPTFILE")
	[ -n "$opt" ] || die "nothing to apply"
	[ -f "$ZAPRET_CONFIG" ] || {
		cp "$ZAPRET_BASE/config.default" "$ZAPRET_CONFIG"
	}
	picker_write_config "$opt" 1
	echo "NFQWS2_OPT updated. Other config keys were left as they were. NFQWS2_ENABLE=1."
	if [ -x /etc/init.d/zapret2 ]; then
		/etc/init.d/zapret2 restart
		echo "service restarted"
	fi
}

cmd_self_test()
{
	fail=0
	check()
	{
		if ! eval "$2"; then
			echo "FAIL $1"
			fail=1
		else
			echo "ok $1"
		fi
	}
	tls=$(IPV=4 "$0" candidates tls)
	cheap=$(IPV=4 "$0" candidates tls cheap)
	mid=$(IPV=4 "$0" candidates tls mid)
	last=$(IPV=4 "$0" candidates tls last)
	quic=$(IPV=4 "$0" candidates quic)
	qcheap=$(IPV=4 "$0" candidates quic cheap)
	qlast=$(IPV=4 "$0" candidates quic last)
	http=$(IPV=4 "$0" candidates http)
	quic6=$(IPV=6 "$0" candidates quic)

	check "tls has multisplit pos" "printf '%s\n' \"\$tls\" | grep -q 'multisplit:pos=2'"
	check "tls has midsld split" "printf '%s\n' \"\$tls\" | grep -q 'pos=midsld'"
	check "tls has endhost split" "printf '%s\n' \"\$tls\" | grep -q 'endhost-1'"
	check "tls has tcp_md5" "printf '%s\n' \"\$tls\" | grep -q 'tcp_md5'"
	check "tls has badsum" "printf '%s\n' \"\$tls\" | grep -q 'badsum'"
	check "tls has ttl 1 and 12" "printf '%s\n' \"\$tls\" | grep -q 'ip_ttl=1' && printf '%s\n' \"\$tls\" | grep -q 'ip_ttl=12'"
	check "tls has autottl" "printf '%s\n' \"\$tls\" | grep -q 'ip_autottl=-2,3-20'"
	check "tls has zero blob" "printf '%s\n' \"\$tls\" | grep -q 'blob=0x00000000'"
	check "tls has google sni" "printf '%s\n' \"\$tls\" | grep -q 'sni=www.google.com'"
	check "tls has repeats 6 and 11" "printf '%s\n' \"\$tls\" | grep -q 'repeats=6' && printf '%s\n' \"\$tls\" | grep -q 'repeats=11'"
	check "tls stays tls" "! printf '%s\n' \"\$tls\" | grep -q quic_initial"
	check "tls count bounded" "[ \$(printf '%s\n' \"\$tls\" | grep -c .) -lt 90 ]"
	check "cheap is fake and split" "printf '%s\n' \"\$cheap\" | grep -q 'fake:blob=fake_default_tls' && printf '%s\n' \"\$cheap\" | grep -q multisplit"
	check "cheap skips ttl wssize ipfrag" "! printf '%s\n' \"\$cheap\" | grep -Eq 'ip_ttl=|wssize|ipfrag'"
	check "mid is ttl and blob" "printf '%s\n' \"\$mid\" | grep -q 'ip_ttl=1' && printf '%s\n' \"\$mid\" | grep -q 'blob=0x00000000' && ! printf '%s\n' \"\$mid\" | grep -q wssize"
	check "last is wssize and ipfrag" "printf '%s\n' \"\$last\" | grep -q wssize && printf '%s\n' \"\$last\" | grep -q ipfrag_pos_tcp"
	check "quic cheap has no frag" "printf '%s\n' \"\$qcheap\" | grep -q 'repeats=1' && ! printf '%s\n' \"\$qcheap\" | grep -q ipfrag"
	check "quic frag is last" "printf '%s\n' \"\$qlast\" | grep -q ipfrag_pos_udp"
	check "no oob" "! printf '%s\n' \"\$tls\$http\$quic\" | grep -q lua-desync=oob"
	# shellcheck disable=SC1091
	. "$ZAPRET_BASE/blockcheck2.d/picker/candidates.inc"
	c1=$(picker_line_cost "--payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:repeats=1")
	c11=$(picker_line_cost "--payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:repeats=11")
	cw=$(picker_line_cost "--lua-desync=wssize:wsize=1:scale=6 --payload=tls_client_hello --lua-desync=multisplit:pos=2")
	check "fewer repeats is cheaper" "[ \"$c1\" -lt \"$c11\" ] && [ \"$c11\" -lt \"$cw\" ]"
	check "quic is quic only" "! printf '%s\n' \"\$quic\" | grep -q tls_client_hello"
	check "quic has frag and repeats" "printf '%s\n' \"\$quic\" | grep -q 'ipfrag_pos_udp=8' && printf '%s\n' \"\$quic\" | grep -q 'repeats=1'"
	check "quic6 has hopbyhop" "printf '%s\n' \"\$quic6\" | grep -q ip6_hopbyhop"
	check "http has method split" "printf '%s\n' \"\$http\" | grep -q 'method+2'"
	check "every tls line is lua-desync" "! printf '%s\n' \"\$tls\" | grep -v lua-desync | grep -q ."

	tmp=$(mktemp -d)
	cp "$ZAPRET_BASE/config.default" "$tmp/config"
	printf '\nUNRELATED_SENTINEL=keep-me\nMODE_FILTER=hostlist\n' >>"$tmp/config"
	hits="$tmp/hits"
	cat >"$hits" <<'EOF'
tls12 4 www.youtube.com --payload=tls_client_hello --lua-desync=multisplit:pos=2
tls13 4 www.youtube.com --payload=tls_client_hello --lua-desync=multidisorder:pos=1
quic 4 www.youtube.com --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=6
http 4 www.youtube.com -
EOF
	NOTEFILE="$tmp/notes" ZAPRET_CONFIG="$tmp/config" picker_build_opt "$hits" >"$tmp/opt"
	opt=$(cat "$tmp/opt")
	check "tls and quic are separate profiles" "printf '%s\n' \"\$opt\" | grep -q -- '--new '"
	check "tls profile present" "printf '%s\n' \"\$opt\" | grep -q 'filter-l7=tls'"
	check "quic profile present" "printf '%s\n' \"\$opt\" | grep -q 'filter-l7=quic'"
	check "prefer tls12 line" "printf '%s\n' \"\$opt\" | grep -q 'multisplit:pos=2'"
	check "tls13 line not applied" "! printf '%s\n' \"\$opt\" | grep -q 'multidisorder:pos=1'"
	check "failed http omitted" "! printf '%s\n' \"\$opt\" | grep -q 'filter-l7=http'"
	check "hostlist markers kept" "printf '%s\n' \"\$opt\" | grep -q '<HOSTLIST>' && printf '%s\n' \"\$opt\" | grep -q '<HOSTLIST_NOAUTO>'"
	check "ipv4 filter on partial test" "printf '%s\n' \"\$opt\" | grep -q 'filter-l3=ipv4'"
	ZAPRET_CONFIG="$tmp/config" picker_write_config "$opt" 1
	check "sentinel kept" "grep -q '^UNRELATED_SENTINEL=keep-me$' \"$tmp/config\""
	check "mode filter kept" "grep -q '^MODE_FILTER=hostlist$' \"$tmp/config\""
	check "enable set" "grep -q '^NFQWS2_ENABLE=1$' \"$tmp/config\""
	check "opt written" "grep -q 'filter-l7=quic' \"$tmp/config\""
	check "old strategy body removed" "! grep -q 'fake_default_http' \"$tmp/config\""
	check "single NFQWS2_OPT" "[ \$(grep -c '^NFQWS2_OPT=' \"$tmp/config\") -eq 1 ]"
	check "flowoffload untouched" "grep -q '^FLOWOFFLOAD=donttouch$' \"$tmp/config\""
	check "http miss is recorded" "grep -q 'did not pass' \"$tmp/notes\""
	# Same line on v4 and v6 collapses? different lines stay split.
	cat >"$hits" <<'EOF'
quic 4 www.youtube.com --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=1
quic 6 www.youtube.com --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=11
EOF
	NOTEFILE="$tmp/notes" picker_build_opt "$hits" >"$tmp/opt2"
	opt2=$(cat "$tmp/opt2")
	check "ipv4 and ipv6 quic both present" "printf '%s\n' \"\$opt2\" | grep -q 'filter-l3=ipv4' && printf '%s\n' \"\$opt2\" | grep -q 'filter-l3=ipv6'"
	check "repeats not merged" "printf '%s\n' \"\$opt2\" | grep -q 'repeats=1' && printf '%s\n' \"\$opt2\" | grep -q 'repeats=11'"
	cat >"$hits" <<'EOF'
tls12 4 www.youtube.com --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:repeats=11
tls12 4 www.youtube.com --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:repeats=1
tls12 4 www.youtube.com --lua-desync=wssize:wsize=1:scale=6 --payload=tls_client_hello --lua-desync=multisplit:pos=2
tls12 4 youtu.be --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:repeats=11
tls12 4 youtu.be --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:repeats=1
EOF
	NOTEFILE="$tmp/notes" picker_build_opt "$hits" >"$tmp/opt3"
	opt3=$(cat "$tmp/opt3")
	check "shared winner prefers repeats=1" "printf '%s\n' \"\$opt3\" | grep -q 'repeats=1'"
	check "shared winner skips wssize" "! printf '%s\n' \"\$opt3\" | grep -q wssize"
	check "run does not mention writing before save" "grep -q 'not written' \"$0\""
	rm -rf "$tmp"
	[ "$fail" = 0 ] || exit 1
	echo self-test passed
}

usage()
{
	echo "usage: zapret2-picker.sh start-bg|run|status|apply|candidates|self-test" >&2
	exit 1
}

cmd=${1:-}
[ -n "$cmd" ] || usage
shift
case $cmd in
	start-bg) cmd_start_bg "$@" ;;
	run) cmd_run "$@" ;;
	status) cmd_status ;;
	apply) cmd_apply ;;
	candidates) cmd_candidates "$@" ;;
	self-test) cmd_self_test ;;
	*) usage ;;
esac
