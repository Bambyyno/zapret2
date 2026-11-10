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
LIVE="$RUNDIR/live.log"
STATE="$RUNDIR/state"
SUMMARY="$RUNDIR/summary.txt"
OPTFILE="$RUNDIR/opt.txt"
NOTEFILE="$RUNDIR/notes.txt"

umask 022

# Probe names. blockcheck skips a host that already answers with no bypass.
# redirector.googlevideo.com is a real video hostname. The apex often refuses
# the connection, while the player uses *.googlevideo.com.
# Innertube in Chrome is www.youtube.com/youtubei/v1/, not a separate host.
# i.ytimg.com and yt3.ggpht.com are real names. A name that does not resolve
# is left as a DNS failure.
YOUTUBE_DOMAINS="www.youtube.com youtube.com m.youtube.com youtu.be i.ytimg.com ytimg.com yt3.ggpht.com ggpht.com googlevideo.com redirector.googlevideo.com youtubei.googleapis.com"

# Suffix labels written into the picker hostlists. nfqws2 includes subdomains,
# so one label covers the names Chrome actually uses.
YOUTUBE_PAGE_HOSTS="youtube.com
youtu.be
youtubei.googleapis.com
ytimg.com
ggpht.com"
YOUTUBE_VIDEO_HOSTS="googlevideo.com"

