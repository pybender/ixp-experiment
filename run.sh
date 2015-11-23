#!/bin/bash

PWD=`pwd`

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

# Number of Member ASes
NUM_MEMBER_ASES=100

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

ACTION=""
case "$1" in
    --start)
        ACTION="START"
        ;;
    --stop)
        ACTION="STOP"
        ;;
    --destroy)
        ACTION="DELETE"
        ;;
    *)
        echo "Invalid argument: $1"
        echo "Options: "
        echo "      --run: create and run the lab"
        echo "      --stop: stop the lab"
        echo "      --delete: delete docker containers)"
        ;;
esac

#create IXP switch

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
        bgpd_conf=$configDir/bgpd.conf
        zebra_conf=$configDir/zebra.conf
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
        echo "Start a Docker container for $as_name"
        docker start $as_name

    else
        return
    fi
    # Add an interface to IXP Switch
    echo "Connect the AS Docker container to IXP switch"
    $PIPEWORK $IXP_SW -i eth1 -l veth1$as_name $as_name $ipaddr/16
}

create_ixp() {
    exist=$(check_docker $RS_NAME)
    if [[ $exist -lt 1 ]]; then
        echo "Create IXP Route Server and Switch"
        #Create an OVS switch as the IXP switch
        $OVSCTL add-br $IXP_SW 2> /dev/null
        $OVSCTL add-br $AS_SW 2> /dev/null
        configDir=$PWD/configs/$RS_NAME
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
            ipaddr="172.16.$y.$x"
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
        docker run --privileged -d -P --name $RS_NAME -v $PWD/configs/$RS_NAME:/etc/quagga -v $LOG_DIR:/tmp $QUAGGA_IMAGE

    elif [[ $exist -eq 1 ]]; then
        #Create an OVS switch as the IXP switch
        $OVSCTL add-br $IXP_SW 2> /dev/null
        local asn=100
        for i in `seq 1 $NUM_MEMBER_ASES`; do
             if [ $i -lt 255 ]; then 
                x=$i
                y=0
            else
                x=$(($i % 254))
                y=$(($i / 254))
            fi
            local ipaddr=172.16.$y.$x
            local net=10.$y.$x.0
            create_member_as $AS_NAME$i $(($asn*$i)) $ipaddr $net
        done
        echo "Start the Route Server Docker container"
        docker start $RS_NAME
    else
        return
    fi
    echo "Connect the Route Server Docker to IXP switch"
    $PIPEWORK $IXP_SW -i eth1 -l veth1$RS_NAME $RS_NAME $RS_IPADDR/16

}

