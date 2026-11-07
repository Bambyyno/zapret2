# YouTube picker candidates. Same nfqws2 arguments blockcheck2 already runs.
# Families, cheap first:
#   1. fake (repeats=1) and split/disorder
#   2. TTL, autottl, blob, higher repeats
#   3. wssize and ipfrag
# TLS lines never contain a QUIC payload. The search does not stop on the
# first curl success: it keeps PICKER_KEEP passes in a family, retests the
# shortlist PICKER_RETEST times, and only then moves to a later family.
# Lower repeats and no wssize win.

PICKER_KEEP=${PICKER_KEEP:-3}
PICKER_RETEST=${PICKER_RETEST:-3}
PICKER_DELAY=${PICKER_DELAY:-3}
PICKER_SLOW_FACTOR=${PICKER_SLOW_FACTOR:-3}

picker_need_def()
{
	[ -n "$ZAPRET_BASE" ] || ZAPRET_BASE=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
	# shellcheck disable=SC1091
	. "$ZAPRET_BASE/blockcheck2.d/standard/def.inc"
	# A previous IPv6 pass must not leave IPVV=6 for the IPv4 pass.
	if [ "$IPV" = 6 ]; then
		IPVV=6
	else
		IPVV=
	fi
}

# IPv6 extension headers and ip6_ttl do nothing useful on an IPv4 test.
picker_strip_foreign_ip()
{
	if [ "$IPV" = 6 ]; then
		cat
		return
	fi
	grep -v -E 'ip6_ttl|ip6_autottl|ip6_hopbyhop|ip6_destopt|ip6_routing|ip6_ah' || true
}

# Highest repeats= on the line. Missing repeats counts as 1.
picker_line_repeats()
{
	max=1
	n=$(printf '%s\n' "$1" | grep -o 'repeats=[0-9][0-9]*' | sed 's/^repeats=//' | sort -n | tail -n 1)
	[ -n "$n" ] && max=$n
	printf '%s\n' "$max"
}

# Lower is better. wssize is always worse than a line without it.
picker_line_cost()
{
	rep=$(picker_line_repeats "$1")
	pen=0
	printf '%s\n' "$1" | grep -q 'wssize' && pen=10000
	extra=$(picker_reset_penalty "$1")
	printf '%s\n' $((pen + rep + extra))
}

picker_now_ms()
{
	if [ -r /proc/uptime ]; then
		awk '{printf "%d\n", $1 * 1000}' /proc/uptime
		return
	fi
	printf '%s\n' $(( $(date +%s) * 1000 ))
}

# googlevideo.com is the video host. A page host is never treated as video.
picker_role()
{
	case $1 in
		googlevideo.com) printf '%s\n' video ;;
		*) printf '%s\n' page ;;
	esac
}

picker_where()
{
	case $(picker_role "$1") in
		video) printf '%s\n' "видео $1" ;;
		*) printf '%s\n' "страница $1" ;;
	esac
}

# open, timeout, reset, blocked. The log also keeps the numeric curl code.
picker_result_word()
{
	case $1 in
		0|open) printf '%s\n' open ;;
		28|timeout) printf '%s\n' timeout ;;
		35|52|55|56|reset) printf '%s\n' reset ;;
		blocked) printf '%s\n' blocked ;;
		*) printf '%s\n' other ;;
	esac
}

# Curl's own exit code and the HTTP status it reported. 000 means no status line.
picker_result_detail()
{
	code=$1
	word=$(picker_result_word "$code")
	http=${PICKER_LAST_HTTP:-000}
	[ -n "$http" ] || http=000
	case $word in
		other) printf '%s\n' "curl $code http $http" ;;
		*) printf '%s\n' "$word curl $code http $http" ;;
	esac
}

picker_ip_label()
{
	printf 'ipv%s\n' "${IPV:-4}"
}

picker_log()
{
	[ -n "${PICKER_LIVE:-}" ] || return 0
	printf '%s\n' "$*" >>"$PICKER_LIVE"
}

# family | ip version | page or video domain | strategy line | phase | result
picker_log_try()
{
	detail=$(picker_result_detail "$4")
	picker_log "семья ${1} | $(picker_ip_label) | $(picker_where "$2") | ${3} | ${5} | результат: ${detail}"
}

