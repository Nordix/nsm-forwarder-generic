#! /bin/sh
##
## template.sh --
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
##  init
##    Called on startup
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
cmd_init() {
	return 0
}
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
      "vni": "$(( (RANDOM << 8) + RANDOM % 256 ))",
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

	# We are in main netns (the forwarder POD has "hostNetwork: true)
	# so bring up the traffic interface
	test -n "$INTERFACE" || INTERFACE="eth3"
	ip link set up dev $INTERFACE || die "Can't bring up [$INTERFACE]"

	local mpref

	mpref=$(cat $json | jq -r '.mechanism_preferences[0].cls')
	if test "$mpref" = "REMOTE"; then
		remote_request_nse
		return 0
	fi

	mpref=$(cat $json | jq -r '.connection.mechanism.cls')
	if test "$mpref" = "REMOTE"; then
		remote_request_nsc
		return 0
	fi

	local_request
}

cmd_close() {
	jq 'del(.path)'
}

# A remote request. We are on the NSC side.
remote_request_nsc() {
	echo "Remote request. NSC side"
	local id=$RANDOM

	local nsc=nsc$id
	local url=$(cat $json | jq -r .mechanism_preferences[0].parameters.inodeURL)
	mknetns $nsc $url

	ip link add name ipvl$id link $INTERFACE type ipvlan mode l2
	ip link set dev ipvl$id netns $nsc

	nsenter --net=/var/run/netns/$nsc $me ifsetup dst ipvl$id $json
	rm -f /var/run/netns/$nsc
}

# A remote request. We are on the NSE side
remote_request_nse() {
	echo "Remote request. NSE side"
	local id=$RANDOM

	local nse=nse$id
	local url=$(cat $json | jq -r .connection.mechanism.parameters.inodeURL)
	mknetns $nse $url

	# First check if the interface is already created
	if nsenter --net=/var/run/netns/$nse ip link show dev ipvl-nse; then
		rm -f /var/run/netns/$nse
		return 0
	fi

	ip link add name ipvl$id link $INTERFACE type ipvlan mode l2
	ip link set dev ipvl$id netns $nse

	nsenter --net=/var/run/netns/$nse $me ifsetup src ipvl$id $json
	rm -f /var/run/netns/$nse
}

# Local request. NSC and NSE are on the same node (this node).
local_request() {
	local url

	local nsc=nsc$id
	url=$(cat $json | jq -r .mechanism_preferences[0].parameters.inodeURL)
	mknetns $nsc $url

	local nse=nse$id
	url=$(cat $json | jq -r .connection.mechanism.parameters.inodeURL)
	mknetns $nse $url

	ip link add name ipvl$id link $INTERFACE type ipvlan mode l2
	ip link set dev ipvl$id netns $nsc
	nsenter --net=/var/run/netns/$nsc $me ifsetup dst ipvl$id $json
	rm -f /var/run/netns/$nsc

	# First check if the interface is already created in the NSE
	if nsenter --net=/var/run/netns/$nse ip link show dev ipvl-nse; then
		rm -f /var/run/netns/$nse
		return 0
	fi

	ip link add name ipvl$id link $INTERFACE type ipvlan mode l2
	ip link set dev ipvl$id netns $nse
	nsenter --net=/var/run/netns/$nse $me ifsetup src ipvl$id $json
	rm -f /var/run/netns/$nse
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
	echo "ifsetup $1 $2 $3"
	json=$3
	local iface=$2
	if test "$1" = "dst"; then
		# This is the NSC. Rename the interface
		iface=$(cat $json | jq -r .mechanism_preferences[0].parameters.name)
		ip link set dev $2 name $iface
	else
		iface=ipvl-nse
		ip link set dev $2 name $iface
	fi

	ip link set up dev $iface

	local x=$1
	local addr=$(cat $json | jq -r .connection.context.ip_context.${x}_ip_addr)
	local ip=ip
	echo $addr | grep -q : && ip="ip -6"
	$ip addr add $addr dev $iface
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