# Create a Test AS
create_test_net() {
    $OVSCTL add-br $TEST_SWITCH 2> /dev/null

    local exist=$( check_docker $AS_T1 )
    if [[ $exist -lt 1 ]]; then
        echo "Creating BGP router: name=$AS_T1, asn=$AS_T1_ASN"
        local configDir=$PWD/configs/$AS_T1
        mkdir $configDir 2> /dev/null
        cp -fP $PWD/configs/base/* $configDir/.
        bgpd_conf=$configDir/bgpd.conf
        zebra_conf=$configDir/zebra.conf
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
        bgpd_conf=$configDir/bgpd.conf
        zebra_conf=$configDir/zebra.conf
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
 neighbor $TEST_NET.3 remote-as $AS_T3_ASN
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
        docker start $AS_T2
    fi
    # Add the as to switch if it is not already
    if [[ $exist -lt 2 ]]; then
        $PIPEWORK $IXP_SW -i eth1 -l veth1$AS_T2 $AS_T2 $AS_T2_IPADDR/16
        $PIPEWORK $TEST_SWITCH -i eth2 -l veth2$AS_T2 $AS_T2 $TEST_NET.2/24
    fi


    local exist=$( check_docker $AS_T3)
    if [[ $exist -lt 1 ]]; then
        echo "Creating a test router: name=$AS_T3, asn=$AS_T3_ASN"
        local configDir=$PWD/configs/$AS_T3
        mkdir $configDir 2> /dev/null
        cp -fP $PWD/configs/base/* $configDir/.
        bgpd_conf=$configDir/bgpd.conf
        zebra_conf=$configDir/zebra.conf
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
        echo "Start a Docker container for $AS_T3"
        docker start $AS_T3
    fi

    if [[ $exist -lt 2 ]]; then
        $PIPEWORK $TEST_SWITCH -i eth1 -l veth1$AS_T3 $AS_T3 $TEST_NET.3/24
    fi
}

create_iperf_host() {
    client=iperf_client
    server=iperf_server
    # Create Iperf server
    exist=check_docker $iperf_server
    if [ $exist -lt 1 ]; then
        docker run -d --name $iperf_server -v $PWD/iperf:/tmp --name $iperf_server ubuntu/iperf /bin/bash -c 'iperf -s -u -x CSV -y C > /tmp/result.txt'
    elif [ $exist -eq 1 ]; then
        docker start $iperf_server
    fi
    sleep 5
    # Create iperf client
    exist=check_docker $iperf_client
    if [ $exist -lt 1 ]; then
        docker run -d --name $iperf_client ubuntu/iperf /bin/bash -c 'sleep 300; for i in {1..10}; do iperf -c 2.0.0.1 -u -b $(($i*100))m; sleep 5; done' 
    elif [ $exist -eq 1 ]; then
        docker start $iperf_client
    fi
}

stop_ixp() {
    for i in `seq 1 $NUM_MEMBER_ASES`; do
        docker stop $AS_NAME$i 2> /dev/null
    done
    
    docker stop $RS_NAME 2> /dev/null
    $OVSCTL del-br $IXP_SW 2> /dev/null

    # Stop the test net
    docker stop $AS_T1
    docker stop $AS_T2
    docker stop $AS_T3
    $OVSCTL del-br $TEST_SWITCH
}

destroy_ixp() {
    configDir=$PWD/configs
    for i in `seq 1 $NUM_MEMBER_ASES`; do
        docker rm -f $AS_NAME$i 2> /dev/null
        rm -r $configDir/$AS_NAME$i
    done
    
    docker rm -f $RS_NAME 2> /dev/null
    rm -r $configDir/$RS_NAME
    $OVSCTL del-br $IXP_SW 2> /dev/null
    $OVSCTL del-br $AS_SW 2> /dev/null

    # Stop the test net
    docker rm -f $AS_T1 2> /dev/null
    rm -r $configDir/$AS_T1
    docker rm -f $AS_T2 2> /dev/null
    rm -r $configDir/$AS_T2
    docker rm -f $AS_T3 2> /dev/null
    rm -r $configDir/$AS_T3
    $OVSCTL del-br $TEST_SWITCH 2> /dev/null
}

start_lab() {
    echo "Starting the lab"
    #create_ixp
    #asn=100
    #i=0
    #ip="172.16.0"
    #for as in ${Member_ASes[@]}
    #do 
    #    i=$(( $i + 1 ))
    #    asn=$(( $asn*$i ))
    #    create_bgp_router $as $asn $ip.$i "true"
    #done

    # Create router D
    #create_bgp_router "isp-d" 400 "4.4.4.4" "false"
    RS="rs"
    AS_A="AS-A"
    AS_B="AS-B"
    AS_C="AS-C"
    AS_D="AS-D"
    # Start RS
    docker start $RS
    docker start $AS_A
    docker start $AS_B
    docker start $AS_C
    docker start $AS_D
    # Create IXP Switch & attach routers to the switch
    IXP_SW="ixp_sw"
    ovs-vsctl add-br $IXP_SW
    $PWD/pipework $IXP_SW -i eth1 $RS 172.16.0.254/24
    $PWD/pipework $IXP_SW -i eth1 $AS_A 172.16.0.1/24
    $PWD/pipework $IXP_SW -i eth1 $AS_B 172.16.0.2/24
    $PWD/pipework $IXP_SW -i eth1 $AS_C 172.16.0.3/24
    # Connect AS-B, AS-C and AS-D
    BCD_SW="bcd_sw"
    ovs-vsctl add-br $BCD_SW
    $PWD/pipework $BCD_SW -i eth2 $AS_B 172.16.1.1/24
    $PWD/pipework $BCD_SW -i eth2 $AS_C 172.16.1.2/24
    $PWD/pipework $BCD_SW -i eth1 $AS_D 172.16.1.3/24

    # Start iperf server and iperf client
    IPERF_S="iperf-srv"
    IPERF_C="iperf-client"
    docker start $IPERF_S 
    docker start $IPERF_C
    NET_1="net_1.0.0"
    NET_2="net_2.0.0"
    ovs-vsctl add-br $NET_1
    ovs-vsctl add-br $NET_2
    
    $PWD/pipework $NET_1 $IPERF_C 1.0.0.1/24@1.0.0.254
    $PWD/pipework $NET_1 -i eth2 $AS_A 1.0.0.254/24

    $PWD/pipework $NET_2 $IPERF_S 2.0.0.1/24@2.0.0.254
    $PWD/pipework $NET_2 -i eth2 $AS_D 2.0.0.254/24

}

stop_lab() {
    echo "Stopping the lab"
    # Stop RouteServer
    docker stop $RS_NAME
    for as in ${Member_ASes[@]}
    do
        docker stop $as
    done
    # Delete OVS bridge
    ovs-vsctl del-br $IXP_SW
}

if [ "$ACTION" == "START" ]; then
    create_ixp
    create_test_net
elif [ "$ACTION" == "STOP" ]; then
    stop_ixp
elif [ "$ACTION" == "DELETE" ]; then
    destroy_ixp 
fi
