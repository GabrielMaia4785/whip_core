// ========================================
// DIRECTOR — the room: editing a scenario together (client/director_room.lua, server/director/room.lua)
//
// THE SCENARIO IS THE ROOM'S. Everything this page changes goes to the room as it is made, and what the others change
// comes onto this page's copy in the room's order (sync.js). Saving saves the room's (app.js saveRoom), whoever made
// the changes; undo takes back only this page's own (doc.js History). New ids are this page's own (doc.js setIdSlot:
// its colour), so two builders adding at once never make the same one.
//
// THE OTHERS, each in their own colour (this page is drawn as it always is):
//   their pointer on the blueprint, in the blueprint's own units (it lands on the same card whatever each one's pan and
//   zoom); the cards they have picked, ringed, their name over them; the field they are typing in, ringed; who is in,
//   in the dock and over the world builder. Only on the variant this page has open (each variant's cards are its own).
//   A card another is dragging is theirs until they let go (app.js ed.heldBy).
//
// What this page says of itself goes to the game (directorPresence) when it changes, at most every SEND_MS, and only
// while someone else is in the room: where it is (the editor, the world builder, a test, away), the variant open, the
// pointer on the blueprint, the cards picked, the thing and the field it is on, and what it is dragging. The game adds
// what the world builder knows (its camera, the spot under its pointer, the thing it moves).
// ========================================

import { nuiCallback } from '../utils.js';
import { listOf, setIdSlot } from './doc.js';
import { RoomSync } from './sync.js';

const SEND_MS = 100;
const ID_OK = /^[A-Za-z0-9_-]{1,64}$/;
const REF_OK = /^[A-Za-z0-9_.:|~-]{1,200}$/;
const MAX_SEL = 40;
const ARROW = '<svg class="dr-peer-arrow" viewBox="0 0 20 22" aria-hidden="true">'
    + '<path d="M2 1.5 L2 18.5 L6.6 14.2 L9.7 21 L13 19.5 L9.9 12.9 L16.2 12.6 Z"/></svg>';
const WHERE_TEXT = { page: 'In the editor', builder: 'In the world builder', test: 'Testing it', away: 'Away' };

let host = null;      // app.js's parts (initRoom)
let key = null;       // the scenario whose room this is
let members = [];     // { src, name, colour, rgb, me, state: { where, variant, cursor, sel, thing, field, drag } }
let layer = null;     // the pointers, in the canvas's world layer (moved and zoomed with the cards)
let sheet = null;     // the others' picks and fields: a style sheet of their colours and names
let worldWho = null;  // who is in, over the world builder
let pointer = null;   // where this page's pointer is on the blueprint, in its units, or null
let pointerWhere = '';   // where this page was as the pointer was last on the blueprint
let sentText = '';    // what was last said, as text
let timer = 0, lastAt = 0;
let sync = null;      // the scenario kept the same as the room's (sync.js)
let syncKey = null;   // the scenario it is on

const others = () => members.filter((m) => !m.me);
const rgbOf = (m) => `rgb(${m.rgb[0]}, ${m.rgb[1]}, ${m.rgb[2]})`;
/** Is the room the scenario open here (not an example the tutorial shows)? */
const ours = () => !!(host && key && host.ed.key === key && host.ed.doc && !host.ed.demo);

/** The page's parts (app.js): ed, canvas, where(), variant(), packed(), setCanon(c), dragging(), dragOf(), thingOn(),
 *  applied(ops), saved(e), takeDoc(doc, o), reapply(ops), watch(known) -> Promise of its answer. */
