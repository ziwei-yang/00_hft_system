#!/bin/bash
# enable_arp_filtering.sh
#
# Purpose: Prevent XDP testing on one interface from breaking connectivity on others
#
# Problem:
#   - Multiple NICs (enp109s0, enp108s0, wlp0s20f3) share the same subnet 192.168.185.0/24
#   - By default, Linux uses "weak host model" - any interface can respond to ARP for any local IP
#   - Gateway may learn enp108s0's MAC for traffic meant for enp109s0
#   - When XDP is attached to enp108s0, it can drop/redirect packets meant for other interfaces
#   - This breaks SSH and all connectivity even though XDP is only on enp108s0
#
# Solution:
#   - arp_filter=1: Only respond to ARP if the kernel would route replies out that interface
#   - arp_ignore=1: Only respond to ARP if target IP address is configured on receiving interface
#   - arp_announce=2: Always use the best local address (the one on the outgoing interface)
#
# This ensures each interface only handles its own traffic, isolating XDP testing to enp108s0

set -e

echo "Enabling ARP filtering..."

sysctl -w net.ipv4.conf.all.arp_filter=1
sysctl -w net.ipv4.conf.all.arp_ignore=1
sysctl -w net.ipv4.conf.all.arp_announce=2

echo "ARP filtering enabled. Current settings:"
sysctl net.ipv4.conf.all.arp_filter net.ipv4.conf.all.arp_ignore net.ipv4.conf.all.arp_announce