# Curl 7 means the connection never opened. Desync cannot change that.
picker_mark_noconnect()
{
	# $1 curl test function name, $2 domain
	case $1 in
		*tls12*) proto=tls12 ;;
		*tls13*) proto=tls13 ;;
		*http3*|*quic*) proto=quic ;;
		*) proto=http ;;
	esac
	hits=${PICKER_HITS:-}
	if [ -n "$hits" ]; then
		mkdir -p "$(dirname "$hits")"
		printf '%s %s %s noconnect\n' "$proto" "${IPV:-4}" "$2" >>"$hits"
	fi
	picker_log "семья - | $(picker_ip_label) | $(picker_where "$2") | строка: без обхода | пропуск: нет соединения, desync не ищется | результат: $(picker_result_detail 7)"
}

# Canonical order. faked (fake-split and QUIC file blobs) is before wssize.
picker_canon_families()
{
	printf '%s\n' "cheap mid faked last"
}

# Families from $1 through the end. A failed family is not retried in front.
picker_order_from()
{
	start=$1
	seen=0
	out=""
	for f in $(picker_canon_families); do
		if [ "$f" = "$start" ]; then
			seen=1
		fi
		if [ "$seen" = 1 ]; then
			out="${out:+$out }$f"
		fi
	done
	[ -n "$out" ] || out=$(picker_canon_families)
	printf '%s\n' "$out"
}

picker_next_family()
{
	found=0
	for f in $(picker_canon_families); do
		if [ "$found" = 1 ]; then
			printf '%s\n' "$f"
			return 0
		fi
		if [ "$f" = "$1" ]; then
			found=1
		fi
	done
	printf '%s\n' cheap
}

# Kept for older tests. A remembered success starts there and does not wrap backwards.
picker_family_order()
{
	picker_order_from "${1:-cheap}"
}

picker_state_key()
{
	case $1 in
		quic) kind=quic ;;
		*) kind=tls ;;
	esac
	printf '%s_%s_%s\n' "$kind" "$(picker_role "$2")" "${IPV:-4}"
}

picker_state_path()
{
	printf '%s\n' "${PICKER_STATE:-${ZAPRET_BASE:-/opt/zapret2}/picker.state}"
}

# State values are ok:family or fail:family. A failure makes the next run start after it.
picker_state_value()
{
	file=$(picker_state_path)
	[ -f "$file" ] || return 0
	sed -n "s/^$1=//p" "$file" | head -n 1
}

picker_store_result()
{
	key=$1
	status=$2
	fam=$3
	# A later miss must not erase a family that already opened a domain.
	if [ "$status" = fail ]; then
		cur=$(picker_state_value "$key")
		case $cur in
			ok:*) return 0 ;;
		esac
	fi
	file=$(picker_state_path)
	mkdir -p "$(dirname "$file")"
	tmp=$(mktemp "${TMPDIR:-/tmp}/zapret2-state.XXXXXX") || return 1
	if [ -f "$file" ]; then
		grep -v "^${key}=" "$file" >"$tmp" || true
	fi
	printf '%s=%s:%s\n' "$key" "$status" "$fam" >>"$tmp"
	mv "$tmp" "$file"
}

picker_start_family()
{
	val=$(picker_state_value "$1")
	status=${val%%:*}
	fam=${val#*:}
	if [ "$status" = fail ] && [ -n "$fam" ] && [ "$fam" != "$val" ]; then
		picker_next_family "$fam"
		return
	fi
	if [ "$status" = ok ] && [ -n "$fam" ] && [ "$fam" != "$val" ]; then
		printf '%s\n' "$fam"
		return
	fi
	printf '%s\n' cheap
}

# 28 is a timeout. 35, 52, 55 and 56 are a reset or a recv failure.
picker_curl_class()
{
	case $1 in
		0) printf '%s\n' ok ;;
		28) printf '%s\n' timeout ;;
		35|52|55|56) printf '%s\n' reset ;;
		*) printf '%s\n' other ;;
	esac
}

picker_fool_key()
{
	printf '%s\n' "$1" | grep -o -E 'badsum|tcp_md5|tcp_seq=[^: ]+|tcp_ack=[^: ]+' | head -n 1
}

picker_note_fail()
{
	key=$(picker_fool_key "$1")
	[ -n "$key" ] || return 0
	stats=${PICKER_STATS:-/tmp/zapret2-curl-stats}
	printf '%s %s\n' "$key" "$2" >>"$stats"
}

