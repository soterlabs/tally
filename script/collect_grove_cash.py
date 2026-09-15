#!/usr/bin/env python3
"""Discover Grove August cash receipts; verify each against transaction logs.
Payer-to-venue classification follows the local pipeline config; it is an
explicit economic policy, not proof that every future payer transfer is yield.
Requires Alchemy-compatible ETH_RPC. Writes a public, credential-free fixture.
"""
import json
import os
from pathlib import Path
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
HOLDER = '0x491edfb0b8b608044e227225c715981a30f3a44e'
USDC = '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48'
AUSD = '0x00000000efe302beaa2b3e6e1b18d08d69a9012a'
SOURCES = [('E21', USDC, '0xac3d86f9840a8be07de5f67d6427983b7009df1b'),
           ('E38', AUSD, '0x4a4593c5d963473a95f0762bd6df4571542af651'),
           ('E38', AUSD, '0xdf27ac19cb1da767e181748aaa54e1535aaa3a1d'),
           ('E42', USDC, '0xba79473abba448c1a2912d3cdc241b18ee83e82c')]
TRANSFER = '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef'


def main():
    rpc = os.environ['ETH_RPC']
    def call(method, params):
        req = urllib.request.Request(rpc, data=json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params}).encode(), headers={'Content-Type':'application/json'})
        try:
            with urllib.request.urlopen(req, timeout=90) as res:
                result = json.load(res)
        except Exception:
            raise RuntimeError('RPC request failed; endpoint suppressed') from None
        if 'error' in result:
            raise RuntimeError('RPC method failed')
        return result['result']
    if not (int(call('eth_chainId', []), 16) == 1):
        raise ValueError("collect_grove_cash.py: int(call('eth_chainId', []), 16) == 1")
    events = []
    seen = set()
    for venue, token, payer in SOURCES:
        if not (int(call('eth_call', [{'to': token, 'data': '0x313ce567'}, hex(25878704)]), 16) == 6):
            raise ValueError("collect_grove_cash.py: int(call('eth_call', [{'to': token, 'data': '0x313ce567'}, hex(25878704)]), 16) == 6")
        params = {'fromBlock':hex(25656293),'toBlock':hex(25878704),
                  'contractAddresses':[token],'fromAddress':payer,'toAddress':HOLDER,
                  'category':['erc20'],'excludeZeroValue':False,'maxCount':'0x3e8','withMetadata':True}
        while True:
            result = call('alchemy_getAssetTransfers', [params])
            for item in result['transfers']:
                receipt = call('eth_getTransactionReceipt', [item['hash']])
                if not (receipt['status'] == '0x1'):
                    raise ValueError("collect_grove_cash.py: receipt['status'] == '0x1'")
                idx = int(item['uniqueId'].split(':log:')[1])
                event = next(e for e in receipt['logs'] if int(e['logIndex'],16) == idx)
                if not (event['address'].lower() == token and event['topics'][0] == TRANSFER):
                    raise ValueError("collect_grove_cash.py: event['address'].lower() == token and event['topics'][0] == TRANSFER")
                if not ('0x'+event['topics'][1][-40:] == payer):
                    raise ValueError("collect_grove_cash.py: '0x'+event['topics'][1][-40:] == payer")
                if not ('0x'+event['topics'][2][-40:] == HOLDER):
                    raise ValueError("collect_grove_cash.py: '0x'+event['topics'][2][-40:] == HOLDER")
                if not (event['transactionHash'] == item['hash']):
                    raise ValueError("collect_grove_cash.py: event['transactionHash'] == item['hash']")
                if not (event['blockNumber'] == item['blockNum']):
                    raise ValueError("collect_grove_cash.py: event['blockNumber'] == item['blockNum']")
                amount = int(event['data'],16)
                if not (amount == int(item['rawContract']['value'],16)):
                    raise ValueError("collect_grove_cash.py: amount == int(item['rawContract']['value'],16)")
                if not ((item['hash'],idx) not in seen):
                    raise ValueError("collect_grove_cash.py: (item['hash'],idx) not in seen")
                seen.add((item['hash'],idx))
                events.append({'venue':venue,'token':token,'payer':payer,'holder':HOLDER,
                               'block':int(item['blockNum'],16),'tx_hash':item['hash'],
                               'log_index':idx,'amount_raw':amount,'decimals':6,
                               'timestamp':item['metadata']['blockTimestamp']})
            if not result.get('pageKey'): break
            params['pageKey'] = result['pageKey']
    events.sort(key=lambda e:(e['block'],e['log_index']))
    result = {'chain_id':1,'start_block':25656292,'end_block':25878704,'events':events}
    path = ROOT/'test/fixtures/grove-cash-2026-08.json'
    path.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(events,indent=2))


if __name__ == '__main__':
    main()