# The desync that reached googlevideo, then UDP 443 for the same names.
# There is no service switch that drops UDP 443 only for a hostlist.
# quic_initial_www_google_com.bin is already shipped; no new blob is added.
picker_youtube_opt()
{
	page=/opt/zapret2/ipset/zapret-hosts-picker-page.txt
	video=/opt/zapret2/ipset/zapret-hosts-picker-video.txt
	quic=/opt/zapret2/files/fake/quic_initial_www_google_com.bin
	printf '%s\n' "--filter-l3=ipv4 --filter-tcp=443 --filter-l7=tls --hostlist=$page --hostlist=$video --out-range=-s34228 --in-range=-s5556 --lua-desync=circular:fails=3 --in-range=x --payload=tls_client_hello --lua-desync=hostfakesplit:midhost=midsld:tcp_md5:repeats=1:strategy=1 --payload=tls_client_hello --lua-desync=hostfakesplit:tcp_md5:repeats=1:strategy=2 --new --filter-l3=ipv4 --filter-udp=443 --filter-l7=quic --hostlist=$page --hostlist=$video --blob=quic_google:@$quic --payload=quic_initial --lua-desync=fake:blob=quic_google:repeats=1"
}

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
		cheap|mid|faked|last) picker_lines_${kind}_$fam ;;
		all) picker_lines_$kind ;;
		*) die "family must be cheap, mid, faked, last or all" ;;
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
	picker_page_list()
	{
		printf '%s\n' "${PICKER_LIST_BASE:-${ZAPRET_BASE:-/opt/zapret2}}/ipset/zapret-hosts-picker-page.txt"
	}
	picker_video_list()
	{
		printf '%s\n' "${PICKER_LIST_BASE:-${ZAPRET_BASE:-/opt/zapret2}}/ipset/zapret-hosts-picker-video.txt"
	}
	agree()
	{
		# $1 proto $2 ip $3 role (page, video, or any).
		# Sets $agreed to the shared line with the lowest cost.
		# Page hosts and googlevideo.com are never mixed in one call.
		# A domain that already opened is absent and does not constrain the role.
		agreed=""
		role=${3:-any}
		list="$work/$1.$2.doms"
		[ -f "$list" ] || return 1
		common="$work/$1.$2.$role.common"
		: >"$common"
		agreed_passed="$work/$1.$2.$role.passed"
		: >"$agreed_passed"
		first=1
		seen=0
		while read -r dom; do
			[ -n "$dom" ] || continue
			if [ "$role" != any ]; then
				[ "$(picker_role "$dom")" = "$role" ] || continue
			fi
			file="$work/$1.$2.$dom"
			if [ -s "$file" ] && [ "$(grep -c . "$file")" -eq 1 ] && grep -qx portblock "$file"; then
				notes="$notes$1 ipv$2: $dom is a full IP or port block. Desync was not searched.
"
				continue
			fi
			if [ -s "$file" ] && [ "$(grep -c . "$file")" -eq 1 ] && grep -qx noconnect "$file"; then
				notes="$notes$1 ipv$2: $dom has no connection (curl 7). Desync was not searched.
"
				continue
			fi
			if [ ! -s "$file" ] || { [ "$(grep -c . "$file")" -eq 1 ] && grep -qx '-' "$file"; }; then
				notes="$notes$1 ipv$2 $role: $dom did not pass.
"
				continue
			fi
			# A domain that opened is kept even when a neighbour did not.
			if ! grep -vx -e '-' -e 'portblock' "$file" | grep -q .; then
				notes="$notes$1 ipv$2 $role: $dom did not pass.
"
				continue
			fi
			printf '%s\n' "$dom" >>"$agreed_passed"
			seen=1
			if [ "$first" = 1 ]; then
				cat "$file" >"$common"
				first=0
			else
				nextf="$work/$1.$2.$role.next"
				: >"$nextf"
				while read -r line; do
					[ -n "$line" ] || continue
					grep -Fx -e "$line" "$file" >/dev/null && printf '%s\n' "$line" >>"$nextf"
				done <"$common"
				mv "$nextf" "$common"
			fi
		done <"$list"
		[ "$seen" = 1 ] || return 1
		agreed_file="$work/$1.$2.$role.best"
		: >"$agreed_file"
		rankraw="$work/$1.$2.$role.rankraw"
		: >"$rankraw"
		while read -r line; do
			[ -n "$line" ] || continue
			[ "$line" = "-" ] && continue
			[ "$line" = portblock ] && continue
			cost=$(picker_line_cost "$line")
			printf '%s %s\n' "$cost" "$line" >>"$rankraw"
		done <"$common"
		sort -n "$rankraw" | head -n 3 | sed 's/^[0-9][0-9]* //' >"$agreed_file"
		agreed=$(head -n 1 "$agreed_file")
		if [ -z "$agreed" ]; then
			if [ -s "$agreed_passed" ]; then
				agreed_split=1
				notes="$notes$1 ipv$2 $role: domains opened on different lines. Each keeps its own.
"
				return 0
			fi
			notes="$notes$1 ipv$2 $role: no line passed for every tested domain in this group.
"
			return 1
		fi
		agreed_split=0
		return 0
	}
	passed_csv()
	{
		# $1 file of domain names, one per line.
		# Every googlevideo hostname becomes googlevideo.com: subdomains are included.
		while read -r d; do
			[ -n "$d" ] || continue
			case $d in
				*googlevideo.com) printf '%s\n' googlevideo.com ;;
				*) printf '%s\n' "$d" ;;
			esac
		done <"$1" | awk 'NF && !seen[$0]++' | tr '\n' ',' | sed 's/,$//'
	}
	emit_split_profiles()
	{
		# $1 proto $2 ip $3 role $4 l3 filter tail after hostlist, before the body is added per domain
		proto=$1
		ip=$2
		role=$3
		filt=$4
		while read -r dom; do
			[ -n "$dom" ] || continue
			one="$work/$proto.$ip.$dom.onebest"
			: >"$work/$proto.$ip.$role.rankraw"
			while read -r line; do
				[ -n "$line" ] || continue
				[ "$line" = "-" ] && continue
				[ "$line" = portblock ] && continue
				cost=$(picker_line_cost "$line")
				printf '%s %s\n' "$cost" "$line"
			done <"$work/$proto.$ip.$dom" | sort -n | head -n 3 | sed 's/^[0-9][0-9]* //' >"$one"
			[ -s "$one" ] || continue
			case $dom in
				*googlevideo.com) hdom=googlevideo.com ;;
				*) hdom=$dom ;;
			esac
			body=$(picker_body_from "$one")
			add_profile "$filt --hostlist-domains=$hdom $body"
			notes="$notes$proto ipv$ip: $dom keeps its own confirmed line.
