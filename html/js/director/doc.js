// ========================================
// DIRECTOR — the scenario document in the editor, and undo
//
// The document is the server's (server/director/graph.lua has the shape): { format, name,
// description, settings, vars[], world[], nodes[], links[] }. Everything the editor changes is a
// change to this one object; the canvas and the column draw from it, and saving sends it whole.
//
// A DOCUMENT FROM LUA IS NORMALISED FIRST. Lua has one table type, so an empty list arrives as {}
// and an empty props map as [] — normalise() makes lists lists and maps maps before anything reads
// them. Keys this editor does not know are KEPT (a newer server's field must survive an older page).
//
// CHANGES ARE PATHS (diffDoc, applyOps): what one change did, as each place in the document it touched and what is
// there now. The room sends them to the others with the scenario open (room.js), and UNDO keeps them: each step is
// what it changed and what was there before, so an undo takes back your own change and nobody else's. A step is
// worked out from the document itself (the one before against the one after), never written by hand, so it cannot
// drift from what the editor did.
// ========================================

import { renameRef, cardUses, cardUsesAll, eachRef } from './refs.js';

export const FORMAT = 2;   // (server/director/doc.lua DirectorDoc.FORMAT: the server says which it reads, catalogue.format)
const UNDO_LIMIT = 120;
const UNDO_BYTES = 24 * 1024 * 1024;

const isObj = (x) => x !== null && typeof x === 'object' && !Array.isArray(x);

/** A list the server sent, as an array. A Lua list with a hole (or an empty one) arrives as an object
 *  ({ "1": ..., "3": ... }): its values in key order. Anything else is none. */
export function listOf(x) {
    if (Array.isArray(x)) return x;
    if (isObj(x)) return Object.keys(x).sort((a, b) => Number(a) - Number(b)).map((k) => x[k]);
    return [];
}

function list(x) {
    return listOf(x).filter(isObj);
}

const map = (x) => (isObj(x) ? x : {});
const num = (x, d) => (typeof x === 'number' && isFinite(x) ? x : d);
const str = (x) => (typeof x === 'string' ? x : '');

/** A document as the editor reads it: lists are lists, maps are maps, unknown keys kept. */
export function normalise(raw) {
    const d = map(raw);
    const doc = {};
    for (const k of Object.keys(d)) doc[k] = d[k];
    doc.format = num(d.format, FORMAT);
    doc.name = str(d.name) || 'Untitled';
    doc.description = str(d.description);
    doc.settings = map(d.settings);
    doc.settings.start = map(doc.settings.start);
    if (!doc.settings.start.mode) doc.settings.start.mode = 'admin';
    doc.vars = list(d.vars);
    doc.world = list(d.world);
    doc.nodes = list(d.nodes);
    doc.links = list(d.links);
    for (const n of doc.nodes) {
        n.props = map(n.props);
        n.x = num(n.x, 0);
        n.y = num(n.y, 0);
    }
    for (const w of doc.world) w.def = map(w.def);
    for (const l of doc.links) {
        l.from = map(l.from);
        l.to = map(l.to);
    }
    // Comment boxes: the editor's alone. The server keeps them with the rest and never
    // reads them.
    // One box per id (a hand-edited file could name two the same: the second could never be taken).
    const noteIds = new Set();
    doc.comments = list(d.comments).filter((c) => isId(c.id) && !noteIds.has(c.id) && noteIds.add(c.id));
    for (const c of doc.comments) {
        c.x = num(c.x, 0);
        c.y = num(c.y, 0);
        c.w = Math.max(COMMENT_MIN.w, num(c.w, 320));
        c.h = Math.max(COMMENT_MIN.h, num(c.h, 200));
        c.text = str(c.text).slice(0, COMMENT_TEXT_MAX);
    }
    // Its other variants (Multi Run Variants: server/director/graph.lua), each read as the document is. None: no key
    // at all (a document with none is saved exactly as it came).
    if (d.variants !== undefined) {
        const seen = new Set(['v1']);
        doc.variants = list(d.variants).filter((v) => typeof v.id === 'string' && /^v\d+$/.test(v.id) && !seen.has(v.id) && seen.add(v.id))
            .map((v) => {
                const one = normalise({ nodes: v.nodes, links: v.links, world: v.world, comments: v.comments });
                return { ...v, name: str(v.name).slice(0, 40), nodes: one.nodes, links: one.links, world: one.world, comments: one.comments };
            });
        if (!doc.variants.length) delete doc.variants;
    }
    return doc;
}

