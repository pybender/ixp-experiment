#!/bin/bash

# Evaluate the convergence property of BGP in an IXP environment.
# Here is the test topology
#                     ______
#                    |      |
#                    |  RS  |
#                    |______|
#                        |
#                        |
#   ______            ___|__            ______
#  |      |          |      |          |      |
#  | AS1  |--------+-| IXP  |-+--------| AST1 |--+   ______     ______
#  |______|        | |______| |        |______|  |  |      |   |      |
#   ______         |          |         ______   +--|TESTSW|---| AST3 |
#  |      |        |          |        |      |  |  |______|   |______|
#  | AS2  |--------+          +--------| AST2 |--+     
#  |______|        |                   |______|
#                  |
#   ______         |
#  |      |        |          
#  | ASn  |--------+          
#  |______|         
#
# Here is how the tests are done
# I. Test Design
# 1. Announcement Tests.
# How quick the network converge when AST1 announces prefixes.
# Tests run with the number of member ASes from 10 to 100, step of 10, and
# each test runs for 10 times
# Prefix test:
# 2. Withdrawal Tests
# AST1 withdraws a prefix.
#
# II. Artifacts
# tcpdump runs on the interface of AST3
# BGP Update MRT dump on all ASes.

PWD=`pwd` # current directory

# RouteServer
RS_NAME=rs
RS_IPADDR=172.16.254.254
RS_ASN=65353

# Member ASes
BASE_ASN=100
AS_NAME=as
# IXP Switch
IXP_SW='ixp-sw'

# A Switch that is used only to get ASes interface up, so we can ping
AS_SW='as-sw'

# Test Net
AS_T1=as-t1
AS_T1_ASN=65352
AS_T1_IPADDR=172.16.254.253
AS_T2=as-t2
AS_T2_ASN=65351
AS_T2_IPADDR=172.16.254.252
AS_T3=as-t3
AS_T3_ASN=65350

TEST_SW='test-sw'
TEST_NET=20.0.0

#Commands
OVSCTL=ovs-vsctl
PIPEWORK=$PWD/pipework

QUAGGA_IMAGE='trungdtbk/quagga:v2.0'
LOG_DIR=$PWD/logs
# Check if the user has root privilege.
if [ "$EUID" != "0" ]; then
      echo "You must be root to run this script."
        exit 1
fi

