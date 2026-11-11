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
const renderSource = html.slice(html.indexOf('async function render()'), html.indexOf('function escapeHtml('));
const renderer = renderSource.replace('async function render()', 'async function renderEmpty()');
const escaper = html.slice(html.indexOf('function escapeHtml('), html.indexOf('// Compute the inline style for the bbox overlay'));
const selectors = html.slice(html.indexOf('function pickAssetViewUrl('), html.indexOf('// Warm the per-Person thumbnail cache up-front'));

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
  const elements = Object.fromEntries(['accept-btn', 'detach-btn', 'undo-btn', 'include-manual'].map(id => [id, {}]));
  const context = createContext({
    state, REQUEST_TIMEOUT_MS: 1000, AbortController, setTimeout, clearTimeout,
    document: { getElementById: id => elements[id], querySelector: () => ({}), querySelectorAll: selector => selector === '#filter-tabs button' ? [] : Object.values(elements) }, undoBtn: elements['undo-btn'],
    changeSubjectLink: { setAttribute() {} }, CSS: { escape: value => value }, UNNAMED_LABEL: '(unnamed)',
    localStorage: { setItem() {} }, LS_KEY_FILTER: 'filter',
    applyFilter: selected => { state.index = 0; if (selected === 'inverse') state.faces = state.snapshot.inverseFaces; if (selected === 'unassigned') state.faces = state.snapshot.unassignedFaces; }, renderTabs() {},
    faceHost: {}, progress: {}, buildInverseFaces: buildLazyFaces, buildUnassignedFaces: buildLazyFaces,
    loadReviewed: () => ({}), subjectLabel: {}, content: {}, hideAllPanels() {},
    closeLightbox() {}, renderProgress() {}, renderReviewScope() {},
    buildSnapshot: async () => initialSnapshot, prefetchPersonThumbs: async () => {},
    flashButton() {}, render() { context.refreshActionControls(); }, prefetchNeighbors() {},
    saveReviewed: (_id, reviewed) => saved.push({ ...reviewed }),
    toast: message => messages.push(message), console: { error() {} },
    fetch: async (url, init) => {
      requests.push({ url, method: init.method, body: JSON.parse(init.body) });
      return fetchResult ? fetchResult(JSON.parse(init.body)) : new Response(JSON.stringify({ person_id: JSON.parse(init.body).person_id, assignment_source: JSON.parse(init.body).person_id === null ? null : 'manual' }));
    },
  });
  runInContext(`${client}\n${actions}\n${navigation}\n${loaders}\n${filter}\n${launch}\n${renderer}\nasync function renderControls() { const face = state.faces[state.index]; ${controls} }\nstate.client = new Client('https://api.example', 'test');`, context);
  return { state, context, requests, messages, saved, elements, loadingStarted, accept: context.acceptCurrent, assign: context.assignTo, detach: context.detachCurrent, undo: context.undoLast, next: context.navAdvance, back: context.navBack, skip: context.skipCurrent, filter: context.setFilter, controls: context.renderControls, launch: context.launchCleanup, renderEmpty: context.renderEmpty };
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
    assert.equal(f.state.snapshot.facesById.get('face_test').assignment_source, 'manual');
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


// Exercise the shipped builders and filtering together: manual metadata must
// survive each list path, and tab counts must describe the visible scope.
const provenance = html.slice(html.indexOf('// ---------- provenance and review scope ----------'), html.indexOf('// ---------- prefetch helpers ----------'));
const builders = html.slice(html.indexOf('async function buildSnapshot('), html.indexOf('// ---------- provenance and review scope ----------'));
const tabsRenderer = html.slice(html.indexOf('function renderTabs()'), html.indexOf('// Triggered the first time the operator opens the inverse tab.'));