// ---- variants: one open at a time ----
//
// THE DOCUMENT KEEPS VARIANT 1 AT ITS TOP (nodes, links, comments, world) and the others in doc.variants, each with its
// own cards, wires, comment boxes and the things only it has. The things every variant SHARES (sharedIds, the server's
// rule) live once, in Variant 1's world.
//
// THE EDITOR WORKS ON A VIEW of the open one (unpackDoc): its cards, wires and boxes at the top, its world the shared
// things (the same objects) then its own. Variant 1's view is the document itself. Everything that leaves the editor
// (a save, a check, a test, undo's snapshots) is packed back (packDoc) into the document as the server keeps it.

export const MAX_VARIANTS = 8;

/** The things every variant shares: what is always present, the start's thing (one start for all), and what those name
 *  (a task step's thing: refs.js). As server/director/graph.lua sharedIds. `taskTypes`: the tasks' catalogue
 *  (ed.tasks.types), which says a step's fields that name a thing. */
export function sharedIds(doc, taskTypes) {
    const byId = new Map((doc.world || []).map((w) => [w.id, w]));
    // What each thing's own steps name.
    const named = new Map();
    eachRef({ world: doc.world || [] }, null, taskTypes, (r) => {
        if (r.kind === 'world' && r.step) named.set(r.thing.id, [...(named.get(r.thing.id) || []), r.id]);
    });
    const shared = new Set(), queue = [];
    const add = (id) => { if (typeof id === 'string' && byId.has(id) && !shared.has(id)) { shared.add(id); queue.push(id); } };
    for (const w of doc.world || []) if (w.layer === 'standing') add(w.id);
    const st = (doc.settings && doc.settings.start) || {};
    if (['interaction', 'press', 'area', 'timer'].includes(st.mode)) add(st.world);
    for (let i = 0; i < queue.length; i++) for (const id of named.get(queue[i]) || []) add(id);
    return shared;
}

/** The variants, in order: [{ id, name }], Variant 1 first. */
export function variantList(doc) {
    return [{ id: 'v1', name: str(doc.variantName) }].concat((doc.variants || []).map((v) => ({ id: v.id, name: str(v.name) })));
}

/** A variant's name as its button says it: its own, else "Variant 2" by where it is. */
export function variantLabel(doc, id) {
    const list = variantList(doc);
    const i = list.findIndex((v) => v.id === id);
    return i < 0 ? id : (list[i].name || `Variant ${i + 1}`);
}

/** The view of variant `id` (see above). Variant 1, or one not there: the document itself. */
export function unpackDoc(canon, id, taskTypes) {
    const v = id && id !== 'v1' && (canon.variants || []).find((x) => x.id === id);
    if (!v) return canon;
    const shared = sharedIds(canon, taskTypes);
    const view = { ...canon };
    view.variantOpen = id;
    view.nodes = v.nodes;
    view.links = v.links;
    view.comments = v.comments;
    view.world = canon.world.filter((w) => shared.has(w.id)).concat(v.world);
    view.variants = canon.variants.map((x) => (x.id === id ? { id: x.id, name: x.name } : x));
    // Variant 1's own, kept out of sight (never serialised with the view).
    Object.defineProperty(view, '_base', { value: { nodes: canon.nodes, links: canon.links, comments: canon.comments, world: canon.world, shared },
                                           enumerable: false, writable: true });
    return view;
}

/** The document as the server keeps it, from a view (unpackDoc). A thing shared when the view was made stays Variant
 *  1's (as it is now in the view, or gone if the view removed it); one that has become shared since (set to Always
 *  present) moves to Variant 1's world; the rest of the view's things are the open variant's own. */
export function packDoc(view, taskTypes) {
    if (!view || !view.variantOpen || !view._base) return view;
    const base = view._base;
    const nowShared = sharedIds(view, taskTypes);
    const inView = new Map(view.world.map((w) => [w.id, w]));
    const baseIds = new Set(base.world.map((w) => w.id));
    const world = [];
    for (const w of base.world) {
        if (!base.shared.has(w.id)) world.push(w);
        else if (inView.has(w.id)) world.push(inView.get(w.id));
    }
    const moved = new Set();
    for (const w of view.world) {
        if (!base.shared.has(w.id) && nowShared.has(w.id) && !baseIds.has(w.id)) { world.push(w); moved.add(w.id); }
    }
    const own = view.world.filter((w) => !base.shared.has(w.id) && !moved.has(w.id));
    const canon = {};
    for (const k of Object.keys(view)) if (k !== 'variantOpen') canon[k] = view[k];
    canon.nodes = base.nodes;
    canon.links = base.links;
    canon.comments = base.comments;
    canon.world = world;
    canon.variants = view.variants.map((x) => (x.id === view.variantOpen
        ? { ...x, nodes: view.nodes, links: view.links, comments: view.comments, world: own } : x));
    return canon;
}

