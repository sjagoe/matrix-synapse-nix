#!/usr/bin/env python3
import json
import os
from datetime import datetime
from enum import Enum

import attr
import click
import requests
# from fasteners import InterProcessLock

BASE_DIR = os.path.dirname(os.path.dirname(__file__))

ENDPOINT = 'https://dns.hetzner.com/api/v1'
UA_PART = 'update-dns-script/0.0.1'


def _to_datetime(value):
    value = value.split('.')[0]
    return datetime.strptime(value, '%Y-%m-%d %H:%M:%S')


class RecordType(Enum):
    A = 'A'
    AAAA = 'AAAA'
    CNAME = 'CNAME'
    SRV = 'SRV'
    TXT = 'TXT'
    MX = 'MX'
    NS = 'NS'
    SOA = 'SOA'


@attr.s(auto_attribs=True)
class Record:
    id: str
    type: RecordType = attr.ib(converter=lambda t: RecordType[t])
    name: str
    value: str
    zone_id: str
    # 2021-04-06 11:51:04.06 +0000 UTC
    created: datetime = attr.ib(converter=_to_datetime)
    # 2021-04-06 11:51:04.06 +0000 UTC
    modified: datetime = attr.ib(converter=_to_datetime)
    ttl: int = attr.ib(default=86400)


class HetznerDNS:

    def __init__(self, zone_id, auth_token):
        self._zone_id = zone_id
        self._session = session = requests.Session()
        session.headers = {
            'User-Agent': f'{UA_PART} python-requests/{requests.__version__}',
            'Content-Type': 'application/json',
            'Auth-API-Token': auth_token,
        }
        self._zone_name = None

    def _api_url(self, fragment, zone_id=None):
        assert fragment.startswith('/'), f'URL fragment {fragment} does not start with /'  # noqa
        query = ''
        if zone_id is not None:
            query = f'?zone_id={zone_id}'
        return f'{ENDPOINT}{fragment}{query}'

    @property
    def zone_name(self):
        if self._zone_name is None:
            url = self._api_url(f'/zones/{self._zone_id}')
            response = self._session.get(url)
            response.raise_for_status()
            name = response.json().get('zone', {}).get('name')
            if name is None:
                raise Exception(
                    f'Unable to find zone name for zone {self._zone_id}')
            self._zone_name = name
        return self._zone_name

    # def _paginate(self, url):
    #     pass

    def fqdn_to_record_name(self, fqdn):
        zone_name = self.zone_name
        if not fqdn.endswith(zone_name):
            raise Exception(
                f'{fqdn} does not seem to be within the zone {zone_name}')
        return fqdn[:-len(f'.{zone_name}')]

    def get_records(self, name=None, value=None, type=None):
        url = self._api_url('/records', zone_id=self._zone_id)
        response = self._session.get(url)
        response.raise_for_status()
        records = [Record(**r) for r in response.json().get('records', [])]
        if name is not None:
            records = [r for r in records if r.name == name]
        if value is not None:
            records = [r for r in records if r.value == value]
        if type is not None:
            records = [r for r in records if r.type == type]
        return records

    def add_host(self, name, type, value, ttl):
        url = self._api_url('/records')
        payload = {
            'zone_id': self._zone_id,
            'type': type.value,
            'ttl': ttl,
            'name': name,
            'value': value,
        }
        response = self._session.post(url, data=json.dumps(payload))
        response.raise_for_status()
        return Record(**response.json()['record'])

    def delete_record(self, record_id):
        url = self._api_url(f'/records/{record_id}')
        response = self._session.delete(url)
        response.raise_for_status()


@click.group()
@click.pass_context
def main(ctx):
    with open(os.path.join(BASE_DIR, 'secrets.json')) as fh:
        secrets = json.loads(fh.read())
    auth_token = secrets['hetznerDNS']['token']
    zone_id = secrets['hetznerDNS']['zoneId']
    ctx.obj = HetznerDNS(zone_id, auth_token)


@main.command('add-host')
@click.argument('fqdn')
@click.argument('public_ipv4')
@click.argument('public_ipv6')
@click.option('--ttl', type=int, default=60)
@click.pass_obj
def add_host(obj, fqdn, public_ipv4, public_ipv6, ttl):
    record_name = obj.fqdn_to_record_name(fqdn)
    current_v4_records = obj.get_records(name=record_name, type=RecordType.A)
    current_v6_records = obj.get_records(
        name=record_name, type=RecordType.AAAA)
    if len(current_v4_records) == 0:
        record = obj.add_host(record_name, RecordType.A, public_ipv4, ttl)
        print(f'Created records {record}')
    if len(current_v6_records) == 0:
        record = obj.add_host(record_name, RecordType.AAAA, public_ipv6, ttl)
        print(f'Created records {record}')

    same_ipv4 = {f'{r.name}: {r.value}': r.value == public_ipv4
                 for r in current_v4_records}
    same_ipv6 = {f'{r.name}: {r.value}': r.value == public_ipv6
                 for r in current_v6_records}
    if not all(same_ipv4.values()) and not all(same_ipv6):
        different_hosts = sorted(k for k, v in same_ipv4.items() if not v) + \
            sorted(k for k, v in same_ipv6.items() if not v)
        raise Exception(
            f'New host has mismatched existing address: {different_hosts}')


@main.command('add-host-to-group')
@click.pass_obj
def add_host_to_group(obj, fqdn, group):
    pass


@main.command('remove-host-from-group')
@click.pass_obj
def remove_host_from_group(obj, fqdn, group):
    pass


@main.command('delete-host')
@click.argument('fqdn')
@click.pass_obj
def delete_host(obj, fqdn):
    record_name = obj.fqdn_to_record_name(fqdn)
    current_v4_records = obj.get_records(name=record_name, type=RecordType.A)
    current_v6_records = obj.get_records(
        name=record_name, type=RecordType.AAAA)

    if len(current_v4_records) > 1 or len(current_v6_records):
        v4_values = {r.value for r in current_v4_records}
        v6_values = {r.value for r in current_v6_records}
        if len(v4_values) > 1:
            raise Exception(
                f'Unexpected multiple canonical IPs for {fqdn}: {sorted(v4_values)}')  # noqa
        if len(v6_values) > 1:
            raise Exception(
                f'Unexpected multiple canonical IPs for {fqdn}: {sorted(b6_values)}')  # noqa

    ipv4 = next(r.value for r in current_v4_records)
    records_to_delete = obj.get_records(value=ipv4, type=RecordType.A)
    for record in records_to_delete:
        obj.delete_record(record.id)
        print(f'Deleted {record.type.value} record {record.name}: {record.value}')  # noqa

    ipv6 = next(r.value for r in current_v6_records)
    records_to_delete = obj.get_records(value=ipv6, type=RecordType.A)
    for record in records_to_delete:
        obj.delete_record(record.id)
        print(f'Deleted {record.type.value} record {record.name}: {record.value}')  # noqa


if __name__ == '__main__':
    main()
