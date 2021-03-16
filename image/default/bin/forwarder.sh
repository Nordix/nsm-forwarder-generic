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
	mkdir -p $tmp
	json=$tmp/connection.json
	jq 'del(.path.path_segments[]|.token,.expires,.id)' > $json
	#jq . > $json
	cat $json

	local cls=$(cat $json | jq -r '.mechanism.cls')
	test "$cls" = "REMOTE" && return 0

	local file=$(cat $json | jq -r .mechanism.parameters.inodeURL | sed -e 's,file://,,')
	echo "File [$file]"
	test -e $file || return 0

	nsenter --net=$file $me ifdel src $json
}

# A remote request. We are on the NSC side.
remote_request_nsc() {
	echo "Remote request. NSC side"
	local nsc=nsc$RANDOM
	local url=$(cat $json | jq -r .mechanism_preferences[0].parameters.inodeURL)
	mknetns $nsc $url

	local param=".connection.mechanism.parameters"
	local raddr=$(cat $json | jq -r $param.dst_ip)
	local vni=$(cat $json | jq -r $param.vni)
	local dev=vni$vni

	ip link add name $dev type geneve id $vni remote $raddr
	ip link set dev $dev netns $nsc

	nsenter --net=/var/run/netns/$nsc $me ifsetup src $dev $json
	rm -f /var/run/netns/$nsc
}

# A remote request. We are on the NSE side
remote_request_nse() {
	echo "Remote request. NSE side"
	local nse=nse$RANDOM
	local url=$(cat $json | jq -r .connection.mechanism.parameters.inodeURL)
	mknetns $nse $url

	local param=".mechanism_preferences[0].parameters"
	local raddr=$(cat $json | jq -r $param.src_ip)
	local vni=$(cat $json | jq -r $param.vni)
	local dev=vni$vni

	ip link add name $dev type geneve id $vni remote $raddr
	ip link set dev $dev netns $nse

	nsenter --net=/var/run/netns/$nse $me ifsetup dst $dev $json
	rm -f /var/run/netns/$nse
}

# Local request. NSC and NSE are on the same node (this node).
local_request() {
	local dev=$(cat $json | jq -r .mechanism_preferences[0].parameters.name)
	local url

	local nsc=nsc$id
	url=$(cat $json | jq -r .mechanism_preferences[0].parameters.inodeURL)
	mknetns $nsc $url

	local nse=nse$id
	url=$(cat $json | jq -r .connection.mechanism.parameters.inodeURL)
	mknetns $nse $url

	ip link add dev veth$id-0 type veth peer name veth$id-1
	ip link set dev veth$id-0 netns $nsc
	ip link set dev veth$id-1 netns $nse

	nsenter --net=/var/run/netns/$nsc $me ifsetup dst veth$id-0 $json
	nsenter --net=/var/run/netns/$nse $me ifsetup src veth$id-1 $json

	rm -f /var/run/netns/$nsc
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

##  ifsetup src/dst <ifname> <json>
##    Shall be called inside a POD's netns.
##
cmd_ifsetup() {
	echo "ifsetup $1 $2 $3"
	json=$3
	local iface=$2
	if test "$1" = "dst"; then
		# This is the NSC. Rename the interface
		iface=$(cat $json | jq -r .mechanism_preferences[0].parameters.name)
		ip link set dev $2 name $iface
	fi

	ip link set up dev $iface

	local x=$1
	local addr=$(cat $json | jq -r .connection.context.ip_context.${x}_ip_addr)
	local ip=ip
	echo $addr | grep -q : && ip="ip -6"
	$ip addr add $addr dev $iface
	local p
	for p in $(cat $json | jq -r .connection.context.ip_context.${x}_routes[].prefix); do
		$ip route add $p dev $iface
	done
}
##  ifdel src/dst <json>
##    Shall be called inside a POD's netns.
##
cmd_ifdel() {
	echo "ifdel $1 $2"
	local x=$1
	json=$2

	# We don't have the name of the interface to delete but we have
	# the address.
	local addr=$(cat $json | jq -r .context.ip_context.${x}_ip_addr | cut -d/ -f1)
	test -n "$addr" || return 0
	echo "Address of interface to delete [$addr]"

	local dev=$(ip -j addr show | jq -r ".[]|select(.addr_info[].local == \"$addr\")|.ifname")
	echo "Interface to delete [$dev]"

	ip link del $dev
	return 0
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
