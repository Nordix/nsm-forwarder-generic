#! /bin/sh
##
## build.sh --
##
##   Build script nsm-forwarder-generic
##
## Commands;
##

prg=$(basename $0)
dir=$(dirname $0); dir=$(readlink -f $dir)
me=$dir/$prg
tmp=/tmp/${prg}_$$
__forwarder=forwarder-generic

die() {
    echo "ERROR: $*" >&2
    rm -rf $tmp
    exit 1
}
help() {
    grep '^##' $0 | cut -c3-
    rm -rf $tmp
    exit 0
}
test -n "$1" || help
echo "$1" | grep -qi "^help\|-h" && help

log() {
	echo "$prg: $*" >&2
}
dbg() {
	test -n "$__verbose" && echo "$prg: $*" >&2
}

##  env
##    Print environment.
##
cmd_env() {

	test -n "$__tag" || __tag="registry.nordix.org/cloud-native/nsm/${__forwarder}:latest"

	if test "$cmd" = "env"; then
		set | grep -E '^(__.*)='
		return 0
	fi
}


##  image [--tag=registry.nordix.org/cloud-native/nsm/nsm-forwarder:latest]
##    Create the docker image and upload it to the local registry.
##
cmd_image() {
	cmd_env
	cmd_go || die Build
	docker build -t $__tag $dir/image
}

##  go
##    Build local go program. Output to ./image/default/bin
##
cmd_go() {
	local bin=$dir/image/default/bin/nsm-$__forwarder
	cd $dir/cmd/nsm-$__forwarder
	CGO_ENABLED=0 GOOS=linux go build \
		-ldflags "-extldflags '-static' -X main.version=$(date +%F:%T)" \
		-o $bin ./ || die "Build failed"
	strip $bin
}

# Get the command
cmd=$1
shift
grep -q "^cmd_$cmd()" $0 $hook || die "Invalid command [$cmd]"

while echo "$1" | grep -q '^--'; do
    if echo $1 | grep -q =; then
	o=$(echo "$1" | cut -d= -f1 | sed -e 's,-,_,g')
	v=$(echo "$1" | cut -d= -f2-)
	eval "$o=\"$v\""
    else
	o=$(echo "$1" | sed -e 's,-,_,g')
	eval "$o=yes"
    fi
    shift
done
unset o v
long_opts=`set | grep '^__' | cut -d= -f1`

# Execute command
trap "die Interrupted" INT TERM
cmd_$cmd "$@"
status=$?
rm -rf $tmp
exit $status

## Common option;
##
##  [--forwarder=<forwarder-generic|forwarder-kernel>]
##    Default value: forwarder-generic
##