export function initRoom(h) {
    host = h;
    const root = h.canvas.root;
    root.addEventListener('mousemove', (ev) => { pointer = h.canvas.toWorld(ev.clientX, ev.clientY); roomSay(); });
    root.addEventListener('mouseleave', () => { pointer = null; roomSay(); });
    // (A wheel zoom moves what is under a still pointer: said again.)
    root.addEventListener('wheel', (ev) => { pointer = h.canvas.toWorld(ev.clientX, ev.clientY); roomSay(); }, { passive: true });
    // The field this page is in, as it comes and goes.
    document.addEventListener('focusin', () => roomSay());
    document.addEventListener('focusout', () => setTimeout(roomSay, 0));
    layer = document.createElement('div');
    layer.className = 'dr-peers';
    h.canvas.world.appendChild(layer);
    sheet = document.createElement('style');
    document.head.appendChild(sheet);
    sync = new RoomSync({
        packed: () => host.packed(),
        setCanon: (c) => host.setCanon(c),
        history: () => host.ed.history,
        dragging: () => host.dragging(),
        send: (b) => nuiCallback('directorRoomOps', { key: syncKey, ...b }),
        applied: (ops) => host.applied(ops),
        saved: (e) => host.saved(e),
        reset: (e) => host.takeDoc(e.doc, { dirty: e.dirty, baseRev: e.baseRev, why: e.why }),
        resync: () => resync(true),
    });
    // (A card another drags is theirs: canvas.js asks.)
    h.ed.heldBy = (id) => {
        const m = others().find((x) => x.state.drag === 'card:' + id && onOurGrid(x));
        return m ? m.name : null;
    };
}

// ============================================================
// The scenario, kept the same as the room's (sync.js)
// ============================================================

/** This page is on the room's scenario: `info` { id, seq, epoch, colour, dirty }, `canon` the room's as it came
 *  (normalised, before what this page adds as it opens). `canon` null: back on the room it had, nothing new in it.
 *  `opts.seed`: this page holds changes the room never got (it started again from the saved draft): they go to it. */
export function roomOpen(info, canon, opts) {
    if (!sync || !host) return;
    syncKey = host.ed.key;
    setIdSlot(Number(info.colour) || 0);
    sync.others = others().length;
    if (canon === null) {
        if (sync.on && sync.roomId === info.id) {
            sync.epoch = info.epoch || sync.epoch;
            // (Batches sent as the screen closed may have reached the room after it heard this page go, and been
            // passed over: the room's scenario again, this page's own put back on it.)
            if (sync.inflight.length) resync(true);
            return;
        }
        resync(true);
        return;
    }
    sync.open(info, canon);
    if (opts && opts.seed) sync.flush(false);
}

/** This page's own ids (doc.js setIdSlot) while the Director is up (`on`), and plain ones while it is closed: the
 *  Systems Creator makes ids with the same freeId. */
export function roomIds(on) {
    const me = members.find((m) => m.me);
    setIdSlot(on && roomOn() && me ? me.colour : 0);
}

/** No room: an old revision open to restore, a shipped one, an example. */
export function roomLeave() {
    if (sync) sync.close();
    syncKey = null;
    setIdSlot(0);
}

/** Is this page's scenario its room's? */
export function roomOn() { return !!(sync && sync.on && host && syncKey === host.ed.key && !host.ed.demo); }

/** How many others are in the room now. */
export function roomOthers() { return others().length; }

/** What this page has of the room ({ id, seq }), or null: not in one. */
export function roomKnown() { return roomOn() ? { id: sync.roomId, seq: sync.seq } : null; }

/** Nothing of this page's is on its way or still to send. */
export function roomClean() { return roomOn() && sync.clean(); }

/** The scenario changed here: the room gets it soon. */
export function roomEdited() { if (roomOn()) sync.edited(); }

/** Everything of this page's sent: the last batch's number (a save waits for the room to have it). */
export function roomSettle() { return roomOn() ? sync.settle() : Promise.resolve(0); }

/** What is not sent yet, sent now (the screen closing). */
export function roomFlushNow() { if (roomOn()) sync.flush(false); }

/** This page saved the room's scenario: heard as the others hear it (sync.js: once what was saved is in here). */
export function roomSaved(e) {
    if (roomOn()) sync.receive({ kind: 'saved', roomId: sync.roomId, seq: e.seq, rev: e.rev, problems: e.problems, mine: true });
}