"
		done <"$work/$proto.$ip.$role.passed"
	}
	picker_tag_line()
	{
		num=$1
		shift
		out=""
		for tok in "$@"; do
			case $tok in
				--lua-desync=*) tok="${tok}:strategy=${num}" ;;
			esac
			out="${out:+$out }$tok"
		done
		printf '%s\n' "$out"
	}
	picker_body_from()
	{
		file=$1
		count=$(grep -c . "$file")
		body=""
		n=0
		if [ "$count" -ge 2 ]; then
			body="--out-range=-s34228 --in-range=-s5556 --lua-desync=circular:fails=3 --in-range=x"
		fi
		while read -r line; do
			[ -n "$line" ] || continue
			n=$((n + 1))
			[ "$n" -gt 3 ] && break
			if [ "$count" -ge 2 ]; then
				tagged=$(picker_tag_line "$n" $line)
				body="$body $tagged"
			else
				body="${body:+$body }$line"
			fi
		done <"$file"
		printf '%s\n' "$body"
	}
	page_domains()
	{
		printf '%s\n' "www.youtube.com,youtu.be,i.ytimg.com,youtubei.googleapis.com"
	}
	video_domains()
	{
		printf '%s\n' "googlevideo.com"
	}
	video_was_tested()
	{
		# $1 proto $2 ip
		[ -f "$work/$1.$2.googlevideo.com" ]
	}

	for ip in 4 6; do
		if agree http "$ip"; then
			add_profile "--filter-l3=ipv$ip --filter-tcp=80 --filter-l7=http <HOSTLIST> $agreed"
		fi
	done

	emit_agreed()
	{
		# Uses the variables just set by agree. $1 is the profile head.
		# $2 proto $3 ip $4 role, only for the split path.
		head=$1
		if [ "$agreed_split" = 1 ]; then
			emit_split_profiles "$2" "$3" "$4" "$head"
			return
		fi
		csv=$(passed_csv "$agreed_passed")
		body=$(picker_body_from "$agreed_file")
		add_profile "$head --hostlist-domains=$csv $body"
	}
	for ip in 4 6; do
		for role in page video; do
			if [ -f "$work/tls12.$ip.doms" ] && agree tls12 "$ip" "$role"; then
				emit_agreed "--filter-l3=ipv$ip --filter-tcp=443 --filter-l7=tls" tls12 "$ip" "$role"
			elif [ -f "$work/tls13.$ip.doms" ] && agree tls13 "$ip" "$role"; then
				emit_agreed "--filter-l3=ipv$ip --filter-tcp=443 --filter-l7=tls" tls13 "$ip" "$role"
			fi
		done
	done

	quic_drop=0
	quic_ok=0
	for ip in 4 6; do
		f="$work/quic.$ip.googlevideo.com"
		if [ -f "$f" ] && [ "$(grep -c . "$f")" -eq 1 ] && grep -qx '-' "$f"; then
			quic_drop=1
		elif [ -f "$f" ]; then
			quic_ok=1
		fi
	done
	if [ "$quic_drop" = 1 ] && [ "$quic_ok" = 0 ]; then
		notes="$notes""quic: no family passed for googlevideo.com. The proposal drops QUIC and keeps TCP. Nothing is written until save.