function provenanceFixture() {
  const raw = [
    { id: 'auto', source: 'automatic', assignment_source: 'assigned' },
    { id: 'manual_assignment', source: 'automatic', assignment_source: 'manual' },
    { id: 'manual_box', source: 'manual', assignment_source: null },
    { id: 'unknown', source: 'automatic', assignment_source: null },
    { id: 'old_api', source: 'automatic' },
  ].map(f => ({ ...f, person_id: 'subject', asset_id: 'asset', cluster_assignment: {
    distance_to_person: 0.8, candidates: [{ person_id: 'subject', name: 'Subject', distance: 0.1 }, { person_id: 'other', name: 'Other', distance: 0.2 }],
  } }));
  const elements = { 'manual-summary': {} };
  const tabButtons = [];
  const state = { includeManual: false, filter: 'all', reviewed: {}, personCache: new Map(), client: {
    getPersonWithMetrics: async () => ({ id: 'subject', name: 'Subject' }),
    listFacesPage: async () => ({ data: raw, has_more: false }),
    listAllFacesPage: async () => ({ data: raw.map(f => ({ ...f, person_id: null })), has_more: false }),
  } };
  const tabs = { appendChild: b => tabButtons.push(b), set innerHTML(_) { tabButtons.length = 0; } };
  const context = createContext({ state, tabs, SIBLING_MARGIN: 0.05, DISTANCE_GATE: 0.35, OUTLIER_DISTANCE: 0.45,
    document: { getElementById: id => elements[id], createElement: () => ({ classList: { add() {} } }) },
    currentPersonId: id => state.snapshot.facesById.get(id)?.initial_person_id ?? null,
    setFilter: async filter => { context.applyFilter(filter); context.renderTabs(); context.renderReviewScope(); }, console,
  });
  runInContext(`${builders}\n${provenance}\n${tabsRenderer}`, context);
  return { state, raw, context, tabButtons, elements };
}

for (const mode of ['normal', 'inverse', 'unassigned']) {
  test(`manual provenance survives the ${mode} builder and is excluded by default`, async () => {
    const f = provenanceFixture();
    const snapshot = await f.context.buildSnapshot('library', 'subject', [{ id: 'other', name: 'Other' }]);
    f.state.snapshot = snapshot;
    let faces = snapshot.faces;
    if (mode === 'inverse') faces = snapshot.inverseFaces = await f.context.buildInverseFaces(snapshot);
    if (mode === 'unassigned') faces = snapshot.unassignedFaces = await f.context.buildUnassignedFaces(snapshot);
    for (const face of faces) snapshot.facesById.set(face.face_id, face);
    f.state.filter = mode === 'normal' ? 'all' : mode;
    f.context.applyFilter(f.state.filter);
    assert.deepEqual(Array.from(f.state.faces, face => face.face_id).sort(), ['auto', 'old_api', 'unknown']);
    f.context.renderReviewScope();
    assert.match(f.elements['manual-summary'].textContent, /2 manual faces hidden/);
    f.context.renderTabs();
    assert.ok(f.tabButtons.some(b => b.textContent === (mode === 'normal' ? 'All (3)' : mode === 'inverse' ? 'Could be on subject (3)' : 'Unassigned candidates (3)')));
    if (mode === 'normal') {
      for (const tab of ['closer', 'ambig', 'gate', 'outliers', 'all']) {
        f.context.applyFilter(tab);
        assert.ok(f.state.faces.every(face => !['manual_assignment', 'manual_box'].includes(face.face_id)), tab);
      }
    }
    await f.context.setIncludeManual(true);
    assert.equal(f.state.faces.length, 5);
    assert.match(f.elements['manual-summary'].textContent, /2 manual faces included/);
    await f.context.setIncludeManual(false);
    assert.equal(f.state.faces.length, 3);
    f.state.actionInFlight = true;
    await f.context.setIncludeManual(true);
    assert.equal(f.state.includeManual, false);
  });
}

