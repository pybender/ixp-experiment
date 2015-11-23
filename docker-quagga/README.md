# docker-quagga
A docker container that runs Quagga routing stack.
Three processes including zebra, ospfd and bgpd are enabled.
Supervisord is installed to manage these processes.
Other utilities installed include tcpdump

Installation
1. Clone git
2. Buid the image: docker build -t <image-name> .
[Noted there is a dot at the end]
3. Create and run the container: docker run -d -P --name <router_name> -v <path2quaggaconfig>:/etc/quagga <image-name>
4. Stop the container: docker stop <router_name>
5. Start the container: docker start <router_name>