/** Run `fn` on every variant's view (Variant 1's is the document); answers the document with what it changed. */
export function eachVariant(canon, fn, taskTypes) {
    fn(canon);
    let doc = canon;
    for (const v of variantList(canon).slice(1)) {
        const view = unpackDoc(doc, v.id, taskTypes);
        fn(view);
        doc = packDoc(view, taskTypes);
    }
    return doc;
}

/** A new variant: a copy of `fromId`'s cards, wires, boxes and own things, their ids kept (so a card named in the
 *  scenario's settings, or allowed by a gated card's rule, is the same in each). Answers its id, or null at the most. */
export function newVariant(canon, fromId, taskTypes) {
    const ids = variantList(canon);
    if (ids.length >= MAX_VARIANTS) return null;
    // (freeId: two builders making a variant at once never make the same one.)
    const id = freeId(new Set(ids.map((v) => v.id)), 'v');
    const from = unpackDoc(canon, fromId, taskTypes);
    const shared = sharedIds(canon, taskTypes);
    const copy = (x) => JSON.parse(JSON.stringify(x));
    canon.variants = (canon.variants || []).concat([{ id, name: '', nodes: copy(from.nodes), links: copy(from.links),
        comments: copy(from.comments || []), world: copy(from.world.filter((w) => !shared.has(w.id))) }]);
    return id;
}

/** Take a variant out (never Variant 1), and out of the In order list. The last one gone: no variants at all. */
export function removeVariant(canon, id) {
    if (!id || id === 'v1') return;
    canon.variants = (canon.variants || []).filter((v) => v.id !== id);
    const s = canon.settings || {};
    if (Array.isArray(s.variantOrder)) s.variantOrder = s.variantOrder.filter((x) => x !== id);
    if (!canon.variants.length) {
        delete canon.variants;
        delete canon.variantName;
        delete s.variantPick;
        delete s.variantOrder;
    }
}

/** A variant's name (Variant 1's is the document's variantName). */
export function renameVariant(canon, id, name) {
    const n = str(name).trim().slice(0, 40);
    if (id === 'v1') { if (n) canon.variantName = n; else delete canon.variantName; return; }
    const v = (canon.variants || []).find((x) => x.id === id);
    if (v) v.name = n;
}

/** Move a variant one place earlier (-1) or later (+1) among the others (Variant 1 stays first: it is the document). */
export function moveVariant(canon, id, by) {
    const list = canon.variants || [];
    const i = list.findIndex((v) => v.id === id);
    const j = i + by;
    if (i < 0 || j < 0 || j >= list.length) return;
    [list[i], list[j]] = [list[j], list[i]];
}

export const COMMENT_MIN = { w: 160, h: 80 };
export const COMMENT_TEXT_MAX = 120;

// ---- ids ----

const ID_OK = /^[A-Za-z0-9_-]{1,64}$/;
export function isId(s) { return typeof s === 'string' && ID_OK.test(s); }

/** A word for an id from any text: "Courier boss" -> "courier_boss". */
export function slug(text, fallback) {
    const s = String(text || '').toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '').slice(0, 40);
    return s || fallback || 'thing';
}

// IN A ROOM (room.js), each builder's new ids are their own: the numbers one in their colour's place of eight (colour 2
// makes card2, card10, card18...), so two builders adding a card at the same moment never make the same id.
let idSlot = 0;
const ID_SLOTS = 8;

/** This page's place among the room's builders (1-8, its colour), or 0: alone, any number. */
export function setIdSlot(n) { idSlot = Number.isInteger(n) && n >= 1 && n <= ID_SLOTS ? n : 0; }

/** The first `base1`, `base2`... not in `used` (in a room, the first of this page's own numbers: setIdSlot). `plain`:
 *  the first of all, wherever made (what every page adds the same way as it opens a scenario). */
export function freeId(used, base, plain) {
    base = slug(base, 'n');
    const own = idSlot && !plain;
    const step = own ? ID_SLOTS : 1;
    let i = own ? idSlot : 1;
    while (used.has(base + i)) i += step;
    return base + i;
}

export function nodeIds(doc) { return new Set(doc.nodes.map((n) => n.id)); }
export function worldIds(doc) { return new Set(doc.world.map((w) => w.id)); }

