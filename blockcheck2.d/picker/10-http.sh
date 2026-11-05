# shellcheck disable=SC1091
. "$TESTDIR/candidates.inc"

pktws_check_http()
{
	# $1 - curl test function
	# $2 - domain
	picker_run_families "$1" "$2" http
}
