// Generate the text-rendering oracle with the same OpenTUI version as docs/opentui.
// bun add --cwd /tmp/opencode-tui-parity --ignore-scripts @opentui/core@0.4.1
// OPENCODE_TUI_ORACLE_ROOT=/tmp/opencode-tui-parity/node_modules bun tests/reference/markdown-oracle.ts
import { readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
const root = process.env.OPENCODE_TUI_ORACLE_ROOT
if (!root) throw new Error('Set OPENCODE_TUI_ORACLE_ROOT to the directory containing @opentui/core 0.4.1')
const { MarkdownRenderable, CodeRenderable, SyntaxStyle, TreeSitterClient, RGBA } = await import(join(root, '@opentui/core/index.js'))
const { createTestRenderer } = await import(join(root, '@opentui/core/testing.js'))
const pkg = JSON.parse(await readFile(join(root, '@opentui/core/package.json'), 'utf8'))
if (pkg.version !== '0.4.1') throw new Error(`Expected OpenTUI 0.4.1, got ${pkg.version}`)
const client = new TreeSitterClient({ dataPath: '/tmp/opencode-tui-parity/parsers' })
client.on('error', (error: string) => { throw new Error(error) })
await client.initialize()
const definitions = {
  default: { fg: '#eeeeee' }, spell:{fg:'#eeeeee'},nospell:{fg:'#eeeeee'},
  'markup.heading': { fg: '#000001', bold:true },
  ...Object.fromEntries([1,2,3,4,5,6].map(n=>['markup.heading.'+n, {fg:n===1?'#000002':'#000001',bold:true,...(n===1?{underline:true}:{})}])),
  'markup.strong': {fg:'#000003',bold:true}, 'markup.italic':{fg:'#000004',italic:true},
  'markup.strikethrough':{fg:'#000005'}, 'markup.raw':{fg:'#000006'}, 'markup.raw.block':{fg:'#000006'},
  'markup.link':{fg:'#000007',underline:true}, 'markup.link.url':{fg:'#000007',underline:true},
  'markup.link.label':{fg:'#000008',underline:true}, 'markup.quote':{fg:'#000009',italic:true},
  conceal:{fg:'#00000a'}, 'markup.list':{fg:'#00000b'}, 'punctuation.special':{fg:'#00000c'},
  'string.escape':{fg:'#00000d'}, 'character.special':{fg:'#00000e'},
}
const style = SyntaxStyle.fromStyles(Object.fromEntries(Object.entries(definitions).map(([key, value])=>[key,{...value,fg:RGBA.fromHex(value.fg)}])))
const inputPath = new URL('../fixtures/markdown/cases.json', import.meta.url)
const cases = JSON.parse(await readFile(inputPath, 'utf8'))
const result = []
try {
for (const entry of cases) {
  for (const width of entry.widths ?? [77, 25]) {
    const test = await createTestRenderer({ width, height: 500 })
    const md = new MarkdownRenderable(test.renderer, {
      id:'markdown',content:'',syntaxStyle:style,treeSitterClient:client,
      fg:RGBA.fromHex('#eeeeee'),internalBlockMode:'top-level', tableOptions:{style:'grid'}, streaming:true,conceal:true,width:'100%',
    })
    try {
    test.renderer.root.add(md)
    let source = ''
    const updates = entry.updates ?? [entry.source]
    for (let step = 0; step < updates.length; step++) {
    source += updates[step]
    md.content = source.trim()
    for(let iteration=0;iteration<20;iteration++) {
      await test.renderOnce()
      const nodes=[md];const pending=[]
      while(nodes.length) {
        const node=nodes.pop();nodes.push(...node.getChildren())
        if(node instanceof CodeRenderable && node.isHighlighting)pending.push(node.highlightingDone)
      }
      if(!pending.length)break
      await Promise.all(pending)
      if(iteration===19)throw new Error(`Highlighting did not settle: ${entry.name}`)
    }
    await test.renderOnce()
    const text=test.captureCharFrame().split('\n').map(x=>x.trimEnd()).join('\n').trimEnd()
    // getSpanLines consumes code points for a grapheme cell and misaligns ZWJ
    // emoji. Read the renderer's actual cell colors/attributes instead.
    const buffer=test.renderer.currentRenderBuffer.buffers
    const styles=text.split('\n').map((_,row)=>{
      const spans=[]
      for(let col=0;col<width;col++) {
        const index=row*width+col
        const fg=buffer.fg[index*4]*65536+buffer.fg[index*4+1]*256+buffer.fg[index*4+2]
        const attrs=buffer.attributes[index]&255
        const last=spans.at(-1)
        if(last && last[2]===fg && last[3]===attrs)last[1]=col+1
        else spans.push([col,col+1,fg,attrs])
      }
      return spans
    })
    result.push({name:entry.name+(entry.updates ? ` step ${step+1}` : ''),source,width,lines:text.split('\n'),styles})
    }
    } finally { test.renderer.destroy() }
  }
}
} finally { await client.destroy() }
await writeFile(new URL('../fixtures/markdown/tui.json',import.meta.url), JSON.stringify({version:pkg.version,cases:result},null,2)+'\n')
console.log(`Generated ${result.length} OpenTUI comparisons`)
