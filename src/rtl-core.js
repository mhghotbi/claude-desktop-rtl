// rtl-core.js -- pure, DOM-free RTL/LaTeX detection logic.
//
// SOURCE OF TRUTH for the detection engine. tools/build-payload.ps1 inlines the
// function bodies of this file into the injected IIFE inside patch.ps1 (it strips
// the module.exports guard at the bottom). test/rtl-core.test.js requires this
// file directly. Keep this file DOM-free so it stays unit-testable.
'use strict';

// Strong-RTL code-point ranges, [lo, hi] inclusive. Covers the modern living
// RTL scripts plus the common historic/astral ones. Tested against code points
// (codePointAt), NOT UTF-16 code units, so astral blocks like Adlam work.
var RTL_RANGES = [
    [0x0600, 0x06FF], // Arabic
    [0x0700, 0x074F], // Syriac
    [0x0750, 0x077F], // Arabic Supplement
    [0x0780, 0x07BF], // Thaana
    [0x07C0, 0x07FF], // NKo
    [0x0800, 0x083F], // Samaritan
    [0x0840, 0x085F], // Mandaic
    [0x0860, 0x086F], // Syriac Supplement
    [0x0870, 0x089F], // Arabic Extended-B
    [0x08A0, 0x08FF], // Arabic Extended-A
    [0xFB50, 0xFDFF], // Arabic presentation forms-A
    [0xFE70, 0xFEFF], // Arabic presentation forms-B
    [0x10800, 0x1083F], // Cypriot Syllabary block (incl. early RTL scripts)
    [0x10840, 0x1085F], // Imperial Aramaic
    [0x10A00, 0x10A5F], // Kharoshthi
    [0x10E60, 0x10E7F], // Rumi Numeral Symbols
    [0x1E800, 0x1E8DF], // Mende Kikakui
    [0x1E900, 0x1E95F], // Adlam
    [0x1EE00, 0x1EEFF]  // Arabic Mathematical Alphabetic Symbols
];

// cp: a Unicode code point (from String.prototype.codePointAt).
function isRTL(cp) {
    for (var i = 0; i < RTL_RANGES.length; i++) {
        if (cp >= RTL_RANGES[i][0] && cp <= RTL_RANGES[i][1]) return true;
    }
    return false;
}

function hasRTL(text) {
    if (!text) return false;
    for (var i = 0; i < text.length;) {
        var cp = text.codePointAt(i);
        if (isRTL(cp)) return true;
        i += cp > 0xFFFF ? 2 : 1;
    }
    return false;
}

// Direction of the first strong character: 'rtl', 'ltr', or null (no strong char).
function firstStrong(text) {
    if (!text) return null;
    for (var i = 0; i < text.length;) {
        var cp = text.codePointAt(i);
        if (cp === 0x200F) return 'rtl'; // RIGHT-TO-LEFT MARK (RLM / نشانه راست‌به‌چپ)
        if (cp === 0x200E) return 'ltr'; // LEFT-TO-RIGHT MARK
        if (isRTL(cp)) return 'rtl';
        // ASCII Latin letters are strong-LTR (matches the original /[a-zA-Z]/ rule).
        if ((cp >= 0x41 && cp <= 0x5A) || (cp >= 0x61 && cp <= 0x7A)) return 'ltr';
        i += cp > 0xFFFF ? 2 : 1;
    }
    return null;
}

