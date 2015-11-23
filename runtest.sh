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
#  | AS1  |--------+-| IXP  |-+--------| AST1 |-------+   ______
#  |______|        | |______| |        |______|       |  |      |
#   ______         |          |         ______        +--| AST3 |
#  |      |        |          |        |      |       |  |______|
#  | AS2  |--------+          +--------| AST2 |-------+     
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

TEST_SWITCH=test-sw
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
    local switch=$5
    local exist=$( check_docker $as_name )
    if [[ $exist -lt 1 ]]; then
        echo "Creating a member AS: name=$as_name, asn=$asn, ip=$ipaddr"
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
        # Create a Docker container for member ASes
        docker run --privileged -d -P --name $as_name -v $configDir:/etc/quagga -v $LOG_DIR:/tmp/ $QUAGGA_IMAGE

    elif [[ $exist -eq 1 ]]; then
        #echo "Start a Docker container for $as_name"
        docker start $as_name

    else
        return
    fi
    # Add an interface to IXP Switch
    #echo "Connect the AS Docker container to IXP switch"
    $PIPEWORK $IXP_SW -i eth1 -l veth1$as_name $as_name $ipaddr/16
    # Connect the AS router to the AS switch
    $PIPEWORK $AS_SW -i eth2 -l veth2$as_name $as_name $net.1/24

}

start_ixp() {
    NUM_MEMBER_ASES=$1
    echo "Start IXP with $NUM_MEMBER_ASES member ASes"
    #Create an OVS switch as the IXP switch
    $OVSCTL add-br $IXP_SW 2> /dev/null
    $OVSCTL add-br $AS_SW 2> /dev/null

    exist=$(check_docker $RS_NAME)
    if [[ $exist -lt 1 ]]; then
        echo "Create IXP Route Server and Switch"
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
        local asn=100
        for i in `seq 1 $NUM_MEMBER_ASES`; do
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
 neighbor $ipaddr remote-as $(($asn * $i))
 neighbor $ipaddr route-server-client
! neighbor $ipaddr soft-reconfiguration inbound
!
EOF
            create_member_as $AS_NAME$i $(($asn * $i)) $ipaddr $net
            # Connect the AS router to the AS switch
            $PIPEWORK $AS_SW -i eth2 -l veth2$AS_NAME$i $AS_NAME$i $net.1/24
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
        # Create a Docker container for the Route Server
        docker run --privileged -d -P --name $RS_NAME -v $PWD/configs/$RS_NAME:/etc/quagga -v $PWD/$LOG_DIR:/tmp $QUAGGA_IMAGE

    elif [[ $exist -eq 1 ]]; then
        #Create an OVS switch as the IXP switch
        $OVSCTL add-br $IXP_SW 2> /dev/null
        asn=100
        for i in `seq 1 $NUM_MEMBER_ASES`; do
             if [ $i -lt 255 ]; then 
                x=$i
                y=0
            else
                x=$(($i % 254))
                y=$(($i / 254))
            fi
            ipaddr=172.16.$y.$x
            net=10.$y.$x
            create_member_as $AS_NAME$i $(($asn*$i)) $ipaddr $net
        done
        #echo "Start the Route Server Docker container"
        docker start $RS_NAME
    else
        return
    fi
    #echo "Connect the Route Server Docker to IXP switch"
    $PIPEWORK $IXP_SW -i eth1 -l veth1$RS_NAME $RS_NAME $RS_IPADDR/16

}

