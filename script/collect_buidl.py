#!/usr/bin/env python3
"""Collect August Grove BUIDL transfers using an Alchemy-compatible ETH_RPC.

Verifies discovery results against block-local eth_getLogs and reconciles every
transfer to boundary balanceOf reads. No transactions or paid Dune executions.
"""
import json
import os
from pathlib import Path
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
TOKEN = '0x6a9da2d710bb9b700acde7cb81f10f1ff8c89041'
HOLDER = '0x491edfb0b8b608044e227225c715981a30f3a44e'
TRANSFER = '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef'
START, END = 25656292, 25878704


def main():
    rpc = os.environ['ETH_RPC']

    def call(method, params):
        req = urllib.request.Request(rpc, data=json.dumps(
            {'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}
        ).encode(), headers={'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(req, timeout=90) as res:
                result = json.load(res)
        except Exception:
            raise RuntimeError('RPC request failed; endpoint details suppressed') from None
        if 'error' in result:
            raise RuntimeError('RPC method failed; requires Alchemy-compatible transfer discovery')
        return result['result']

    def balance(block):
        return int(call('eth_call', [{'to': TOKEN, 'data': '0x70a08231' + HOLDER[2:].zfill(64)}, hex(block)]), 16)

    found = {}
    for direction in ('fromAddress', 'toAddress'):
        params = {'fromBlock': hex(START + 1), 'toBlock': hex(END),
                  'contractAddresses': [TOKEN], 'category': ['erc20'],
                  'excludeZeroValue': False, 'maxCount': '0x3e8', direction: HOLDER}
        while True:
            result = call('alchemy_getAssetTransfers', [params])
            for item in result['transfers']:
                found[item['uniqueId']] = item
            if not result.get('pageKey'):
                break
            params['pageKey'] = result['pageKey']
    events = []
    running = opening = balance(START)
    for block in sorted({int(item['blockNum'], 16) for item in found.values()}):
        if not (balance(block - 1) == running):
            raise ValueError('Unexplained balance change between discovered blocks')
        logs = call('eth_getLogs', [{'address': TOKEN, 'fromBlock': hex(block),
                                    'toBlock': hex(block), 'topics': [TRANSFER]}])
        for event in sorted(logs, key=lambda e: int(e['logIndex'], 16)):
            sender, recipient = ('0x' + topic[-40:] for topic in event['topics'][1:3])
            if HOLDER not in (sender, recipient):
                continue
            uid = event['transactionHash'] + ':log:' + str(int(event['logIndex'], 16))
            if not (uid in found):
                raise ValueError('collect_buidl.py: uid in found')
            amount = int(event['data'], 16)
            if not (amount == int(found[uid]['rawContract']['value'], 16)):
                raise ValueError("collect_buidl.py: amount == int(found[uid]['rawContract']['value'], 16)")
            before = running
            delta = (amount if recipient == HOLDER else 0) - (amount if sender == HOLDER else 0)
            running += delta
            # Explicit August-only classification: all inflows are issuer
            # mints; the four outflows form two paired redemption transfers.
            if recipient == HOLDER:
                if not (sender == '0x' + '0' * 40 and amount < 1_000_000 * 10**6):
                    raise ValueError("collect_buidl.py: sender == '0x' + '0' * 40 and amount < 1_000_000 * 10**6")
                kind = 'dividend_mint'
            else:
                if not (recipient == '0x8780dd016171b91e4df47075da0a947959c34200'):
                    raise ValueError("collect_buidl.py: recipient == '0x8780dd016171b91e4df47075da0a947959c34200'")
                kind = 'capital_outflow'
            events.append({'block': block, 'log_index': int(event['logIndex'], 16),
                           'tx_hash': event['transactionHash'], 'from': sender, 'to': recipient,
                           'amount_raw': amount, 'kind': kind,
                           'balance_before_raw': before, 'balance_after_raw': running})
        if not (balance(block) == running):
            raise ValueError('Logs do not reproduce block balance')
    if not (len(events) == len(found) == 25):
        raise ValueError('collect_buidl.py: len(events) == len(found) == 25')
    if not (balance(END) == running):
        raise ValueError('collect_buidl.py: balance(END) == running')
    result = {'token': TOKEN, 'holder': HOLDER, 'decimals': 6,
              'start_block': START, 'end_block': END, 'opening_balance_raw': opening,
              'closing_balance_raw': running, 'events': events}
    path = ROOT / 'test/fixtures/buidl-2026-08.json'
    path.parent.mkdir(exist_ok=True)
    path.write_text(json.dumps(result, indent=2) + '\n')
    print(f'Verified {len(events)} transfers and boundary balances: {path}')


if __name__ == '__main__':
    main()