test('box and assignment labels distinguish manual, automatic, unknown, and unassigned', async () => {
  const f = provenanceFixture();
  f.state.snapshot = await f.context.buildSnapshot('library', 'subject', []);
  for (const [source, expected] of [
    ['assigned', 'Automatic — ingest'], ['clustered', 'Automatic — clustered'],
    ['auto_merged', 'Automatic — merged'], ['manual', 'Manual'], [null, 'Unknown'], [undefined, 'Unknown'],
  ]) {
    const labels = f.context.provenanceLabels({ face_id: 'auto', source: 'automatic', assignment_source: source });
    assert.match(labels, /Box: Automatically detected/);
    assert.ok(labels.includes(`Assignment: ${expected}</span>`));
  }
  const labels = f.context.provenanceLabels({ face_id: 'missing', source: 'manual', assignment_source: null });
  assert.match(labels, /Box: Manually created/);
  assert.match(labels, /Assignment: Unassigned/);
});

test('a response from an older API clears stale assignment provenance to unknown', async () => {
  const f = fixture({ fetchResult: body => new Response(JSON.stringify({ person_id: body.person_id })) });
  f.state.snapshot.facesById.get('face_test').assignment_source = 'assigned';
  await f.accept();
  assert.equal(f.state.snapshot.facesById.get('face_test').assignment_source, undefined);
});


test('Accept refreshes provenance tab counts without removing recent edits from Prev and Undo', async () => {
  const f = fixture();
  f.context.OUTLIER_DISTANCE = 0.45;
  f.state.includeManual = false;
  f.state.snapshot.faces = f.state.faces;
  f.state.faces.forEach(face => { face.d_current = 0.7; face.assignment_source = 'assigned'; });
  const buttons = [];
  f.context.tabs = { appendChild: b => buttons.push(b), set innerHTML(_) { buttons.length = 0; } };
  f.context.document.createElement = () => ({ classList: { add() {} } });
  runInContext(`${provenance}\n${tabsRenderer}`, f.context);
  f.context.renderTabs();
  assert.ok(buttons.some(b => b.textContent === 'All (2)'));
  await f.accept();
  assert.ok(buttons.some(b => b.textContent === 'All (1)'));
  assert.equal(f.state.faces.length, 2);
  f.back();
  assert.equal(f.state.faces[f.state.index].face_id, 'face_test');
});

// Model the API's lean default so losing include=variants reproduces the
// thumbnail-only lightbox, including when neighbor prefetch fills the cache.
const assetHelpers = html.slice(html.indexOf('// ---------- prefetch helpers ----------'), html.indexOf('// Warm the per-Person thumbnail cache up-front'));
const lightbox = html.slice(html.indexOf('function escapeHtml('), html.indexOf('// ---------- actions ----------'));

