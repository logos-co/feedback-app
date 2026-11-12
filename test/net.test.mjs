// node --test test/  : net.js against the values the live probes returned (2026-11-11, delivery_module 0.3.3)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const src = readFileSync(new URL('../net.js', import.meta.url), 'utf8').replace(/^\.pragma library\s*$/m, '');
const Net = {};
vm.runInNewContext(src + '\nthis.Net = { nodeConfig, unwrap, isAlreadyInitialized, clusterFromEnr, rlnStateName, rlnGated, classify, canSend, bannerText, isLoop, pill };', Net);
const N = Net.Net;
const j = (o) => JSON.parse(JSON.stringify(o)); // objects from the vm sandbox have another prototype

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
	// Chat first: adopted, cluster 2, RLN on -> warn at once, before any send (manual test 2026-11-12)
	assert.equal(N.classify({ adopted: true, cluster: 2, rln: 'Failed' }), 'rlnBlocked');
	assert.equal(N.classify({ adopted: true, cluster: 2, rln: 'Ready' }), 'rlnBlocked');
	assert.equal(N.classify({ adopted: true, cluster: 2, rln: 'Initializing' }), 'rlnBlocked');
	// adopted, rlnState not read yet: keep checking
	assert.equal(N.classify({ adopted: true, cluster: 2, rln: '' }), 'checking');
	// adopted but RLN-free (Feedback-style config by another app): fine
	assert.equal(N.classify({ adopted: true, cluster: 2, rln: 'Disabled' }), 'ok');
	// gated but a send was confirmed (a membership exists): fine
	assert.equal(N.classify({ adopted: true, cluster: 2, rln: 'Ready', confirmed: true }), 'ok');
	// adopted node on devnet
	assert.equal(N.classify({ adopted: true, cluster: 3, rln: 'Disabled' }), 'wrongNetwork');
	assert.equal(N.classify({ adopted: true, cluster: -1, rln: '' }), 'checking');
	// delivery stopped answering (crashed after a second start(), 2026-11-12): say so instead of checking forever
	assert.equal(N.classify({ adopted: true, cluster: -1, rln: '', noAnswer: true }), 'unreachable');
	assert.equal(N.classify({ adopted: false, cluster: 2, rln: 'Disabled', noAnswer: true }), 'unreachable');
	assert.equal(N.canSend('unreachable'), false);
	assert.match(N.bannerText('unreachable'), /isn't answering.*quit Basecamp, start it again and open Feedback first/);
	assert.deepEqual(j(N.pill('unreachable', '')), { text: "Can't send", tone: 'error' });
});

test('unwrap: every answer shape a Basecamp build returns', () => {
	assert.deepEqual(j(N.unwrap({ success: true, value: 'Connected', error: null })), { ok: true, value: 'Connected', error: '' });
	assert.deepEqual(j(N.unwrap({ result: { success: true, value: 'Connected', error: null } })), { ok: true, value: 'Connected', error: '' });
	assert.deepEqual(j(N.unwrap({ result: 'Connected' })), { ok: true, value: 'Connected', error: '' }); // bare value under result
	assert.equal(N.unwrap({ result: { state: 'Failed', message: 'x' } }).value.state, 'Failed'); // bare object under result
	assert.equal(N.unwrap('Connected').value, 'Connected');
	assert.equal(N.unwrap({ _raw: 'Connected' }).value, 'Connected');
	assert.equal(N.unwrap({ error: 'Module not connected' }).ok, false);
	assert.equal(N.unwrap({ result: { error: 'Context already initialized', success: false, value: null } }).error, 'Context already initialized');
	assert.equal(N.rlnStateName(N.unwrap({ result: { state: 'Disabled', message: '' } }).value), 'Disabled');
});

test('pill: checking first, then the honest state', () => {
	assert.deepEqual(j(N.pill('checking', '')), { text: 'Checking delivery…', tone: 'neutral' });
	assert.deepEqual(j(N.pill('checking', 'Connected')), { text: 'Checking delivery…', tone: 'neutral' });
	assert.deepEqual(j(N.pill('ok', 'Connected')), { text: 'Delivery connected', tone: 'success' });
	assert.deepEqual(j(N.pill('ok', 'PartiallyConnected')), { text: 'Delivery connected', tone: 'success' });
	assert.deepEqual(j(N.pill('ok', 'Disconnected')), { text: 'Delivery reconnecting…', tone: 'warning' });
	assert.deepEqual(j(N.pill('rlnBlocked', 'Connected')), { text: "Can't send", tone: 'error' });
	assert.deepEqual(j(N.pill('wrongNetwork', 'Connected')), { text: "Can't send", tone: 'error' });
});

test('send gating and the user-facing text', () => {
	assert.equal(N.canSend('ok'), true);
	for (const s of ['checking', 'wrongNetwork', 'rlnBlocked']) assert.equal(N.canSend(s), false);
	assert.match(N.bannerText('wrongNetwork'), /different network.*Close that app, quit Basecamp, start it again and open Feedback first/);
	assert.match(N.bannerText('rlnBlocked'), /RLN on.*no RLN membership.*Close that app, quit Basecamp, start it again and open Feedback first/);
	assert.equal(N.bannerText('ok'), null);
	assert.equal(N.bannerText('checking'), null);
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
		assert.match(N.bannerText(s, false), /quit Basecamp, start it again and open Feedback first/);
		assert.doesNotMatch(N.bannerText(s, true), /start it again|Restart Basecamp/);
		assert.match(N.bannerText(s, true), /after a restart.*Your feedback is saved/);
		assert.ok(!/\u2014/.test(N.bannerText(s, true)));
	}
	assert.match(N.bannerText('rlnBlocked', true), /RLN membership/);
});
