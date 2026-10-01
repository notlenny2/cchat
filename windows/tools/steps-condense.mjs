// Memory condensing: run with CCHAT_CONDENSE_AT tiny so every reply gets condensed, then check it still remembers.
export default async ({ js, shot, sleep, until, log }) => {
  await until(`!!document.querySelector('#modal-back:not([hidden]) .status')`, 30);
  await sleep(1000);
  await js(`S.projectsRoot='C:\\\\Users\\\\you\\\\cchat-test\\\\projects'; S.userName='Sam'; [...document.querySelectorAll('#modal button')].find(b=>b.textContent==='Start texting').click()`);
  await sleep(500);
  await js(`document.querySelector('#empty input').value='Kiwi Shop'; [...document.querySelectorAll('#empty button')].find(b=>b.textContent==='Start').click()`);
  await until(`!document.querySelector('#chat').hidden`, 20);
  await js(`conv(selected).model='haiku'`);
  await js(`document.querySelector('#input').value='Remember this secret word: walrus. Just say ok.'; document.querySelector('#composer').requestSubmit()`);
  await sleep(1500);
  await until(`conv(selected).messages.some(m=>m.senderId)`, 180);
  const s1 = await js(`Object.values(conv(selected).sessions)[0]`);
  await sleep(1000);
  await shot('c1-tidying');
  log('while tidying:', await js(`JSON.stringify(busy[selected]||null)`));
  await until(`!busy[selected] && !pumping[selected]`, 300);
  log('after 1:', await js(`JSON.stringify(conv(selected).messages.map(m=>[m.kind,m.text.slice(0,120)]))`));
  await js(`document.querySelector('#input').value='What was the secret word? One word.'; document.querySelector('#composer').requestSubmit()`);
  await sleep(1500);
  await until(`conv(selected).messages.filter(m=>m.senderId).length>=2 && !busy[selected] && !pumping[selected]`, 300);
  log('reply2:', await js(`conv(selected).messages.filter(m=>m.senderId).pop().text`));
  log('session same:', await js(`Object.values(conv(selected).sessions)[0]`) === s1);
  await sleep(500);
  await shot('c2-after');
};
