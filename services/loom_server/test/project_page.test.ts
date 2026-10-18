import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {renderLandingPage} from '../src/http/landing_page.ts';
import type {LoomNodeConfig} from '../src/config/config.ts';
const config = {showProjectSupport:true,operatorName:'Test <Node>',publicDomain:'node.test',publicBaseUrl:'https://node.test',registrationPolicy:'approval',federationMode:'disabled',networkJurisdiction:'Test',maxAttachmentBytes:104857600} as LoomNodeConfig;

test('project support uses only the approved wallet and public checkout link', () => {
 const body = renderLandingPage(config);
 const readme = readFileSync(new URL('../../../README.md',import.meta.url),'utf8');
 const approved = '0x5D303A4DF69C5058c70E0ECf3280BDA600824685';
 const addresses = (body + readme).match(/0x[a-fA-F0-9]{40}/g) ?? [];
 assert.ok(addresses.length >= 6);
 assert.ok(addresses.every(address => address === approved));
 assert.match(body, /USDT · BNB Smart Chain \(BEP-20\)/);
 assert.match(body, /USDT · Ethereum \(ERC-20\)/);
 assert.match(body, /href="https:\/\/nowpayments\.io\/donation\/loom"/);
 assert.equal((body.match(/data-wallet-copy=/g) ?? []).length, 2);
 assert.doesNotMatch(body + readme, /api_key=|tronscan\.org/);
 assert.match(body, /github\.com\/0800x\/Loom/);
 assert.match(body,/Public alpha/); assert.match(body,/opportunistic Android Nearby/);
 assert.match(body,/Test &lt;Node&gt;/); assert.doesNotMatch(body,/>Test <Node>/);
});

test('operator support is separate and unsafe links are discarded', () => {
 const previous = process.env.LOOM_DONATION_LINKS;
 try {
  process.env.LOOM_DONATION_LINKS='Operator|https://operator.test/support;Unsafe|javascript:alert(1)';
  const body=renderLandingPage(config);
  assert.match(body,/Support Loom development/); assert.match(body,/Support this node/);
  assert.match(body,/https:\/\/operator.test\/support/); assert.doesNotMatch(body,/javascript:alert/);
 } finally { if(previous === undefined) delete process.env.LOOM_DONATION_LINKS; else process.env.LOOM_DONATION_LINKS=previous; }
});

test('project support is opt-in and the configured source preserves approved destinations',()=>{
 const body=renderLandingPage({...config,showProjectSupport:false});
 assert.doesNotMatch(body,/data-wallet-copy=|nowpayments\.io/);
 const canonical=JSON.parse(readFileSync(new URL('../src/config/project_support.json',import.meta.url),'utf8'));
 const readme=readFileSync(new URL('../../../README.md',import.meta.url),'utf8');
 for(const wallet of canonical.wallets){assert.ok(readme.includes(wallet.address));assert.ok(renderLandingPage(config).includes(wallet.address));}
});