for (const video of [false, true]) {
for (const prefetched of [false, true]) {
  test(`${video ? 'Video still' : 'Photo'} lightbox loads a distinct preview with ${prefetched ? 'prefetched' : 'on-demand'} asset metadata`, async () => {
    const requests = [];
    const warmed = [];
    const mounted = [];
    const state = {
      snapshot: { library_id: 'lib_test' }, index: 0, prefetchInFlight: false,
      faces: [{ face_id: 'face_test', asset_id: 'asset_test' }],
      faceCache: new Map([['face_test', {}]]), assetCache: new Map(),
    };
    const context = createContext({
      state, URLSearchParams, AbortController, setTimeout, clearTimeout,
      REQUEST_TIMEOUT_MS: 1000, PREFETCH_RADIUS: 2, PREFETCH_BATCH_SIZE: 100,
      Image: class { set src(url) { warmed.push(url); } },
      document: {
        createElement: () => ({ innerHTML: '', addEventListener() {}, remove() {} }),
        body: { appendChild: element => mounted.push(element) },
      },
      toast: () => assert.fail('A larger preview should be available'), console,
      fetch: async url => {
        requests.push(new URL(url));
        const variants = new URL(url).searchParams.get('include') === 'variants';
        const asset_urls = { [video ? 'thumbnail_image' : 'thumbnail']: { url: 'https://cdn.example/thumb.jpg', width: 360, mimetype: 'image/jpeg' } };
        if (variants) {
          asset_urls[video ? 'preview_image' : 'preview'] = { url: 'https://cdn.example/preview.jpg', width: 1440, mimetype: 'image/jpeg' };
          if (video) asset_urls.original = { url: 'https://cdn.example/video.mp4', mimetype: 'video/mp4' };
        }
        return new Response(JSON.stringify({ data: [{ id: 'asset_test', width: 1440, height: 960, asset_urls }] }));
      },
    });
    runInContext(`${client}\n${assetHelpers}\n${lightbox}\nstate.client = new Client('https://api.example', 'test');`, context);
    if (prefetched) await context.prefetchNeighbors();
    const asset = await context.ensureAsset('asset_test');
    assert.equal(requests.length, 1);
    assert.equal(requests[0].searchParams.get('library_id'), 'lib_test');
    assert.deepEqual(requests[0].searchParams.getAll('ids'), ['asset_test']);
    assert.equal(context.pickAssetThumbUrl(asset), 'https://cdn.example/thumb.jpg');
    assert.deepEqual(warmed, prefetched ? ['https://cdn.example/thumb.jpg'] : []);
    context.openLightbox(asset, { x: 144, y: 96, w: 288, h: 192 });
    assert.equal(mounted.length, 1);
    assert.match(mounted[0].innerHTML, /src="https:\/\/cdn.example\/preview.jpg"/);
    assert.doesNotMatch(mounted[0].innerHTML, /thumb.jpg/);
    assert.match(mounted[0].innerHTML, /left:10%;top:10%;width:20%;height:20%/);
    assert.equal(context.lightboxOpen(), true);
    context.closeLightbox();
    assert.equal(context.lightboxOpen(), false);
  });
}

}

test('image selectors never use a video original when a larger still is missing', () => {
  const context = createContext({});
  runInContext(selectors, context);
  const asset = { asset_urls: { original: { url: 'video.mp4', mimetype: 'video/mp4' }, thumbnail_image: { url: 'still.jpg', mimetype: 'image/jpeg' } } };
  assert.equal(context.pickAssetViewUrl(asset), 'still.jpg');
  assert.equal(context.pickAssetThumbUrl(asset), 'still.jpg');
  delete asset.asset_urls.thumbnail_image;
  assert.equal(context.pickAssetViewUrl(asset), null);
  assert.equal(context.pickAssetThumbUrl(asset), null);
  assert.equal(context.pickAssetViewUrl({ asset_urls: { original: { url: 'photo.jpg', mimetype: 'image/jpeg' } } }), 'photo.jpg');
});

// ---------- API key storage ----------
const keyStorage = html.slice(html.indexOf('// ---------- config / persistence ----------'), html.indexOf('// ---------- toast ----------'));
const credentialFlow = html.slice(html.indexOf('async function runStage()'), html.indexOf('function renderLibraryPicker()'));

class FakeStorage {
  constructor(entries = {}) { this.map = new Map(Object.entries(entries)); this.writes = []; }
  getItem(key) { return this.map.has(key) ? this.map.get(key) : null; }
  setItem(key, value) { this.writes.push(key); this.map.set(key, String(value)); }
  removeItem(key) { this.map.delete(key); }
}

function credentialFixture({ local = {}, session = {}, inputs = {} } = {}) {
  const localStorage = new FakeStorage(local);
  const sessionStorage = new FakeStorage(session);
  const clients = [];
  const messages = [];
  let reloads = 0;
  const elements = Object.fromEntries(['api-base', 'api-key', 'creds-hint'].map(id => [id, { value: inputs[id] ?? '', textContent: '' }]));
  const state = { libraries: [], actionInFlight: false };
  const context = createContext({
    state, localStorage, sessionStorage,
    document: { getElementById: id => elements[id] },
    credsPanel: { hidden: true }, changeSubjectLink: { hidden: true }, forgetKeyLink: { hidden: true },
    hideAllPanels() {}, toast: message => messages.push(message),
    location: { reload: () => { reloads += 1; } },
    Client: class { constructor(base, key) { clients.push({ base, key }); } async listLibraries() { return []; } },
  });
  runInContext(`${keyStorage}\n${credentialFlow}`, context);
  return { context, localStorage, sessionStorage, clients, messages, elements, state, reloads: () => reloads };
}

