import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { createContext, runInContext } from 'node:vm';

const html = readFileSync(new URL('./index.html', import.meta.url), 'utf8');
// Exercise the shipped Client and action handlers without credentials or a DOM.
const client = html.slice(html.indexOf('class Client {'), html.indexOf('// ---------- state ----------'));
const actions = html.slice(html.indexOf('// ---------- actions ----------'), html.indexOf('// ---------- bindings ----------'));
const navigation = html.slice(html.indexOf('function navAdvance()'), html.indexOf("document.getElementById('next-btn').onclick"));

function fixture({ owner = 'person_subject', mode, lastAssigned, fetchResult } = {}) {
  const face = { face_id: 'face_test', initial_person_id: owner, mode };
  const requests = [];
  const messages = [];
  const saved = [];
  const state = {
    snapshot: {
      library_id: 'lib_test', subject: { id: 'person_subject' },
      facesById: new Map([[face.face_id, face]]),
    },
    faces: [face, { face_id: 'face_next' }], index: 0,
    personId: 'person_subject', reviewed: {}, history: [],
    lastAssigned: new Map(lastAssigned), actionInFlight: false,
  };
  const context = createContext({
    state, REQUEST_TIMEOUT_MS: 1000, AbortController, setTimeout, clearTimeout,
    document: { getElementById: () => ({}) }, undoBtn: {},
    flashButton() {}, render() {}, prefetchNeighbors() {},
    saveReviewed: (_id, reviewed) => saved.push({ ...reviewed }),
    toast: message => messages.push(message), console: { error() {} },
    fetch: async (url, init) => {
      requests.push({ url, method: init.method, body: JSON.parse(init.body) });
      return fetchResult ? fetchResult() : new Response('{}');
    },
  });
  runInContext(`${client}\n${actions}\n${navigation}\nstate.client = new Client('https://api.example', 'test');`, context);
  return { state, requests, messages, saved, accept: context.acceptCurrent, undo: context.undoLast, next: context.navAdvance };
}

for (const [name, options, personId] of [
  ['subject', {}, 'person_subject'],
  ['inverse tab current owner', { mode: 'inverse', owner: 'person_donor' }, 'person_donor'],
  ['latest session assignment', { lastAssigned: [['face_test', 'person_new']] }, 'person_new'],
]) {
  test(`Accept confirms the ${name}`, async () => {
    const f = fixture(options);
    await f.accept();
    assert.deepEqual(f.requests, [{
      url: 'https://api.example/api/faces/face_test?library_id=lib_test',
      method: 'PATCH', body: { person_id: personId },
    }]);
    assert.equal(f.state.reviewed.face_test, 'accepted');
    assert.equal(f.state.lastAssigned.get('face_test'), personId);
    assert.equal(f.state.index, 1);
    assert.equal(f.saved.length, 1);
    assert.equal(f.state.actionInFlight, false);
  });
}

test('unassigned Accept stays local', async () => {
  const f = fixture({ owner: null, mode: 'unassigned' });
  await f.accept();
  assert.equal(f.requests.length, 0);
  assert.equal(f.state.reviewed.face_test, 'accepted');
  assert.equal(f.state.index, 1);
});

test('a pending confirmation prevents duplicate actions and premature review', async () => {
  let resolve;
  const response = new Promise(r => { resolve = r; });
  const f = fixture({ fetchResult: () => response });
  const pending = f.accept();
  await f.accept();
  f.next();
  assert.equal(f.requests.length, 1);
  assert.equal(f.state.index, 0);
  assert.deepEqual(f.state.reviewed, {});
  assert.equal(f.saved.length, 0);
  resolve(new Response('{}'));
  await pending;
  assert.equal(f.state.index, 1);
});

for (const [name, fetchResult] of [
  ['HTTP failure', () => new Response('{"detail":"rejected"}', { status: 500 })],
  ['network failure', () => { throw new Error('offline'); }],
]) {
  test(`${name} leaves the face available for retry`, async () => {
    const f = fixture({ fetchResult });
    await f.accept();
    assert.equal(f.state.index, 0);
    assert.deepEqual(f.state.reviewed, {});
    assert.equal(f.state.history.length, 0);
    assert.equal(f.state.lastAssigned.size, 0);
    assert.equal(f.saved.length, 0);
    assert.equal(f.state.actionInFlight, false);
    assert.match(f.messages[0], /^Accept failed:/);
    f.state.client.updateFace = async () => ({});
    await f.accept();
    assert.equal(f.state.reviewed.face_test, 'accepted');
  });
}

test('Undo reopens review without pretending to revert manual provenance', async () => {
  const f = fixture();
  await f.accept();
  await f.undo();
  assert.equal(f.requests.length, 1);
  assert.deepEqual(f.state.reviewed, {});
  assert.equal(f.state.index, 0);
  assert.match(f.messages[0], /manual confirmation remains saved/);
});
