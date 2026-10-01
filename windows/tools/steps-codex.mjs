// A Codex 1:1: two turns (memory across turns), next chips, and the Codex usage meter.
export default async ({ js, shot, sleep, until, log }) => {
  await until(`!!document.querySelector('#modal-back:not([hidden]) .status')`, 30);
  await sleep(1000);
  await js(`S.projectsRoot='C:\\\\Users\\\\you\\\\cchat-test\\\\projects'; S.userName='Sam'; [...document.querySelectorAll('#modal button')].find(b=>b.textContent==='Start texting').click()`);
  await sleep(500);
  await js(`document.querySelector('#empty input').value='Plum Stand'; [...document.querySelectorAll('#empty button')].find(b=>b.textContent==='Start').click()`);
  await until(`!document.querySelector('#chat').hidden`, 20);
  await js(`(() => { const p = projectOf(conv(selected)); const c = openChat([p.id], 'codex'); return c.id; })()`);
  await sleep(500);
  await js(`document.querySelector('#input').value='Remember the word marmalade. Reply with one short sentence.'; document.querySelector('#composer').requestSubmit()`);
  await sleep(1500);
  await shot('c1-typing');
  await until(`conv(selected).messages.filter(m=>m.senderId).length>=1 && !busy[selected] && !pumping[selected]`, 300);
  await js(`document.querySelector('#input').value='What word did I ask you to remember?'; document.querySelector('#composer').requestSubmit()`);
  await sleep(1500);
  await until(`conv(selected).messages.filter(m=>m.senderId).length>=2 && !busy[selected] && !pumping[selected]`, 300);
  log('msgs:', await js(`JSON.stringify(conv(selected).messages.map(m=>[m.senderId?'agent':(m.kind||'me'), m.text.slice(0,160)]))`));
  log('engine/session/chips:', await js(`JSON.stringify([conv(selected).engine, Object.keys(conv(selected).sessions).length, conv(selected).suggestions])`));
  await js(`pollCodex && pollCodex()`).catch(() => {});
  await sleep(1500);
  log('usage:', await js(`JSON.stringify(usage.codex||null)`));
  await shot('c2-done');
};