# A fooling that fails as reset more often than as timeout is a worse score.
picker_reset_penalty()
{
	key=$(picker_fool_key "$1")
	stats=${PICKER_STATS:-/tmp/zapret2-curl-stats}
	[ -n "$key" ] && [ -f "$stats" ] || {
		printf '%s\n' 0
		return
	}
	r=$(grep -c "^${key} reset$" "$stats" || true)
	t=$(grep -c "^${key} timeout$" "$stats" || true)
	if [ "$r" -ge 2 ] && [ "$r" -gt "$t" ]; then
		printf '%s\n' 500
	else
		printf '%s\n' 0
	fi
}

picker_kyber_curl()
{
	ver=$(${CURL:-curl} --version 2>/dev/null | head -n 5)
	printf '%s\n' "$ver" | grep -Eq 'OpenSSL/3\.([5-9]|[1-9][0-9])'
}

# $1 input "milliseconds strategy", $2 output strategy lines.
# A success several times slower than a neighbor in this family is dropped.
# The fastest line is never the one dropped. wssize is not decided here.
picker_drop_slow()
{
	src=$1
	dst=$2
	factor=${PICKER_SLOW_FACTOR:-3}
	: >"$dst"
	[ -s "$src" ] || return 0
	count=$(grep -c . "$src")
	if [ "$count" -le 1 ]; then
		sed 's/^[0-9][0-9]* //' "$src" >"$dst"
		return 0
	fi
	body=$(mktemp "${TMPDIR:-/tmp}/zapret2-slow.XXXXXX") || return 1
	i=1
	while read -r ms line; do
		[ -n "$line" ] || continue
		[ "$ms" -lt 1 ] && ms=1
		printf '%s\n' "$ms" >"$body.ms.$i"
		printf '%s\n' "$line" >"$body.ln.$i"
		i=$((i + 1))
	done <"$src"
	count=$((i - 1))
	i=1
	while [ "$i" -le "$count" ]; do
		ms=$(cat "$body.ms.$i")
		slow=0
		if [ "$i" -gt 1 ]; then
			prev=$(cat "$body.ms.$((i - 1))")
			[ "$ms" -ge $((prev * factor)) ] && slow=1
		fi
		if [ "$i" -lt "$count" ]; then
			nxt=$(cat "$body.ms.$((i + 1))")
			[ "$ms" -ge $((nxt * factor)) ] && slow=1
		fi
		if [ "$slow" = 0 ]; then
			cat "$body.ln.$i" >>"$dst"
		fi
		i=$((i + 1))
	done
	if [ ! -s "$dst" ]; then
		best_i=1
		best_ms=$(cat "$body.ms.1")
		i=2
		while [ "$i" -le "$count" ]; do
			ms=$(cat "$body.ms.$i")
			if [ "$ms" -lt "$best_ms" ]; then
				best_ms=$ms
				best_i=$i
			fi
			i=$((i + 1))
		done
		cat "$body.ln.$best_i" >>"$dst"
	fi
	rm -f "$body".ms.* "$body".ln.*
	rm -f "$body"
}

picker_lines_http_cheap()
{
	local pos fool
	picker_need_def
	for fool in $FOOLINGS_TCP; do
		echo "--payload=http_req --lua-desync=fake:blob=fake_default_http:${fool}:repeats=1"
	done
	for pos in method+2 midsld method+2,midsld; do
		echo "--payload=http_req --lua-desync=multisplit:pos=$pos"
		echo "--payload=http_req --lua-desync=${MULTIDISORDER}:pos=$pos"
	done
	echo "--payload=http_req --lua-desync=tcpseg:pos=0,-1:seqovl=1 --lua-desync=drop"
}

picker_lines_http_mid()
{
	local ttl d
	picker_need_def
	ttl=1
	while [ "$ttl" -le 12 ]; do
		echo "--payload=http_req --lua-desync=fake:blob=fake_default_http:ip${IPVV}_ttl=${ttl}:repeats=1"
		ttl=$((ttl + 1))
	done
	d=1
	while [ "$d" -le 5 ]; do
		echo "--payload=http_req --lua-desync=fake:blob=fake_default_http:ip${IPVV}_autottl=-${d},3-20:repeats=1"
		d=$((d + 1))
	done
	echo "--payload=http_req --lua-desync=fake:blob=0x00000000:tcp_md5:repeats=1"
	echo "--payload=http_req --lua-desync=fake:blob=fake_default_http:tcp_md5:repeats=6"
	echo "--payload=http_req --lua-desync=fake:blob=fake_default_http:tcp_md5 --lua-desync=multisplit:pos=method+2"
}