"
		add_profile "--filter-udp=443 --filter-l7=quic --lua-desync=drop"
	else
		for ip in 4 6; do
			if agree quic "$ip" page; then
				emit_agreed "--filter-l3=ipv$ip --filter-udp=443 --filter-l7=quic" quic "$ip" page
			fi
			if agree quic "$ip" video; then
				emit_agreed "--filter-l3=ipv$ip --filter-udp=443 --filter-l7=quic" quic "$ip" video
			fi
		done
	fi

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
	: >"$LIVE"
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
	echo "Families: fake and split, TTL and blob, fakedsplit and QUIC blobs, then wssize and ipfrag."
	echo "A remembered failure starts at the next family. repeats are not raised."
	echo "Two or three passing lines are saved as circular strategy numbers in the log."
	echo "www.youtube.com is the page. googlevideo.com is the video host. One does not count for the other."
	echo "The saved strategy is the Chrome profile: both hostfakesplit lines, then UDP 443 with quic_initial_www_google_com.bin."
	echo "Up to $PASSES passes are kept. A much slower neighbor is dropped. The winner is retested, then once more after ${PICKER_DELAY:-3}s."
	echo "NFQWS2_OPT is not written by the test."
	echo "domains=$DOMAINS ip=$IPVS tls12=$ENABLE_TLS12 tls13=$ENABLE_TLS13 quic=$ENABLE_QUIC passes=$PASSES"
	printf '%s\n' "тест запущен. NFQWS2_OPT не пишется, пока не нажата кнопка «Записать сработавшую стратегию»." >>"$LIVE"

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
		PICKER_DELAY="${PICKER_DELAY:-3}" \
		PICKER_STATE="${PICKER_STATE:-$ZAPRET_BASE/picker.state}" \
		PICKER_LIVE="$LIVE" \
		ZAPRET_BASE="$ZAPRET_BASE" \
		ZAPRET_CONFIG="$ZAPRET_CONFIG" \
		sh "$ZAPRET_BASE/blockcheck2.sh"
	) </dev/null >"$LOG" 2>&1
	code=$?

	# Curl is not Chrome. The proposal is the profile that reached gvs,
	# for the suffix host set, plus UDP 443. Hits stay in the log.
	picker_youtube_opt >"$OPTFILE"
	{
		# shellcheck disable=SC1091
		. "$ZAPRET_BASE/blockcheck2.d/picker/candidates.inc"
		echo "blockcheck exit $code"
		echo "A curl pass is not the site opening in a browser."
		if picker_kyber_curl; then
			echo "curl is OpenSSL 3.5 or newer, so Kyber may be in the ClientHello."
		else
			echo "curl is not OpenSSL 3.5 or newer. A pass is not a Kyber pass."
		fi
		echo "NFQWS2_OPT was not written. The save button writes it."
		printf '%s\n' "тест закончен. NFQWS2_OPT не записан, ждёт кнопку «Записать сработавшую стратегию»." >>"$LIVE"
		if grep -q "working without bypass" "$LOG" 2>/dev/null; then
			echo "At least one domain already opened with no bypass, so it was not searched."
		fi
		echo
		if [ -s "$NOTEFILE" ]; then
			cat "$NOTEFILE"
			echo
		fi
		echo "Proposed NFQWS2_OPT is the Chrome profile (not applied yet):"
		cat "$OPTFILE"
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
	svc=stopped
	if [ -x /etc/init.d/zapret2 ] && /etc/init.d/zapret2 status >/dev/null 2>&1; then
		svc=running
	fi
	echo "service=$svc"
	echo "--- summary ---"
	[ -f "$SUMMARY" ] && cat "$SUMMARY"
	echo "--- opt ---"
	[ -f "$OPTFILE" ] && cat "$OPTFILE"
	echo "--- log ---"
	if [ -f "$LIVE" ]; then
		lines=$(wc -l <"$LIVE" | tr -d ' ')
		if [ "$lines" -le 180 ]; then
			cat "$LIVE"
		else
			head -n 2 "$LIVE"
			echo "..."
			tail -n 160 "$LIVE"
		fi
	fi
}

picker_write_hostlists()
{
	# Only the picker-owned lists. User hostlists are not touched.
	# Called from save, not from the test run.
	# One label is a suffix: youtube.com includes www and m, ytimg.com includes
	# i.ytimg.com, ggpht.com includes yt3.ggpht.com, googlevideo.com includes rr*.
	opt=$1
	base="${PICKER_LIST_BASE:-$ZAPRET_BASE}"
	page="${base}/ipset/zapret-hosts-picker-page.txt"
	video="${base}/ipset/zapret-hosts-picker-video.txt"
	printf '%s\n' "$opt" | grep -q 'zapret-hosts-picker-page.txt' && {
		mkdir -p "${base}/ipset"
		printf '%s\n' "$YOUTUBE_PAGE_HOSTS" >"$page"
	}
	printf '%s\n' "$opt" | grep -q 'zapret-hosts-picker-video.txt' && {
		mkdir -p "${base}/ipset"
		printf '%s\n' "$YOUTUBE_VIDEO_HOSTS" >"$video"
	}
}

