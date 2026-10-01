// First run, new project, a 1:1 chat with memory across two turns (Haiku to keep it cheap).
import os from 'node:os';
import path from 'node:path';
// Test projects go in a throwaway folder in the user's home, never their real projects folder.
const ROOT = JSON.stringify(path.join(os.homedir(), 'cchat-test', 'projects'));
export default async ({ js, shot, sleep, until, log }) => {
  await until(`!!document.querySelector('#modal-back:not([hidden]) .status')`, 30);
  await sleep(1500);
  await shot('1-welcome');
  log('welcome:', await js(`document.querySelector('#modal').innerText.replace(/\\n+/g,' | ')`));
  await js(`[...document.querySelectorAll('#modal input.field')][1].value=${ROOT}; [...document.querySelectorAll('#modal input.field')][1].dispatchEvent(new Event('change')); S.userName='Sam';`);
  await js(`[...document.querySelectorAll('#modal button')].find(b=>b.textContent==='Start texting').click()`);
  await sleep(500);
  await shot('2-empty');
  await js(`document.querySelector('#empty input').value='Banana Stand'; [...document.querySelectorAll('#empty button')].find(b=>b.textContent==='Start').click()`);
  await until(`!document.querySelector('#chat').hidden`, 20);
  await js(`conv(selected).model='haiku'`);
  await sleep(500);
  await shot('3-new-chat');
  await js(`document.querySelector('#input').value='Reply with only the word "mango" and your next line.'; document.querySelector('#composer').requestSubmit()`);
  await sleep(1500);
  await shot('4-typing');
  await until(`conv(selected).messages.some(m=>m.senderId) && !busy[selected]`, 180);
  log('reply1:', await js(`JSON.stringify(conv(selected).messages.filter(m=>m.senderId||m.kind!=='normal').map(m=>[m.kind,m.text]))`));
  log('chips:', await js(`JSON.stringify(conv(selected).suggestions)`));
  await js(`document.querySelector('#input').value='What word did you just say? One word.'; document.querySelector('#composer').requestSubmit()`);
  await sleep(500);
  await until(`conv(selected).messages.filter(m=>m.senderId).length>=2 && !busy[selected]`, 180);
  log('reply2:', await js(`conv(selected).messages.filter(m=>m.senderId).pop().text`));
  log('session:', await js(`JSON.stringify(conv(selected).sessions)`));
  await sleep(500);
  await shot('5-chat');
};