test('a saved API key lives in session storage, never local storage', async () => {
  const f = credentialFixture({ inputs: { 'api-base': 'https://api.example', 'api-key': 'key_test' } });
  await f.context.onSaveCreds();
  assert.equal(f.sessionStorage.getItem('fcd:api_key'), 'key_test');
  assert.deepEqual(f.localStorage.writes, ['fcd:api_base']);
  assert.deepEqual(f.clients, [{ base: 'https://api.example', key: 'key_test' }]);
  assert.equal(f.context.forgetKeyLink.hidden, false);
});

test('a key left in local storage by an earlier version moves into the session', async () => {
  const f = credentialFixture({ local: { 'fcd:api_base': 'https://api.example', 'fcd:api_key': 'key_old' } });
  await f.context.runStage();
  assert.equal(f.localStorage.getItem('fcd:api_key'), null);
  assert.equal(f.sessionStorage.getItem('fcd:api_key'), 'key_old');
  assert.deepEqual(f.clients, [{ base: 'https://api.example', key: 'key_old' }]);
});

test('without a session key the Connect panel shows and Forget API key hides', async () => {
  const f = credentialFixture({ local: { 'fcd:api_base': 'https://api.example' } });
  f.context.forgetKeyLink.hidden = false;
  await f.context.runStage();
  assert.equal(f.context.credsPanel.hidden, false);
  assert.equal(f.context.forgetKeyLink.hidden, true);
  assert.deepEqual(f.clients, []);
});

test('Forget API key clears the key from both storages and reloads', () => {
  const f = credentialFixture({ local: { 'fcd:api_key': 'key_old', 'fcd:library_id': 'lib_test' }, session: { 'fcd:api_key': 'key_test' } });
  f.context.onForgetKey({ preventDefault() {} });
  assert.equal(f.sessionStorage.getItem('fcd:api_key'), null);
  assert.equal(f.localStorage.getItem('fcd:api_key'), null);
  assert.equal(f.localStorage.getItem('fcd:library_id'), 'lib_test');
  assert.equal(f.reloads(), 1);
});

test('Forget API key waits for a pending change', () => {
  const f = credentialFixture({ session: { 'fcd:api_key': 'key_test' } });
  f.state.actionInFlight = true;
  f.context.onForgetKey({ preventDefault() {} });
  assert.equal(f.sessionStorage.getItem('fcd:api_key'), 'key_test');
  assert.equal(f.reloads(), 0);
  assert.equal(f.messages.length, 1);
});

// ---------- HTML escaping of API values ----------
const hostileUrl = 'https://cdn.example/x.jpg" data-injected="1';

test('person picker cards escape API-returned URLs and counts', () => {
  const personList = html.slice(html.indexOf('function renderPersonList()'), html.indexOf('function onPickPerson('));
  const cards = [];
  const context = createContext({
    state: { peoplePicker: [{ id: 'person_test', name: null, cluster_metrics: { face_count: '<b>3</b>' }, asset_urls: { thumbnail: { url: hostileUrl } } }] },
    UNNAMED_LABEL: '(unnamed)', onPickPerson() {},
    document: {
      getElementById: id => (id === 'person-filter' ? { value: '' } : { innerHTML: '', appendChild: card => cards.push(card) }),
      createElement: () => ({}),
    },
  });
  runInContext(`${personList}\n${escaper}`, context);
  context.renderPersonList();
  assert.equal(cards.length, 1);
  assert.match(cards[0].innerHTML, /src="https:\/\/cdn.example\/x.jpg&quot; data-injected=&quot;1"/);
  assert.match(cards[0].innerHTML, /&lt;b&gt;3&lt;\/b&gt; faces/);
  assert.doesNotMatch(cards[0].innerHTML, /<b>/);
});

