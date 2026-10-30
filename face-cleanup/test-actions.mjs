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
const lightbox = html.slice(html.indexOf('function bboxOverlayStyle('), html.indexOf('// ---------- actions ----------'));

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
  const selectors = html.slice(html.indexOf('function pickAssetViewUrl('), html.indexOf('// Warm the per-Person thumbnail cache up-front'));
  runInContext(selectors, context);
  const asset = { asset_urls: { original: { url: 'video.mp4', mimetype: 'video/mp4' }, thumbnail_image: { url: 'still.jpg', mimetype: 'image/jpeg' } } };
  assert.equal(context.pickAssetViewUrl(asset), 'still.jpg');
  assert.equal(context.pickAssetThumbUrl(asset), 'still.jpg');
  delete asset.asset_urls.thumbnail_image;
  assert.equal(context.pickAssetViewUrl(asset), null);
  assert.equal(context.pickAssetThumbUrl(asset), null);
  assert.equal(context.pickAssetViewUrl({ asset_urls: { original: { url: 'photo.jpg', mimetype: 'image/jpeg' } } }), 'photo.jpg');
});

// Audit mode: run the shipped block against a synthetic queue and a fake API.
const audit = html.slice(html.indexOf('// ---------- audit mode ----------'), html.indexOf('// ---------- init / multi-stage flow ----------'));

const faceItem = (id, candidate = 'person_candidate') => ({ item_id: id, stratum: 'unassigned', kind: 'face', face_id: `face_${id}`, candidate_person_id: candidate, distance: 0.41 });
const clusterItem = id => ({ item_id: id, stratum: 'unnamed', kind: 'cluster', source_person_id: 'person_source', candidate_person_id: 'person_candidate', distance: 0.31 });
const queueOf = (items, queue_id = 'queue_test') => ({ schema: 'face-review-queue/1', queue_id, library_id: 'lib_test', items });

function auditFixture(items, { owners = {}, fetchResult, storage = new Map(), failSave = false } = {}) {
  const requests = [];
  const messages = [];
  const downloads = [];
  const elements = new Map();
  const element = () => ({
    classList: { add() {}, remove() {}, toggle() {} }, dataset: {}, children: [],
    appendChild(child) { this.children.push(child); }, replaceChildren(...children) { this.children = children; },
  });
  const server = new Map(Object.entries(owners));
  const state = { libraries: [{ id: 'lib_test' }], faceCache: new Map(), assetCache: new Map(), personCache: new Map(), auditOpen: true, audit: null };
  const preloaded = [];
  const opened = [];
  class TestBlob { constructor(parts) { this.text = parts.join(''); } }
  class TestImage { set src(url) { preloaded.push(url); } }
  const context = createContext({
    state, AbortController, setTimeout, clearTimeout, URLSearchParams, REQUEST_TIMEOUT_MS: 1000, Image: TestImage,
    UNNAMED_LABEL: '(unnamed)', Blob: TestBlob, console: { error() {}, warn() {} }, JSON,
    URL: { createObjectURL: blob => { downloads.push({ blob }); return 'blob:test'; }, revokeObjectURL() {} },
    localStorage: {
      getItem: key => storage.get(key) ?? null, removeItem: key => storage.delete(key),
      setItem: (key, value) => { if (failSave && key.startsWith('fcd:audit:queue')) throw new Error('quota'); storage.set(key, value); },
    },
    document: {
      getElementById: id => elements.get(id) ?? elements.set(id, element()).get(id),
      createElement: tag => {
        const el = element();
        if (tag === 'a') el.click = () => { downloads.at(-1).name = el.download; };
        // Decode immediately so evidence becomes ready as it would in a browser.
        if (tag === 'img') Object.defineProperty(el, 'src', { set(url) { setTimeout(() => (url.includes('broken') ? el.onerror : el.onload)(), 0); } });
        return el;
      },
    },
    closeLightbox() {}, openLightbox: (asset, bbox) => opened.push({ asset, bbox }), toast: message => messages.push(message),
    ensureFace: async id => ({ asset_id: `asset_${id}`, bounding_box: { id }, asset_urls: { thumbnail: { url: id.includes('broken') ? 'https://cdn.example/broken.jpg' : `https://cdn.example/${id}.jpg` } } }),
    ensureAsset: async id => ({ id }), ensurePerson: async () => ({ name: 'Candidate', thumbnail_face_id: 'face_thumbnail' }),
    pickAssetViewUrl: asset => `https://cdn.example/${asset.id}.jpg`,
    auditLoadPanel: {}, auditReview: {}, reviewBusy: () => false,
    fetch: async (url, init) => {
      requests.push({ url, method: init.method, body: init.body ? JSON.parse(init.body) : undefined });
      const faceId = new URL(url).pathname.split('/').pop();
      if (fetchResult) {
        const result = fetchResult(init, faceId);
        if (result) return result;
      }
      if (init.method === 'PATCH') server.set(faceId, JSON.parse(init.body).person_id);
      if (faceId === 'faces') return new Response(JSON.stringify({ data: [{ id: 'face_source', asset_urls: { thumbnail: { url: 'https://cdn.example/source.jpg' } } }] }));
      return new Response(JSON.stringify({ id: faceId, person_id: server.get(faceId) ?? null }));
    },
  });
  runInContext(`${client}\n${audit}\nstate.client = new Client('https://api.example', 'test');`, context);
  const settle = () => new Promise(resolve => setTimeout(resolve, 5));
  const begin = async (queue = queueOf(items)) => { context.auditBegin(context.auditValidateQueue(queue)); await settle(); };
  const decide = async outcome => { await settle(); await context.auditDecide(outcome); await settle(); };
  const writes = () => requests.filter(r => r.method === 'PATCH');
  const clearRequests = () => { requests.length = 0; };
  return { state, context, requests, messages, downloads, storage, server, elements, begin, decide, writes, clearRequests, settle, preloaded, opened, log: () => context.auditLog(new Date('2026-01-02T03:04:05Z')) };
}

