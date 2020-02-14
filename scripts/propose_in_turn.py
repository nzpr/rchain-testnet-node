"""
servers:
  - node0:
      host: node0.sandboxnet.rchain-dev.tk
      grpc_port: 40401
      http_port: 40403
  - node1:
      host: node1.sandboxnet.rchain-dev.tk
      grpc_port: 40401
      http_port: 40403
  - node2:
      host: node2.sandboxnet.rchain-dev.tk
      grpc_port: 40401
      http_port: 40403
  - node3:
      host: node3.sandboxnet.rchain-dev.tk
      grpc_port: 40401
      http_port: 40403
  - node4:
      host: node4.sandboxnet.rchain-dev.tk
      grpc_port: 40401
      http_port: 40403
waitTimeout: 300
waitInterval: 10
error_node_records: /rchain/rchain-testnet-node/error.txt
deploy:
    contract: /rchain/rholang/examples/hello_world_again.rho
    phlo_limit: 100000
    phlo_price: 1
    deploy_key: 34d969f43affa8e5c47900e6db475cb8ddd8520170ee73b2207c54014006ff2b

This script would take the orders node1 -> node2 -> node2 to propose block in order.

"""

import logging
import asyncio
import sys
import os
from argparse import ArgumentParser
import yaml
import grpc
import time
from rchain.client import RClient, RClientException
from rchain.crypto import PrivateKey
from collections import deque

handler = logging.StreamHandler(sys.stdout)
handler.setLevel(logging.INFO)
root = logging.getLogger()
root.addHandler(handler)
root.setLevel(logging.INFO)

loop = asyncio.get_event_loop()

parser = ArgumentParser(description="In turn propose script")
parser.add_argument("-c", "--config-file", action="store", type=str, required=True, dest="config",
                    help="the config file of the script")

args = parser.parse_args()


class Client():
    def __init__(self, host, grpc_port, websocket_host, host_name):
        self.host = host
        self.grpc_host = "{}:{}".format(host, grpc_port)
        self.websocket_host = "ws://{}:{}/ws/events".format(host, websocket_host)
        self.host_name = host_name
        self.asycn_ws = None

    def deploy_and_propose(self, deploy_key, contract, phlo_price, phlo_limit):
        with grpc.insecure_channel(self.grpc_host) as channel:
            client = RClient(channel)
            client.deploy_with_vabn_filled(deploy_key, contract, phlo_price,
                                           phlo_limit,
                                           int(time.time() * 1000))
            return client.propose()

    def is_contain_block_hash(self, block_hash):
        with grpc.insecure_channel(self.grpc_host) as channel:
            client = RClient(channel)
            try:
                client.show_block(block_hash)
                return True
            except RClientException:
                logging.info("node {} doesn't contain {}".format(self.host_name, block_hash))
                return False


class DispatchCenter():
    def __init__(self, config):
        logging.info("Initialing dispatcher")
        self._config = config

        self.clients = {}
        for server in config['servers']:
            for host_name, host_config in server.items():
                self.clients[host_name] = init_client(host_name, host_config)

        logging.info("Read the deploying contract {}".format(config['deploy']['contract']))
        with open(config['deploy']['contract']) as f:
            self.contract = f.read()
        logging.info("Checking if deploy key is valid.")
        self.deploy_key = PrivateKey.from_hex(config['deploy']['deploy_key'])

        self.phlo_limit = int(config['deploy']['phlo_limit'])
        self.phlo_price = int(config['deploy']['phlo_price'])

        self.wait_timeout = int(config['waitTimeout'])
        self.wait_interval = int(config['waitInterval'])

        self.error_node_records = config['error_node_records']

        self.error_nodes = []
        if os.path.exists(self.error_node_records):
            with open(self.error_node_records) as f:
                for line in f.readlines():
                    host_name, host = line.split(',')
                    self.error_nodes.append((host_name, host))

        self.queue = deque()
        for client in self.clients.values():
            if client.host_name not in self.error_nodes:
                self.queue.append(client.host_name)

        self._running = False

    def deploy_and_propose(self):
        current_server = self.queue.popleft()
        logging.info("Going to deploy and propose in {}".format(current_server))
        client = self.clients[current_server]
        try:
            block_hash = client.deploy_and_propose(self.deploy_key, self.contract, self.phlo_price, self.phlo_limit)
            self.queue.append(current_server)
            logging.info("Successfully deploy and propose {} in {}".format(block_hash, current_server))
            return block_hash
        except Exception as e:
            logging.warning("Node {} can not deploy and propose because of {}".format(client.host_name, e))

    def wait_server_to_receive(self, block_hash):
        current_time = int(time.time())
        wait_server = self.queue.popleft()
        client = self.clients[wait_server]
        logging.info("Waiting {} to receive {} at {}".format(client.host_name, block_hash, current_time))
        while time.time() - current_time < self.wait_timeout:
            try:
                time.sleep(self.wait_interval)
                is_contain = client.is_contain_block_hash(block_hash)
                if is_contain:
                    logging.info("Node {} successfully receive block hash {}".format(client.host_name, block_hash))
                    self.queue.appendleft(wait_server)
                    return
                else:
                    logging.info(
                        "Node {} does not have block hash {}. Sleep {} s and try again".format(client.host_name,
                                                                                               block_hash,
                                                                                               self.wait_interval))
            except Exception as e:
                logging.warning(
                    "There is something wrong with node {}, exception {}".format(client.host_name, e))
                break
        logging.info("Timeout waiting {} to receive {} at {}".format(client.host_name, block_hash, time.time()))
        self.write_error_node(client)

    def write_error_node(self, client):
        self.error_nodes.append((client.host_name, client.host))
        with open(self.error_node_records, 'w') as f:
            for host_name, host in self.error_nodes:
                f.write("{},{}\n".format(host_name, host))

    def run(self):
        self._running = True
        while self._running:
            block_hash = self.deploy_and_propose()
            self.wait_server_to_receive(block_hash)


with open(args.config) as f:
    config = yaml.load(f)


def init_client(host_name, host_config):
    return Client(host_config['host'], host_config['grpc_port'], host_config['http_port'], host_name)


if __name__ == '__main__':
    dispatcher = DispatchCenter(config)
    dispatcher.run()