export function findNode(doc, id) { return doc.nodes.find((n) => n.id === id) || null; }
export function findWorld(doc, id) { return doc.world.find((w) => w.id === id) || null; }

// ---- cards and wires ----

/** A new card of a type, its fields at their defaults. */
export function makeNode(doc, def, x, y) {
    const short = def.type.split('.').pop();
    const props = {};
    for (const f of def.props || []) {
        if (f.default !== undefined && f.default !== null) props[f.key] = f.default;
    }
    const node = { id: freeId(nodeIds(doc), short), type: def.type, v: def.v, x: Math.round(x), y: Math.round(y), props };
    doc.nodes.push(node);
    return node;
}

/** A copy of cards (and the wires between them), moved by dx/dy. Answers the new ids. */
export function duplicateNodes(doc, ids, dx, dy) {
    const used = nodeIds(doc);
    const remap = new Map();
    const made = [];
    for (const id of ids) {
        const n = findNode(doc, id);
        if (!n) continue;
        const copy = JSON.parse(JSON.stringify(n));
        copy.id = freeId(used, n.type.split('.').pop());
        used.add(copy.id);
        copy.x = n.x + dx;
        copy.y = n.y + dy;
        remap.set(id, copy.id);
        doc.nodes.push(copy);
        made.push(copy.id);
    }
    for (const l of doc.links.slice()) {
        if (remap.has(l.from.node) && remap.has(l.to.node)) {
            addLink(doc, { node: remap.get(l.from.node), pin: l.from.pin }, { node: remap.get(l.to.node), pin: l.to.pin });
        }
    }
    return made;
}

export function removeNodes(doc, ids) {
    const gone = new Set(ids);
    doc.nodes = doc.nodes.filter((n) => !gone.has(n.id));
    doc.links = doc.links.filter((l) => !gone.has(l.from.node) && !gone.has(l.to.node));
}

// ---- copy and paste ----

/** What Copy keeps: the cards (deep copies) and the wires between them. Plain data, so it can go
 *  into another scenario: what it names there (a placed thing, a variable) is Check's to judge. */
export function copyNodes(doc, ids) {
    const keep = new Set(ids);
    const nodes = doc.nodes.filter((n) => keep.has(n.id)).map((n) => JSON.parse(JSON.stringify(n)));
    const links = doc.links.filter((l) => keep.has(l.from.node) && keep.has(l.to.node))
        .map((l) => ({ from: { node: l.from.node, pin: l.from.pin }, to: { node: l.to.node, pin: l.to.pin } }));
    return nodes.length ? { nodes, links } : null;
}

/** Put a copy in: its top-left card at `at` (world units, snapped to `snap`), new ids, its wires
 *  between the new cards. Answers the new ids. */
export function pasteNodes(doc, clip, at, snap) {
    if (!clip || !Array.isArray(clip.nodes) || !clip.nodes.length) return [];
    let x0 = Infinity, y0 = Infinity;
    for (const n of clip.nodes) { x0 = Math.min(x0, n.x); y0 = Math.min(y0, n.y); }
    const s = snap || 1;
    const dx = Math.round((at.x - x0) / s) * s, dy = Math.round((at.y - y0) / s) * s;
    const used = nodeIds(doc);
    const remap = new Map();
    const made = [];
    for (const n of clip.nodes) {
        const copy = JSON.parse(JSON.stringify(n));
        copy.id = freeId(used, String(n.type || 'card').split('.').pop());
        used.add(copy.id);
        copy.x = n.x + dx;
        copy.y = n.y + dy;
        remap.set(n.id, copy.id);
        doc.nodes.push(copy);
        made.push(copy.id);
    }
    for (const l of clip.links || []) {
        if (remap.has(l.from.node) && remap.has(l.to.node)) {
            addLink(doc, { node: remap.get(l.from.node), pin: l.from.pin }, { node: remap.get(l.to.node), pin: l.to.pin });
        }
    }
    return made;
}

// ---- comment boxes ----

export function findComment(doc, id) { return (doc.comments || []).find((c) => c.id === id) || null; }

/** A comment box round a rectangle (world units). Answers it. */
export function makeComment(doc, rect, text) {
    if (!Array.isArray(doc.comments)) doc.comments = [];
    const c = {
        id: freeId(new Set(doc.comments.map((x) => x.id)), 'note'),
        x: Math.round(rect.x), y: Math.round(rect.y),
        w: Math.max(COMMENT_MIN.w, Math.round(rect.w)), h: Math.max(COMMENT_MIN.h, Math.round(rect.h)),
        text: String(text || '').slice(0, COMMENT_TEXT_MAX),
    };
    doc.comments.push(c);
    return c;
}