test('audit: the shown item and the next two load ahead, with their photos', async () => {
  const f = auditFixture([faceItem('one'), faceItem('two'), faceItem('three'), faceItem('four')]);
  await f.begin();
  const faces = f.state.audit.schedule.slice(0, 3).map(slot => slot.item.face_id);
  for (const id of faces) {
    assert.ok(f.preloaded.includes(`https://cdn.example/${id}.jpg`), `${id} thumbnail`);
    assert.ok(f.preloaded.includes(`https://cdn.example/asset_${id}.jpg`), `${id} photo`);
  }
  const later = f.state.audit.schedule[3].item.face_id;
  assert.ok(!f.preloaded.some(url => url.includes(later)));
});

test('audit: a cluster read for loading ahead is not fetched again when shown', async () => {
  const f = auditFixture([clusterItem('one')]);
  await f.begin();
  assert.equal(f.requests.length, 1);
  assert.ok(f.preloaded.includes('https://cdn.example/source.jpg'));
});

test('audit: a failed preload leaves the review usable', async () => {
  const f = auditFixture([faceItem('one'), faceItem('two')]);
  f.context.ensureAsset = async () => { throw new Error('offline'); };
  await f.begin();
  assert.equal(f.state.audit.evidenceReady, true);
  assert.equal(f.messages.length, 0);
});

test('audit: face, cluster and candidate thumbnails each open their own photo', async () => {
  const f = auditFixture([faceItem('one'), clusterItem('two')]);
  await f.begin();
  for (let shown = 0; shown < 2; shown += 1) {
    const { item } = f.state.audit.schedule[shown];
    const host = item.kind === 'face' ? f.elements.get('audit-face') : f.elements.get('audit-cluster').children[0];
    await host.onclick();
    await f.elements.get('audit-person-thumb').onclick();
    const faceId = item.kind === 'face' ? item.face_id : 'face_source';
    assert.deepEqual(Array.from(f.opened.splice(0), o => o.bbox.id), [faceId, 'face_thumbnail']);
    assert.equal(f.opened.length, 0);
    await f.decide('skip');
  }
});

