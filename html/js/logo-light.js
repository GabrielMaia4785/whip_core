// ========================================
// LOGO LIGHT — whip's logo with its loading light, for any page that shows it
//
// The light is the loading screen's (whip_loadingscreen/html/js/logo.js): the I's four circles
// light one at a time, top to bottom, each at once and with a random interaction icon on it, and
// fade as the light moves on. The W's and the P's circles are always lit, with fixed icons. The
// icons come from js/glyphs.js: the actions only, as in the loading screen's copy (NOT_LIT).
//
// Shared by the landing page (landing.js, which has the logo in index.html), the pause menu
// (pause.js, which builds it with logoMarkup) and the logo over a load's black (curtain.js) — one
// copy of the light, not three that drift.
// Styled by the page that shows it: .ld-letters, .ld-ring, .ld-disc, .ld-hole, .ld-icon, and
// .ld-dot.lit for the lit circle (landing.css has the look).
// ========================================

/** How long each circle stays lit before the next takes over — the loading screen's pace. */
const STEP_MS = 450;

/** How wide an icon is against its disc: the 3D badge's share. The car slices fill the disc. */
const ICON_SHARE = 0.46 / 0.78;

const shared = window.WhipGlyphs || { glyphs: {}, fullBleed: {} };

/** The marks that are not actions: a menu arrow (`back`), an objective card's (a tick or a cross lit
 *  over a load would read as a verdict on it), the notifications', an announcement's, and the dev tools' own. */
const NOT_LIT = new Set(['back', 'objective', 'target', 'pin', 'star', 'timer',
    'fail', 'success', 'info', 'warning', 'object', 'ped', 'camera', 'announce']);
const names = Object.keys(shared.glyphs).filter((n) => !NOT_LIT.has(n));

/** The logo's markup — the landing page's trace of the whip logo — with clip ids under `prefix`, so two
 *  copies on one page do not share them. */
export function logoMarkup(prefix) {
    const circle = (cx, cy) => '<circle cx="' + cx + '" cy="' + cy + '" r="20.5"/>';
    const light = (cx, cy, clip) => '<g class="ld-light"><circle class="ld-ring" cx="' + cx + '" cy="' + cy + '" r="26.5"/>'
        + '<circle class="ld-disc" cx="' + cx + '" cy="' + cy + '" r="20.5"/>'
        + '<g class="ld-icon" clip-path="url(#' + prefix + '-' + clip + ')"></g></g>';
    const dot = (cy, i) => '<g class="ld-dot"><circle class="ld-hole" cx="710" cy="' + cy + '" r="20"/>' + light(710, cy, i) + '</g>';
    return '<svg viewBox="58 46 997 235" xmlns="http://www.w3.org/2000/svg"><defs>'
        + '<clipPath id="' + prefix + '-w">' + circle(95, 83) + '</clipPath>'
        + '<clipPath id="' + prefix + '-p">' + circle(897, 190) + '</clipPath>'
        + [83, 136.67, 190.33, 244].map((cy, i) => '<clipPath id="' + prefix + '-' + i + '">' + circle(710, cy) + '</clipPath>').join('')
        + '</defs><g class="ld-letters">'
        + '<path d="M62 83 A33 33 0 0 1 128 83 L128 211 L169 211 L169 50 L235 50 L235 211 L276 211 L276 50 L342 50 L342 277 L117 277 A55 55 0 0 1 62 222 Z"/>'
        + '<path d="M369 50 H435 V157 H583 V50 H649 V277 H583 V223 H435 V277 H369 Z"/>'
        + '<rect x="677" y="50" width="66" height="227" rx="33"/>'
        + '<path d="M771 50 H1001 A50 50 0 0 1 1051 100 V173 A50 50 0 0 1 1001 223 H897 A33 33 0 0 1 897 157 H985 V116 H837 V277 H771 Z"/>'
        + '</g>'
        + light(95, 83, 'w').replace('<g class="ld-light">', '<g class="ld-light" data-icon="pickup">')
        + light(897, 190, 'p').replace('<g class="ld-light">', '<g class="ld-light" data-icon="store">')
        + [83, 136.67, 190.33, 244].map(dot).join('')
        + '</svg>';
}

/** The light on a logo inside `root`: { start, stop }. Paints the fixed W and P icons at once. */
export function logoLight(root) {
    const dots = root ? Array.from(root.querySelectorAll('.ld-dot')) : [];
    let bag = [], last = null, timer = null, at = -1;

    function shuffle(list) {
        for (let i = list.length - 1; i > 0; i--) {
            const j = Math.floor(Math.random() * (i + 1));
            const t = list[i]; list[i] = list[j]; list[j] = t;
        }
        return list;
    }

    /** A random icon: shuffled in rounds, never the same one twice running. */
    function nextIcon() {
        if (!names.length) return null;
        if (!bag.length) {
            bag = shuffle(names.slice());
            // The round is dealt from the end: do not start it with the one just shown.
            if (bag.length > 1 && bag[bag.length - 1] === last) {
                const t = bag[0]; bag[0] = bag[bag.length - 1]; bag[bag.length - 1] = t;
            }
        }
        last = bag.pop();
        return last;
    }

    /** Put an icon on a circle's disc, sized in the logo's own coordinates. */
    function paint(group, name) {
        const slot = group.querySelector('.ld-icon');
        const disc = group.querySelector('.ld-disc');
        if (!slot || !disc) return;
        if (!name || !shared.glyphs[name]) { slot.innerHTML = ''; return; }
        const cx = +disc.getAttribute('cx'), cy = +disc.getAttribute('cy'), r = +disc.getAttribute('r');
        const size = shared.fullBleed[name] ? r * 2 : r * 2 * ICON_SHARE;
        slot.innerHTML = shared.glyphs[name];
        const svg = slot.firstElementChild;
        if (!svg) return;
        svg.setAttribute('x', cx - size / 2);
        svg.setAttribute('y', cy - size / 2);
        svg.setAttribute('width', size);
        svg.setAttribute('height', size);
    }

    if (root) root.querySelectorAll('[data-icon]').forEach((g) => paint(g, g.getAttribute('data-icon')));

    function step() {
        if (at >= 0) dots[at].classList.remove('lit');   // fades (the page's CSS), its icon with it
        at = (at + 1) % dots.length;
        paint(dots[at], nextIcon());
        dots[at].classList.add('lit');                   // lights at once
    }

    return {
        start() {
            if (timer || !dots.length) return;
            at = -1;
            step();
            timer = setInterval(step, STEP_MS);
        },
        stop() {
            if (timer) clearInterval(timer);
            timer = null;
            dots.forEach((d) => d.classList.remove('lit'));
            at = -1;
        },
    };
}
