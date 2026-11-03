# shellcheck disable=SC1091
. "$TESTDIR/candidates.inc"

pktws_check_http3()
{
	picker_lines_quic | picker_run_lines "$1" "$2" quic
}