export function removeComment(doc, id) { doc.comments = (doc.comments || []).filter((c) => c.id !== id); }

// ---- reroutes ----

/** Put a Reroute dot on a wire: from -> dot -> to. Answers the dot's card, or null. */
export function insertReroute(doc, linkId, def, at) {
    const l = doc.links.find((k) => k.id === linkId);
    if (!l || !def) return null;
    const from = { node: l.from.node, pin: l.from.pin }, to = { node: l.to.node, pin: l.to.pin };
    const dot = makeNode(doc, def, at.x, at.y);
    removeLink(doc, linkId);
    addLink(doc, from, { node: dot.id, pin: def.inputs[0] });
    addLink(doc, { node: dot.id, pin: def.outputs[0] }, to);
    return dot;
}

function linkIds(doc) { return new Set(doc.links.map((l) => l.id)); }

/** Wire an OUTPUT to an INPUT. An output may lead to several places (Car Entered to a Countdown AND
 *  a Goal): each wire's card starts at the same moment, the oldest wire first, as
 *  Do in Order does. The same wire twice is a no-op. Answers the link. */
export function addLink(doc, from, to) {
    const same = doc.links.find((l) => l.from.node === from.node && l.from.pin === from.pin
        && l.to.node === to.node && l.to.pin === to.pin);
    if (same) return same;
    const link = { id: freeId(linkIds(doc), 'w'), from: { node: from.node, pin: from.pin }, to: { node: to.node, pin: to.pin } };
    doc.links.push(link);
    return link;
}

/** Break every wire on one pin. `side` is 'in' or 'out'. Answers how many went. */
export function breakPin(doc, nodeId, pin, side) {
    const before = doc.links.length;
    doc.links = doc.links.filter((l) => {
        const end = side === 'out' ? l.from : l.to;
        return !(end.node === nodeId && end.pin === pin);
    });
    return before - doc.links.length;
}

export function removeLink(doc, id) { doc.links = doc.links.filter((l) => l.id !== id); }

/** Is anything wired to this pin? */
export function isWired(doc, nodeId, pin, side) {
    return doc.links.some((l) => {
        const end = side === 'out' ? l.from : l.to;
        return end.node === nodeId && end.pin === pin;
    });
}

// ---- placed things and variables: rename everywhere they are named (refs.js walks every place one can be) ----

/** A placed thing renamed everywhere: cards' and steps' fields, other things' settings (a car's riders, its key's spot,
 *  its trailers), the Settings. `taskTypes`: the step types (ed.tasks.types). */
export function renameWorld(doc, cards, taskTypes, oldId, newId) { renameRef(doc, cards, taskTypes, 'world', oldId, newId); }

/** A variable renamed everywhere: the cards that name it, read it, or read it inside (an answer's Only if). */
export function renameVar(doc, cards, oldId, newId) { renameRef(doc, cards, null, 'var', oldId, newId); }

/** Cards that name a placed thing (a 'worlds' list holding it too): [{ node, field }]. */
export function usesOfWorld(doc, cards, id) { return cardUses(doc, cards, 'world', id); }

/** usesOfWorld for every placed thing at once (one walk of the cards): Map id -> [{ node, field }]. */
export function usesOfWorlds(doc, cards) { return cardUsesAll(doc, cards, 'world'); }

/** Cards that name or read a variable. */
export function usesOfVar(doc, cards, id) { return cardUses(doc, cards, 'var', id); }

export { eachRef };

// ---- problems (Check's answers) ----

/** The cards a problem is about: its own card, and every card that names the placed thing it is about. */
export function problemCards(p) {
    const ids = [];
    if (p.node) ids.push(p.node);
    const more = listOf(p.nodes);
    for (const id of more) if (typeof id === 'string' && !ids.includes(id)) ids.push(id);
    return ids;
}

// ---- changes as paths ----
//
// A CHANGE is a list of OPS, each one place in the document and what is there now:
//   { p: [...path], v: value }        set: a field, a card, a thing, a list that is not keyed (set whole)
//   { p: [...path], d: 1 }            gone
//   { p: [...path, '@'], v: [keys] }  a keyed list's order
// A path's steps are an object's keys, or a member of a KEYED LIST: '#' and its key. A list is keyed when every member
// is an object with an id (or a step's or point's k) and no two share one: cards, wires, boxes, things, variables,
// steps, points, variants, takes. A member's key is 'i' + its id, else 'k' + its k ('#iguard1', '#kab3x9'). Any
// other list is a value, set whole. A member set where none has that key is added at the end; its place among the
// rest is the order op's.
// The values are plain data (JSON), and are never shared with the document they came from or go into.