test('the lightbox escapes an API-returned image URL', () => {
  const mounted = [];
  const context = createContext({
    toast: () => assert.fail('a URL is available'),
    document: { createElement: () => ({ innerHTML: '', addEventListener() {} }), body: { appendChild: element => mounted.push(element) } },
  });
  runInContext(`${selectors}\n${lightbox}`, context);
  context.openLightbox({ asset_urls: { preview: { url: hostileUrl } } }, null);
  assert.match(mounted[0].innerHTML, /src="https:\/\/cdn.example\/x.jpg&quot; data-injected=&quot;1"/);
});

async function renderFaceCard(viewUrl) {
  const elements = new Map();
  const element = id => {
    if (!elements.has(id)) elements.set(id, { id, innerHTML: '', textContent: '', classList: { add() {}, remove() {} }, removeAttribute(name) { delete this[name]; }, appendChild() {} });
    return elements.get(id);
  };
  const buttons = [];
  const face = { face_id: 'face_<i>1</i>', asset_id: 'asset_test', mode: 'subject', d_current: 0.4, candidates: [{ id: 'person_new', name: 'Morgan', d: 0.3 }, { id: 'person_lazy', name: 'Casey', d: 0.32 }] };
  const state = {
    faces: [face], index: 0, reviewed: {},
    snapshot: { subject: { id: 'person_subject', name: 'Riley' }, people: [] },
    personCache: new Map([['person_new', { asset_urls: { thumbnail: { url: hostileUrl } } }]]),
  };
  const context = createContext({
    state, UNNAMED_LABEL: '(unnamed)', CANDIDATE_WINDOW: 0.6, DISTANCE_GATE: 0.35, COHESION_GATE: 0.65,
    closeLightbox() {}, refreshActionControls() {}, renderReviewScope() {}, renderProgress() {},
    currentPersonId: () => 'person_subject', currentPersonName: () => 'Riley',
    provenanceLabels: () => '', badgeFor: () => '', reviewBusy: () => false, assignTo() {}, openLightbox() {},
    bboxOverlayStyle: () => '', ensurePerson: async () => ({ asset_urls: { thumbnail: { url: hostileUrl } } }),
    ensureFace: async () => ({ asset_urls: { thumbnail: { url: hostileUrl } } }),
    ensureAsset: async () => ({ asset_urls: { thumbnail: { url: hostileUrl }, preview: { url: viewUrl } } }),
    faceHost: element('face-host'), progress: element('progress'),
    document: { getElementById: element, createElement: () => { const b = { dataset: {}, thumb: { innerHTML: '' } }; b.querySelector = () => b.thumb; buttons.push(b); return b; } },
    console,
  });
  runInContext(`${renderSource}\n${escaper}\n${selectors}`, context);
  element('asset-link').href = 'about:blank';
  await context.render();
  await new Promise(resolve => setTimeout(resolve, 0));
  return { faceHost: context.faceHost, element, buttons };
}

test('the face card escapes API-returned values and links only to http(s) assets', async () => {
  const { faceHost, element, buttons } = await renderFaceCard('javascript:alert(1)');
  const escaped = /src="https:\/\/cdn.example\/x.jpg&quot; data-injected=&quot;1"/;
  assert.match(faceHost.innerHTML, /<code>face_&lt;i&gt;1&lt;\/i&gt;<\/code>/);
  assert.match(element('face-img-wrap').innerHTML, escaped);
  assert.match(element('asset-img-wrap').innerHTML, escaped);
  assert.equal(buttons.length, 2);
  assert.match(buttons[0].innerHTML, escaped);
  assert.match(buttons[1].thumb.innerHTML, escaped);
  assert.equal(element('asset-link').href, undefined);
  assert.equal(element('asset-link').textContent, 'asset url unavailable');
});

test('the face card links an http(s) asset view URL', async () => {
  const { element } = await renderFaceCard('https://cdn.example/preview.jpg');
  assert.equal(element('asset-link').href, 'https://cdn.example/preview.jpg');
});
