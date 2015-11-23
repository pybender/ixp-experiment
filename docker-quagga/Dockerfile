# HEADER
FROM ubuntu:14.04 

MAINTAINER Trung Truong <trungdtbk@gmail.com>

RUN apt-get update
RUN apt-get install -qy --no-install-recommends supervisor quagga telnet traceroute tcpdump fping

RUN sed -i 's/bgpd=no/bgpd=yes/g' /etc/quagga/daemons
RUN sed -i 's/zebra=no/zebra=yes/g' /etc/quagga/daemons

ADD supervisord.conf /etc/supervisord.conf

EXPOSE 179 2601 2605

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