const KEYED_LIST = '#';
const ORDER = '@';

const copyOf = (v) => (v === undefined ? undefined : JSON.parse(JSON.stringify(v)));

/** A member's key in a keyed list, or null. */
function memberKey(x) {
    if (!isObj(x)) return null;
    if (typeof x.id === 'string' || (typeof x.id === 'number' && isFinite(x.id))) return 'i' + x.id;
    if (typeof x.k === 'string' || (typeof x.k === 'number' && isFinite(x.k))) return 'k' + x.k;
    return null;
}

/** The list's members by key, or null when it is not keyed (a member with none, or two with one). */
function keyedMap(list) {
    const m = new Map();
    for (const x of list) {
        const k = memberKey(x);
        if (k === null || m.has(k)) return null;
        m.set(k, x);
    }
    return m;
}

/** Are two plain values the same (an object's keys in any order)? */
export function sameValue(a, b) {
    if (a === b) return true;
    if (Array.isArray(a)) {
        if (!Array.isArray(b) || a.length !== b.length) return false;
        for (let i = 0; i < a.length; i++) if (!sameValue(a[i], b[i])) return false;
        return true;
    }
    if (isObj(a)) {
        if (!isObj(b)) return false;
        const ka = Object.keys(a).filter((k) => a[k] !== undefined), kb = Object.keys(b).filter((k) => b[k] !== undefined);
        if (ka.length !== kb.length) return false;
        for (const k of ka) if (!(k in b) || !sameValue(a[k], b[k])) return false;
        return true;
    }
    return false;
}

/** An object's keys a path can name (none that a path step could be taken for). */
const pathSafe = (o) => Object.keys(o).every((k) => k !== ORDER && k[0] !== KEYED_LIST);

function walk(a, b, p, ops) {
    if (a === b) return;
    if (isObj(a) && isObj(b) && pathSafe(a) && pathSafe(b)) {
        for (const k of Object.keys(a)) {
            if (a[k] !== undefined && (!(k in b) || b[k] === undefined)) ops.push({ p: p.concat(k), d: 1 });
        }
        for (const k of Object.keys(b)) {
            if (b[k] === undefined) continue;
            if (!(k in a) || a[k] === undefined) ops.push({ p: p.concat(k), v: copyOf(b[k]) });
            else walk(a[k], b[k], p.concat(k), ops);
        }
        return;
    }
    if (Array.isArray(a) && Array.isArray(b) && (a.length || b.length)) {
        const am = keyedMap(a), bm = keyedMap(b);
        if (am && bm) {
            for (const k of am.keys()) if (!bm.has(k)) ops.push({ p: p.concat(KEYED_LIST + k), d: 1 });
            for (const [k, y] of bm) {
                if (!am.has(k)) ops.push({ p: p.concat(KEYED_LIST + k), v: copyOf(y) });
                else walk(am.get(k), y, p.concat(KEYED_LIST + k), ops);
            }
            // The order the ops above leave (the gone ones out, the new ones at the end), against the one wanted.
            const left = [...am.keys()].filter((k) => bm.has(k)).concat([...bm.keys()].filter((k) => !am.has(k)));
            const want = [...bm.keys()];
            if (left.some((k, i) => k !== want[i])) ops.push({ p: p.concat(ORDER), v: want });
            return;
        }
    }
    if (!sameValue(a, b)) ops.push({ p, v: copyOf(b) });
}

/** What changed from `a` to `b` (both plain documents), as ops. None: the same. */
export function diffDoc(a, b) {
    const ops = [];
    walk(a, b, [], ops);
    return ops;
}

/** One step of a path: an object's key, or a keyed list's member. */
function stepIn(cur, seg) {
    if (seg[0] === KEYED_LIST) return Array.isArray(cur) ? cur.find((x) => memberKey(x) === seg.slice(1)) : undefined;
    return isObj(cur) ? cur[seg] : undefined;
}

/** One op on `root`, in place. Answers the root (a new one for an op on the whole), and whether it applied: a path
 *  through a member that is not there (taken away meanwhile) does not. A missing object on the way is made (what
 *  normalise() makes on one page and not on another). */
