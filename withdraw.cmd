bgpd
enable
configure terminal
router bgp 65352
neighbor 172.16.254.254 prefix-list PL1 out
end
clear ip bgp 172.16.254.254 out
exit
