#!/usr/bin/env python3
import json
import random
import os
from ipaddress import ip_address, ip_network


import click
from fasteners import InterProcessLock


def write_ip(host_json_path, host_address, prefix_length):
    os.makedirs(os.path.dirname(host_json_path), exist_ok=True)
    host_data = {}
    if os.path.exists(host_json_path):
        with open(host_json_path) as fh:
            host_data = json.loads(fh.read())
    ipv6 = host_data.setdefault('ipv6', {})
    ipv6['address'] = host_address
    ipv6['prefixLength'] = prefix_length
    with open(host_json_path, 'w') as fh:
        fh.write(json.dumps(host_data, indent=4, sort_keys=True))


@click.command()
@click.argument('host_json_path')
def main(host_json_path):
    lockfile = os.path.join(
        os.path.dirname(os.path.dirname(__file__)), '.ip-alloc.lock')

    with open(host_json_path) as fh:
        prefix = json.loads(fh.read())['ipv6']['prefix']

    network = ip_network(prefix)
    host_part = hex(random.randint(2, 65534))[2:]
    host_address = ip_address(f'{network.network_address}{host_part}')

    with InterProcessLock(lockfile):
        write_ip(host_json_path, host_address.compressed, network.prefixlen)


if __name__ == '__main__':
    main()