// Remove leading LTR-only noise (filenames, URLs, paths, backtick-code) so a
// Persian/RTL sentence that starts with "foo.js" still detects as RTL.
function stripLeadingLTR(text) {
    return text
        .replace(/^[\s]*(?:[\w.\-]+\.[\w]{1,5})\s*/g, '')
        .replace(/https?:\/\/\S+/g, '')
        .replace(/[\w.\-]+[\/\\][\w.\-\/\\]+/g, '')
        .replace(/`[^`]+`/g, '');
}

// A "$...$" body is treated as math only when it carries a real LaTeX signal.
// This is the currency guard: "$5.99" or "$5 to $10" lack the signal and stay text.
var LATEX_SIGNAL = /[\\^_{}]|\b(?:frac|sqrt|sum|prod|int|lim|infty|cdot|times|div|leq|geq|neq|approx|partial|nabla|alpha|beta|gamma|delta|theta|lambda|mu|pi|sigma|omega|matrix|begin|end|left|right|text|mathbb|mathcal|vec|hat|bar|overline|underline)\b/;

function hasLatexSignal(body) {
    return LATEX_SIGNAL.test(body);
}

// Find math regions as [start, end) index pairs over `text`.
// Unambiguous delimiters ($$...$$, \[...\], \(...\)) always count; single $...$
// only counts with a LaTeX signal and only outside already-claimed regions.
function findLatexRanges(text) {
    var ranges = [];
    if (!text) return ranges;

    function claim(re, requireSignal, bodyStart, bodyEnd) {
        var m;
        re.lastIndex = 0;
        while ((m = re.exec(text)) !== null) {
            var start = m.index;
            var end = m.index + m[0].length;
            if (overlaps(start, end)) continue;
            if (requireSignal) {
                var body = m[0].slice(bodyStart, m[0].length - bodyEnd);
                if (!hasLatexSignal(body)) continue;
            }
            ranges.push([start, end]);
        }
    }
    function overlaps(s, e) {
        for (var i = 0; i < ranges.length; i++) {
            if (s < ranges[i][1] && e > ranges[i][0]) return true;
        }
        return false;
    }

    // Order matters: claim the unambiguous, greedier delimiters first.
    claim(/\$\$[\s\S]+?\$\$/g, false, 0, 0);
    claim(/\\\[[\s\S]+?\\\]/g, false, 0, 0);
    claim(/\\\([\s\S]+?\\\)/g, false, 0, 0);
    // Single $...$ -- no newline inside, must carry a LaTeX signal (currency guard).
    claim(/\$[^$\n]+?\$/g, true, 1, 1);

    ranges.sort(function (a, b) { return a[0] - b[0]; });
    return ranges;
}

// Split text into alternating {type:'text'|'math', value} segments.
function segmentText(text) {
    var segs = [];
    if (!text) return segs;
    var ranges = findLatexRanges(text);
    if (!ranges.length) {
        segs.push({ type: 'text', value: text });
        return segs;
    }
    var pos = 0;
    for (var i = 0; i < ranges.length; i++) {
        if (ranges[i][0] > pos) {
            segs.push({ type: 'text', value: text.slice(pos, ranges[i][0]) });
        }
        segs.push({ type: 'math', value: text.slice(ranges[i][0], ranges[i][1]) });
        pos = ranges[i][1];
    }
    if (pos < text.length) segs.push({ type: 'text', value: text.slice(pos) });
    return segs;
}

// Classify a table cell's direction from its text. A cell counts as RTL if it
// *contains* any RTL character -- not merely if its first strong char is RTL.
// Header labels often start with a Latin term ("blob ...", "ID ...") yet belong
// to an RTL column, so first-strong is too weak here. Neutral cells (digits,
// hashes, punctuation only) return null so they do not sway the majority.
function cellDir(text) {
    if (hasRTL(text)) return 'rtl';
    if (firstStrong(text) === 'ltr') return 'ltr';
    return null;
}

// Decide a whole table's column direction from header / first-column cell dirs.
// Each input is an array of 'rtl' | 'ltr' | null. Header wins; first column is
// the tie-breaker. Returns 'rtl' (flip columns) or null (leave LTR).
function tableDirFromCells(headerDirs, firstColDirs) {
    // First header is the semantic key column (row labels). If it's RTL and the
    // first data cell agrees, the table is a Persian/RTL table regardless of how many
    // product/entity names appear as LTR in subsequent headers.
    if (headerDirs && headerDirs[0] === 'rtl' &&
            firstColDirs && firstColDirs[0] === 'rtl') return 'rtl';
    var h = majorityDir(headerDirs || []);
    if (h === 'rtl') return 'rtl';
    if (h === 'ltr') return null;
    var c = majorityDir(firstColDirs || []);
    return c === 'rtl' ? 'rtl' : null;
}

function majorityDir(dirs) {
    var r = 0, l = 0;
    for (var i = 0; i < dirs.length; i++) {
        if (dirs[i] === 'rtl') r++;
        else if (dirs[i] === 'ltr') l++;
    }
    if (r > l) return 'rtl';
    if (l > r) return 'ltr';
    return null;
}

if (typeof module !== 'undefined' && module.exports) {
    module.exports = {
        RTL_RANGES: RTL_RANGES,
        isRTL: isRTL,
        hasRTL: hasRTL,
        firstStrong: firstStrong,
        stripLeadingLTR: stripLeadingLTR,
        LATEX_SIGNAL: LATEX_SIGNAL,
        hasLatexSignal: hasLatexSignal,
        findLatexRanges: findLatexRanges,
        segmentText: segmentText,
        cellDir: cellDir,
        tableDirFromCells: tableDirFromCells,
        majorityDir: majorityDir
    };
}
