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

picker_need_def()
{
	[ -n "$ZAPRET_BASE" ] || ZAPRET_BASE=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
	# shellcheck disable=SC1091
	. "$ZAPRET_BASE/blockcheck2.d/standard/def.inc"
	IPVV=${IPVV:-}
	[ "$IPV" = 6 ] && IPVV=6
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
	printf '%s\n' $((pen + rep))
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
	picker_lines_http_last
}

picker_lines_tls()
{
	picker_lines_tls_cheap
	picker_lines_tls_mid
	picker_lines_tls_last
}

picker_lines_quic()
{
	picker_lines_quic_cheap
	picker_lines_quic_mid
	picker_lines_quic_last
}

# Shortlist up to PICKER_KEEP curl passes, then retest each PICKER_RETEST times.
# Stable lines are appended to $3, cheapest family that yields one stops the caller.
picker_family_stable()
{
	# $1 curl test function, $2 domain, $3 output file. Lines on stdin.
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
		if pktws_curl_test_update "$fn" "$dom" $line; then
			printf '%s\n' "$line" >>"$short"
			kept=$((kept + 1))
		fi
	done
	if [ -s "$short" ]; then
		sorted=$(mktemp "${TMPDIR:-/tmp}/zapret2-sort.XXXXXX") || {
			rm -f "$short"
			return 1
		}
		while IFS= read -r line; do
			printf '%s %s\n' "$(picker_line_cost "$line")" "$line"
		done <"$short" | sort -n | sed 's/^[0-9][0-9]* //' >"$sorted"
		while IFS= read -r line; do
			[ -n "$line" ] || continue
			ok=0
			n=0
			while [ "$n" -lt "$PICKER_RETEST" ]; do
				if pktws_curl_test_update "$fn" "$dom" $line; then
					ok=$((ok + 1))
				fi
				n=$((n + 1))
			done
			[ "$ok" = "$PICKER_RETEST" ] && printf '%s\n' "$line" >>"$out"
		done <"$sorted"
		rm -f "$sorted"
	fi
	rm -f "$short"
	[ -s "$out" ]
}

# $1 curl test function, $2 domain, $3 proto (http|tls12|tls13|quic)
picker_run_families()
{
	fn=$1
	dom=$2
	proto=$3
	hits="${PICKER_HITS:-/var/run/zapret2-picker/hits}"
	mkdir -p "$(dirname "$hits")"
	stable=$(mktemp "${TMPDIR:-/tmp}/zapret2-stable.XXXXXX") || return 1
	: >"$stable"
	found=1
	for fam in cheap mid last; do
		: >"$stable"
		case $proto in
			http) gen=picker_lines_http_$fam ;;
			tls12|tls13) gen=picker_lines_tls_$fam ;;
			quic) gen=picker_lines_quic_$fam ;;
			*) rm -f "$stable"; return 1 ;;
		esac
		$gen | picker_family_stable "$fn" "$dom" "$stable"
		if [ -s "$stable" ]; then
			while IFS= read -r line; do
				[ -n "$line" ] || continue
				printf '%s %s %s %s\n' "$proto" "$IPV" "$dom" "$line" >>"$hits"
			done <"$stable"
			found=0
			break
		fi
	done
	rm -f "$stable"
	if [ "$found" != 0 ]; then
		printf '%s %s %s -\n' "$proto" "$IPV" "$dom" >>"$hits"
		return 1
	fi
	return 0
}
