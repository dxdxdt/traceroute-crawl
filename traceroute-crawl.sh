#!/bin/bash
#
# https://stackoverflow.com/questions/34320429/simulating-network-hops-on-a-single-linux-box
#
# traceroute fun with linux namespaces
#  each namespace is basically a router we connect
#  to each other using fancy /32 networking
#
# scott nicholas <scott@nicholas.one> 2018-10-27
# IPv6 version by David Timber <dxdt@dev.snart.me> 2024-07
#

[ -z "$API_URL" ] && API_URL="https://api.hetzner.cloud/v1"
[ -z "$API_RETRY" ] && API_RETRY=3
[ -z "$NS_PREFIX" ] && NS_PREFIX=ns-
[ -z "$HOP_PREFIX" ] && HOP_PREFIX=hop-

hzr_apierr () {
	err=$(jq -r ".error")
	[ "$err" == "null" ] && return 1
	return 0
}

hzr_do_get_rdns () {
	# https://docs.hetzner.cloud/#servers-get-a-server
	# cache the JSON so that the connnection won't stay open
	echo "$(curl -s \
		"$API_URL/servers/$SERVER" \
		-H "Authorization: $AUTH_TOKEN")" |
		jq -r '.server.public_net.ipv6.dns_ptr[] | objects | .ip + " " + .dns_ptr'
}

hzr_do_add_rdns () {
	# https://docs.hetzner.cloud/#server-actions-change-reverse-dns-entry-for-this-server
	local doc="{\"ip\":\"$1\",\"dns_ptr\":\"$2\"}"

	echo "$doc" >&2
	curl -s \
		"$API_URL/servers/$SERVER/actions/change_dns_ptr" \
		-H "Authorization: $AUTH_TOKEN" \
		-H "Content-Type: application/json" \
		-H "Accept: application/json" \
		--data "$doc"
}

hzr_do_rm_rdns () {
	# https://docs.hetzner.cloud/#server-actions-change-reverse-dns-entry-for-this-server
	local doc="{\"ip\":\"$1\",\"dns_ptr\":null}"

	echo "$doc" >&2
	curl -s \
		"$API_URL/servers/$SERVER/actions/change_dns_ptr" \
		-H "Authorization: $AUTH_TOKEN" \
		-H "Content-Type: application/json" \
		-H "Accept: application/json" \
		--data "$doc"
}

do_tail () {
	local j

	for (( j = 0; j < API_RETRY; j += 1 ))
	do
		hzr_do_add_rdns "$TAIL_ADDR" "$TAIL_NAME" \
			| tee /dev/stderr \
			| hzr_apierr \
			|| break
		sleep 2
	done
}

do_add () {
	local i=0
	local j
	local l
	local ip
	local ret

	echo "$PTR_LINES" | while read l
	do
		let 'i += 1'
		ip="$PREFIX$(printf '%x' $i)"

		ret=false
		for (( j = 0; j < API_RETRY; j += 1 ))
		do
			sleep 2
			hzr_do_add_rdns "$ip" "$l" \
				| tee /dev/stderr \
				| hzr_apierr

			if [ $? -ne 0 ]; then
				ret=true
				break
			fi
		done

		"$ret" || exit 1
	done

	if [ $? -eq 0 ]; then
		if [ ! -z "$TAIL_NAME" ]; then
			do_tail || exit 1
		fi

		echo
		echo OK
	fi
}

do_purge () {
	local target_net=$(ipcalc -6 --no-decorate -n "$PREFIX/$CIDR")
	local l
	local j
	local ip
	local name
	local net
	local ret
	local delim_pos

	hzr_do_get_rdns | while read l
	do
		[ -z "$l" ] && continue
		ip=$(echo $l | cut -sd ' ' -f1)
		name=$(echo $l | cut -sd ' ' -f2)

		net=$(ipcalc -6 --no-decorate -n "$ip/$CIDR")
		if [ "$net" == "$target_net" ]; then
			ret=false
			for (( j = 0; j < API_RETRY; j += 1 ))
			do
					sleep 2
					hzr_do_rm_rdns "$ip" "$name" \
						| tee /dev/stderr \
						| hzr_apierr

					if [ $? -ne 0 ]; then
						ret=true
						break
					fi
			done

			"$ret" || exit 1
		fi
	done
}

