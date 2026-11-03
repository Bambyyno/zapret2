# Candidate lines for the LuCI picker.
# Same nfqws2 arguments blockcheck2 already feeds to nfqws2.
# Axes, and only these, match the strategy study:
#   split position, fooling, TTL/autottl, blob, repeats.
# Protocols stay in separate functions. TLS lines are never QUIC lines.
# wssize, oob, http_methodeol and http_unixeol are not ordinary candidates.

picker_need_def()
{
	[ -n "$ZAPRET_BASE" ] || ZAPRET_BASE=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
	# shellcheck disable=SC1091
	. "$ZAPRET_BASE/blockcheck2.d/standard/def.inc"
	IPVV=${IPVV:-}
	[ "$IPV" = 6 ] && IPVV=6
}

picker_lines_http()
{
	local pos fool ttl d
	picker_need_def
	for pos in method+2 midsld method+2,midsld; do
		echo "--payload=http_req --lua-desync=multisplit:pos=$pos"
		echo "--payload=http_req --lua-desync=${MULTIDISORDER}:pos=$pos"
	done
	echo "--payload=http_req --lua-desync=tcpseg:pos=0,-1:seqovl=1 --lua-desync=drop"
	for fool in $FOOLINGS_TCP; do
		echo "--payload=http_req --lua-desync=fake:blob=fake_default_http:${fool}:repeats=1"
	done
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

picker_lines_tls()
{
	local pos fool ttl d
	picker_need_def
	for pos in 2 1 sniext+1 sniext+4 host+1 midsld 1,midsld 1,midsld,1220 1,sniext+1,host+1,midsld-2,midsld,midsld+2,endhost-1; do
		echo "--payload=tls_client_hello --lua-desync=multisplit:pos=$pos"
		echo "--payload=tls_client_hello --lua-desync=${MULTIDISORDER}:pos=$pos"
	done
	echo "--payload=tls_client_hello --lua-desync=tcpseg:pos=0,-1:seqovl=1 --lua-desync=drop"
	for fool in $FOOLINGS_TCP; do
		echo "--payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:${fool}:repeats=1"
	done
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
	echo "--payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:tls_mod=rnd,dupsid,sni=www.google.com:repeats=11"
	echo "--payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000 --lua-desync=multidisorder:pos=1,midsld"
	echo "--payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000:repeats=6 --lua-desync=multidisorder:pos=1,midsld"
	echo "--payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:repeats=11:tls_mod=rnd,dupsid,sni=www.google.com --lua-desync=multidisorder:pos=1,midsld"
}

picker_lines_quic()
{
	local n pos fool
	picker_need_def
	for n in 1 6 11; do
		echo "--payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=$n"
	done
	for pos in 8 16 32 64; do
		echo "--payload=quic_initial --lua-desync=send:ipfrag:ipfrag_pos_udp=$pos --lua-desync=drop"
		echo "--payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=6 --lua-desync=send:ipfrag:ipfrag_pos_udp=$pos --lua-desync=drop"
	done
	if [ "$IPV" = 6 ]; then
		for fool in ip6_hopbyhop ip6_destopt ip6_hopbyhop:ip6_destopt; do
			echo "--payload=quic_initial --lua-desync=send:${fool} --lua-desync=drop"
		done
	fi
}

# $1 curl test function, $2 domain, $3 proto token. Lines on stdin.
# First curl exit 0 wins. HTTP 400 and a foreign redirect stay failures
# because the curl test function is blockcheck's own.
picker_run_lines()
{
	local line found=1
	local hits="${PICKER_HITS:-/var/run/zapret2-picker/hits}"
	mkdir -p "$(dirname "$hits")"
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		case $line in
			\#*) continue ;;
		esac
		if pktws_curl_test_update "$1" "$2" $line; then
			printf '%s %s %s %s\n' "$3" "$IPV" "$2" "$line" >>"$hits"
			found=0
			break
		fi
	done
	[ "$found" = 0 ] || printf '%s %s %s -\n' "$3" "$IPV" "$2" >>"$hits"
	return $found
}
