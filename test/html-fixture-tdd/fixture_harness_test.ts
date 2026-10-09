// Structural HTML comparison tests for the Odin templates.
//
// The Odin harness (test/html-fixture-tdd/fixture_harness.odin) renders each case
// and prints it in a delimited block. This test compares the harness output to the expected
// fixtures structurally with Cheerio: attribute sets, attribute values, tag
// names, and text content — whitespace-insensitive where the DOM allows it.
//
// The expected fixtures are treated as read-only baselines: this test never
// feeds them back into the implementation.

import { assert, assertEquals } from 'jsr:@std/assert@1';
import * as cheerio from 'npm:cheerio@1.0.0';

const ROOT = new URL('../..', import.meta.url).pathname;
const HARNESS = 'test/html-fixture-tdd/fixture_harness.odin';
const FIXTURES = `${ROOT}test/html-fixture-tdd/fixture`;

async function runHarness(): Promise<Map<string, string>> {
    const cmd = new Deno.Command('odin', {
        args: ['run', HARNESS, '-file', '-out:/tmp/odin-fixture-harness', FIXTURES],
        cwd: ROOT,
        stdout: 'piped',
        stderr: 'piped',
    });
    const { code, stdout, stderr } = await cmd.output();
    if (code !== 0) {
        throw new Error(`odin harness failed:\n${new TextDecoder().decode(stderr)}`);
    }
    const text = new TextDecoder().decode(stdout);
    const cases = new Map<string, string>();
    const re = /<<<CASE (.+?)>>>\n([\s\S]*?)\n<<<END>>>/g;
    for (const m of text.matchAll(re)) cases.set(m[1], m[2]);
    return cases;
}

function loadExpected(name: string): string {
    return Deno.readTextFileSync(`${FIXTURES}/${name}`);
}

// Normalize an element into a comparable structural shape.
function walk(el: any): unknown {
    const tag = (el[0]?.tagName ?? el.prop('tagName') ?? '').toLowerCase();
    const attrs: Record<string, string> = {};
    for (const [k, v] of Object.entries(el.attr() ?? {})) attrs[k] = String(v);

    const children: unknown[] = [];
    el.contents().each((_: any, c: any) => {
        if (c.type === 'text') {
            const t = (c.data as string).replace(/\s+/g, ' ').trim();
            if (t) children.push({ text: t });
        } else if (c.type === 'tag' || c.type === 'script' || c.type === 'style') {
            children.push(walk(cheerio.load('' as any)(c)));
        }
    });
    return { tag, attrs, children };
}

function compare(caseName: string, actualHtml: string, expectedHtml: string) {
    // For full documents compare the <html> root; for fragments wrap in a container.
    const isDoc = actualHtml.trimStart().toLowerCase().startsWith('<!doctype');
    const wrap = (s: string) => isDoc ? s : `<div id="__root__">${s}</div>`;
    const sel = isDoc ? 'html' : '#__root__';
    const actual = cheerio.load(wrap(actualHtml), null, isDoc);
    const expected = cheerio.load(wrap(expectedHtml), null, isDoc);
    const a = walk(actual(sel).first());
    const e = walk(expected(sel).first());
    assertEquals(a, e, `structural mismatch for case '${caseName}'`);
}

const CASES: { name: string; fixture: string }[] = [
    { name: 'toast', fixture: 'toast.expected.html' },
    { name: 'item_card', fixture: 'item_card.expected.html' },
    { name: 'photo_grid', fixture: 'photo_grid.expected.html' },
    { name: 'inspector', fixture: 'inspector.expected.html' },
    { name: 'gallery_content', fixture: 'gallery_content.expected.html' },
    { name: 'gallery_page', fixture: 'gallery_page.expected.html' },
];

const harness = await runHarness();

for (const { name, fixture } of CASES) {
    Deno.test(`template: ${name}`, () => {
        const actual = harness.get(name);
        assert(actual !== undefined, `harness did not emit case '${name}'`);
        compare(name, actual!, loadExpected(fixture));
    });
}
