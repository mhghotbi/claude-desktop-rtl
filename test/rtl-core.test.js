'use strict';

const test = require('node:test');
const assert = require('node:assert');
const core = require('../src/rtl-core.js');

const cp = (s) => s.codePointAt(0);

test('isRTL covers expanded ranges', () => {
    assert.ok(core.isRTL(cp('ف')), 'Persian/Arabic');
    assert.ok(core.isRTL(cp('ا')), 'Arabic');
    assert.ok(core.isRTL(cp('ܐ')), 'Syriac');
    assert.ok(core.isRTL(cp('ހ')), 'Thaana');
    assert.ok(core.isRTL(cp('ߒ')), 'NKo');
    assert.ok(core.isRTL(cp('𞤀')), 'Adlam (astral)');
    assert.ok(!core.isRTL(cp('A')), 'Latin');
    assert.ok(!core.isRTL(cp('5')), 'digit');
    assert.ok(!core.isRTL(cp('$')), 'dollar');
});

test('isRTL: Persian numerals (U+06F0–U+06F9) are inside Arabic block → rtl', () => {
    assert.ok(core.isRTL(cp('۱')), 'Persian one');
    assert.ok(core.isRTL(cp('۹')), 'Persian nine');
});

test('hasRTL walks code points (astral safe)', () => {
    assert.ok(core.hasRTL('hello سلام'));
    assert.ok(core.hasRTL('text 𞤀𞤣'));       // Adlam only
    assert.ok(!core.hasRTL('plain ascii 123'));
    assert.ok(!core.hasRTL('price $5.99'));
});

test('hasRTL: ZWNJ (U+200C / نیم‌فاصله) alone is not RTL', () => {
    assert.ok(!core.hasRTL('‌'), 'bare ZWNJ is neutral');
    assert.ok(core.hasRTL('می‌توانم'), 'Persian word with ZWNJ is still RTL');
});

test('firstStrong picks first strong character', () => {
    assert.strictEqual(core.firstStrong('سلام world'), 'rtl');
    assert.strictEqual(core.firstStrong('world سلام'), 'ltr');
    assert.strictEqual(core.firstStrong('123 — سلام'), 'rtl');
    assert.strictEqual(core.firstStrong('123 456'), null);
});

test('firstStrong: RLM (U+200F) is strong-RTL', () => {
    assert.strictEqual(core.firstStrong('‏سلام'), 'rtl', 'RLM before Persian text');
    assert.strictEqual(core.firstStrong('‏hello'), 'rtl', 'RLM before Latin text');
});

test('firstStrong: LRM (U+200E) is strong-LTR', () => {
    assert.strictEqual(core.firstStrong('‎سلام'), 'ltr', 'LRM overrides following RTL');
});

test('firstStrong: ZWNJ (U+200C) is neutral, does not affect direction', () => {
    assert.strictEqual(core.firstStrong('‌سلام'), 'rtl', 'ZWNJ before Persian → RTL from first Persian char');
    assert.strictEqual(core.firstStrong('‌hello'), 'ltr', 'ZWNJ before Latin → LTR from first Latin char');
});

test('currency $ is NOT treated as LaTeX', () => {
    assert.deepStrictEqual(core.findLatexRanges('قیمت $5.99 است'), []);
    assert.deepStrictEqual(core.findLatexRanges('بین $5 و $10'), []);
    assert.deepStrictEqual(core.findLatexRanges('costs $20 and $30'), []);
});

test('real LaTeX is detected', () => {
    assert.strictEqual(core.findLatexRanges('این $x^2$ است').length, 1);
    assert.strictEqual(core.findLatexRanges('فرمول $$\\frac{a}{b}$$ اینجا').length, 1);
    assert.strictEqual(core.findLatexRanges('inline \\(a+b\\) here').length, 1);
    assert.strictEqual(core.findLatexRanges('block \\[E=mc^2\\] done').length, 1);
});

test('$$ wins over inner single $', () => {
    const ranges = core.findLatexRanges('a $$x = 5$$ b');
    assert.strictEqual(ranges.length, 1);
    assert.strictEqual('a $$x = 5$$ b'.slice(ranges[0][0], ranges[0][1]), '$$x = 5$$');
});

test('segmentText splits text and math', () => {
    const segs = core.segmentText('فارسی $x^2$ ادامه');
    assert.strictEqual(segs.length, 3);
    assert.strictEqual(segs[0].type, 'text');
    assert.strictEqual(segs[1].type, 'math');
    assert.strictEqual(segs[1].value, '$x^2$');
    assert.strictEqual(segs[2].type, 'text');
});

test('segmentText with no math returns single text segment', () => {
    const segs = core.segmentText('متن ساده با $5 قیمت');
    assert.strictEqual(segs.length, 1);
    assert.strictEqual(segs[0].type, 'text');
});

test('cellDir: contains-RTL beats first-strong (header starting with Latin term)', () => {
    assert.strictEqual(core.cellDir('blob فایل‌محلی (HEAD c16c988)'), 'rtl'); // Latin-first but Persian column
    assert.strictEqual(core.cellDir('blob فارسی-CDN'), 'rtl');
    assert.strictEqual(core.cellDir('فایل'), 'rtl');
    assert.strictEqual(core.cellDir('patch.ps1'), 'ltr');
    assert.strictEqual(core.cellDir('9f954eb'), 'ltr');  // hex still has Latin letters (f,e,b)
    assert.strictEqual(core.cellDir('123.45'), null);    // truly neutral: no letters, no sway
});

test('tableDirFromCells: header majority RTL → rtl', () => {
    // فارسی | English | نوشته
    const headers = [core.firstStrong('فارسی'), core.firstStrong('English'), core.firstStrong('نوشته')];
    assert.strictEqual(core.tableDirFromCells(headers, []), 'rtl');
});

test('table with Latin-first Persian headers flips (regression: CDN comparison table)', () => {
    // Real case: headers contain Persian but two start with "blob".
    const headers = ['فایل', 'blob فایل‌محلی (HEAD c16c988)', 'blob فارسی-CDN', 'نتیجه'].map(core.cellDir);
    const firstCol = ['patch.ps1', 'patch.ps1.sig'].map(core.cellDir); // Latin first column
    assert.deepStrictEqual(headers, ['rtl', 'rtl', 'rtl', 'rtl']);
    assert.strictEqual(core.tableDirFromCells(headers, firstCol), 'rtl');
});

test('mostly-English table does NOT flip even with one Persian header', () => {
    const headers = ['Name', 'Value', 'نام'].map(core.cellDir);
    assert.strictEqual(core.tableDirFromCells(headers, []), null);
});

test('tableDirFromCells: header majority LTR → null (no flip)', () => {
    const headers = [core.firstStrong('Name'), core.firstStrong('Value'), core.firstStrong('نام')];
    assert.strictEqual(core.tableDirFromCells(headers, []), null);
});

test('tableDirFromCells: first column tie-breaks when headers are inconclusive', () => {
    const headers = [null, null];
    const firstCol = [core.firstStrong('سلام'), core.firstStrong('ممنون'), core.firstStrong('خانه')];
    assert.strictEqual(core.tableDirFromCells(headers, firstCol), 'rtl');
});

test('stripLeadingLTR drops leading filename then detects RTL', () => {
    const stripped = core.stripLeadingLTR('foo.js سلام دنیا');
    assert.strictEqual(core.firstStrong(stripped), 'rtl');
});