function applyOne(root, op) {
    const p = op.p;
    if (!Array.isArray(p)) return [root, false];
    if (!p.length) return op.d ? [root, false] : [copyOf(op.v), true];
    let parent = null, seg = null, cur = root;
    for (let i = 0; i < p.length - 1; i++) {
        let next = stepIn(cur, p[i]);
        if (next === undefined && p[i][0] !== KEYED_LIST && isObj(cur) && !op.d) {
            next = p[i + 1][0] === KEYED_LIST || p[i + 1] === ORDER ? [] : {};
            cur[p[i]] = next;
        }
        if (next === undefined || next === null || typeof next !== 'object') return [root, false];
        // (An empty list where an object is wanted: what Lua sends for an empty map.)
        if (Array.isArray(next) && !next.length && p[i + 1][0] !== KEYED_LIST && p[i + 1] !== ORDER && isObj(cur) && p[i][0] !== KEYED_LIST) {
            next = {};
            cur[p[i]] = next;
        }
        parent = cur;
        seg = p[i];
        cur = next;
    }
    const last = p[p.length - 1];
    if (last === ORDER) {
        if (!Array.isArray(cur) || !Array.isArray(op.v)) return [root, false];
        const at = new Map(op.v.map((k, i) => [k, i]));
        const listed = cur.filter((x) => at.has(memberKey(x))).sort((x, y) => at.get(memberKey(x)) - at.get(memberKey(y)));
        const rest = cur.filter((x) => !at.has(memberKey(x)));
        cur.length = 0;
        cur.push(...listed, ...rest);
        return [root, true];
    }
    if (last[0] === KEYED_LIST) {
        if (!Array.isArray(cur)) {
            // (An empty map where a list is wanted: the other way round.)
            if (!(isObj(cur) && !Object.keys(cur).length && parent && seg !== null && seg[0] !== KEYED_LIST)) return [root, false];
            cur = [];
            parent[seg] = cur;
        }
        const k = last.slice(1);
        const i = cur.findIndex((x) => memberKey(x) === k);
        if (op.d) { if (i >= 0) cur.splice(i, 1); return [root, true]; }
        if (i >= 0) cur[i] = copyOf(op.v); else cur.push(copyOf(op.v));
        return [root, true];
    }
    if (Array.isArray(cur) && !cur.length && parent && seg !== null && seg[0] !== KEYED_LIST) {
        cur = {};
        parent[seg] = cur;
    }
    if (!isObj(cur)) return [root, false];
    if (op.d) delete cur[last]; else cur[last] = copyOf(op.v);
    return [root, true];
}

/** The ops on `root`, in place and in order. Answers the root (a new one when an op set the whole) and how many did
 *  not apply. */
export function applyOps(root, ops) {
    let missed = 0;
    for (const op of ops) {
        const [r, ok] = applyOne(root, op);
        root = r;
        if (!ok) missed++;
    }
    return { doc: root, missed };
}

/** Is path `a` the same as `b`, or a place inside it? */
export function pathWithin(a, b) {
    if (a.length < b.length) return false;
    for (let i = 0; i < b.length; i++) if (a[i] !== b[i]) return false;
    return true;
}

/** A document's text with every object's keys in order: two documents that are the same read the same, however their
 *  keys came to be in them (what "not saved" compares). */
export function stableText(v) {
    if (Array.isArray(v)) return '[' + v.map((x) => (x === undefined ? 'null' : stableText(x))).join(',') + ']';
    if (isObj(v)) {
        return '{' + Object.keys(v).filter((k) => v[k] !== undefined).sort()
            .map((k) => JSON.stringify(k) + ':' + stableText(v[k])).join(',') + '}';
    }
    return JSON.stringify(v === undefined ? null : v);
}

const opsBytes = (ops) => ops.reduce((n, o) => n + (o.v === undefined ? 16 : JSON.stringify(o.v).length + 16), 0);

// ---- undo ----
//
// YOUR OWN STEPS: each is what it changed (do) and what was there before (undo), worked out at commit from the document
// as it was last committed. What others change (remote) goes into that document too, so it is never taken for a step of
// yours, and an undo takes back only what you did, leaving theirs. Alone, it is the same as going back to the document
// as it was.

export class History {
    /** `pack`: the document as it is kept, from what the editor holds (a variant's view: packDoc); none, as it is.
     *  Each step remembers the variant it was made in (undo goes back to it: lastVariant). */
    constructor(doc, pack) {
        this.pack = typeof pack === 'function' ? pack : (d) => d;
        this.last = copyOf(this.pack(doc));   // the document as of the last step, others' changes in it
        this.steps = [];                      // { do, undo, made, tag, bytes }
        this.at = 0;                          // steps[0 .. at-1] are done
        this.saved = stableText(this.last);
        this.lastVariant = null;
        this.tag = null;                      // the next step's tag (tagSteps)
    }

