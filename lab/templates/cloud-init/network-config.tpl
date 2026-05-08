version: 2
ethernets:
  # Single-NIC blank: the lab-LAN NIC (Lab-NAT switch, MAC pinned to
  # @@DOMAIN_MAC_COLON@@ by New-CoreTestVM.ps1; dnsmasq hands it
  # @@DOMAIN_IP@@). MAC-based match keeps the binding deterministic
  # regardless of which kernel-predictable name (eth0 / enp1s0 / ens3)
  # the host picks at boot.
  lab:
    match:
      macaddress: "@@DOMAIN_MAC_COLON@@"
    dhcp4: true
    dhcp6: false
    # Force a MAC-based DHCP client-id instead of systemd-networkd's
    # default DUID. Without this, dnsmasq sees the DUID as the client-id
    # and refuses to match the MAC-only dhcp-host= reservation, handing
    # out a dynamic-pool address instead. Affects build-time only — at
    # deploy time the operator typically picks a static IP via the
    # core-init wizard, but leaving this here keeps reservation-aware
    # servers behaving deterministically.
    dhcp-identifier: mac
