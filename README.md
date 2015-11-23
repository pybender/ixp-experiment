1. Introduction
A simple IXP lab built with docker containers.
#                                    _______
#                                   |       |
#                                   |   RS  |
#                                   |_______|
#                                       |
#                                       |
#  _____       _______               ___|___             _______
# |     |     |       |             |       |           |       |
# | H_1 |-----| ISP_A |-------------| IXPSW |-----------| ISP_B |
# |_____|     |_______|             |_______|           |_______|
#                                      |                   |
#                                      |                   |
#                                   ___|___             ___|___       _____
#                                  |       |           |       |     |     |
#                                  | ISP_C |-----------| ISP_D |-----| H_2 |
#                                  |_______|           |_______|     |_____|
#

2. Build
2.1. Docker installation
# Install docker on Ubuntu 14.04
sudo apt-get update
sudo apt-get install docker.io docker

2.2. Clone the git repo

2.3. Create a docker image for hosts
Jump into docker-host and run the command:
sudo docker build -t ubuntu/iperf-host .

2.4. Create a docker image for Quagga
Jump into docker-quagga and run the command
sudo docker build -t ubuntu/quagga .

2.5. Get pipework
git clone http

3. Run the lab
sudo ./run-ixp-lab --run

4. Stop the lab
sudo ./run-ixp-lab --stop

5. Modifications
Quagga configs for each routers are stored in configs directory.
