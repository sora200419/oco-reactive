// Checks the page's configuration against the deployment and Foundry. Run: node --test web/config.test.mjs
// Needs Foundry's `cast` on PATH.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

import { ADDR, POOL_KEY, VAULT_ABI, REACTIVE_ABI, SWAPPER_ABI, ERC20_ABI } from './config.js';

const cast = (...args) => execFileSync('cast', args, { encoding: 'utf8' }).trim();

test('every address is written with its EIP-55 checksum (viem rejects a wrong one)', () => {
  for (const [name, a] of Object.entries(ADDR)) {
    assert.equal(a, cast('to-check-sum-address', a), `${name} has the wrong letter case`);
  }
});

test('addresses match the deployment recorded in docs/tx-hashes.md', () => {
  const doc = readFileSync(new URL('../docs/tx-hashes.md', import.meta.url), 'utf8').toLowerCase();
  for (const [name, a] of Object.entries(ADDR)) {
    assert.ok(doc.includes(a.toLowerCase()), `${name} ${a} is not in docs/tx-hashes.md`);
  }
  assert.equal(POOL_KEY.currency0, ADDR.token0);
  assert.equal(POOL_KEY.currency1, ADDR.token1);
});

test('every error and event in the ABIs is declared with the same types in the Solidity sources', () => {
  const src = ['OrderVault.sol', 'OcoReactive.sol', 'v4/V4Swapper.sol', 'v4/TestToken.sol']
    .map((f) => readFileSync(new URL(`../src/${f}`, import.meta.url), 'utf8'))
    .join('\n')
    .replace(/\s+/g, ' ');
  for (const abi of [VAULT_ABI, REACTIVE_ABI, SWAPPER_ABI]) {
    for (const item of abi.filter((x) => x.type === 'error' || x.type === 'event')) {
      // Rebuild the declaration's parameter types, e.g. "error StopNotBelowPrice(int24 nStop, int24 nNow)".
      const re = new RegExp(`${item.type} ${item.name}\\(([^)]*)\\)`);
      const m = src.match(re);
      assert.ok(m, `${item.type} ${item.name} is not declared in src/`);
      const types = m[1].split(',').map((p) => p.trim().split(' ')[0]).filter(Boolean);
      assert.deepEqual(types, item.inputs.map((i) => i.type), `${item.type} ${item.name} has different parameter types`);
    }
  }
});

test('the faucet call matches TestToken.mint, which is open to everyone', () => {
  const src = readFileSync(new URL('../src/v4/TestToken.sol', import.meta.url), 'utf8');
  const decl = src.match(/function mint\(([^)]*)\)\s*external\s*\{/);
  assert.ok(decl, 'TestToken.mint must be a plain external function with no access modifier');
  const types = decl[1].split(',').map((p) => p.trim().split(' ')[0]);
  const mint = ERC20_ABI.find((x) => x.name === 'mint');
  assert.deepEqual(types, mint.inputs.map((i) => i.type));
  assert.equal(cast('sig', `mint(${types.join(',')})`), cast('sig', 'mint(address,uint256)'));
});

test('event signatures in the ABIs match the contracts', () => {
  const sig = (abi, name) => {
    const e = abi.find((x) => x.type === 'event' && x.name === name);
    return `${name}(${e.inputs.map((i) => i.type).join(',')})`;
  };
  assert.equal(sig(VAULT_ABI, 'OrderExecuted'), 'OrderExecuted(uint256,uint8,uint256,int24,uint256)');
  assert.equal(sig(VAULT_ABI, 'OrderExecutionFailed'), 'OrderExecutionFailed(uint256,uint8,bytes)');
  assert.equal(sig(REACTIVE_ABI, 'Triggered'), 'Triggered(uint256,uint8,int24,int24)');
});
