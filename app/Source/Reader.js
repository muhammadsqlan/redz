(() => {
  'use strict';
  document.documentElement.dataset.readerTheme = window.readAlongTheme || (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
  const send = (type, value = {}) => window.webkit.messageHandlers.reader.postMessage({type, ...value});
  const htmlNS = 'http://www.w3.org/1999/xhtml';
  const el = name => document.createElementNS(htmlNS, name);
  const style = el('style');
  style.textContent = `
    :root { color-scheme:light; --paper:#faf9f5; --ink:#242722; --accent:#275c45; --highlight:#f7de81; --highlight-ink:#242722; --muted:#667064; --border:#dcded5; --reading-size:21px; --reading-face:Georgia,'Times New Roman',serif; }
    :root[data-reader-theme="dark"] { color-scheme:dark; --paper:#1e1e1e; --ink:#dddddd; --accent:#419cff; --highlight:#345ea8; --highlight-ink:#ffffff; --muted:#9a9a9a; --border:#343434; }
    html, body { margin:0!important; padding:0!important; width:100%!important; height:100%!important; overflow:hidden!important; background:var(--paper)!important; color:var(--ink)!important; }
    #reader-viewport { position:fixed; top:28px; bottom:28px; left:50%; width:calc(100% - 80px); max-width:860px; transform:translateX(-50%); overflow:hidden; }
    #reader-flow { height:100%; column-fill:auto; column-gap:64px; font-size:var(--reading-size)!important; font-family:var(--reading-face)!important; line-height:1.65!important; text-align:left; }
    #reader-flow * { color:inherit!important; text-rendering:optimizeLegibility; }
    #reader-flow, #reader-flow section, #reader-flow div, #reader-flow p, #reader-flow table, #reader-flow td, #reader-flow th, #reader-flow pre, #reader-flow code { background:transparent!important; }
    #reader-flow section, #reader-flow div { font-size:inherit; line-height:inherit; margin:0!important; padding:0!important; }
    #reader-flow p { font-size:1em!important; line-height:inherit!important; margin:0 0 .85em!important; text-indent:0!important; }
    #reader-flow p.bl { display:none!important; }
    #reader-flow h1, #reader-flow h2, #reader-flow h3, #reader-flow h4 { font-family:-apple-system,BlinkMacSystemFont,sans-serif!important; line-height:1.25!important; text-align:left!important; margin:0 0 .8em!important; break-after:avoid; }
    #reader-flow h1 { font-size:1.7em!important; } #reader-flow h2 { font-size:1.4em!important; } #reader-flow h3 { font-size:1.2em!important; }
    #reader-flow h1 span, #reader-flow h2 span, #reader-flow h3 span { font-size:inherit!important; margin:0!important; line-height:inherit!important; text-align:inherit!important; display:inline!important; text-transform:none!important; }
    #reader-flow ul, #reader-flow ol { margin:0 0 .8em!important; padding-left:1.4em!important; }
    #reader-flow a { color:var(--accent)!important; text-decoration:underline; text-underline-offset:3px; }
    #reader-flow figure { break-inside:avoid; margin:1em 0!important; padding:0!important; width:100%!important; }
    #reader-flow figure div { margin:0!important; padding:0!important; }
    #reader-flow img { display:block; width:auto!important; height:auto!important; max-width:100%!important; max-height:var(--image-height)!important; object-fit:contain; margin:0 auto!important; cursor:zoom-in; }
    #reader-flow figcaption { font-size:.82em!important; line-height:1.4!important; margin-top:.5em!important; }
    #reader-flow figcaption p { margin:0!important; }
    #reader-flow p.pdf-caption, #reader-flow p.pdf-footnote { font-size:.85em!important; }
    #reader-flow table { max-width:100%; font-size:.8em; border-collapse:collapse; } #reader-flow td, #reader-flow th { border:1px solid var(--border); padding:.25em; }
    #reader-flow pre { white-space:pre-wrap; overflow-wrap:anywhere; font-size:.82em; }
    #reader-flow [role="doc-pagebreak"] { display:none!important; }
    .reader-word, .reader-gap { display:inline!important; font-size:inherit!important; line-height:inherit!important; margin:0!important; padding:0!important; text-transform:inherit!important; }
    #reader-flow .reader-word.speaking, #reader-flow .reader-gap.speaking { background:var(--highlight)!important; color:var(--highlight-ink)!important; border-radius:2px; box-shadow:0 0 0 1px var(--highlight); }
    :root[data-reader-theme="dark"] #reader-flow img, :root[data-reader-theme="dark"] #reader-zoom img { background:#fff; border-radius:4px; }
    #reader-zoom { position:fixed; inset:0; z-index:999999; background:var(--paper); display:flex; align-items:center; justify-content:center; padding:30px; }
    #reader-zoom img { max-width:100%; max-height:100%; object-fit:contain; }
    #reader-zoom button { position:absolute; right:18px; top:14px; border:1px solid var(--border); background:var(--paper); color:var(--ink); border-radius:8px; font:24px -apple-system; width:36px; height:36px; cursor:pointer; }
    #reader-zoom button:focus-visible { outline:2px solid var(--accent); outline-offset:3px; }
  `;
  document.head.appendChild(style);
  const viewport = el('div'); viewport.id = 'reader-viewport';
  const flow = el('div'); flow.id = 'reader-flow';
  while (document.body.firstChild) flow.appendChild(document.body.firstChild);
  viewport.appendChild(flow); document.body.appendChild(viewport);
  const words = [], units = [], gaps = [];
  const walker = document.createTreeWalker(flow, NodeFilter.SHOW_TEXT);
  const nodes = [];
  while (walker.nextNode()) {
    const node = walker.currentNode;
    if (!node.textContent.trim() || node.parentElement.closest('script,style,svg,math,[role="doc-pagebreak"],[aria-hidden="true"]')) continue;
    if (node.parentElement.closest('p.bl') || getComputedStyle(node.parentElement).display === 'none') continue;
    nodes.push(node);
  }
  for (const node of nodes) {
    const block = node.parentElement.closest('p,h1,h2,h3,h4,h5,h6,li,pre,td,th,figcaption,blockquote') || node.parentElement;
    const frag = document.createDocumentFragment();
    const parts = node.textContent.split(/(\s+)/u);
    for (const part of parts) {
      if (!part) continue;
      if (/^\s+$/u.test(part)) {
        const span = el('span'); span.className = 'reader-gap'; span.textContent = part;
        gaps.push({span,before:words.length-1}); frag.appendChild(span); continue;
      }
      const span = el('span'); span.className = 'reader-word'; span.textContent = part; span.dataset.word = String(words.length);
      words.push({text:part, span, block, index:words.length}); frag.appendChild(span);
    }
    node.parentNode.replaceChild(frag, node);
  }
  const segmenter = new Intl.Segmenter('en', {granularity:'sentence'});
  let group = [];
  function commitGroup() {
    if (!group.length) return;
    let text = '', offsets = [];
    for (const word of group) { if (text) text += ' '; offsets.push({index:word.index,start:text.length,length:word.text.length}); text += word.text; }
    for (const segment of segmenter.segment(text)) {
      const subset = offsets.filter(w => w.start >= segment.index && w.start < segment.index + segment.segment.length);
      if (!subset.length) continue;
      const first = subset[0].start, last = subset[subset.length-1];
      const sentence = units.length;
      for (const word of subset) words[word.index].sentence = sentence;
      units.push({text:text.slice(first, last.start + last.length), words:subset.map(w=>({...w,start:w.start-first}))});
    }
    group = [];
  }
  for (const word of words) { if (group.length && group[0].block !== word.block) commitGroup(); group.push(word); }
  commitGroup();
  for (const unit of units) unit.spans = unit.words.map(w=>words[w.index].span);
  for (const gap of gaps) {
    const sentence = words[gap.before]?.sentence;
    if (sentence !== undefined && words[gap.before+1]?.sentence === sentence) units[sentence].spans.push(gap.span);
  }
  let currentPage = 0, pages = 1, step = 1, highlighted = -1, highlightedSentence = -1, zoom = null, layoutTimer;
  const pageFor = word => {
    const x = word.span.getBoundingClientRect().left - viewport.getBoundingClientRect().left + currentPage * step;
    return Math.max(0, Math.min(pages-1, Math.floor((x + 1) / step)));
  };
  function topWord() { return words.find(w => pageFor(w) >= currentPage)?.index ?? -1; }
  function sourcePage() {
    const word = words[highlighted >= 0 ? highlighted : topWord()];
    return Number(word?.span.closest('[data-source-page]')?.dataset.sourcePage || 1);
  }
  function state() {
    const first = topWord();
    const sentenceWords = units[highlightedSentence]?.words.map(w=>w.index) || [];
    return {theme:document.documentElement.dataset.readerTheme, sourcePage:sourcePage(), page:currentPage, pages, topWord:first, wordCount:words.length, unitCount:units.length, highlighted, highlightedSentence, sentenceWords, zoom:!!zoom,
      images:[...flow.querySelectorAll('img')].map(i=>({loaded:i.complete && i.naturalWidth>0,src:i.getAttribute('src')}))};
  }
  function showPage(page, source='navigation') {
    currentPage = Math.max(0, Math.min(pages-1, page));
    flow.style.transform = `translateX(${-currentPage*step}px)`;
    send('page', {...state(), source});
    return state();
  }
  function layout(preserve=true) {
    const anchor = preserve ? (highlighted >= 0 ? highlighted : topWord()) : -1;
    flow.style.transform = 'none';
    currentPage = 0;
    flow.style.width = `${viewport.clientWidth}px`;
    flow.style.columnWidth = `${viewport.clientWidth}px`;
    flow.style.setProperty('--image-height', `${Math.max(100, Math.floor(viewport.clientHeight * .66))}px`);
    step = viewport.clientWidth + 64;
    pages = Math.max(1, Math.ceil((flow.scrollWidth + 64) / step));
    if (anchor >= 0 && words[anchor]) currentPage = pageFor(words[anchor]);
    showPage(currentPage, 'layout');
    return state();
  }
  function clearHighlight() {
    for (const span of units[highlightedSentence]?.spans || []) span.classList.remove('speaking');
    highlighted = -1; highlightedSentence = -1;
  }
  function highlight(index) {
    if (!words[index]) return;
    const sentence = words[index].sentence;
    if (sentence !== highlightedSentence) {
      clearHighlight(); highlightedSentence = sentence;
      for (const span of units[sentence].spans) span.classList.add('speaking');
    }
    highlighted = index;
    if (!zoom) showPage(pageFor(words[index]), 'speech');
  }
  function plan(index) {
    if (index < 0) return [];
    return units.filter(u=>u.words.some(w=>w.index>=index)).map(u=>{
      const selected=u.words.filter(w=>w.index>=index), start=selected[0].start;
      return {text:u.text.slice(start),words:selected.map(w=>({...w,start:w.start-start}))};
    });
  }
  function nearby(index) {
    const sentence = words[index]?.sentence;
    if (sentence === undefined) return [];
    return [0,-1,1,-2,2].map(delta=>units[sentence+delta]).filter(Boolean)
      .map(u=>({text:u.text,words:u.words}));
  }
  function closeZoom() { if (zoom) { zoom.remove(); zoom=null; send('zoomClosed'); } }
  function setTheme(theme, palette = window.readAlongDarkPalette || {}) {
    const dark = theme === 'dark';
    window.readAlongDarkPalette = palette;
    document.documentElement.dataset.readerTheme = dark ? 'dark' : 'light';
    for (const key of ['paper','ink','accent','highlight','highlight-ink','muted','border']) {
      if (dark && palette[key]) document.documentElement.style.setProperty('--' + key, palette[key]);
      else document.documentElement.style.removeProperty('--' + key);
    }
    document.documentElement.style.backgroundColor = 'var(--paper)';
    document.documentElement.style.colorScheme = document.documentElement.dataset.readerTheme;
    return state();
  }
  function sentenceStart(index=highlighted>=0?highlighted:topWord()) {
    return units[words[index]?.sentence]?.words[0]?.index ?? -1;
  }
  function moveSentence(delta) {
    const sentence = highlightedSentence>=0 ? highlightedSentence : words[topWord()]?.sentence;
    if (sentence === undefined) return {word:-1,boundary:delta};
    const next = sentence + delta;
    if (next < 0 || next >= units.length) return {word:units[sentence].words[0].index,boundary:delta};
    const word = units[next].words[0].index;
    highlight(word);
    return {word,boundary:0};
  }
  function selectSentenceEdge(direction) {
    const word = (direction < 0 ? units[units.length-1] : units[0])?.words[0]?.index ?? -1;
    if (word>=0) highlight(word);
    return word;
  }
  document.addEventListener('click', event => {
    const image = event.target.closest?.('img');
    if (image && !zoom) {
      send('pause'); zoom=el('div'); zoom.id='reader-zoom'; zoom.setAttribute('role','dialog'); zoom.setAttribute('aria-label','Image');
      const copy=el('img'); copy.src=image.src; copy.alt=image.alt;
      const close=el('button'); close.textContent='×'; close.setAttribute('aria-label','Close image'); close.onclick=closeZoom;
      zoom.append(copy,close); document.body.append(zoom); close.focus(); event.preventDefault();
    }
    const link=event.target.closest?.('a');
    if (link) { event.preventDefault(); send('link',{href:link.getAttribute('href')||''}); }
  });
  document.addEventListener('keydown',event=>{ if (event.key==='Escape' && zoom) { event.preventDefault(); closeZoom(); } });
  document.addEventListener('dblclick',event=>{ const word=event.target.closest?.('.reader-word'); if(word && !zoom){event.preventDefault();send('seek',{index:Number(word.dataset.word)});} });
  const api = {
    state, layout, topWord, sourcePage, plan, nearby, highlight, clearHighlight, closeZoom, sentenceStart, moveSentence, selectSentenceEdge, setTheme,
    setPage:page=>{clearHighlight();return showPage(page);},
    restore:index=>{clearHighlight();if(words[index])return showPage(pageFor(words[index]),'restore');return showPage(0,'restore');},
    navigate:delta=>{clearHighlight();const next=currentPage+delta;if(next<0||next>=pages){send('boundary',{delta});return state();}return showPage(next);},
    goAnchor:id=>{const target=document.getElementById(id);if(!target)return false;const word=target.matches('.reader-word')?target:target.querySelector('.reader-word');if(word)return api.restore(Number(word.dataset.word));const following=words.find(w=>target.compareDocumentPosition(w.span)&Node.DOCUMENT_POSITION_FOLLOWING);return following?api.restore(following.index):false;},
    setFont:size=>{document.documentElement.style.setProperty('--reading-size',`${size}px`);return layout();}
  };
  window.Reader = api;
  window.addEventListener('resize',()=>{clearTimeout(layoutTimer);layoutTimer=setTimeout(()=>layout(),100);});
  const ready=async()=>{await document.fonts.ready;await Promise.all([...flow.querySelectorAll('img')].map(image=>image.complete?Promise.resolve():new Promise(resolve=>{image.onload=resolve;image.onerror=resolve;})));layout(false);send('ready',state());};
  ready().catch(error=>send('error',{message:String(error)}));
})();
