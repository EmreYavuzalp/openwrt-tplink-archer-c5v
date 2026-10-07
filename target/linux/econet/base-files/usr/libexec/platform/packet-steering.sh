#!/bin/sh
# TP-Link Archer C5v: spread the CPU-path (Wi-Fi <-> WAN/LAN) software
# forwarding across the two VPE threads.
#
# The ethernet IRQ + RX-NAPI and both mt76 Wi-Fi IRQs are wired to CPU0 (the
# en751221-intc cannot reaffine them -- /proc/irq/*/smp_affinity returns EPERM),
# while the mt76 Wi-Fi RX-NAPI threads and TX workers run on CPU1. So CPU0
# carries the ethernet receive + the Wi-Fi interrupt/softirq load and CPU1 the
# Wi-Fi NAPI/TX. Cross-steer the forwarding with RPS so each direction's
# forward/NAT lands on the core *opposite* its receive side:
#   - eth0 ingress (download / wired->Wi-Fi) -> forward on CPU1 (mask 2)
#   - phy* ingress (upload / Wi-Fi->wired)   -> forward on CPU0 (mask 1)
# Measured: download 136 -> 156 Mbit, CPU0 99% -> 76% (balanced with CPU1);
# upload unchanged ~252 Mbit. Only software-forwarded flows are affected; PPE
# hardware-offloaded wired<->WAN traffic never reaches the CPU.
#
# $1 = network.@globals[0].packet_steering uci value (unused for C5v). Every
# other econet board falls through to the generic implementation unchanged.

board="$(cat /tmp/sysinfo/board_name 2>/dev/null)"

if [ "$board" != "tplink,archer-c5v" ]; then
	steering_flows="$(uci -q get network.@globals[0].steering_flows)"
	[ "${steering_flows:-0}" -gt 0 ] && set -- -l "$steering_flows" "$@"
	exec /usr/libexec/network/packet-steering.uc "$@"
fi

# eth0 ingress (download) -> forward on CPU1
for q in /sys/class/net/eth0/queues/rx-*/rps_cpus; do
	[ -e "$q" ] && printf '2' > "$q" 2>/dev/null
done
# Wi-Fi ingress (upload) -> forward on CPU0
for d in phy0-ap0 phy1-ap0; do
	for q in /sys/class/net/"$d"/queues/rx-*/rps_cpus; do
		[ -e "$q" ] && printf '1' > "$q" 2>/dev/null
	done
done

exit 0