# Check if a Docker container exists
check_docker() {
    #Remarks: 0 = not exist; 1=not running; 2=running
    rt=2
    CONTAINER=$1
    RUNNING=$(docker inspect --format="{{ .State.Running }}" $CONTAINER 2> /dev/null)
    if [ $? -eq 1 ]; then
        rt=0
    fi

    if [ "$RUNNING" = "false" ]; then
        rt=1
    fi
    echo $rt
}
# Create a member AS 
create_member_as() {
    local as_name=$1
    local asn=$2
    local ipaddr=$3
    local net=$4
    echo "Creating a Docker container for AS: name=$as_name, asn=$asn, ip=$ipaddr"
    local configDir=$PWD/configs/$as_name
    mkdir $configDir 2> /dev/null
    cp -fP $PWD/configs/base/* $configDir/.
    local bgpd_conf=$configDir/bgpd.conf
    local zebra_conf=$configDir/zebra.conf
    cat > $bgpd_conf <<EOF
!
! BGP configuration for $as_name
!
hostname $as_name
password bgpd
log stdout
dump bgp updates /tmp/$as_name-updates.dump
dump bgp routes-mrt /tmp/$as_name-routes.dump
!
router bgp $asn
 bgp router-id $ipaddr
 no bgp enforce-first-as
 neighbor $RS_IPADDR remote-as $RS_ASN
 network $net.0/24
!
line vty
EOF
    cat > $zebra_conf <<EOF
! Zebra configs for $as_name
hostname $as_name
password zebra
line vty
!
EOF
    docker rm -f $as_name
    docker run --privileged -d -P --name $as_name -v $configDir:/etc/quagga -v $LOG_DIR:/tmp/ $QUAGGA_IMAGE
}

create_route_server() {
    local num=$1 # Number of member ASes
    echo "Create a Docker contaner for IXP Route Server"
    local configDir=$PWD/configs/$RS_NAME
    mkdir $configDir 2> /dev/null
    cp -fP $PWD/configs/base/* $configDir/.
    # Generate bgpd.conf
    cat > $configDir/bgpd.conf <<EOF
!
! BGP configuration for Route Server
!
hostname RS
password bgpd
log stdout
!
dump bgp updates /tmp/rs-updates.dump
dump bgp routes-mrt /tmp/rs-routes.dump
!
bgp multiple-instance
!
router bgp $RS_ASN view RS
 bgp router-id $RS_IPADDR
EOF
    for i in `seq 1 $num`; do
        if [[ $i -lt 255 ]]; then 
            x=$i
            y=0
        else
            x=$(($i % 254))
            y=$(($i / 254))
        fi
        local ipaddr="172.16.$y.$x"
        local net=10.$y.$x
            cat >> $configDir/bgpd.conf <<EOF
 neighbor $ipaddr remote-as $(($BASE_ASN * $i))
 neighbor $ipaddr route-server-client
! neighbor $ipaddr soft-reconfiguration inbound
!
EOF
    done
    cat >> $configDir/bgpd.conf <<EOF
 neighbor $AS_T1_IPADDR remote-as $AS_T1_ASN
 neighbor $AS_T1_IPADDR route-server-client
! neighbor $AS_T1_IPADDR soft-reconfiguration inbound
 neighbor $AS_T2_IPADDR remote-as $AS_T2_ASN
 neighbor $AS_T2_IPADDR route-server-client
! neighbor $AS_T2_IPADDR soft-reconfiguration inbound
!
line vty
!
EOF
    cat > $configDir/zebra.conf <<EOF
hostname $RS_NAME
password zebra
line vty
EOF
    docker rm -f $RS_NAME
    docker run --privileged -d -P --name $RS_NAME -v $PWD/configs/$RS_NAME:/etc/quagga -v $PWD/$LOG_DIR:/tmp $QUAGGA_IMAGE
}

create_ixp() {
    local num=$1 # Number of member ASes
    echo "Create IXP with $num member ASes"
    create_route_server $num
    
    # Create member ASes
    for i in `seq 1 $num`; do
         if [ $i -lt 255 ]; then 
            x=$i
            y=0
        else
            x=$(($i % 254))
            y=$(($i / 254))
        fi
        local ip1=172.16.$y.$x
        local ip2=10.$y.$x.1
        create_member_as $AS_NAME$i $ip1 $ip2
    done
}

create_test_ases() {
    echo "Creating Test Router name=$AS_T1, asn=$AS_T1_ASN"
    local configDir=$PWD/configs/$AS_T1
    mkdir $configDir 2> /dev/null
    cp -fP $PWD/configs/base/* $configDir/.
    local bgpd_conf=$configDir/bgpd.conf
    local zebra_conf=$configDir/zebra.conf
    cat > $bgpd_conf <<EOF
!
! BGP configuration for $AS_T1
!
hostname $AS_T1
password bgpd
log stdout
dump bgp updates /tmp/$AS_T1-updates.dump
dump bgp routes-mrt /tmp/$AS_T1-routes.dump
!
router bgp $AS_T1_ASN
 bgp router-id $AS_T1_IPADDR
 no bgp enforce-first-as
 neighbor $RS_IPADDR remote-as $RS_ASN
 neighbor $TEST_NET.3 remote-as $AS_T3_ASN
 network 172.16.0.0/16
!
ip prefix-list PL1 seq 10 deny 20.0.0.0/24
!
line vty
EOF
    cat > $zebra_conf <<EOF
! Zebra configs for $AS_T1
hostname $AS_T1
password zebra
line vty
!
EOF
    docker rm -f $AS_T1
    docker run --privileged -d -P --name $AS_T1 -v $configDir:/etc/quagga -v $LOG_DIR:/tmp/ $QUAGGA_IMAGE
    
    echo "Creating BGP router: name=$AS_T2, asn=$AS_T2_ASN"
    local configDir=$PWD/configs/$AS_T2
    mkdir $configDir 2> /dev/null
    cp -fP $PWD/configs/base/* $configDir/.
    local bgpd_conf=$configDir/bgpd.conf
    local zebra_conf=$configDir/zebra.conf
    cat > $bgpd_conf <<EOF
!
! BGP configuration for $AS_T2
!
hostname $AS_T2
password bgpd
log stdout
dump bgp updates /tmp/$AS_T2-updates.dump
dump bgp routes-mrt /tmp/$AS_T2-routes.dump
!
router bgp $AS_T2_ASN
 bgp router-id $AS_T2_IPADDR
 no bgp enforce-first-as
 neighbor $RS_IPADDR remote-as $RS_ASN
 neighbor $RS_IPADDR route-map RM1 out
 neighbor $TEST_NET.3 remote-as $AS_T3_ASN
 neighbor 20.0.0.3 remote-as 65350
 network 172.16.0.0/16
!
ip prefix-list PL1 seq 10 permit 20.0.0.0/24
!
route-map RM1 permit 10 
 match ip address prefix-list PL1
 set as-path prepend 65351 65351 
!
line vty
EOF
    cat > $zebra_conf <<EOF
! Zebra configs for $AS_T2
hostname $AS_T2
password zebra
line vty
!
EOF
    docker rm -f $AS_T2
    docker run --privileged -d -P --name $AS_T2 -v $configDir:/etc/quagga -v $LOG_DIR:/tmp/ $QUAGGA_IMAGE
   
    echo "Creating a test router: name=$AS_T3, asn=$AS_T3_ASN"
    local configDir=$PWD/configs/$AS_T3
    mkdir $configDir 2> /dev/null
    cp -fP $PWD/configs/base/* $configDir/.
    local bgpd_conf=$configDir/bgpd.conf
    local zebra_conf=$configDir/zebra.conf
    cat > $bgpd_conf <<EOF
!
! BGP configuration for $AS_T3
!
hostname $AS_T3
password bgpd
log stdout
dump bgp updates /tmp/$AS_T3-updates.dump
dump bgp routes-mrt /tmp/$AS_T3-routes.dump
!
router bgp $AS_T3_ASN
 bgp router-id $TEST_NET.3
 no bgp enforce-first-as
 neighbor $TEST_NET.1 remote-as $AS_T1_ASN
 neighbor $TEST_NET.2 remote-as $AS_T2_ASN
 network $TEST_NET.0/24
!
line vty
EOF
    cat > $zebra_conf <<EOF
! Zebra configs for $AS_T3
hostname $AS_T3
password zebra
line vty
!
EOF
    docker rm -f $AS_T3
    docker run --privileged -d -P --name $AS_T3 -v $configDir:/etc/quagga -v $LOG_DIR:/tmp/ $QUAGGA_IMAGE
}
start_member_as() {
    local as_name=$1
    local ip1=$2
    local ip2=$3
    echo "Start member AS $as_name"
    docker stop $as_name 1> /dev/null
    docker start $as_name 1> /dev/null
    # Add an interface to IXP Switch
    $PIPEWORK $IXP_SW -i eth1 -l veth1$as_name $as_name $ip1/16
    # Connect the AS router to the AS switch
    $PIPEWORK $AS_SW -i eth2 -l veth2$as_name $as_name $ip2/24
}

stop_member_as() {
    echo "Stop member AS $1"
    local as_name=$1
    docker stop $as_name 1> /dev/null
}

start_route_server() {
    echo "Start Route Server"
    docker stop $RS_NAME 1> /dev/null
    docker start $RS_NAME 1> /dev/null
    $PIPEWORK $IXP_SW -i eth1 -l veth1$RS_NAME $RS_NAME $RS_IPADDR/16
}

stop_route_server() {
    echo "Stop Route Server"
    docker stop $RS_NAME 1> /dev/null
}

start_ixp() {
    num=$1 # Number of member ASes
    #Create an OVS switch as the IXP switch
    $OVSCTL add-br $IXP_SW 2> /dev/null
    $OVSCTL add-br $AS_SW 2> /dev/null
    start_route_server 
    for i in `seq 1 $num`; do
         if [ $i -lt 255 ]; then 
            x=$i
            y=0
        else
            x=$(($i % 254))
            y=$(($i / 254))
        fi
        local ip1="172.16.$y.$x"
        local ip2=10.$y.$x.1
        start_member_as $AS_NAME$i $ip1 $ip2
    done
}

stop_ixp() {
    echo "Stop the IXP network of $1 member ASes"
    local n=$1 # Number of member ASes
    stop_route_server
    for i in `seq 1 $n`; do
        stop_member_as $AS_NAME$i
    done
    # Delete an OVS switch as the IXP switch
    $OVSCTL del-br $IXP_SW 2> /dev/null
    $OVSCTL del-br $AS_SW 2> /dev/null
}

start_test_ast1() {
    echo "Start Test AST1"
    docker stop $AS_T1 &> /dev/null
    docker start $AS_T1 1> /dev/null
    $PIPEWORK $IXP_SW -i eth1 -l veth1$AS_T1 $AS_T1 $AS_T1_IPADDR/16
    $PIPEWORK $TEST_SW -i eth2 -l veth2$AS_T1 $AS_T1 $TEST_NET.1/24
}
stop_test_ast1() {
    echo "Stop Test AST1"
    docker stop $AS_T1 1> /dev/null
}

start_test_ast2() {
    echo "Start Test AST2"
    docker stop $AS_T2 &> /dev/null
    docker start $AS_T2 1> /dev/null
    $PIPEWORK $IXP_SW -i eth1 -l veth1$AS_T2 $AS_T2 $AS_T2_IPADDR/16
    $PIPEWORK $TEST_SW -i eth2 -l veth2$AS_T2 $AS_T2 $TEST_NET.2/24
}
stop_test_ast2() {
    echo "Stop Test AST2"
    docker stop $AS_T2 1> /dev/null
}

start_test_ast3() {
    echo "Start Test AST3"
    docker stop $AS_T3 &> /dev/null
    docker start $AS_T3 1> /dev/null
    $PIPEWORK $TEST_SW -i eth1 -l veth1$AS_T3 $AS_T3 $TEST_NET.3/24
}
stop_test_ast3() {
    echo "Stop Test AST3"
    docker stop $AS_T3 1> /dev/null
}

run_tup_test() {
    ntimes=$1 # Run for ntimes
    nases=$2 # Number of member ASes
    echo "Run Tup test for $nases of member ASes for $ntimes times"
    local logdir=$LOG_DIR/tup/$nases
    rm -r $logdir 2> /dev/null
    mkdir -p $logdir 2> /dev/null
    for l in `seq 1 $ntimes`; do
        sleep 10 
        echo "It's run $l"
        mkdir -p $logdir/run$l 2> /dev/null
        rm -f $LOG_DIR/*.dump 2> /dev/null
        $OVSCTL add-br $TEST_SW 1> /dev/null
        start_ixp $nases
        start_test_ast1
        sleep 40 # Wait for the IXP becomes stable
        start_test_ast3 
        sleep 70 # Wait for the Update reaches all ASes
        echo "Stop the run"
        cp -fp $LOG_DIR/*updates.dump $logdir/run$l/.
        chmod 777 $logdir/run$l/*
        stop_ixp $nases
        sleep 1
        stop_test_ast1
        stop_test_ast3
        $OVSCTL del-br $TEST_SW 1> /dev/null
    done
}

run_tdown_test() {
    ntimes=$1 # Run for ntimes
    nases=$2 # Number of member ASes
    echo "Start the test"
    logdir=$LOG_DIR/tdown
    mkdir -p $logdir 2> /dev/null

    for i in `seq 1 $ntimes`; do
        mkdir -p $logdir/$i 2> /dev/null
        rm -f $LOG_DIR/*.dump
        $OVSCTL add-br $TEST_SW 1> /dev/null
        start_ixp $nases
        start_test_ast1
        start_test_ast3 
        sleep 60 
        # Withdraw a prefix, netcat to AS_T3 and configure BGP to withdraw the prefix
        cat > $PWD/withdrawal.cmd <<EOF
bgpd
enable
configure terminal
router bgp $AS_T3_ASN
no network 20.0.0.0/24
end
exit
EOF
        local as_t3_ip=`$PWD/getdockerip $AS_T3`
        echo "Withdraw the prefix"
        nc $as_t3_ip 2605 < $PWD/withdrawal.cmd &>/dev/null
        sleep 30 
        echo "Stop the test"
        cp -fp $LOG_DIR/*updates.dump $logdir/$i/.
        chmod 777 $logdir/$i/*
        stop_ixp $nases
        stop_test_ast1
        stop_test_ast3
        $OVSCTL del-br $TEST_SW 1> /dev/null
    done
}

ast3_start_fping() {
    local num=$1
    echo "Start fping in AST3"
    # Prepare fping target files
    head -$num $PWD/targets.txt > $PWD/configs/$AS_T3/mytargets.txt
    # Start fping
    docker exec -d $AS_T3 /bin/bash \
        -c "fping -l -Q 1 -f /etc/quagga/mytargets.txt &> /tmp/fping.out"
}
ast3_stop_fping() {
    echo "Stop fping in AST3"
    docker exec -d $AS_T3 /bin/bash -c "pkill -x fping"
}

ast1_announce() {
    local ip=`$PWD/getdockerip $AS_T1`
    echo "AST1 announces a prefix"
    nc -i 1 $ip 2605 < $PWD/ast1_announce.cmd &>/dev/null
}

ast1_withdraw() {
    local ip=`$PWD/getdockerip $AS_T1`
    echo "AST1 withdraws a prefix"
    nc -i 1 $ip 2605 < $PWD/ast1_withdraw.cmd &>/dev/null
}

ast1_discards() {
    local num=$1
    echo "AST1 discards packets from 10.x.x.x"
    for q in `seq 1 $num`; do
         if [ $q -lt 255 ]; then 
            x=$q
            y=0
        else
            x=$(($q % 254))
            y=$(($q / 254))
        fi
        local ip=10.$y.$x.1
        docker exec -d $AS_T1 /bin/bash -c "ip route add $ip via 127.0.0.1"
    done
}

ast1_unfilter_routes() {
    local ip=`$PWD/getdockerip $AS_T1`
    echo "AST1 unfilters a prefix"
    nc -i 1 $ip 2605 < $PWD/ast1_unfilter_routes.cmd &>/dev/null
}

route_check() {
    local as_name=$1
    local route=$2
    local ip=`$PWD/getdockerip $as_name`
    r=$(nc $ip 2605 < $PWD/command.txt 2>&1)
    if ! printf -- '%s' "$r" | egrep -q -- "$route"; then
        return 1
    else
        return 0
    fi
}

ping_check() {
    local host=$1
    local out=$(docker exec $AS_T3 /bin/bash -c "fping $host")
    #echo $out
    if ! printf -- '%s' "$out" | egrep -q -- "alive"; then
        return 1
    else
        return 0
    fi
}


run_tlong_test() {
    nases=$1 # Number of member ASes
    ntimes=$2 # Run for ntimes
    echo "Run Tlong test for $nases of member ASes for $ntimes times"
    local logdir=$LOG_DIR/tlong/$nases
    rm -r $logdir 2> /dev/null
    mkdir -p $logdir 2> /dev/null
    for l in `seq 1 $ntimes`; do
        echo "It's run $l"
        mkdir -p $logdir/run$l 2> /dev/null
        rm -f $LOG_DIR/*.dump
        #truncate -s 0 $LOG_DIR/*updates.dump # Clear Update log content
        $OVSCTL add-br $TEST_SW 1> /dev/null
        start_ixp $k
        while true;
        do
            if route_check as10 10.0.1.0; then
                break
            fi
            sleep 2
        done
        sleep 10
        start_test_ast1
        start_test_ast2
        while true;
        do
            if route_check $AS_T2 10.0.10.0; then
                if route_check $AS_T1 10.0.10.0; then
                    break
                fi
            fi
            sleep 2
        done
        sleep 10
        start_test_ast3
        echo "waiting for the IXP to become stable..."
        lm=0
        while [[ $lm -lt 15 ]]
        do
            if ping_check 10.0.1.1; then
                break
            fi
            sleep 2
            lm=$[$lm + 1]
        done
        sleep 2
        ast3_start_fping $nases
        sleep 10
        ast1_withdraw
        ast1_discards $nases # Pretend to be a failure
        sleep 30 # Wait for the withdrawal to progagate
        echo "Stop the run"
        cp -fp $LOG_DIR/*updates.dump $logdir/run$l/.
        cp -fp $LOG_DIR/fping.out $logdir/run$l/.
        chmod 777 $logdir/run$l/*
        stop_test_ast3
        stop_test_ast1
        stop_test_ast2
        stop_ixp $nases
        $OVSCTL del-br $TEST_SW 1> /dev/null
        sleep 10
    done
}

stop_on_interrupt() {
    echo "Test interrupted"
    stop_ixp 100 
    docker stop $AS_T1 &> /dev/null
    docker stop $AS_T2 &> /dev/null
    docker stop $AS_T3 &> /dev/null
    $OVSCTL del-br $TEST_SW 1> /dev/null
    exit 0
}
trap "stop_on_interrupt" INT 
# Main program
for k in `seq 10 10 100`; do
    run_tlong_test $k 10 
done
