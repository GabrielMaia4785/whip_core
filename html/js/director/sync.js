// ========================================
// DIRECTOR — keeping a scenario the same on every page in its room (server/director/room.lua)
//
// The room holds the scenario; each page has a copy and edits it as if alone. What a page changes goes up as OPS
// (doc.js diffDoc: a path and what is there now), worked out by comparing its copy with `base`, the copy as last sent
// or heard: at most every SEND_MS while edits come (typing, dragging), and at once before a save. The room numbers each
// batch it takes (seq) and sends it to the others; the sender hears its batch's number (an ack).
//
// EVERY PAGE PUTS THEM ON IN THE ROOM'S ORDER: what comes is held until the one before it has come, then put on.
// Another's op on a place this page has changed itself and not yet heard back (its batch is on its way, or not sent
// yet) is passed over: the room takes this page's after it, so this page's is the one everyone ends with. An op on a
// place that holds one of this page's own (a card replaced whole, while a field of it was changed here) is put on, and
// this page's own put back on top, as the room will have it.
//
// Nothing is put on while a card is being dragged (its page holds the cards it moves): held, and put on once it is let
// go. A gap that does not fill in RESYNC_MS (something lost on the way) asks for the room's scenario whole (resync).
//
// The page (app.js, through room.js) gives `io`:
//   packed()        its copy as kept (every variant: doc.js packDoc); changed in place by what is put on
//   setCanon(c)     after ops were put on `c` (packed()'s, or a new one): the page's view of it again
//   history()       its undo (doc.js History): others' ops go into it as theirs (remote)
//   send(batch)     a batch up: { roomId, epoch, n, quiet, ops: [{ p, v: text } | { p, d: 1 }] }
//   dragging()      a drag under way on the grid
//   applied(ops)    others' ops are on: draw again
//   saved(e)        the room's scenario was saved: { rev, by, problems, mine }
//   reset(e)        the room's scenario, whole, to start from: { doc, dirty, why }
//   resync()        ask the room for its scenario whole
// ========================================

import { diffDoc, applyOps, pathWithin } from './doc.js';

const SEND_MS = 100;
const SEND_ALONE_MS = 300;   // nobody else in the room: the room still keeps it, less often
const RESYNC_MS = 5000;
const BIG = 6000;            // a batch this big goes as a latent event: the next waits for its ack (client/director_room.lua)

const copyOf = (v) => JSON.parse(JSON.stringify(v));

/** Ops off the wire: each value's text read back. */
export function readWire(list) {
    const out = [];
    for (const o of Array.isArray(list) ? list : Object.values(list || {})) {
        if (!o || typeof o !== 'object') continue;
        const p = Array.isArray(o.p) ? o.p : Object.values(o.p || {});
        if (!p.every((s) => typeof s === 'string')) continue;
        if (o.d) { out.push({ p, d: 1 }); continue; }
        if (typeof o.v !== 'string') continue;
        try { out.push({ p, v: JSON.parse(o.v) }); } catch (_) { /* (not JSON: passed over) */ }
    }
    return out;
}

/** Ops onto the wire: each value as its JSON text, so nothing is lost on the way through Lua. */
export function toWire(ops) {
    return ops.map((o) => (o.d ? { p: o.p, d: 1 } : { p: o.p, v: JSON.stringify(o.v === undefined ? null : o.v) }));
}

export class RoomSync {
    constructor(io) {
        this.io = io;
        this.on = false;
        this.others = 0;
    }

    /** Start on the room's scenario: `info` { id, seq, epoch }, `canon` its document as it came (normalised, before
     *  anything this page adds as it opens: the first batch, `quiet`, sends that). */
    open(info, canon) {
        clearTimeout(this.timer);
        clearTimeout(this.gapTimer);
        this.on = true;
        this.roomId = info.id;
        this.epoch = info.epoch || 1;
        this.seq = info.seq || 0;
        this.base = copyOf(canon);
        this.n = 0;
        this.inflight = [];     // [{ n, ops }] sent, not yet heard back
        this.latent = 0;        // a big batch on its way: the next waits for it
        this.waiting = false;   // a send held for it
        this.queue = new Map(); // seq -> what came early
        this.saves = [];        // saves heard, waiting for their seq
        this.timer = 0;
        this.gapTimer = 0;
        this.lastSend = 0;
        // What this page added as it opened (a start card, lore characters' peds): sent at once, not an edit.
        this.flush(true);
    }

    close() {
        clearTimeout(this.timer);
        clearTimeout(this.gapTimer);
        this.on = false;
        this.queue = new Map();
        this.inflight = [];
    }

    /** What this page has not sent yet. */
    unsent() { return this.on ? diffDoc(this.base, copyOf(this.io.packed())) : []; }

    /** Nothing of this page's is on its way or still to send. */
    clean() { return this.on && !this.inflight.length && !this.latent && !this.unsent().length; }

