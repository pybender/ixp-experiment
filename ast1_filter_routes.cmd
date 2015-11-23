bgpd
enable
configure terminal
router bgp 65352
neighbor 172.16.254.254 prefix-list PL2 in
neighbor 20.0.0.3 prefix-list PL2 in
end
clear ip bgp 172.16.254.254 in
clear ip bgp 20.0.0.3 in 
