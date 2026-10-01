// A group of two personas: "everyone" (Director answers last), then an un-named text (the router picks).
export default async ({ js, shot, sleep, until, log }) => {
  await until(`!!document.querySelector('#modal-back:not([hidden]) .status')`, 30);
  await sleep(1000);
  await js(`S.projectsRoot='C:\\\\Users\\\\you\\\\cchat-test\\\\projects'; S.userName='Sam'; [...document.querySelectorAll('#modal button')].find(b=>b.textContent==='Start texting').click()`);
  await sleep(500);
  await js(`document.querySelector('#empty input').value='Lemon Cart'; [...document.querySelectorAll('#empty button')].find(b=>b.textContent==='Start').click()`);
  await until(`!document.querySelector('#chat').hidden`, 20);
  await js(`(() => { const p = projectOf(conv(selected));
    const d = addSub(p, 'Lemon Cart Designer', 'The Designer. Cares how it feels to use. Keep replies to one short sentence.');
    const b = addSub(p, 'Lemon Cart Director', 'The Director. Weighs the others and makes the call. Keep replies to one short sentence.');
    const g = openChat([d.id, b.id], 'claude', 'haiku', 'Lemon Cart Team'); return g.id; })()`);
  await sleep(500);
  await js(`document.querySelector('#input').value='Everyone: should the lemon cart sign be yellow or green? One sentence each.'; document.querySelector('#composer').requestSubmit()`);
  await sleep(1500);
  await shot('g1-typing');
  await until(`conv(selected).messages.filter(m=>m.senderId).length>=2 && !busy[selected] && !pumping[selected]`, 300);
  log('round1:', await js(`JSON.stringify(conv(selected).messages.map(m=>[m.senderId?contact(m.senderId).name:(m.kind==='system'?'note':'me'), m.text.slice(0,140)]))`));
  await shot('g2-round1');
  const before = await js(`conv(selected).messages.length`);
  await js(`document.querySelector('#input').value='Which font would feel friendliest on the sign? Short answer.'; document.querySelector('#composer').requestSubmit()`);
  await sleep(1500);
  await until(`conv(selected).messages.length>${before + 1} && !busy[selected] && !pumping[selected]`, 300);
  log('round2:', await js(`JSON.stringify(conv(selected).messages.slice(${before}).map(m=>[m.senderId?contact(m.senderId).name:(m.kind==='system'?'note':'me'), m.text.slice(0,140)]))`));
  log('sessions:', await js(`Object.keys(conv(selected).sessions).length`));
  await sleep(500);
  await shot('g3-round2');
};