cmd_apply()
{
	[ -s "$OPTFILE" ] || die "nothing to apply"
	opt=$(cat "$OPTFILE")
	[ -n "$opt" ] || die "nothing to apply"
	[ -f "$ZAPRET_CONFIG" ] || {
		cp "$ZAPRET_BASE/config.default" "$ZAPRET_CONFIG"
	}
	picker_write_hostlists "$opt"
	picker_write_config "$opt" 1
	echo "NFQWS2_OPT updated. Other config keys were left as they were. NFQWS2_ENABLE=1."
	if [ -x /etc/init.d/zapret2 ]; then
		/etc/init.d/zapret2 restart
		echo "service restarted"
	fi
}

# Print the current NFQWS2_OPT value, without the surrounding quotes.
cmd_show_opt()
{
	[ -f "$ZAPRET_CONFIG" ] || die "no config: $ZAPRET_CONFIG"
	awk '
		/^#*[[:space:]]*NFQWS2_OPT="/ {
			rest = $0
			sub(/^[^"]*"/, "", rest)
			if (rest ~ /"$/) {
				sub(/"$/, "", rest)
				printf "%s", rest
				exit
			}
			out = rest
			while ((getline line) > 0) {
				if (line ~ /"$/) {
					sub(/"$/, "", line)
					if (line != "") out = (out == "" ? line : out "\n" line)
					break
				}
				out = (out == "" ? line : out "\n" line)
			}
			printf "%s", out
			exit
		}
		/^#*[[:space:]]*NFQWS2_OPT=/ {
			sub(/^[^=]*=/, "")
			gsub(/^["'\'']|["'\'']$/, "")
			printf "%s", $0
			exit
		}
	' "$ZAPRET_CONFIG"
}

# $1 is the whole strategy, including spaces and newlines. Empty clears it.
cmd_set_opt()
{
	[ $# -le 1 ] || die "set-opt expects the strategy as one argument"
	opt=${1-}
	en=1
	[ -n "$opt" ] || en=0
	[ -f "$ZAPRET_CONFIG" ] || {
		cp "$ZAPRET_BASE/config.default" "$ZAPRET_CONFIG"
	}
	picker_write_hostlists "$opt"
	picker_write_config "$opt" "$en"
	echo "NFQWS2_OPT updated. Other config keys were left as they were. NFQWS2_ENABLE=$en."
	if [ -x /etc/init.d/zapret2 ]; then
		/etc/init.d/zapret2 restart
		echo "service restarted"
	fi
}

cmd_service()
{
	# start or stop the installed service without touching the strategy text.
	case $1 in
		start) en=1 ;;
		stop) en=0 ;;
		*) die "service must be start or stop" ;;
	esac
	[ -f "$ZAPRET_CONFIG" ] || cp "$ZAPRET_BASE/config.default" "$ZAPRET_CONFIG"
	opt=$(cmd_show_opt)
	picker_write_config "$opt" "$en"
	if [ ! -x /etc/init.d/zapret2 ]; then
		echo "NFQWS2_ENABLE=$en. The init script is not installed."
		return 0
	fi
	if [ "$en" = 1 ]; then
		/etc/init.d/zapret2 enable
		/etc/init.d/zapret2 start
		echo "zapret2 started"
	else
		/etc/init.d/zapret2 stop
		/etc/init.d/zapret2 disable
		echo "zapret2 stopped"
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
	check "tls count bounded" "[ \$(printf '%s\n' \"\$tls\" | grep -c .) -lt 140 ]"
	faked=$(IPV=4 "$0" candidates tls faked)
	qfaked=$(IPV=4 ZAPRET_BASE="$ZAPRET_BASE" "$0" candidates quic faked)
	check "faked before wssize" "printf '%s\n' \"\$faked\" | grep -q fakedsplit && printf '%s\n' \"\$faked\" | grep -q hostfakesplit && ! printf '%s\n' \"\$faked\" | grep -q wssize"
	check "sni variant stays repeats 1" "printf '%s\n' \"\$faked\" | grep -q 'sni=www.google.com' && printf '%s\n' \"\$faked\" | grep 'sni=www.google.com' | grep -q 'repeats=1'"
	check "quic blobs before frag" "printf '%s\n' \"\$qfaked\" | grep -q 'quic_initial_www_google_com.bin' && ! printf '%s\n' \"\$qfaked\" | grep -q ipfrag"
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
	PICKER_LIVE="$tmp/live"
	picker_log_try cheap www.youtube.com "--payload=tls_client_hello --lua-desync=multisplit:pos=2" 28 проба
	picker_log_try cheap googlevideo.com "--payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=1" 35 проба
	picker_log "семья cheap | $(picker_where www.youtube.com) | запомнил неудачу. repeats не увеличены."
	picker_log "тест закончен. NFQWS2_OPT не записан, ждёт кнопку «Записать сработавшую стратегию»."
	check "live log names family domain line and result" "grep -q 'семья cheap | ipv4 | страница www.youtube.com | --payload=tls_client_hello --lua-desync=multisplit:pos=2 | проба | результат: timeout curl 28 http 000' \"$tmp/live\""
	check "video domain is labeled" "grep -q 'видео googlevideo.com' \"$tmp/live\" && grep -q 'результат: reset curl 35 http 000' \"$tmp/live\""
	check "unknown curl code is not bucketed" "PICKER_LAST_HTTP=000 picker_result_detail 7 | grep -qx 'curl 7 http 000'"
	check "live log remembers failure and waits for save" "grep -q 'запомнил неудачу' \"$tmp/live\" && grep -q 'ждёт кнопку' \"$tmp/live\""
	mkdir -p "$tmp/run"
	cp "$tmp/live" "$tmp/run/live.log"
	st=$(PICKER_RUNDIR="$tmp/run" "$0" status)
	check "status prints the live log" "printf '%s\n' \"\$st\" | grep -q 'curl 28'"
	IPV=4 IPVV=6
	picker_need_def
	check "ipv4 clears a stale ip6 marker" "[ -z \"$IPVV\" ]"
	printf '%s\n' '--lua-desync=fake:ip6_ttl=1:ip6_hopbyhop' '--lua-desync=fake:ip_ttl=1' | picker_strip_foreign_ip >"$tmp/v4lines"
	check "ipv4 drops ip6 foolings" "grep -q 'ip_ttl=1' \"$tmp/v4lines\" && ! grep -q ip6_ \"$tmp/v4lines\""
	unset PICKER_LIVE
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
	check "page uses hostlist-domains" "printf '%s\n' \"\$opt\" | grep -q 'hostlist-domains=www.youtube.com'"
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
	printf '%s\n' '100 fast-a' '900 slow-b' '110 fast-c' >"$tmp/slow"
	picker_drop_slow "$tmp/slow" "$tmp/slowout"
	check "slow neighbor dropped" "grep -qx fast-a \"$tmp/slowout\" && grep -qx fast-c \"$tmp/slowout\" && ! grep -q slow-b \"$tmp/slowout\""
	ord=$(picker_order_from "$(picker_next_family cheap)")
	check "failure steps to the next family" "[ \"$ord\" = 'mid faked last' ]"
	check "last failure wraps to cheap" "[ \"$(picker_next_family last)\" = cheap ]"
	check "timeout and reset differ" "[ \"$(picker_curl_class 28)\" = timeout ] && [ \"$(picker_curl_class 35)\" = reset ]"
	PICKER_STATS="$tmp/stats"
	printf '%s\n' 'tcp_md5 reset' 'tcp_md5 reset' >"$PICKER_STATS"
	pen=$(picker_reset_penalty "--payload=tls_client_hello --lua-desync=fake:tcp_md5:repeats=1")
	check "reset fooling is penalized" "[ \"$pen\" = 500 ]"
	unset PICKER_STATS
	cat >"$hits" <<'EOF'
