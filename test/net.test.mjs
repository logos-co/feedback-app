// node --test test/  : net.js against the values the live probes returned (2026-11-11, delivery_module 0.3.3)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const src = readFileSync(new URL('../net.js', import.meta.url), 'utf8').replace(/^\.pragma library\s*$/m, '');
const Net = {};
vm.runInNewContext(src + '\nthis.Net = { nodeConfig, unwrap, isAlreadyInitialized, clusterFromEnr, rlnStateName, rlnGated, classify, canSend, bannerText, isLoop };', Net);
const N = Net.Net;

// ENR the probe node returned on cluster 2 (getNodeInfo "MyENR")
const ENR_C2 = 'enr:-K24QNRtRffo_rnJP_EQG3P5pPKiAkj7RBp5Z2HZy2OK3tgJE7MfdPn-wd3a-4mgCAcUuoNImIguyOcztVb7-aNHmxMPgmlkgnY0im11bHRpYWRkcnOAgnJzkwACCAAAAAEAAgADAAQABQAGAAeJc2VjcDI1NmsxoQKW6rTiysIQRblYCVu-Kl1HBZRkP1ChgdLskFOqo1RSGIN0Y3CCpgODdWRwguSChXdha3UyDQ';

test('node config: logos.test spelled out, no preset name', () => {
	const c = JSON.parse(N.nodeConfig());
	assert.equal(c.preset, '');
	assert.equal(c.clusterId, 2);
	assert.equal(c.numShardsInNetwork, 8);
	assert.equal(c.maxMessageSize, '150KiB');
	assert.equal(c.entryNodes.length, 6);
	assert.ok(c.entryNodes.every((e) => e.includes('.logos.test.status.im/')));
});

test('ENR -> cluster', () => {
	assert.equal(N.clusterFromEnr(ENR_C2), 2);
	assert.equal(N.clusterFromEnr(''), -1);
	assert.equal(N.clusterFromEnr('enr:not-base64!!'), -1);
	assert.equal(N.clusterFromEnr(null), -1);
});

test('ENR with the cluster bytes changed to 3 reads as 3', () => {
	// rs payload "0002 08 0000 0001 …" -> "0003 …": same record shape, cluster 3
	const b = Buffer.from(ENR_C2.slice(4).replace(/-/g, '+').replace(/_/g, '/'), 'base64');
	const i = b.indexOf(Buffer.from([0x72, 0x73, 0x93, 0x00, 0x02])); // 'rs', the 0x93 string header, cluster 0x0002
	assert.ok(i > 0);
	b[i + 4] = 3;
	const enr3 = 'enr:' + b.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
	assert.equal(N.clusterFromEnr(enr3), 3);
});

test('createNode refusal = another app owns the node', () => {
	const r = N.unwrap({ result: { error: 'Context already initialized', success: false, value: null } });
	assert.equal(r.ok, false);
	assert.ok(N.isAlreadyInitialized(r.error));
	assert.ok(!N.isAlreadyInitialized('service discovery setup failed'));
	assert.equal(N.unwrap({ error: null, success: true, value: 'abc' }).value, 'abc');
	assert.equal(N.unwrap(null).ok, false);
});

test('rlnState: Disabled is open, the rest is gated', () => {
	const failed = { epochSizeSec: 600, message: 'rln module start failed', registryId: 'logos:testnet:fd32…', state: 'Failed' };
	assert.equal(N.rlnStateName({ message: '', state: 'Disabled' }), 'Disabled');
	assert.equal(N.rlnStateName(failed), 'Failed');
	assert.equal(N.rlnGated('Disabled'), false);
	assert.equal(N.rlnGated(''), false);
	for (const s of ['Initializing', 'Ready', 'Failed']) assert.equal(N.rlnGated(s), true);
});

test('classify: the states from the order tests', () => {
	// we created it (probe: preset "" -> Disabled, cluster 2)
	assert.equal(N.classify({ adopted: false, cluster: 2, rln: 'Disabled' }), 'ok');
	// Feedback first, Chat adopted ours: still ours, still Disabled
	assert.equal(N.classify({ adopted: false, cluster: 2, rln: 'Disabled' }), 'ok');
	// Chat first: adopted, cluster 2, RLN Failed -> try once, then blocked when unconfirmed
	assert.equal(N.classify({ adopted: true, cluster: 2, rln: 'Failed' }), 'rlnSuspect');
	assert.equal(N.classify({ adopted: true, cluster: 2, rln: 'Failed', unconfirmed: true }), 'rlnBlocked');
	// gated but a send was confirmed (a membership exists): fine
	assert.equal(N.classify({ adopted: true, cluster: 2, rln: 'Ready', unconfirmed: false, confirmed: true }), 'ok');
	// adopted node on devnet
	assert.equal(N.classify({ adopted: true, cluster: 3, rln: 'Disabled' }), 'wrongNetwork');
	assert.equal(N.classify({ adopted: true, cluster: -1, rln: '' }), 'checking');
});

test('send gating and the user-facing text', () => {
	assert.equal(N.canSend('ok'), true);
	assert.equal(N.canSend('rlnSuspect'), true);
	for (const s of ['checking', 'wrongNetwork', 'rlnBlocked']) assert.equal(N.canSend(s), false);
	assert.match(N.bannerText('wrongNetwork'), /different network.*Restart Basecamp and open Feedback first/);
	assert.match(N.bannerText('rlnBlocked'), /RLN on.*no RLN membership.*Restart Basecamp and open Feedback first/);
	assert.equal(N.bannerText('ok'), null);
	assert.equal(N.bannerText('rlnSuspect'), null);
	for (const s of ['wrongNetwork', 'rlnBlocked']) assert.ok(!/—/.test(N.bannerText(s)), 'no em dash');
});

test('restart loop (#6): advised on one node, blocked again on another', () => {
	const A = '16Uiu2HAm5wEUCLQ1n8f2RWnQfpmhoGMShMpPGTiyaH4M8etMc63D'; // probe: run 1
	const B = '16Uiu2HAmKs9qVZFmecvwNSDsRAbRRzUMHuNiFPpABZ7NKPcV7ZXX'; // probe: run 2, same data dir
	assert.equal(N.isLoop('', A), false); // first time: advise
	assert.equal(N.isLoop(A, A), false); // reopened Feedback, same Basecamp run: keep advising
	assert.equal(N.isLoop(A, B), true); // restarted and still blocked: a loop
	assert.equal(N.isLoop(A, ''), false);
	for (const s of ['wrongNetwork', 'rlnBlocked']) {
		assert.match(N.bannerText(s, false), /Restart Basecamp and open Feedback first/);
		assert.doesNotMatch(N.bannerText(s, true), /Restart Basecamp/);
		assert.match(N.bannerText(s, true), /after a restart.*Your feedback is saved/);
		assert.ok(!/\u2014/.test(N.bannerText(s, true)));
	}
	assert.match(N.bannerText('rlnBlocked', true), /RLN membership/);
});
