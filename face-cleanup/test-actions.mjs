import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { createContext, runInContext } from 'node:vm';

const html = readFileSync(new URL('./index.html', import.meta.url), 'utf8');
// Exercise the shipped Client and action handlers without credentials or a DOM.
const client = html.slice(html.indexOf('class Client {'), html.indexOf('// ---------- state ----------'));
const actions = html.slice(html.indexOf('// ---------- actions ----------'), html.indexOf('// ---------- bindings ----------'));
const navigation = html.slice(html.indexOf('function navAdvance()'), html.indexOf("document.getElementById('next-btn').onclick"));
const filter = html.slice(html.indexOf('async function setFilter('), html.indexOf('function renderProgress()'));
const loaders = html.slice(html.indexOf('async function ensureInverseFaces()'), html.indexOf('async function setFilter('));
const controls = html.slice(html.indexOf('  const ownerId = currentPersonId('), html.indexOf('  const reviewedTag ='));
const launch = html.slice(html.indexOf('async function launchCleanup()'), html.indexOf('init().catch('));
const renderer = html.slice(html.indexOf('async function render()'), html.indexOf('function escapeHtml(')).replace('async function render()', 'async function renderEmpty()');

function fixture({ owner = 'person_subject', mode, lastAssigned, fetchResult, lazyFaces } = {}) {
  const face = { face_id: 'face_test', initial_person_id: owner, mode, candidates: [{ id: 'person_new', name: 'Morgan' }] };
  const requests = [];
  const messages = [];
  const saved = [];
  const state = {
    snapshot: {
      library_id: 'lib_test', subject: { id: 'person_subject', name: 'Riley' },
      people: [{ id: 'person_donor', name: 'Casey' }], inverseFaces: [], unassignedFaces: [],
      facesById: new Map([[face.face_id, face]]),
    },
    faces: [face, { face_id: 'face_next' }], index: 0,
    personId: 'person_subject', reviewed: {}, history: [],
    lastAssigned: new Map(lastAssigned), actionInFlight: false,
    faceCache: new Map(), assetCache: new Map(), personCache: new Map(), peoplePicker: [], libraryId: 'lib_test',
  };
  const initialSnapshot = state.snapshot;
  let startLoading;
  const loadingStarted = new Promise(resolve => { startLoading = resolve; });
  const buildLazyFaces = () => { startLoading(); return lazyFaces; };
  const elements = Object.fromEntries(['accept-btn', 'detach-btn', 'undo-btn'].map(id => [id, {}]));
  const context = createContext({
    state, REQUEST_TIMEOUT_MS: 1000, AbortController, setTimeout, clearTimeout,
    document: { getElementById: id => elements[id], querySelector: () => ({}), querySelectorAll: selector => selector === '#filter-tabs button' ? [] : Object.values(elements) }, undoBtn: elements['undo-btn'],
    changeSubjectLink: { setAttribute() {} }, CSS: { escape: value => value }, UNNAMED_LABEL: '(unnamed)',
    localStorage: { setItem() {} }, LS_KEY_FILTER: 'filter',
    applyFilter: selected => { state.index = 0; if (selected === 'inverse') state.faces = state.snapshot.inverseFaces; if (selected === 'unassigned') state.faces = state.snapshot.unassignedFaces; }, renderTabs() {},
    faceHost: {}, progress: {}, buildInverseFaces: buildLazyFaces, buildUnassignedFaces: buildLazyFaces,
    loadReviewed: () => ({}), subjectLabel: {}, content: {}, hideAllPanels() {},
    closeLightbox() {}, renderProgress() {},
    buildSnapshot: async () => initialSnapshot, prefetchPersonThumbs: async () => {},
    flashButton() {}, render() { context.refreshActionControls(); }, prefetchNeighbors() {},
    saveReviewed: (_id, reviewed) => saved.push({ ...reviewed }),
    toast: message => messages.push(message), console: { error() {} },
    fetch: async (url, init) => {
      requests.push({ url, method: init.method, body: JSON.parse(init.body) });
      return fetchResult ? fetchResult(JSON.parse(init.body)) : new Response(JSON.stringify({ person_id: JSON.parse(init.body).person_id }));
    },
  });
  runInContext(`${client}\n${actions}\n${navigation}\n${loaders}\n${filter}\n${launch}\n${renderer}\nasync function renderControls() { const face = state.faces[state.index]; ${controls} }\nstate.client = new Client('https://api.example', 'test');`, context);
  return { state, requests, messages, saved, elements, loadingStarted, accept: context.acceptCurrent, assign: context.assignTo, detach: context.detachCurrent, undo: context.undoLast, next: context.navAdvance, back: context.navBack, skip: context.skipCurrent, filter: context.setFilter, controls: context.renderControls, launch: context.launchCleanup, renderEmpty: context.renderEmpty };
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

for (const selected of ['inverse', 'unassigned']) {
  test(`a pending ${selected} list load blocks actions on the hidden previous face`, async () => {
    let resolve;
    const lazyFaces = new Promise(r => { resolve = r; });
    const f = fixture({ lazyFaces });
    f.state.snapshot[`${selected}Faces`] = null;
    const loading = f.filter(selected);
    await f.accept();
    await f.assign('person_new');
    await f.detach();
    await f.undo();
    f.skip();
    f.next();
    assert.equal(f.requests.length, 0);
    assert.equal(f.state.index, 0);
    assert.deepEqual(f.state.reviewed, {});
    assert.equal(f.elements['accept-btn'].disabled, true);
    resolve([{ face_id: 'face_loaded' }]);
    await loading;
    assert.equal(f.state.faces[0].face_id, 'face_loaded');
    assert.equal(f.state.index, 0);
    assert.equal(f.elements['accept-btn'].disabled, false);
  });
  test(`background ${selected} loading does not block the active tab`, async () => {
    let resolve;
    const lazyFaces = new Promise(r => { resolve = r; });
    const f = fixture({ lazyFaces });
    f.state.snapshot[`${selected}Faces`] = null;
    const loading = f.filter(selected);
    await f.filter('all');
    assert.equal(f.elements['accept-btn'].disabled, false);
    await f.accept();
    assert.equal(f.requests.length, 1);
    assert.equal(f.state.index, 1);
    resolve([{ face_id: 'face_loaded' }]);
    await loading;
    assert.equal(f.state.filter, 'all');
    assert.equal(f.state.faces[0].face_id, 'face_test');
    assert.equal(f.state.index, 1);
  });
  test(`a stale ${selected} loader cannot replace a new subject's review`, async () => {
    let resolve;
    const lazyFaces = new Promise(r => { resolve = r; });
    const f = fixture({ lazyFaces });
    f.state.snapshot[`${selected}Faces`] = null;
    const loading = f.filter(selected);
    f.state.snapshot = { ...f.state.snapshot };
    const newFaces = [{ face_id: 'face_new_subject' }];
    f.state.faces = newFaces;
    resolve([{ face_id: 'face_loaded' }]);
    await loading;
    assert.equal(f.state.faces, newFaces);
  });
  test(`launching a saved ${selected} tab shares the snapshot-bound filter path`, async () => {
    let resolve;
    const lazyFaces = new Promise(r => { resolve = r; });
    const f = fixture({ lazyFaces });
    f.state.snapshot[`${selected}Faces`] = null;
    f.state.filter = selected;
    const launching = f.launch();
    await f.loadingStarted;
    assert.equal(f.state.snapshot[`${selected}Loading`], true);
    await f.filter('all');
    f.state.snapshot = null;
    const newFaces = [{ face_id: 'face_new_subject' }];
    f.state.faces = newFaces;
    resolve([{ face_id: 'face_loaded' }]);
    await launching;
    assert.equal(f.state.faces, newFaces);
  });
}

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
  await f.filter('all');
  assert.equal(f.state.filter, undefined);
  assert.equal(f.elements['accept-btn'].disabled, true);
  resolve(new Response('{"person_id":"person_subject"}'));
  await pending;
  assert.equal(f.state.index, 1);
});