/** The room's scenario whole, asked for (a gap that did not fill; batches that may have been passed over). `keepMine`:
 *  this page's own changes not yet in it are put back on it and sent again. */
async function resync(keepMine) {
    if (!roomOn()) return;
    const k = syncKey;
    const r = await host.watch({ id: 0, seq: 0 });
    if (!r || !r.ok || !r.data || !r.data.doc || !r.data.room || syncKey !== k) return;
    const mine = keepMine ? sync.inflight.flatMap((b) => b.ops).concat(sync.unsent()) : [];
    const canon = host.takeDoc(r.data.doc, { dirty: r.data.room.dirty, baseRev: r.data.baseRev, problems: r.data.problems });
    sync.open(r.data.room, canon);
    if (mine.length) {
        host.reapply(mine);
        sync.flush(false);
    }
}

// ============================================================
// Saying where this page is
// ============================================================

/** The field this page is in (a Director field: its data-t and data-k), or ''. */
function fieldNow() {
    let a = document.activeElement;
    // (A list is whip's box over its select: dropdown.js.)
    if (a && a.classList && a.classList.contains('dr-dd') && a.parentNode) a = a.parentNode.querySelector('select') || a;
    if (!a || !a.dataset || !a.dataset.t || !a.dataset.k) return '';
    if (!a.closest('#director, .fz-cfg, .fz-bp')) return '';
    const f = a.dataset.t + '|' + a.dataset.k;
    return REF_OK.test(f) ? f : '';
}

function stateNow() {
    const where = host.where();
    // Into the world builder or back (the blueprint moved under a still pointer, which heard no leaving): off it, until
    // it moves again.
    if (where !== pointerWhere) { pointerWhere = where; pointer = null; }
    const grid = where === 'page' || where === 'builder';
    const at = grid ? pointer : null;
    const thing = host.thingOn();
    const drag = host.dragging() ? host.dragOf() : '';
    return {
        where,
        variant: host.variant(),
        cursor: !!at,
        cx: at ? Math.round(at.x * 10) / 10 : 0,
        cy: at ? Math.round(at.y * 10) / 10 : 0,
        sel: [...host.ed.selected].filter((id) => ID_OK.test(id)).slice(0, MAX_SEL),
        thing: thing && REF_OK.test('thing:' + thing) ? 'thing:' + thing : '',
        field: fieldNow(),
        drag: drag && REF_OK.test(drag) ? drag : '',
    };
}

function flush() {
    timer = 0;
    if (!ours() || !others().length) return;
    const s = stateNow();
    const text = JSON.stringify(s);
    if (text === sentText) return;
    sentText = text;
    lastAt = Date.now();
    nuiCallback('directorPresence', s);
}

/** Something this page says may have changed (the pointer, a pick, the variant, where it is, a field): said when it
 *  has, at most every SEND_MS. */
export function roomSay() {
    if (!host || timer || !ours() || !others().length) return;
    const wait = SEND_MS - (Date.now() - lastAt);
    if (wait > 0) timer = setTimeout(flush, wait);
    else flush();
}

// ============================================================
// The others
// ============================================================

function readState(s) {
    s = s && typeof s === 'object' ? s : {};
    const c = s.cursor && typeof s.cursor === 'object' && Number.isFinite(Number(s.cursor.x)) && Number.isFinite(Number(s.cursor.y))
        ? { x: Number(s.cursor.x), y: Number(s.cursor.y) } : null;
    const ref = (v) => (typeof v === 'string' && REF_OK.test(v) ? v : null);
    return { where: WHERE_TEXT[s.where] ? s.where : 'away', variant: typeof s.variant === 'string' ? s.variant : 'v1', cursor: c,
             sel: listOf(s.sel).filter((id) => typeof id === 'string' && ID_OK.test(id)),
             thing: ref(s.thing), field: ref(s.field), drag: ref(s.drag) };
}