    /** The copy changed: sent soon (at most every SEND_MS). */
    edited() {
        if (!this.on || this.timer) return;
        const every = this.others ? SEND_MS : SEND_ALONE_MS;
        const wait = Math.max(0, every - (Date.now() - this.lastSend));
        this.timer = setTimeout(() => { this.timer = 0; this.flush(false); }, wait);
    }

    /** What changed since the last, sent now (`quiet`: not an edit). Answers the last batch's number. */
    flush(quiet) {
        if (!this.on) return 0;
        clearTimeout(this.timer);
        this.timer = 0;
        if (this.latent) { this.waiting = true; return this.n; }
        const now = copyOf(this.io.packed());
        const ops = diffDoc(this.base, now);
        if (!ops.length) return this.n;
        this.base = now;
        const n = ++this.n;
        const wire = toWire(ops);
        this.inflight.push({ n, ops });
        if (wire.reduce((s, o) => s + (o.v ? o.v.length : 0) + 64, 0) > BIG) this.latent = n;
        this.lastSend = Date.now();
        this.io.send({ roomId: this.roomId, epoch: this.epoch, n, quiet: quiet === true, ops: wire });
        return n;
    }

    /** Everything of this page's sent (a big batch on its way first heard back): the last batch's number. */
    settle() {
        return new Promise((resolve) => {
            const go = () => {
                if (!this.on) { resolve(0); return; }
                if (this.latent) { setTimeout(go, 100); return; }
                resolve(this.flush(false));
            };
            go();
        });
    }

    /** What the room sent: 'ops' (another's), 'ack' (this page's numbered), 'saved', 'reset'. */
    receive(m) {
        if (!this.on || !m) return;
        if (m.kind === 'reset') { this.takeReset(m); return; }
        if (m.roomId !== this.roomId) return;
        if (m.kind === 'saved') { this.saves.push(m); this.drain(); return; }
        if (!(m.seq > this.seq)) return;   // (in the scenario this page started from)
        this.queue.set(m.seq, m);
        this.drain();
    }

    drain() {
        if (!this.on) return;
        if (this.io.dragging()) { setTimeout(() => this.drain(), 150); return; }
        const took = [];
        while (this.queue.has(this.seq + 1)) {
            const m = this.queue.get(this.seq + 1);
            this.queue.delete(this.seq + 1);
            this.seq += 1;
            // (An ack brings the order of any list its batch added to, as the room has it: room.lua ordersAfter.)
            if (m.kind === 'ack') { this.acked(m.n); took.push(...this.put(readWire(m.ops))); }
            else took.push(...this.put(readWire(m.ops)));
        }
        if (took.length) this.io.applied(took);
        // Saves, once what was saved is in.
        const now = this.saves.filter((s) => s.seq <= this.seq);
        this.saves = this.saves.filter((s) => s.seq > this.seq);
        for (const s of now) this.io.saved({ rev: s.rev, by: s.by, problems: s.problems, mine: s.mine === true, clean: this.clean() });
        // A gap: asked for whole if it does not fill.
        clearTimeout(this.gapTimer);
        this.gapTimer = 0;
        if (this.queue.size) {
            this.gapTimer = setTimeout(() => {
                this.gapTimer = 0;
                if (this.on && this.queue.size) this.io.resync();
            }, RESYNC_MS);
        }
    }

    acked(n) {
        this.inflight = this.inflight.filter((b) => b.n > n);
        if (this.latent && this.latent <= n) {
            this.latent = 0;
            if (this.waiting) { this.waiting = false; this.flush(false); }
        }
    }

    /** Another's ops onto this page's copy (see the top). Answers those put on. */
    put(ops) {
        if (!ops.length) return [];
        const sent = this.inflight.flatMap((b) => b.ops);
        const unsent = this.unsent();
        const mine = sent.concat(unsent);
        const take = ops.filter((op) => !mine.some((m) => pathWithin(op.p, m.p)));
        if (!take.length) return [];
        const under = (m) => take.some((op) => m.p.length > op.p.length && pathWithin(m.p, op.p));
        const back = mine.filter(under);
        const r = applyOps(this.io.packed(), take.concat(back));
        this.io.setCanon(r.doc);
        // (What is sent is in base; what is not yet sent stays out of it, to be sent.)
        this.base = applyOps(this.base, take.concat(sent.filter(under))).doc;
        this.io.history().remote(take.concat(back));
        return take;
    }

    /** The room's scenario whole (a batch of this page's refused, a draft saved elsewhere, a resync). */
    takeReset(m) {
        this.roomId = m.roomId;
        this.epoch = m.epoch || this.epoch;
        this.seq = m.seq || 0;
        this.inflight = [];
        this.latent = 0;
        this.waiting = false;
        this.queue = new Map();
        this.saves = [];
        clearTimeout(this.timer);
        this.timer = 0;
        const canon = this.io.reset({ doc: m.doc, dirty: m.dirty === true, why: m.why || null, baseRev: m.baseRev });
        if (canon) this.base = copyOf(canon);
        this.flush(true);
    }
}