for (const [name, outcome, owner, write, body] of [
  ['correct on an unassigned face assigns', 'correct', null, 'assignment', { person_id: 'person_candidate' }],
  ['correct on another owner assigns', 'correct', 'person_other', 'assignment', { person_id: 'person_candidate' }],
  ['correct on the candidate confirms', 'correct', 'person_candidate', 'confirmation', { person_id: 'person_candidate' }],
  ['wrong on the candidate detaches', 'wrong', 'person_candidate', 'unlink', { person_id: null }],
  ['wrong on an unassigned face stays local', 'wrong', null, 'none', null],
  ['wrong on another owner stays local', 'wrong', 'person_other', 'none', null],
  ['not a face stays local', 'not_a_face', 'person_candidate', 'none', null],
  ['unsure stays local', 'unsure', 'person_candidate', 'none', null],
  ['skip stays local', 'skip', 'person_candidate', 'none', null],
]) {
  test(`audit: ${name}`, async () => {
    const f = auditFixture([faceItem('one')], { owners: { face_one: owner } });
    await f.begin();
    await f.decide(outcome);
    assert.equal(f.state.audit.entries[0].write, write);
    assert.deepEqual(Array.from(f.writes(), r => r.body), body ? [body] : []);
    if (body) assert.equal(f.writes()[0].url, 'https://api.example/api/faces/face_one?library_id=lib_test');
  });
}

test('audit: a face without a candidate cannot be marked correct or wrong', async () => {
  const f = auditFixture([faceItem('one', null), faceItem('two', null), faceItem('three', null)], { owners: { face_one: 'person_other' } });
  await f.begin();
  assert.deepEqual(Array.from(f.context.auditOutcomes(f.state.audit.queue.items[0]), o => o.outcome), ['not_a_face', 'unsure', 'skip']);
  await f.decide('correct');
  await f.decide('wrong');
  assert.equal(f.state.audit.entries.length, 0);
  await f.decide('not_a_face');
  assert.equal(f.state.audit.entries[0].write, 'none');
  assert.equal(f.writes().length, 0);
});

test('audit: every cluster outcome is log-only and never reaches a merge route', async () => {
  const outcomes = ['same_person', 'different', 'mixed', 'unsure', 'skip'];
  const f = auditFixture(outcomes.map((_, i) => clusterItem(`c${i}`)));
  await f.begin();
  for (const outcome of outcomes) await f.decide(outcome);
  assert.deepEqual(Array.from(f.state.audit.entries, e => [e.outcome, e.write]), outcomes.map(o => [o, 'none']));
  assert.deepEqual([...new Set(f.requests.map(r => r.method))], ['GET']);
  assert.ok(f.requests.every(r => new URL(r.url).pathname === '/api/faces'));
  assert.equal(new URL(f.requests[0].url).searchParams.get('limit'), '12');
  assert.equal(new URL(f.requests[0].url).searchParams.get('person_id'), 'person_source');
});

test('audit: repeats are deterministic, about 5%, and spaced after their originals', () => {
  const { context } = auditFixture([]);
  const items = Array.from({ length: 200 }, (_, i) => faceItem(`i${i}`));
  const plan = JSON.stringify(context.auditSchedule('queue_a', items));
  assert.equal(JSON.stringify(context.auditSchedule('queue_a', items)), plan);
  assert.notEqual(JSON.stringify(context.auditSchedule('queue_b', items)), plan);
  for (const size of [19, 20, 21, 40, 73, 119, 200, 500]) {
    for (const queueId of ['alpha', 'beta', 'gamma']) {
      const list = Array.from({ length: size }, (_, i) => faceItem(`i${i}`));
      const schedule = context.auditSchedule(queueId, list);
      const repeats = schedule.filter(slot => slot.repeat_of);
      assert.equal(schedule.length - repeats.length, size);
      assert.equal(repeats.length, size < 20 ? 0 : Math.round(size * 0.05));
      assert.equal(new Set(repeats.map(slot => slot.repeat_of)).size, repeats.length);
      schedule.forEach((slot, index) => {
        if (slot.repeat_of) assert.ok(index - schedule.findIndex(s => s.item.item_id === slot.repeat_of) >= 20);
      });
    }
  }
});

