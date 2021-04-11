#!/usr/bin/env python3
import json
import os
import sys

import click
from fasteners import InterProcessLock
from netaddr import IPAddress, IPNetwork


def find_next_unallocated_ip(network, used_addresses):
    # First IP in the subnet is reserved by hetzner as the gateway
    if len(used_addresses) == 0 or network[2] != used_addresses[0]:
        return network[2]

    used_ips = [int(addr) for addr in used_addresses]

    for a, b in zip(used_ips[:-1], used_ips[1:]):
        if b - a > 1:
            return IPAddress(a + 1)

    return IPAddress(used_ips[-1] + 1)


def load_host_file(dirpath, filename):
    path = os.path.join(dirpath, filename)
    with open(path) as fh:
        return json.loads(fh.read())


def load_hosts(hosts_dir):
    for dirpath, dirnames, filenames in os.walk(hosts_dir):
        for filename in filenames:
            if filename == 'host.json':
                yield load_host_file(dirpath, filename)


def allocate_new_ip(network_name, hosts_dir, networks_json):
    hosts = list(load_hosts(hosts_dir))
    with open(networks_json) as fh:
        networks = json.loads(fh.read())['networks']

    network = networks.get(network_name)
    if network is None:
        raise Exception(f'Network {network_name} does not exist')
    network = IPNetwork(network)

    used_addresses = sorted(
        IPNetwork(host['ipv4'][network_name]).ip
        for host in hosts
        if network_name in host['ipv4']
    )

    ip_address = find_next_unallocated_ip(network, used_addresses)

    if ip_address not in network:
        raise Exception(
            f'Discovered IP {ip_address} not contained in network {network}')

    return network, ip_address, network.prefixlen


def write_ip(host_json_path, network_name, network, ip_address, prefix_length):
    os.makedirs(os.path.dirname(host_json_path), exist_ok=True)
    host_data = {}
    if os.path.exists(host_json_path):
        with open(host_json_path) as fh:
            host_data = json.loads(fh.read())
    ipv4 = host_data.setdefault('ipv4', {})
    ipv4.setdefault[network_name] = {
        'network': str(network),
        'address': str(ip_address),
        'prefixLength': prefix_length,
    }
    with open(host_json_path, 'w') as fh:
        fh.write(json.dumps(host_data, indent=4, sort_keys=True))


def get_current_ip(host_json_path, network_name):
    if not os.path.exists(host_json_path):
        return None
    with open(host_json_path) as fh:
        host_data = json.loads(fh.read())
    return host_data.get('ipv4', {}).get(network_name)


@click.command()
@click.argument('host_name')
@click.argument('network_name')
@click.argument('hosts_dir')
@click.argument('networks_json')
def main(host_name, network_name, hosts_dir, networks_json):
    lockfile = os.path.join(
        os.path.dirname(os.path.dirname(__file__)), '.ip-alloc.lock')
    with InterProcessLock(lockfile):
        host_json_path = os.path.join(hosts_dir, host_name, 'host.json')
        current_ip = get_current_ip(host_json_path, network_name)
        if current_ip is None:
            network, ip_address, prefix_length = allocate_new_ip(
                network_name, hosts_dir, networks_json)
            write_ip(host_json_path, network_name, network, ip_address,
                     prefix_length)
        else:
            ip_address = current_ip.ip
            prefix_length = current_ip.prefixlen
    print(f'Allocated {ip_address}/{prefix_length} to {host_name}',
          file=sys.stderr)
    print(f'{ip_address}/{prefix_length}')


if __name__ == '__main__':
    main()