tls12 4 www.youtube.com --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:repeats=1
tls12 4 googlevideo.com --payload=tls_client_hello --lua-desync=multisplit:pos=2
quic 4 www.youtube.com --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=1
quic 4 googlevideo.com -
EOF
	NOTEFILE="$tmp/notes" PICKER_LIST_BASE="$tmp" picker_build_opt "$hits" >"$tmp/opt4"
	opt4=$(cat "$tmp/opt4")
	check "page and video are separate domains" "printf '%s\n' \"\$opt4\" | grep -q 'hostlist-domains=www.youtube.com' && printf '%s\n' \"\$opt4\" | grep -q 'hostlist-domains=googlevideo.com'"
	check "video keeps its own tls line" "printf '%s\n' \"\$opt4\" | grep -q 'multisplit:pos=2'"
	check "failed video quic disables quic" "printf '%s\n' \"\$opt4\" | grep -q -- '--lua-desync=drop'"
	check "page quic is not kept" "! printf '%s\n' \"\$opt4\" | grep -q fake_default_quic"
	check "user hostlist name not used" "! printf '%s\n' \"\$opt4\" | grep -q zapret-hosts-user.txt"
	cat >"$hits" <<'EOF'
tls12 4 www.youtube.com --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:repeats=1
tls12 4 www.youtube.com --payload=tls_client_hello --lua-desync=multisplit:pos=2
tls12 4 youtu.be --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:repeats=1
tls12 4 youtu.be --payload=tls_client_hello --lua-desync=multisplit:pos=2
EOF
	NOTEFILE="$tmp/notes" picker_build_opt "$hits" >"$tmp/opt5"
	opt5=$(cat "$tmp/opt5")
	check "two lines become circular" "printf '%s\n' \"\$opt5\" | grep -q 'circular:fails=3' && printf '%s\n' \"\$opt5\" | grep -q 'strategy=1' && printf '%s\n' \"\$opt5\" | grep -q 'strategy=2'"
	cat >"$hits" <<'EOF'