picker_lines_http_last()
{
	picker_need_def
	echo "--lua-desync=wssize:wsize=1:scale=6 --payload=http_req --lua-desync=multisplit:pos=method+2"
	echo "--payload=http_req --lua-desync=send:ipfrag:ipfrag_pos_tcp=32 --lua-desync=drop"
}

picker_lines_tls_cheap()
{
	local pos fool
	picker_need_def
	for fool in $FOOLINGS_TCP; do
		echo "--payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:${fool}:repeats=1"
	done
	for pos in 2 1 sniext+1 sniext+4 host+1 midsld 1,midsld 1,midsld,1220 1,sniext+1,host+1,midsld-2,midsld,midsld+2,endhost-1; do
		echo "--payload=tls_client_hello --lua-desync=multisplit:pos=$pos"
		echo "--payload=tls_client_hello --lua-desync=${MULTIDISORDER}:pos=$pos"
	done
	echo "--payload=tls_client_hello --lua-desync=tcpseg:pos=0,-1:seqovl=1 --lua-desync=drop"
}

picker_lines_tls_mid()
{
	local ttl d
	picker_need_def
	ttl=1
	while [ "$ttl" -le 12 ]; do
		echo "--payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:ip${IPVV}_ttl=${ttl}:repeats=1"
		ttl=$((ttl + 1))
	done
	d=1
	while [ "$d" -le 5 ]; do
		echo "--payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:ip${IPVV}_autottl=-${d},3-20:repeats=1"
		d=$((d + 1))
	done
	echo "--payload=tls_client_hello --lua-desync=fake:blob=0x00000000:tcp_md5:repeats=1"
	echo "--payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:tls_mod=rnd,dupsid:repeats=1"
	echo "--payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:tls_mod=rnd,dupsid,rndsni:repeats=1"
	echo "--payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:tls_mod=rnd,dupsid,sni=www.google.com:repeats=6"
	echo "--payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000 --lua-desync=multidisorder:pos=1,midsld"
	echo "--payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000:repeats=6 --lua-desync=multidisorder:pos=1,midsld"
	echo "--payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:repeats=11:tls_mod=rnd,dupsid,sni=www.google.com --lua-desync=multidisorder:pos=1,midsld"
}

picker_lines_tls_faked()
{
	picker_need_def
	echo "--payload=tls_client_hello --lua-desync=fakedsplit:pos=2:tcp_md5:repeats=1"
	echo "--payload=tls_client_hello --lua-desync=fakeddisorder:pos=midsld:tcp_md5:repeats=1"
	echo "--payload=tls_client_hello --lua-desync=hostfakesplit:tcp_md5:repeats=1"
	echo "--payload=tls_client_hello --lua-desync=hostfakesplit:midhost=midsld:tcp_md5:repeats=1"
	echo "--payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:repeats=1:tls_mod=rnd,dupsid,sni=www.google.com"
	echo "--payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:repeats=1:tls_mod=rnd,dupsid,sni=www.google.com --lua-desync=multisplit:pos=2"
}

picker_lines_http_faked()
{
	picker_need_def
	echo "--payload=http_req --lua-desync=fakedsplit:pos=method+2:tcp_md5:repeats=1"
	echo "--payload=http_req --lua-desync=hostfakesplit:tcp_md5:repeats=1"
}

picker_quic_blob()
{
	name=$1
	file=$2
	[ -f "$file" ] || return 0
	echo "--blob=${name}:@${file} --payload=quic_initial --lua-desync=fake:blob=${name}:repeats=1"
}

