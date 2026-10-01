// Show the Work: a Claude (Haiku) turn and a Codex turn that each have to look at files; the live log while it
// runs, then the folded log under the reply, opened.
export default async ({ js, shot, sleep, until, log }) => {
  await until(`!!document.querySelector('#modal-back:not([hidden]) .status')`, 30);
  await sleep(1000);
  await js(`S.projectsRoot='C:\\\\Users\\\\you\\\\cchat-test\\\\projects'; S.userName='Sam'; [...document.querySelectorAll('#modal button')].find(b=>b.textContent==='Start texting').click()`);
  await sleep(500);
  await js(`document.querySelector('#empty input').value='Fig Jam'; [...document.querySelectorAll('#empty button')].find(b=>b.textContent==='Start').click()`);
  await until(`!document.querySelector('#chat').hidden`, 20);
  await js(`conv(selected).model='haiku'; document.querySelector('.work-btn').click()`);
  log('toggle on:', await js(`showWork + ' ' + document.querySelector('.work-btn').classList.contains('on')`));
  const ask = 'Make a file called notes.txt with three fruit names, one per line, then read it back and tell me how many lines it has. One short sentence.';
  await js(`document.querySelector('#input').value=${JSON.stringify(ask)}; document.querySelector('#composer').requestSubmit()`);
  await until(`(work[selected]||[]).some(s=>s.kind==='tool')`, 120);
  await sleep(300);
  await shot('w1-live');
  await until(`conv(selected).messages.filter(m=>m.senderId).length>=1 && !busy[selected] && !pumping[selected]`, 300);
  const m = await js(`JSON.stringify((()=>{const m=conv(selected).messages.filter(m=>m.senderId).at(-1); return {text:m.text, kinds:(m.work||[]).map(s=>s.kind+(s.title?':'+s.title:'')), info:(m.work||[]).filter(s=>s.kind==='info').map(s=>s.text)}})())`);
  log('claude reply:', m);
  await js(`document.querySelector('.workfold button').click()`);
  await sleep(400);
  await shot('w2-claude-open');
  // Codex
  await js(`(() => { const p = projectOf(conv(selected)); openChat([p.id], 'codex'); render(); })()`);
  await sleep(500);
  await js(`document.querySelector('#input').value='How many lines are in notes.txt? Check the file, then answer in one short sentence.'; document.querySelector('#composer').requestSubmit()`);
  await until(`conv(selected).messages.filter(m=>m.senderId).length>=1 && !busy[selected] && !pumping[selected]`, 300);
  const c = await js(`JSON.stringify((()=>{const m=conv(selected).messages.filter(m=>m.senderId).at(-1); return {text:m.text, kinds:(m.work||[]).map(s=>s.kind+(s.title?':'+s.title:''))}})())`);
  log('codex reply:', c);
  await js(`document.querySelector('.workfold button')?.click()`);
  await sleep(400);
  await shot('w3-codex-open');
  // Off again: the log is hidden, the reply stays.
  await js(`document.querySelector('.work-btn').click()`);
  await sleep(300);
  log('toggle off, folds shown:', await js(`document.querySelectorAll('.workfold').length`));
  log('saved bytes:', await js(`JSON.stringify(S).length`));
};