# Create  and Start Test ASes AST1, AST2 and AST3
start_as_test() {
    local NUM_MEMBER_ASES=$1
    $OVSCTL add-br $TEST_SWITCH 2> /dev/null

    local exist=$( check_docker $AS_T1 )
    if [[ $exist -lt 1 ]]; then
        echo "Creating BGP router: name=$AS_T1, asn=$AS_T1_ASN"
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
        # Create a Docker container for member ASes
        docker run --privileged -d -P --name $AS_T1 -v $configDir:/etc/quagga -v $LOG_DIR:/tmp/ $QUAGGA_IMAGE

    elif [[ $exist -eq 1 ]]; then
        docker start $AS_T1
    fi
    # Add the as to switch if it is not already
    if [[ $exist -lt 2 ]]; then
        $PIPEWORK $IXP_SW -i eth1 -l veth1$AS_T1 $AS_T1 $AS_T1_IPADDR/16
        $PIPEWORK $TEST_SWITCH -i eth2 -l veth2$AS_T1 $AS_T1 $TEST_NET.1/24
    fi

    local exist=$( check_docker $AS_T2 )
    if [[ $exist -lt 1 ]]; then
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
        # Create a Docker container for member ASes
        docker run --privileged -d -P --name $AS_T2 -v $configDir:/etc/quagga -v $LOG_DIR:/tmp/ $QUAGGA_IMAGE

    elif [[ $exist -eq 1 ]]; then
        #echo "Temporary disable AST2"
        docker start $AS_T2
    fi
    # Add the as to switch if it is not already
    if [[ $exist -lt 2 ]]; then
        #echo "Temporary disable AST2"
        $PIPEWORK $IXP_SW -i eth1 -l veth1$AS_T2 $AS_T2 $AS_T2_IPADDR/16
        $PIPEWORK $TEST_SWITCH -i eth2 -l veth2$AS_T2 $AS_T2 $TEST_NET.2/24
    fi

    local exist=$( check_docker $AS_T3)
    if [[ $exist -lt 1 ]]; then
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
        # Create a Docker container for member ASes
        docker run --privileged -d -P --name $AS_T3 -v $configDir:/etc/quagga -v $LOG_DIR:/tmp/ $QUAGGA_IMAGE

    elif [[ $exist -eq 1 ]]; then
        #echo "Start a Docker container for $AS_T3"
        docker start $AS_T3
    fi

    if [[ $exist -lt 2 ]]; then
        $PIPEWORK $TEST_SWITCH -i eth1 -l veth1$AS_T3 $AS_T3 $TEST_NET.3/24
        # Prepare fping target files
        head -$NUM_MEMBER_ASES $PWD/targets.txt > $PWD/configs/$AS_T3/mytargets.txt
        # Start fping
        docker exec -d $AS_T3 /bin/bash -c "sleep 40; fping -l -Q 1 -f /etc/quagga/mytargets.txt &> /tmp/fping.out"
    fi
}

stop_as_test() {
    # Stop the test net
    echo "Stop Test ASes"
    docker stop $AS_T1 &> /dev/null
    docker stop $AS_T2 &> /dev/null
    docker stop $AS_T3 &> /dev/null
    $OVSCTL del-br $TEST_SWITCH
}

stop_ixp() {
    local NUM_MEMBER_ASES=$1
    for i in `seq 1 $NUM_MEMBER_ASES`; do
        docker stop $AS_NAME$i
    done
    
    docker stop $RS_NAME
    $OVSCTL del-br $IXP_SW &> /dev/null
    $OVSCTL del-br $AS_SW &> /dev/null
}

run_test() {
    # Run with m member ases
    local m=$1
    # Run the test for n times
    local t=$2
    local testname=tlong
    echo "Run Tests with $m member ASes for $t times"
    rm -r $LOG_DIR/$testname/$m >& /dev/null
    for k in `seq 1 $t`; do
        echo "Run: $k"
        sleep 1 # Before the next run
        # Delete old logs
        local dir=$LOG_DIR/$testname/$m/run$k
        mkdir -p $dir
        rm $LOG_DIR/*.*
        # Start the IXP network
        start_ixp $m
        # Start the Test network
        start_as_test $m
        sleep 60 # To make sure that the IXP is converged before the announcement
        # Telnet to AST1 and announces a prefix
        # Create announcement command file for netcat
#        cat > $PWD/announce.cmd <<EOF
#bgpd
#enable
#configure terminal
#router bgp $AS_T3_ASN
#network $TEST_NET.0/24
#end
#exit
#EOF
        cat > $PWD/withdraw.cmd <<EOF
bgpd
enable
configure terminal
router bgp $AS_T1_ASN
neighbor 172.16.254.254 prefix-list PL1 out
end
clear ip bgp 172.16.254.254 out
exit
EOF

        local as_t1_ipaddr=`$PWD/getdockerip $AS_T1`
        echo "AST1 withdraws a prefix"
        nc $as_t1_ipaddr 2605 < $PWD/withdraw.cmd &>/dev/null
        # Shutdown the interface to AST3 to make prevent packet going through this intf
        #docker exec -d $AS_T1 /bin/bash/ -c "ifconfig eth2 down"
        ifconfig veth2as-t1 down
        # Sleep for xxx seconds to make sure all routers get updated
        sleep 120
        # Copy BGP dump to that folder
        cp -fP $LOG_DIR/*updates.dump $dir/.
        cp -fP $LOG_DIR/fping.out $dir/.
        chmod 777 $dir/*
        stop_ixp $m
        sleep 1
        stop_as_test
    done
}
stop_test() {
    echo "Test interrupted"
    stop_ixp 100 
    stop_as_test
    exit 0
}
trap "stop_test" INT
# Main program
for it in `seq 10 10 100`; do
    run_test $it 10
done