picker_lines_quic_faked()
{
	base=${ZAPRET_BASE:-.}
	picker_quic_blob quic_google "$base/files/fake/quic_initial_www_google_com.bin"
	picker_quic_blob quic_gv "$base/files/fake/quic_initial_rr2---sn-gvnuxaxjvh-o8ge_googlevideo_com.bin"
	picker_quic_blob quic_gv_k1 "$base/files/fake/quic_initial_rr1---sn-xguxaxjvh-n8me_googlevideo_com_kyber_1.bin"
	picker_quic_blob quic_gv_k2 "$base/files/fake/quic_initial_rr1---sn-xguxaxjvh-n8me_googlevideo_com_kyber_2.bin"
}

picker_lines_tls_last()
{
	local pos
	picker_need_def
	for pos in 2 midsld 1,midsld; do
		echo "--lua-desync=wssize:wsize=1:scale=6 --payload=tls_client_hello --lua-desync=multisplit:pos=$pos"
		echo "--lua-desync=wssize:wsize=1:scale=6 --payload=tls_client_hello --lua-desync=${MULTIDISORDER}:pos=$pos"
	done
	for pos in 8 16 32 64; do
		echo "--payload=tls_client_hello --lua-desync=send:ipfrag:ipfrag_pos_tcp=$pos --lua-desync=drop"
	done
}

picker_lines_quic_cheap()
{
	local fool
	picker_need_def
	echo "--payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=1"
	if [ "$IPV" = 6 ]; then
		for fool in ip6_hopbyhop ip6_destopt ip6_hopbyhop:ip6_destopt; do
			echo "--payload=quic_initial --lua-desync=send:${fool} --lua-desync=drop"
		done
	fi
}

picker_lines_quic_mid()
{
	picker_need_def
	echo "--payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=6"
	echo "--payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=11"
}

picker_lines_quic_last()
{
	local pos
	picker_need_def
	for pos in 8 16 32 64; do
		echo "--payload=quic_initial --lua-desync=send:ipfrag:ipfrag_pos_udp=$pos --lua-desync=drop"
		echo "--payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=6 --lua-desync=send:ipfrag:ipfrag_pos_udp=$pos --lua-desync=drop"
	done
}

picker_lines_http()
{
	picker_lines_http_cheap
	picker_lines_http_mid
	picker_lines_http_faked
	picker_lines_http_last
}

picker_lines_tls()
{
	picker_lines_tls_cheap
	picker_lines_tls_mid
	picker_lines_tls_faked
	picker_lines_tls_last
}

picker_lines_quic()
{
	picker_lines_quic_cheap
	picker_lines_quic_mid
	picker_lines_quic_faked
	picker_lines_quic_last
}

# One more curl after a pause. The immediate retests are not enough.
picker_recheck_later()
{
	fn=$1
	dom=$2
	shift 2
	delay=${PICKER_DELAY:-3}
	if [ "$delay" -gt 0 ]; then
		picker_log "семья ${PICKER_FAMILY:-?} | $(picker_where "$dom") | пауза ${delay} с перед повторной проверкой"
		sleep "$delay"
	fi
	picker_attempt "повтор после паузы" "$fn" "$dom" "$@"
}

picker_attempt()
{
	phase=$1
	fn=$2
	dom=$3
	shift 3
	line="$*"
	pktws_curl_test_update "$fn" "$dom" $line
	rc=$?
	picker_note_result "$line" "$rc"
	picker_log_try "${PICKER_FAMILY:-?}" "$dom" "$line" "$rc" "$phase"
	return $rc
}

# HEAD can pass while a long body dies at the 16 KB cutoff.
picker_long_get()
{
	fn=$1
	dom=$2
	shift 2
	saved=${HTTPS_HEAD-}
	HTTPS_HEAD=
	picker_attempt "длинный GET" "$fn" "$dom" "$@"
	rc=$?
	HTTPS_HEAD=$saved
	return $rc
}

picker_note_result()
{
	line=$1
	rc=$2
	class=$(picker_curl_class "$rc")
	[ "$class" = ok ] || picker_note_fail "$line" "$class"
}

