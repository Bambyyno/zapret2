# shellcheck disable=SC1091
. "$TESTDIR/candidates.inc"

pktws_check_http3()
{
	picker_run_families "$1" "$2" quic
}