test('audit: a repeat logs repeat_of, makes no server request, and looks like any other item', async () => {
  const items = Array.from({ length: 40 }, (_, i) => faceItem(`i${i}`));
  const f = auditFixture(items);
  await f.begin();
  const { schedule } = f.state.audit;
  for (let i = 0; i < schedule.length - 1; i++) {
    const slot = f.context.auditCurrent();
    if (slot.repeat_of) {
      f.clearRequests();
      await f.decide('correct');
      assert.equal(f.requests.length, 0);
      const entry = f.state.audit.entries.at(-1);
      assert.equal(entry.repeat_of, slot.item.item_id);
      assert.equal(entry.item_id, slot.item.item_id);
      assert.equal(entry.write, 'none');
      return;
    }
    await f.decide('skip');
  }
  assert.fail('expected a repeat in a 40-item queue');
});

test('audit: reviewer-visible text omits distance, stratum, item id, and repeat status', async () => {
  const f = auditFixture([faceItem('secret_item')]);
  await f.begin();
  assert.equal(f.state.audit.queue.items[0].distance, undefined);
  const visible = [f.elements.get('audit-card-host').innerHTML, f.elements.get('audit-progress').innerHTML].join(' ');
  assert.doesNotMatch(visible, /0\.41|unassigned|secret_item|repeat|provenance/i);
});

test('audit: reload resumes the position, log, and Undo state', async () => {
  const storage = new Map();
  const items = [faceItem('one'), faceItem('two'), faceItem('three')];
  const first = auditFixture(items, { storage });
  await first.begin();
  await first.decide('correct');
  await first.decide('skip');
  assert.equal(storage.get('fcd:audit:active'), 'queue_test');
  const reloaded = auditFixture(items, { storage });
  await reloaded.begin(JSON.parse(storage.get('fcd:audit:queue_test')).queue);
  assert.equal(reloaded.state.audit.entries.length, 2);
  assert.equal(reloaded.context.auditCurrent().item.item_id, 'three');
  await reloaded.context.auditUndo();
  assert.equal(reloaded.context.auditCurrent().item.item_id, 'two');
  await reloaded.context.auditUndo();
  await reloaded.context.auditUndo();
  assert.deepEqual(Array.from(reloaded.writes(), r => r.body), [{ person_id: null }]);
});

test('audit: a changed queue cannot adopt saved progress for the same queue_id', async () => {
  const storage = new Map();
  const first = auditFixture([faceItem('one')], { storage });
  await first.begin();
  const changed = auditFixture([faceItem('two')], { storage });
  assert.throws(() => changed.context.auditBegin(changed.context.auditValidateQueue(queueOf([faceItem('two')]))), /different items/);
});

test('audit: a queue for an unreadable library is refused', async () => {
  const f = auditFixture([faceItem('one')]);
  f.state.libraries = [{ id: 'lib_other' }];
  await assert.rejects(f.begin(), /cannot read library/);
});

for (const [name, change, pattern] of [
  ['schema', q => { q.schema = 'other'; }, /schema/],
  ['empty items', q => { q.items = []; }, /no items/],
  ['duplicate item_id', q => { q.items.push({ ...q.items[0] }); }, /duplicate/],
  ['unknown kind', q => { q.items[0].kind = 'merge'; }, /unknown kind/],
  ['path traversal in face_id', q => { q.items[0].face_id = '../people/person_a'; }, /face_id/],
  ['null cluster candidate', q => { q.items[0] = { ...clusterItem('c'), candidate_person_id: null }; }, /candidate_person_id/],
]) {
  test(`audit: queue validation rejects ${name}`, () => {
    const { context } = auditFixture([]);
    const queue = queueOf([faceItem('one')]);
    change(queue);
    assert.throws(() => context.auditValidateQueue(queue), pattern);
  });
}