function readMember(m) {
    if (!m || !Number.isInteger(Number(m.src))) return null;
    const rgb = listOf(m.rgb).map(Number);
    return { src: Number(m.src), name: typeof m.name === 'string' && m.name ? m.name : 'Someone', me: m.me === true,
             colour: Number(m.colour) || 0, rgb: rgb.length === 3 && rgb.every(Number.isFinite) ? rgb : [255, 255, 255],
             state: readState(m.state) };
}

/** What client/director_room.lua sends: the room (directorRoom), one member's word (directorPeer), and the scenario's
 *  changes (directorRoomOps, directorRoomAck, directorRoomReset, directorRoomSaved). */
export function roomMessage(d) {
    if (!host) return;
    switch (d.action) {
        case 'directorRoom': {
            const had = others().length;
            members = listOf(d.members).map(readMember).filter(Boolean);
            key = members.length ? d.key : null;
            const me = members.find((m) => m.me);
            if (me && roomOn() && d.key === syncKey) setIdSlot(me.colour);
            if (sync) sync.others = others().length;
            // Someone new: they hear this page as it is now.
            if (others().length > had) sentText = '';
            roomDraw();
            roomSay();
            return;
        }
        case 'directorPeer': {
            const m = d.key === key ? members.find((x) => x.src === Number(d.src)) : null;
            if (!m || m.me) return;
            const was = m.state.where;
            m.state = readState(d.state);
            drawPointer(m);
            drawSheet();
            if (m.state.where !== was) drawWho();
            return;
        }
        case 'directorRoomOps':
        case 'directorRoomAck':
        case 'directorRoomSaved':
            if (!roomOn() || d.key !== syncKey) return;
            sync.receive({ kind: d.action === 'directorRoomOps' ? 'ops' : d.action === 'directorRoomAck' ? 'ack' : 'saved',
                           roomId: d.roomId, seq: Number(d.seq), n: Number(d.n), ops: d.ops, rev: d.rev, by: d.by,
                           problems: d.problems });
            return;
        case 'directorRoomReset':
            if (!roomOn() || d.key !== syncKey) return;
            sync.receive({ kind: 'reset', roomId: d.roomId, seq: Number(d.seq), epoch: Number(d.epoch), doc: d.doc,
                           dirty: d.dirty === true, why: d.why, baseRev: Number(d.baseRev) });
            return;
        default:
    }
}

// ============================================================
// Drawing them
// ============================================================

/** Everything again: the pointers, the picks and fields, who is in. (The variant open changed, the scenario, the room.) */
export function roomDraw() {
    if (!host) return;
    const seen = new Set();
    for (const m of others()) { drawPointer(m); seen.add(String(m.src)); }
    for (const el of [...layer.children]) if (!seen.has(el.dataset.src)) el.remove();
    drawSheet();
    drawWho();
}

/** Does `m`'s pointer show on this page's blueprint? On the same scenario's same variant, and on its blueprint. */
function onOurGrid(m) {
    return ours() && (m.state.where === 'page' || m.state.where === 'builder') && m.state.variant === host.variant();
}

function drawPointer(m) {
    let el = layer.querySelector(`.dr-peer[data-src="${m.src}"]`);
    const c = onOurGrid(m) ? m.state.cursor : null;
    if (!c) { if (el) el.remove(); return; }
    if (!el) {
        el = document.createElement('div');
        el.className = 'dr-peer';
        el.dataset.src = String(m.src);
        el.innerHTML = ARROW + '<span class="dr-peer-name"></span>';
        // (Its first place is taken at once, not glided to from the corner.)
        el.style.left = c.x + 'px';
        el.style.top = c.y + 'px';
        layer.appendChild(el);
    }
    el.style.setProperty('--peer', rgbOf(m));
    const name = el.querySelector('.dr-peer-name');
    if (name.textContent !== m.name) name.textContent = m.name;
    el.style.left = c.x + 'px';
    el.style.top = c.y + 'px';
}

