# shellcheck disable=SC1091
. "$TESTDIR/candidates.inc"

pktws_check_https_tls12()
{
	picker_run_families "$1" "$2" tls12
}

pktws_check_https_tls13()
{
	picker_run_families "$1" "$2" tls13
}