for (const [name, fetchResult] of [
  ['HTTP failure', init => (init.method === 'PATCH' ? new Response('{"detail":"rejected"}', { status: 500 }) : null)],
  ['network failure', init => { if (init.method === 'PATCH') throw new Error('offline'); }],
  ['read failure', () => new Response('{"detail":"missing"}', { status: 404 })],
  ['mismatched response', init => (init.method === 'PATCH' ? new Response('{"person_id":"person_other"}') : null)],
]) {
  test(`audit: ${name} leaves the item undecided and says so`, async () => {
    const f = auditFixture([faceItem('one'), faceItem('two')], { fetchResult });
    await f.begin();
    await f.decide('correct');
    assert.equal(f.context.auditCurrent().item.item_id, 'one');
    assert.equal(f.state.audit.entries[0].write, 'failed');
    assert.ok(f.state.audit.entries[0].error);
    assert.equal(f.state.audit.notice.error, true);
    assert.match(f.state.audit.notice.text, /still undecided/);
    assert.equal(f.elements.get('audit-alert').hidden, false);
    assert.match(f.messages[0], /still undecided/);
    assert.equal(f.state.audit.busy, false);
  });
}

test('audit: a retry after a failed write decides the item and keeps the failed attempt', async () => {
  let fail = true;
  const f = auditFixture([faceItem('one'), faceItem('two')], { fetchResult: init => {
    if (init.method === 'PATCH' && fail) { fail = false; return new Response('{}', { status: 503 }); }
    return null;
  } });
  await f.begin();
  await f.decide('correct');
  await f.decide('correct');
  assert.deepEqual(Array.from(f.state.audit.entries, e => e.write), ['failed', 'assignment']);
  assert.equal(f.context.auditCurrent().item.item_id, 'two');
  assert.equal(f.state.audit.notice, null);
});

test('audit: a verdict waits for its evidence, while unsure and skip do not', async () => {
  const f = auditFixture([faceItem('broken'), faceItem('two')], { owners: { face_broken: 'person_candidate' } });
  await f.begin();
  await f.decide('correct');
  await f.decide('wrong');
  await f.decide('not_a_face');
  assert.equal(f.state.audit.entries.length, 0);
  assert.equal(f.writes().length, 0);
  assert.equal(f.elements.get('audit-face').textContent, 'load failed');
  await f.decide('skip');
  assert.equal(f.state.audit.entries[0].outcome, 'skip');
});

test('audit: a pending write blocks a second decision', async () => {
  let release;
  const gate = new Promise(resolve => { release = resolve; });
  const f = auditFixture([faceItem('one'), faceItem('two')], { fetchResult: init => (init.method === 'PATCH' ? gate : null) });
  await f.begin();
  await f.settle();
  const pending = f.context.auditDecide('correct');
  await f.context.auditDecide('skip');
  await f.context.auditUndo();
  assert.equal(f.state.audit.entries.length, 0);
  release(new Response('{"person_id":"person_candidate"}'));
  await pending;
  assert.equal(f.state.audit.entries.length, 1);
});

test('audit: Undo of a log-only decision reopens the item without a request', async () => {
  const f = auditFixture([faceItem('one')], { owners: { face_one: 'person_candidate' } });
  await f.begin();
  await f.decide('skip');
  f.clearRequests();
  await f.context.auditUndo();
  assert.equal(f.state.audit.entries.length, 0);
  assert.equal(f.requests.length, 0);
  assert.equal(f.context.auditCurrent().item.item_id, 'one');
});

for (const [name, owner, outcome, restored, notice] of [
  ['assignment from unassigned', null, 'correct', null, /new ordinary edit.*clears the assignment.*rejection/],
  ['assignment from another person', 'person_other', 'correct', 'person_other', /new ordinary edit.*previous person/],
  ['unlink', 'person_candidate', 'wrong', 'person_candidate', /new ordinary edit.*candidate person/],
]) {
  test(`audit: Undo of ${name} warns, then writes the previous person as a fresh edit`, async () => {
    const f = auditFixture([faceItem('one')], { owners: { face_one: owner } });
    await f.begin();
    await f.decide(outcome);
    const before = f.writes().length;
    await f.context.auditUndo();
    assert.equal(f.writes().length, before);
    assert.equal(f.state.audit.entries.length, 1);
    assert.match(f.state.audit.notice.text, notice);
    assert.match(f.state.audit.notice.text, /does not reverse server history/);
    await f.context.auditUndo();
    assert.deepEqual(f.writes().at(-1).body, { person_id: restored });
    assert.equal(f.state.audit.entries.length, 0);
  });
}