const cssText = (s) => String(s).replace(/[\\"]/g, '\\$&').replace(/[\r\n]+/g, ' ');

/** A card another has picked wears a ring in their colour and their name over it (director.css .dr-field-host .dr-card
 *  reads --peer and --peer-name); two on one card, the first's colour and both names. A field another is typing in
 *  wears a ring in theirs (director.css .dr-peer-field). */
function drawSheet() {
    const byCard = new Map();
    const fields = [];
    for (const m of others()) {
        const sameVariant = ours() && m.state.variant === host.variant();
        if (!sameVariant) continue;
        if (onOurGrid(m) || m.state.where === 'test') {
            for (const id of m.state.sel) {
                if (!byCard.has(id)) byCard.set(id, []);
                byCard.get(id).push(m);
            }
        }
        if (m.state.field) {
            const cut = m.state.field.lastIndexOf('|');
            fields.push({ m, t: m.state.field.slice(0, cut), k: m.state.field.slice(cut + 1) });
        }
    }
    let css = '';
    for (const [id, list] of byCard) {
        const names = cssText(list.map((m) => m.name).join(' · '));
        css += `.dr-field-host .dr-card[data-id="${id}"] { --peer: ${rgbOf(list[0])}; --peer-name: "${names}"; `
            + 'outline: 2px solid var(--peer); outline-offset: 4px; }\n';
    }
    for (const f of fields) {
        if (!REF_OK.test(f.t) || !REF_OK.test(f.k)) continue;
        // (A list's own select is hidden under whip's box: dropdown.js. The box wears it.)
        const at = `:is(#director, .fz-cfg) [data-t="${f.t}"][data-k="${f.k}"]`;
        css += `${at}, ${at} + .dr-dd { --peer: ${rgbOf(f.m)}; outline: 2px solid var(--peer) !important; outline-offset: 2px; }\n`;
    }
    if (sheet.textContent !== css) sheet.textContent = css;
}

function initials(name) {
    const words = String(name).trim().split(/\s+/).filter(Boolean);
    const s = words.length > 1 ? words[0][0] + words[words.length - 1][0] : (words[0] || '?').slice(0, 2);
    return s.toUpperCase();
}

function escapeAttr(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

/** Who is in, as a row of rounds: you first, then each other in their colour (their name and where they are on
 *  hover). Nobody else in: nothing. */
function whoHtml() {
    const list = others();
    if (!ours() || !list.length) return '';
    const you = '<span class="dr-who-one you" title="You">You</span>';
    return you + list.map((m) => `<span class="dr-who-one" style="--peer: ${rgbOf(m)}" title="${escapeAttr(m.name)}: `
        + `${WHERE_TEXT[m.state.where]}">${escapeAttr(initials(m.name))}</span>`).join('');
}

/** The row in the editor's dock (app.js drawDock makes its .dr-who), and over the world builder while it is open. */
export function drawWho() {
    if (!host) return;
    const html = whoHtml();
    for (const el of document.querySelectorAll('#director .dr-who')) {
        if (el.innerHTML !== html) el.innerHTML = html;
        el.hidden = !html;
    }
    // (In the world builder's scaled layer, furnisher.css .fz-scale, so it is the size its buttons are.)
    const fz = document.querySelector('#furnisher .fz-scale') || document.getElementById('furnisher');
    const inWorld = !!html && host.where() === 'builder' && !!fz;
    if (inWorld && !worldWho) {
        worldWho = document.createElement('div');
        worldWho.className = 'dr-who dr-who-world';
        fz.appendChild(worldWho);
    }
    if (worldWho) {
        if (worldWho.innerHTML !== (inWorld ? html : '')) worldWho.innerHTML = inWorld ? html : '';
        worldWho.hidden = !inWorld;
    }
}
