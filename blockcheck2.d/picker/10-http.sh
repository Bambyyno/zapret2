# shellcheck disable=SC1091
. "$TESTDIR/candidates.inc"

pktws_check_http()
{
	# $1 - curl test function
	# $2 - domain
	picker_lines_http | picker_run_lines "$1" "$2" http
}
