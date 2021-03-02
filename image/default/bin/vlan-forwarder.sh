#! /bin/sh
##
## vlan-forwarder.sh -- Simple callout implementation for generic forwarder
##
##
## Commands;
##

prg=$(basename $0)
dir=$(dirname $0); dir=$(readlink -f $dir)
tmp=/tmp/${prg}_$$
me=$dir/$prg

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
	test "$cmd" = "env" && set | grep -E '^(__.*|ARCHIVE)='
	return 0
}

## Callout functions;
##  request
##    Expects a NSM-request in json format on stdin.
##    This function shall setup communication and inject interfaces
##
##  mechanism
##    Produce a networkservice.Mechanism mechanism array in json format
##    on stdout
##
##  close
##    Expects a NSM-connection in json format on stdin.
##
cmd_mechanism() {
	cat <<EOF
[
  {
    "cls": "LOCAL",
    "type": "KERNEL"
  },
  {
    "cls": "REMOTE",
    "type": "KERNEL",
    "parameters": {
      "src_ip": "$POD_IP",
      "vlan": "$(( RANDOM % 4093 + 1 ))"
    }
  }
]
EOF
}

cmd_request() {
        # json is global
        mkdir -p $tmp
	json=$tmp/connection.json
	jq 'del(.connection.path)' > $json
	cat $json

	local mpref

	local is_nsc=$(cat $json | jq '.mechanism_preferences[0].parameters | has("name")')

	if test "$is_nsc" != "true"; then
	    echo "Not an NSC request (is_nsc=$is_nsc)"
	    cat $json | jq -r .mechanism_preferences[0].parameters
	    return 0;
	fi

	mpref=$(cat $json | jq -r '.mechanism_preferences[0].cls')
	if test "$mpref" = "REMOTE"; then
		return 0
	fi
	handle_request_nsc
}

cmd_close() {
	jq .
}

# A remote request. We are on the NSC side.
handle_request_nsc() {
	echo "Remote or local request for NSC"
	local id=$RANDOM
	local param=".mechanism_preferences[0].parameters"
	local iface=$(cat $json | jq -r $param.name)
	local dev=$iface$id
	local nsc=nsc$id
	local url=$(cat $json | jq -r $param.inodeURL)
	mknetns $nsc $url

	param=".connection.mechanism.parameters"
	local vlan=$(cat $json | jq -r $param.vlan)

	ip link add link eth2 name $dev type vlan id $vlan
	ip link set up dev eth2
	ip link set dev $dev netns $nsc

	nsenter --net=/var/run/netns/$nsc $me ifsetup $dev $json
	return 0
}

# mknetns <name> <url>
mknetns() {
	# Url example; file:///proc/20/fd/11",
	local file=$(echo $2 | sed -e 's,file://,,')
	mkdir -p /var/run/netns
	ln -s $file /var/run/netns/$1
}

##  ifsetup src/dst <ifname>
##    Shall be called inside a POD's netns. Reads /tmp/connection.json
##
cmd_ifsetup() {
        json=$2
	local iface=$(cat $json | jq -r .mechanism_preferences[0].parameters.name)
	echo "ifsetup $1 > $iface"
	ip link set dev $1 name $iface
	ip link set up dev $iface

	local addr=$(cat $json | jq -r .connection.context.ip_context.dst_ip_addr)
	ip addr add $addr dev $iface
	local p
	for p in $(cat $json | jq -r .connection.context.ip_context.dst_routes[].prefix); do
		ip route add $p dev $iface
	done
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