do_mkns () {
	set -e

	local i=0
	local depth
	local ns
	local if
	local ip
	local j
	local ll

	# count depth
	depth=$(echo "$PTR_LINES" | wc -l)

	sysctl -qw \
		"net.ipv4.conf.all.forwarding=1" \
		"net.ipv4.conf.default.forwarding=1" \
		"net.ipv4.ip_forward=1" \
		"net.ipv6.conf.default.forwarding=1" \
		"net.ipv6.conf.all.forwarding=1" \
		"net.ipv4.ip_default_ttl=$HOPLIMIT" \
		"net.ipv6.conf.all.hop_limit=$HOPLIMIT" \
		"net.ipv6.conf.default.hop_limit=$HOPLIMIT"

	# instead of special casing things, if we bind init's netns into a name
	# all of the code can use "-n ns"
	mkdir -p /var/run/netns
	[ ! -f /var/run/netns/default ] && touch /var/run/netns/default && mount --bind /proc/1/ns/net /var/run/netns/default

	ns[0]=default if[0]=root ip[0]=${PREFIX}
	for ((i = 1; i <= depth; i++))
	do
		n=$(printf '%04x' $i)
		ns[i]=$NS_PREFIX$n if[i]=$HOP_PREFIX$n ip[i]=$PREFIX$n
	done
	n=$(printf '%04x' $i)
	ns[i]=$NS_PREFIX$n if[i]=$HOP_PREFIX$n ip[i]=$TAIL_ADDR
	let 'depth += 1'

	for ((i = 1; i <= depth; i++))
	do
		ip -6 netns add ${ns[i]}
		ip netns exec ${ns[i]} \
			sysctl -qw \
				"net.ipv4.conf.all.forwarding=1" \
				"net.ipv4.conf.default.forwarding=1" \
				"net.ipv4.ip_forward=1" \
				"net.ipv6.conf.default.forwarding=1" \
				"net.ipv6.conf.all.forwarding=1" \
				"net.ipv4.ip_default_ttl=$HOPLIMIT" \
				"net.ipv6.conf.all.hop_limit=$HOPLIMIT" \
				"net.ipv6.conf.default.hop_limit=$HOPLIMIT"
		# interfaces are named by whom is on the other side
		# so it's kinda flip-flopped looking.
		ip -6 -n ${ns[i-1]} link add ${if[i]} type veth peer name ${if[i-1]} netns ${ns[i]}
		ip -6 -n ${ns[i]} a a ${ip[i]}/128 dev ${if[i-1]}

		# interfaces must be up before adding routes
		ip -6 -n ${ns[i-1]} link set ${if[i]}   up
		ip -6 -n ${ns[i  ]} link set lo           up
		ip -6 -n ${ns[i  ]} link set ${if[i-1]} up
	done

	for ((i = 1; i <= depth; i++))
	do
		while true
		do
			ll=$(ip -br -6 -n ${ns[i-1]} addr show dev ${if[i]} scope link | grep -Eo 'fe[^\s/]+')
			# wait for the ll addr to come up
			[ -z "$ll" ] && sleep 0.1 || break
		done

		ip -6 -n ${ns[i  ]} route add default dev ${if[i-1]} via ${ll}
	done

	# tell everyone above my parent that i'm down here in this mess
	for ((i = 0; i < depth; i++))
	do
		while true
		do
			ll=$(ip -br -6 -n ${ns[i+1]} addr show dev ${if[i]} scope link | grep -Eo 'fe[^\s/]+')
			# wait for the ll addr to come up
			[ -z "$ll" ] && sleep 0.1 || break
		done

		for ((j = i + 1; j <= depth; j++))
		do
			ip -6 -n ${ns[i]} route add ${ip[j]} dev ${if[i+1]} via ${ll}
		done
	done

	set +e
}

do_rmns () {
	local i=0
	local depth
	local ns
	local if
	local ll

	# count depth
	depth=$(echo "$PTR_LINES" | wc -l)
	let "depth += 1"

	ns[0]=default if[0]=root
	for (( i = 1; i <= depth; i += 1))
	do
		n=$(printf '%04x' $i)
		ns[i]=$NS_PREFIX$n if[i]=$HOP_PREFIX$n
	done

	for (( i = depth; i > 0; i -= 1))
	do
		ip -n ${ns[i-1]} link del ${if[i]}
		ip netns del ${ns[i]}
	done
}

do_daemon_ns_systemd () {
	set_status () {
		echo "$1" >&2
		systemd-notify --status="$1"
	}

	do_mkns

	set_status "Stopped and holding netns"
	systemd-notify --ready
	kill -STOP 0

	systemd-notify --stopping
	set_status "Deleting netns"
	do_rmns

	set_status ""
}

do_daemon_ns () {
	set_status () {
		echo "$1" >&2
	}

	mk_pidfile () {
		if [ ! -z "$pidfile" ]; then
			echo "$1" > "$pidfile"
		fi
	}

	child_main () {
		set_status "Stopped and holding netns"
		kill -STOP 0
		set_status "Deleting netns"

		do_rmns
	}

	do_mkns
	child_main &
	mk_pidfile $!
}

do_dig () {
	local i=0
	local ip

	echo "$PTR_LINES" | while read l
	do
		let 'i += 1'
		ip="$PREFIX$(printf '%x' $i)"

		echo -e "$ip\t $(dig +short -x "$ip")"
	done

	echo -e "$TAIL_ADDR\t $(dig +short -x "$TAIL_ADDR")"
}

do_help () {
	cat << EOF
EOF
}

cmd="$1"
if [ -z "$cmd" ]; then
	do_help >&2
	exit 2
else
	shift
	"do_$cmd"
fi
