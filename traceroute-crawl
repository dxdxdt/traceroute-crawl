#!/bin/sh
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

# TODO: remove, put in a separate env file
AUTH_TOKEN="Bearer XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
SERVER="00000000"
PREFIX="2001:db8:574f:4567::"
LINES="a.long.time.ago.in.a.galaxy.far.far.away
star.wars
episode.iv
a.new.hope
it.is.a.period.of.civil.war
rebel.spaceships.striking
from.a.hidden.base.have.won
their.first.victory.against
the.evil.galactic.empire
during.the.battle.rebel
spies.managed.to.steal.secret
plans.to.the.empires
ultimate.weapon.the.death
star.an.armored.space
station.with.enough.power.to
destroy.an.entire.planet
pursued.by.the.empires
sinister.agents.princess
leia.races.home.aboard.her
starship.custodian.of.the
stolen.plans.that.can.save
her.people.and.restore
freedom.to.the.galaxy
l.xxxxxxxxxxxxxxxxxxx.l
l.xxxxxxxxxxxxxxxxxx.l
l.xxxxxxxxxxxxxxxxx.l
l.xxxxxxxxxxxxxxxx.l
l.xxxxxxxxxxxxxxx.l
l.xxxxxxxxxxxxxx.l
l.xxxxxxxxxxxxx.l
l.xxxxxxxxxxxx.l
l.xxxxxxxxxxx.l
l.xxxxxxxxxx.l
l.xxxxxxxxx.l
l.xxxxxxxx.l
l.xxxxxxx.l
l.xxxxxx.l
l.xxxxx.l
l.xxxx.l
l.xxx.l
l.xx.l
l.x.l
l.l
x.x
by.david.timber
dxdt.at.dev.snart.me
tribute.to.ipv6.deployment"
TAIL_NAME="episode-iv.example.net"
TAIL_ADDR="2001:db8:574f:4567::ffff"

do_tail () {
	local doc="{\"ip\":\"$TAIL_ADDR\",\"dns_ptr\":\"$TAIL_NAME\"}"
	echo "$doc" >&2
	curl -s \
		"https://api.hetzner.cloud/v1/servers/$SERVER/actions/change_dns_ptr" \
		-H "Authorization: $AUTH_TOKEN" \
		--json "$doc"
}

do_add () {
	local i=0
	local l
	local doc
	local ip

	for l in $LINES
	do
		let 'i += 1'
		ip="$PREFIX$(printf '%x' $i)"

		while true
		do
			sleep 2

			doc="{\"ip\":\"$ip\",\"dns_ptr\":\"$l\"}"
			echo "$doc" >&2
			curl -s \
				"https://api.hetzner.cloud/v1/servers/$SERVER/actions/change_dns_ptr" \
				-H "Authorization: $AUTH_TOKEN" \
				--json "$doc" \
			| tee /dev/stdout \
			| grep '"error"' | grep null > /dev/null \
			&& break
		done
	done
}

do_ns () {
	# set -e

	local i=0
	local depth
	local ns
	local if
	local ip
	local j
	local ll

	# count depth
	for l in $LINES
	do
		let 'i += 1'
	done
	depth=$i

	sysctl -qw \
		"net.ipv4.conf.all.forwarding = 1" \
		"net.ipv4.conf.default.forwarding = 1" \
		"net.ipv4.ip_forward = 1" \
		"net.ipv6.conf.default.forwarding = 1" \
		"net.ipv6.conf.all.forwarding = 1" \
		"net.ipv4.ip_default_ttl = 128" \
		"net.ipv6.conf.all.hop_limit = 128" \
		"net.ipv6.conf.default.hop_limit = 128"

	# instead of special casing things, if we bind init's netns into a name
	# all of the code can use "-n ns"
	mkdir -p /var/run/netns
	[ ! -f /var/run/netns/default ] && touch /var/run/netns/default && mount --bind /proc/1/ns/net /var/run/netns/default

	ns[0]=default if[0]=root ip[0]=${PREFIX}
	for ((i = 1; i <= depth; i++))
	do
		n=$(printf '%04x' $i)
		ns[i]=ns-$n if[i]=hop-$n ip[i]=$PREFIX$n
	done
	n=$(printf '%04x' $i)
	ns[i]=ns-$n if[i]=hop-$n ip[i]=$TAIL_ADDR
	let 'depth += 1'

	for ((i = 1; i <= depth; i++))
	do
		ip -6 netns add ${ns[i]}
		ip netns exec ${ns[i]} \
			sysctl -qw \
				"net.ipv4.conf.all.forwarding = 1" \
				"net.ipv4.conf.default.forwarding = 1" \
				"net.ipv4.ip_forward = 1" \
				"net.ipv6.conf.default.forwarding = 1" \
				"net.ipv6.conf.all.forwarding = 1" \
				"net.ipv4.ip_default_ttl = 128" \
				"net.ipv6.conf.all.hop_limit = 128" \
				"net.ipv6.conf.default.hop_limit = 128"
		# interfaces are named by whom is on the other side
		# so it's kinda flip-flopped looking.
		ip -6 -n ${ns[i-1]} link add ${if[i]} type veth peer name ${if[i-1]} netns ${ns[i]}
		ip -6 -n ${ns[i]} a a ${ip[i]}/128 dev ${if[i-1]}

		# interfaces must be up before adding routes
		ip -6 -n ${ns[i-1]} link set ${if[i]}   up
		ip -6 -n ${ns[i  ]} link set lo           up
		ip -6 -n ${ns[i  ]} link set ${if[i-1]} up

		#ip -6 -n ${ns[i-1]} route add ${ip[i  ]}/128 dev ${if[i]}
		#ip -6 -n ${ns[i  ]} route add ${ip[i-1]}/128 dev ${if[i-1]}
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
}

do_dig () {
	local i=0
	local ip

	for l in $LINES
	do
		let 'i += 1'
		ip="$PREFIX$(printf '%x' $i)"

		echo -e "$ip\t $(dig +short -x "$ip")"
	done

	echo -e "$TAIL_ADDR\t $(dig +short -x "$TAIL_ADDR")"
}

cmd="$1"
shift
"do_$cmd"