tls12 4 www.youtube.com -
tls12 4 youtubei.googleapis.com --payload=tls_client_hello --lua-desync=hostfakesplit:tcp_md5:repeats=1
tls12 4 youtubei.googleapis.com --payload=tls_client_hello --lua-desync=hostfakesplit:tcp_md5:repeats=1
EOF
	NOTEFILE="$tmp/notes" picker_build_opt "$hits" >"$tmp/opt6"
	opt6=$(cat "$tmp/opt6")
	check "confirmed open is kept for that domain" "printf '%s\n' \"\$opt6\" | grep -q 'hostlist-domains=youtubei.googleapis.com' && printf '%s\n' \"\$opt6\" | grep -q 'hostfakesplit:tcp_md5:repeats=1'"
	check "failed neighbour is not in that profile" "! printf '%s\n' \"\$opt6\" | grep -q 'hostlist-domains=www.youtube.com'"
	check "run does not mention writing before save" "grep -q 'not written' \"$0\""
	cat >"$tmp/config" <<'EOF'
OTHER=keep
NFQWS2_OPT="
--filter-tcp=443 --lua-desync=fake:blob=fake_default_tls
"
NFQWS2_ENABLE=0
EOF
	shown=$(ZAPRET_CONFIG="$tmp/config" "$0" show-opt)
	check "show-opt reads the saved strategy" "printf '%s\n' \"\$shown\" | grep -q 'fake_default_tls'"
	ZAPRET_CONFIG="$tmp/config" "$0" set-opt '--filter-udp=443 --lua-desync=fake:blob=fake_default_quic:repeats=1' >/dev/null
	check "set-opt keeps other keys" "grep -q '^OTHER=keep$' \"$tmp/config\""
	check "set-opt writes the pasted strategy" "grep -q 'fake_default_quic:repeats=1' \"$tmp/config\""
	check "set-opt enables the service" "grep -q '^NFQWS2_ENABLE=1$' \"$tmp/config\""
	check "redirector is the video host" "[ \"$(picker_role redirector.googlevideo.com)\" = video ]"
	cat >"$hits" <<'EOF'