test('audit: Undo of a confirmation warns and writes nothing', async () => {
  const f = auditFixture([faceItem('one')], { owners: { face_one: 'person_candidate' } });
  await f.begin();
  await f.decide('correct');
  await f.context.auditUndo();
  assert.match(f.state.audit.notice.text, /confirmation stays saved/);
  await f.context.auditUndo();
  assert.equal(f.writes().length, 1);
  assert.equal(f.state.audit.entries.length, 0);
});

test('audit: a failed Undo keeps the decision and says so', async () => {
  let failing = false;
  const f = auditFixture([faceItem('one')], { fetchResult: init => (failing && init.method === 'PATCH' ? new Response('{}', { status: 500 }) : null) });
  await f.begin();
  await f.decide('correct');
  failing = true;
  await f.context.auditUndo();
  await f.context.auditUndo();
  assert.equal(f.state.audit.entries.length, 1);
  assert.equal(f.state.audit.entries[0].write, 'assignment');
  assert.match(f.state.audit.notice.text, /Undo failed/);
});

test('audit: an unsaved log warns the reviewer to export', async () => {
  const f = auditFixture([faceItem('one'), faceItem('two')], { failSave: true });
  await f.begin();
  await f.decide('skip');
  assert.match(f.state.audit.notice.text, /Export the log/);
});

test('audit: the export has the exact log shape and only identifiers', async () => {
  const items = [faceItem('one'), clusterItem('two')];
  const f = auditFixture(items, { fetchResult: init => (init.method === 'PATCH' ? new Response('{}', { status: 500 }) : null) });
  await f.begin();
  await f.decide('correct');
  await f.decide('skip');
  await f.decide('mixed');
  const log = f.log();
  assert.deepEqual(Object.keys(log), ['schema', 'queue_id', 'exported_at', 'entries']);
  assert.equal(log.schema, 'face-review-log/1');
  assert.equal(log.queue_id, 'queue_test');
  assert.equal(log.exported_at, '2026-01-02T03:04:05.000Z');
  assert.deepEqual(Array.from(log.entries, e => [e.item_id, e.stratum, e.kind, e.outcome, e.repeat_of, e.write]), [
    ['one', 'unassigned', 'face', 'correct', null, 'failed'],
    ['one', 'unassigned', 'face', 'skip', null, 'none'],
    ['two', 'unnamed', 'cluster', 'mixed', null, 'none'],
  ]);
  for (const entry of log.entries) {
    assert.deepEqual(Object.keys(entry), ['item_id', 'stratum', 'kind', 'outcome', 'repeat_of', 'decided_at', 'write', 'error']);
    assert.match(entry.decided_at, /^\d{4}-\d{2}-\d{2}T/);
  }
  assert.match(log.entries[0].error, /500/);
  assert.equal(log.entries[1].error, null);
  f.context.auditExport();
  assert.equal(f.downloads[0].name, 'face-review-log-queue_test.json');
  assert.equal(JSON.parse(f.downloads[0].blob.text).schema, 'face-review-log/1');
  assert.equal(f.state.audit.entries.length, 3);
  assert.doesNotMatch(f.downloads[0].blob.text, /Candidate|undo_person_id/);
});

test('audit: keyboard ignores modified and held keys and maps kinds separately', async () => {
  const f = auditFixture([faceItem('one'), clusterItem('two')]);
  await f.begin();
  await f.settle();
  const key = (k, extra = {}) => f.context.auditKeydown({ key: k, preventDefault() {}, ...extra });
  key('a', { metaKey: true });
  key('a', { repeat: true });
  key('m');
  await f.settle();
  assert.equal(f.state.audit.entries.length, 0);
  key('N');
  await f.settle();
  assert.equal(f.state.audit.entries[0].outcome, 'not_a_face');
  await f.settle();
  key('m');
  await f.settle();
  assert.equal(f.state.audit.entries[1].outcome, 'mixed');
});
