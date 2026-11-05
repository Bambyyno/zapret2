# shellcheck disable=SC1091
. "$TESTDIR/candidates.inc"

pktws_check_https_tls12()
{
	picker_lines_tls | picker_run_lines "$1" "$2" tls12
}

pktws_check_https_tls13()
{
	picker_lines_tls | picker_run_lines "$1" "$2" tls13
}