tls12 4 redirector.googlevideo.com --payload=tls_client_hello --lua-desync=hostfakesplit:tcp_md5:repeats=1
EOF
	NOTEFILE="$tmp/notes" picker_build_opt "$hits" >"$tmp/opt7"
	opt7=$(cat "$tmp/opt7")
	check "video profile covers googlevideo subdomains" "printf '%s\n' \"\$opt7\" | grep -q 'hostlist-domains=googlevideo.com' && ! printf '%s\n' \"\$opt7\" | grep -q 'hostlist-domains=redirector'"
	ZAPRET_CONFIG="$tmp/config" "$0" service stop >/dev/null
	check "service stop clears enable" "grep -q '^NFQWS2_ENABLE=0$' \"$tmp/config\""
	check "service stop keeps the strategy" "grep -q 'fake_default_quic:repeats=1' \"$tmp/config\""
	preset=$(picker_youtube_opt)
	check "preset is the gvs hostfakesplit pair" "printf '%s\n' \"\$preset\" | grep -q 'hostfakesplit:midhost=midsld:tcp_md5:repeats=1:strategy=1' && printf '%s\n' \"\$preset\" | grep -q 'hostfakesplit:tcp_md5:repeats=1:strategy=2' && printf '%s\n' \"\$preset\" | grep -q 'payload=tls_client_hello'"
	check "preset separates udp with --new" "printf '%s\n' \"\$preset\" | grep -q ' --new ' && printf '%s\n' \"\$preset\" | grep -q 'filter-udp=443' && printf '%s\n' \"\$preset\" | grep -q 'quic_initial_www_google_com.bin'"
	check "preset matches config.default" "grep -F -q -e \"\$preset\" \"$ZAPRET_BASE/config.default\""
	check "probe list includes chrome hosts" "printf '%s\n' \"\$YOUTUBE_DOMAINS\" | grep -qw www.youtube.com && printf '%s\n' \"\$YOUTUBE_DOMAINS\" | grep -qw m.youtube.com && printf '%s\n' \"\$YOUTUBE_DOMAINS\" | grep -qw yt3.ggpht.com && printf '%s\n' \"\$YOUTUBE_DOMAINS\" | grep -qw i.ytimg.com && printf '%s\n' \"\$YOUTUBE_DOMAINS\" | grep -qw ggpht.com && printf '%s\n' \"\$YOUTUBE_DOMAINS\" | grep -qw youtube.com"
	PICKER_LIST_BASE="$tmp" picker_write_hostlists "$preset"
	check "page list uses suffix labels" "grep -qx youtube.com \"$tmp/ipset/zapret-hosts-picker-page.txt\" && grep -qx ytimg.com \"$tmp/ipset/zapret-hosts-picker-page.txt\" && grep -qx ggpht.com \"$tmp/ipset/zapret-hosts-picker-page.txt\" && grep -qx youtu.be \"$tmp/ipset/zapret-hosts-picker-page.txt\" && grep -qx youtubei.googleapis.com \"$tmp/ipset/zapret-hosts-picker-page.txt\" && ! grep -qx www.youtube.com \"$tmp/ipset/zapret-hosts-picker-page.txt\" && ! grep -qx i.ytimg.com \"$tmp/ipset/zapret-hosts-picker-page.txt\""
	check "video list is the googlevideo suffix" "grep -qx googlevideo.com \"$tmp/ipset/zapret-hosts-picker-video.txt\" && [ \"\$(grep -c . \"$tmp/ipset/zapret-hosts-picker-video.txt\")\" -eq 1 ]"
	rm -rf "$tmp"
	[ "$fail" = 0 ] || exit 1
	echo self-test passed
}

usage()
{
	echo "usage: zapret2-picker.sh start-bg|run|status|apply|show-opt|set-opt|service|write-hostlists|candidates|self-test" >&2
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
	show-opt) cmd_show_opt ;;
	set-opt) cmd_set_opt "$@" ;;
	write-hostlists) picker_write_hostlists "$(picker_youtube_opt)" ;;
	service) cmd_service "$@" ;;
	candidates) cmd_candidates "$@" ;;
	self-test) cmd_self_test ;;
	*) usage ;;
esac
