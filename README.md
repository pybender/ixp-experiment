 Evaluate the convergence property of BGP in an IXP environment.
 Here is the test topology
                     ______
                    |      |
                    |  RS  |
                    |______|
                        |
                        |
   ______            ___|__            ______
  |      |          |      |          |      |
  | AS1  |--------+-| IXP  |-+--------| AST1 |--+   ______     ______
  |______|        | |______| |        |______|  |  |      |   |      |
   ______         |          |         ______   +--|TESTSW|---| AST3 |
  |      |        |          |        |      |  |  |______|   |______|
  | AS2  |--------+          +--------| AST2 |--+     
  |______|        |                   |______|
                  |
   ______         |
  |      |        |          
  | ASn  |--------+          
  |______|         

 Here is how the tests are done
 I. Test Design
 1. Announcement Tests.
 How quick the network converge when AST1 announces prefixes.
 Tests run with the number of member ASes from 10 to 100, step of 10, and
 each test runs for 10 times
 Prefix test:
 2. Withdrawal Tests
 AST1 withdraws a prefix.

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