    /** Record the document as it is now. Answers false when nothing changed. */
    commit(doc) {
        const now = copyOf(this.pack(doc));
        const fwd = diffDoc(this.last, now);
        const tag = this.tag;
        this.tag = null;
        if (!fwd.length) return false;
        const back = diffDoc(now, this.last);
        this.steps.length = this.at;
        this.steps.push({ do: fwd, undo: back, made: (doc && doc.variantOpen) || 'v1', tag, bytes: opsBytes(fwd) + opsBytes(back) });
        // At most UNDO_LIMIT steps, and (a scenario of eight variants is big) about 24 MB of them.
        let bytes = this.steps.reduce((n, s) => n + s.bytes, 0);
        while (this.steps.length > 1 && (this.steps.length > UNDO_LIMIT || bytes > UNDO_BYTES)) {
            bytes -= this.steps[0].bytes;
            this.steps.shift();
        }
        this.at = this.steps.length;
        this.last = now;
        return true;
    }

    /** The document (as kept) with your last step taken back, or null. A change not yet committed (half-typed) counts as
     *  a step. The variant the undone step was made in: lastVariant. */
    undo(doc) {
        this.commit(doc);
        if (this.at === 0) return null;
        const s = this.steps[this.at - 1];
        this.at -= 1;
        this.lastVariant = s.made;
        return this.applied(doc, s.undo);
    }

    /** The document (as kept) with your next undone step done again, or null. Without `doc` (the Systems Creator's
     *  call), the document as last recorded: a redo follows an undo, with nothing changed between. */
    redo(doc) {
        if (doc !== undefined) this.commit(doc);
        if (this.at >= this.steps.length) return null;
        const s = this.steps[this.at];
        this.at += 1;
        this.lastVariant = s.made;
        return this.applied(doc, s.do);
    }

    /** `ops` on a copy of the document as kept now (none: as last recorded): the document it makes, recorded as the last. */
    applied(doc, ops) {
        const out = applyOps(copyOf(doc === undefined ? this.last : this.pack(doc)), ops).doc;
        this.last = copyOf(out);
        return out;
    }

    /** Every step tagged `tag` (newest first) taken back, and gone from undo and redo: the document (as kept), or null
     *  when there were none. The world builder's Exit: what it placed, moved and removed since its last Save. */
    undoTagged(doc, tag) {
        this.commit(doc);
        const mine = this.steps.filter((s) => s.tag === tag);
        if (!mine.length) return null;
        let out = copyOf(this.pack(doc));
        for (let i = mine.length - 1; i >= 0; i--) out = applyOps(out, mine[i].undo).doc;
        const keep = this.steps.slice(0, this.at).filter((s) => s.tag !== tag);
        this.steps = keep;
        this.at = keep.length;
        this.last = copyOf(out);
        return out;
    }

    /** The next commit's step is tagged (undoTagged). */
    tagNext(tag) { this.tag = tag; }
    /** No step is tagged any more (what they did was saved). */
    untag(tag) { for (const s of this.steps) if (s.tag === tag) s.tag = null; }

    /** Someone else's change, already on the document: in the document steps are worked out from, never a step. */
    remote(ops) { this.last = applyOps(this.last, ops).doc; }

    /** The document as kept is now `canon` from elsewhere (the room's, as it is): the steps are let go of. */
    reset(canon) {
        this.last = copyOf(canon);
        this.steps = [];
        this.at = 0;
    }

    /** A change made under the builder, not by them (a lore character's new ped): `change(doc)` goes into the document
     *  steps are worked out from, and into the saved copy when it was saved. Nothing to undo, and nothing new to save. */
    adopt(doc, change) {
        this.commit(doc);   // a change of theirs not yet committed stays a step of its own, and unsaved
        const wasSaved = this.saved === stableText(this.last);
        change(doc);
        this.last = copyOf(this.pack(doc));
        if (wasSaved) this.saved = stableText(this.last);
    }

    canUndo() { return this.at > 0; }
    canRedo() { return this.at < this.steps.length; }
    markSaved(doc) { this.saved = stableText(this.pack(doc)); }
    /** What a save sent, as it was sent (stableText of the packed document, taken before the reply): what is typed while
     *  the save is on its way stays unsaved. */
    markSavedText(text) { this.saved = text; }
    /** Not saved, whatever it is now (the room's, holding changes nobody has saved). */
    markUnsaved() { this.saved = null; }
    isDirty(doc) { return this.saved === null || stableText(this.pack(doc)) !== this.saved; }
}