# Shortlist up to PICKER_KEEP curl passes in this family.
# Drop a pass that is several times slower than its neighbor, retest the
# rest, then confirm the cheapest survivor once more after PICKER_DELAY.
# $3 receives the winning lines (usually one).
picker_family_stable()
{
	fn=$1
	dom=$2
	out=$3
	short=$(mktemp "${TMPDIR:-/tmp}/zapret2-short.XXXXXX") || return 1
	kept=0
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		case $line in
			\#*) continue ;;
		esac
		[ "$kept" -ge "$PICKER_KEEP" ] && break
		t0=$(picker_now_ms)
		picker_attempt "проба" "$fn" "$dom" $line
		rc=$?
		if [ "$rc" = 0 ]; then
			t1=$(picker_now_ms)
			dt=$((t1 - t0))
			[ "$dt" -lt 1 ] && dt=1
			printf '%s %s\n' "$dt" "$line" >>"$short"
			kept=$((kept + 1))
		fi
	done
	if [ -s "$short" ]; then
		keptf=$(mktemp "${TMPDIR:-/tmp}/zapret2-kept.XXXXXX") || {
			rm -f "$short"
			return 1
		}
		picker_drop_slow "$short" "$keptf"
		sorted=$(mktemp "${TMPDIR:-/tmp}/zapret2-sort.XXXXXX") || {
			rm -f "$short" "$keptf"
			return 1
		}
		while IFS= read -r line; do
			[ -n "$line" ] || continue
			printf '%s %s\n' "$(picker_line_cost "$line")" "$line"
		done <"$keptf" | sort -n | sed 's/^[0-9][0-9]* //' >"$sorted"
		while read -r ms line; do
			[ -n "$line" ] || continue
			grep -Fx -e "$line" "$keptf" >/dev/null && continue
			picker_log "семья ${PICKER_FAMILY:-?} | $(picker_where "$dom") | ${line} | пропуск: в несколько раз медленнее соседней"
		done <"$short"
		wins=0
		while IFS= read -r line; do
			[ -n "$line" ] || continue
			ok=0
			n=0
			while [ "$n" -lt "$PICKER_RETEST" ]; do
				n=$((n + 1))
				picker_attempt "перепроверка ${n}/${PICKER_RETEST}" "$fn" "$dom" $line
				rc=$?
				if [ "$rc" = 0 ]; then
					ok=$((ok + 1))
				fi
			done
			if [ "$ok" = "$PICKER_RETEST" ] && picker_long_get "$fn" "$dom" $line && picker_recheck_later "$fn" "$dom" $line; then
				printf '%s\n' "$line" >>"$out"
				wins=$((wins + 1))
				[ "$wins" -ge 3 ] && break
			fi
		done <"$sorted"
		rm -f "$sorted" "$keptf"
	fi
	rm -f "$short"
	[ -s "$out" ]
}

# $1 curl test function, $2 domain, $3 proto (http|tls12|tls13|quic)
# The family that worked last time for this provider and role is tried first.
# If it passes again, the other families are not run.
picker_run_families()
{
	fn=$1
	dom=$2
	proto=$3
	hits="${PICKER_HITS:-/var/run/zapret2-picker/hits}"
	mkdir -p "$(dirname "$hits")"
	stable=$(mktemp "${TMPDIR:-/tmp}/zapret2-stable.XXXXXX") || return 1
	if picker_full_port_block "$dom" "$proto"; then
		printf '%s %s %s portblock\n' "$proto" "$IPV" "$dom" >>"$hits"
		port=${HTTPS_PORT:-443}
		[ "$proto" = http ] && port=${HTTP_PORT:-80}
		picker_log "семья - | $(picker_where "$dom") | порт ${port} | пропуск: полный блок IP или порта, desync не ищется | результат: blocked"
		rm -f "$stable"
		return 1
	fi
	# TLS 1.3 used to walk every family again and could replace a TLS 1.2 open with a miss.
	if [ "$proto" = tls13 ] && picker_proto_touched "$hits" tls12 "$IPV" "$dom"; then
		picker_log "семья - | $(picker_where "$dom") | пропуск: семьи уже пройдены на TLS 1.2, второй полный круг не запускается"
		picker_confirm_saved tls12 tls13 "$fn" "$dom" "$hits"
		rm -f "$stable"
		return 0
	fi
	key=$(picker_state_key "$proto" "$dom")
	remembered=$(picker_state_value "$key")
	start=$(picker_start_family "$key")
	case $remembered in
		fail:*)
			picker_log "семья ${remembered#fail:} | $(picker_where "$dom") | запомнил неудачу с прошлого раза, начинаю с семьи ${start}. repeats не увеличены."
			;;
	esac
	order=$(picker_order_from "$start")
	found=1
	last_fail=""
	for fam in $order; do
		: >"$stable"
		case $proto in
			http) gen=picker_lines_http_$fam ;;
			tls12|tls13) gen=picker_lines_tls_$fam ;;
			quic) gen=picker_lines_quic_$fam ;;
			*) rm -f "$stable"; return 1 ;;
		esac
		PICKER_FAMILY=$fam
		export PICKER_FAMILY
		$gen | picker_strip_foreign_ip | picker_family_stable "$fn" "$dom" "$stable"
		if [ -s "$stable" ]; then
			while IFS= read -r line; do
				[ -n "$line" ] || continue
				printf '%s %s %s %s\n' "$proto" "$IPV" "$dom" "$line" >>"$hits"
			done <"$stable"
			picker_store_result "$key" ok "$fam"
			picker_log "семья ${fam} | $(picker_where "$dom") | запомнил удачную семью. остальные семьи этого домена пропускаются."
			found=0
			rest=0
			for skip in $order; do
				if [ "$rest" = 1 ]; then
					picker_log "семья ${skip} | $(picker_where "$dom") | пропуск: семья ${fam} уже прошла"
				fi
				[ "$skip" = "$fam" ] && rest=1
			done
			break
		fi
		last_fail=$fam
		picker_store_result "$key" fail "$fam"
		picker_log "семья ${fam} | $(picker_where "$dom") | запомнил неудачу. repeats не увеличены. дальше: $(picker_next_family "$fam")"
	done
	rm -f "$stable"
	if [ "$found" != 0 ]; then
		if picker_success_lines "$hits" "$proto" "$IPV" "$dom" | grep -q .; then
			picker_log "семья - | $(picker_where "$dom") | пропуск: подтверждённое открытие остаётся, повторная неудача его не затирает"
			return 0
		fi
		printf '%s %s %s -\n' "$proto" "$IPV" "$dom" >>"$hits"
		return 1
	fi
	return 0
}