test('empty and completed tabs refresh action controls while a background scan continues', async () => {
  const f = fixture();
  f.state.snapshot.inverseLoading = true;
  f.state.filter = 'all';
  for (const faces of [[], [{ face_id: 'face_done' }]]) {
    f.elements['accept-btn'].disabled = true;
    f.state.faces = faces;
    f.state.index = faces.length;
    await f.renderEmpty();
    assert.equal(f.elements['accept-btn'].disabled, false);
  }
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
    assert.match(f.messages[0], /may have saved; reload/);
    f.state.client.updateFace = async () => ({ person_id: 'person_subject' });
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

for (const [mode, owner] of [['normal', 'person_subject'], ['inverse', 'person_donor'], ['unassigned', null]]) {
  test(`revisiting a reassigned ${mode} face labels and confirms the returned owner`, async () => {
    const f = fixture({ mode, owner });
    await f.assign('person_new');
    f.back();
    await f.controls();
    assert.equal(f.elements['accept-btn'].textContent, 'Accept — keep on Morgan (A)');
    assert.equal(f.elements['detach-btn'].hidden, false);
    await f.accept();
    assert.deepEqual(f.requests.at(-1).body, { person_id: 'person_new' });
  });
}

test('Detach clears the current assignment and revisiting it offers local Accept', async () => {
  const f = fixture();
  await f.detach();
  assert.deepEqual(f.requests[0].body, { person_id: null });
  assert.equal(f.state.lastAssigned.get('face_test'), null);
  f.back();
  await f.controls();
  assert.equal(f.elements['accept-btn'].textContent, 'Accept — leave unassigned (A)');
  assert.equal(f.elements['detach-btn'].hidden, true);
  await f.detach();
  await f.accept();
  assert.equal(f.requests.length, 1);
});

test('stale displayed owner sends the displayed target without an owner guard', async () => {
  let savedOwner = 'person_new';
  const f = fixture({ fetchResult: body => {
    savedOwner = body.person_id;
    return new Response(JSON.stringify({ person_id: savedOwner }));
  } });
  await f.accept();
  assert.deepEqual(f.requests[0].body, { person_id: 'person_subject' });
  assert.equal(savedOwner, 'person_subject');
});

test('a differing returned assignment stays visible and is not marked accepted', async () => {
  const f = fixture({ fetchResult: () => new Response('{"person_id":"person_new"}') });
  await f.accept();
  assert.equal(f.state.index, 0);
  assert.deepEqual(f.state.reviewed, {});
  assert.equal(f.state.lastAssigned.get('face_test'), 'person_new');
  await f.controls();
  assert.equal(f.elements['accept-btn'].textContent, 'Accept — keep on Morgan (A)');
});

test('ordinary Undo is a new assignment, while failed Undo preserves history without claiming unchanged server state', async () => {
  const f = fixture();
  await f.assign('person_new');
  f.state.client.updateFace = async () => { throw new Error('response lost'); };
  await f.undo();
  assert.equal(f.state.history.length, 1);
  assert.equal(f.state.reviewed.face_test, 'reassigned');
  assert.match(f.messages[0], /may have saved; reload/);
  f.state.client.updateFace = async (_id, _library, person_id) => ({ person_id });
  await f.undo();
  assert.equal(f.state.lastAssigned.get('face_test'), 'person_subject');
  assert.deepEqual(f.state.reviewed, {});
  assert.match(f.messages[1], /new edit.*does not reverse/);
});