picker_proto_touched()
{
	# $1 hits $2 proto $3 ip $4 domain
	[ -f "$1" ] || return 1
	grep -q "^$2 $3 $4 " "$1"
}

picker_success_lines()
{
	# $1 hits $2 proto $3 ip $4 domain
	[ -f "$1" ] || return 0
	while read -r p i d line; do
		[ "$p" = "$2" ] && [ "$i" = "$3" ] && [ "$d" = "$4" ] || continue
		[ -n "$line" ] || continue
		[ "$line" = "-" ] && continue
		[ "$line" = portblock ] && continue
		printf '%s\n' "$line"
	done <"$1"
}

# Try lines already kept for $1 on protocol $2. A miss does not delete $1.
picker_confirm_saved()
{
	src=$1
	dst=$2
	fn=$3
	dom=$4
	hits=$5
	tmp=$(mktemp "${TMPDIR:-/tmp}/zapret2-keep.XXXXXX") || return 1
	picker_success_lines "$hits" "$src" "$IPV" "$dom" >"$tmp"
	[ -s "$tmp" ] || {
		rm -f "$tmp"
		return 0
	}
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		picker_attempt "проверка $dst" "$fn" "$dom" $line
		rc=$?
		if [ "$rc" = 0 ]; then
			printf '%s %s %s %s\n' "$dst" "$IPV" "$dom" "$line" >>"$hits"
		else
			picker_log "семья - | $(picker_where "$dom") | пропуск: строка TLS 1.2 не открыла $dst, полный перебор не повторяется"
		fi
	done <"$tmp"
	rm -f "$tmp"
}

picker_full_port_block()
{
	dom=$1
	proto=$2
	port=${HTTPS_PORT:-443}
	[ "$proto" = http ] && port=${HTTP_PORT:-80}
	ips=""
	if [ -n "${MDIG:-}" ] && [ -x "$MDIG" ]; then
		ips=$(printf '%s\n' "$dom" | "$MDIG" --family="${IPV:-4}" 2>/dev/null)
	fi
	[ -n "$ips" ] || return 1
	if command -v ncat >/dev/null 2>&1; then
		probe="ncat -z -w 2"
	else
		return 1
	fi
	saw=0
	for ip in $ips; do
		saw=1
		# shellcheck disable=SC2086
		if $probe "$ip" "$port" >/dev/null 2>&1; then
			return 1
		fi
	done
	[ "$saw" = 1 ]
}
