// Usage meter: one Claude reply should fill the Claude bars; Codex's come from its own logs.
import os from 'node:os';
import path from 'node:path';
// Test projects go in a throwaway folder in the user's home, never their real projects folder.
const ROOT = JSON.stringify(path.join(os.homedir(), 'cchat-test', 'projects'));
export default async ({ js, shot, sleep, until, log }) => {
  await until(`!!document.querySelector('#modal-back:not([hidden]) .status')`, 30);
  await sleep(1000);
  await js(`S.projectsRoot=${ROOT}; S.userName='Sam'; [...document.querySelectorAll('#modal button')].find(b=>b.textContent==='Start texting').click()`);
  await sleep(500);
  await js(`document.querySelector('#empty input').value='Plum Stand'; [...document.querySelectorAll('#empty button')].find(b=>b.textContent==='Start').click()`);
  await until(`!document.querySelector('#chat').hidden`, 20);
  await js(`conv(selected).model='haiku'`);
  log('codex before:', await js(`JSON.stringify(usage.codex||null)`));
  await js(`document.querySelector('#input').value='Say hi in three words.'; document.querySelector('#composer').requestSubmit()`);
  await sleep(1500);
  await until(`conv(selected).messages.some(m=>m.senderId) && !busy[selected] && !pumping[selected]`, 180);
  log('usage:', await js(`JSON.stringify(usage)`));
  log('meter:', await js(`document.querySelector('#usage').innerText.replace(/\\n+/g,' | ')`));
  await shot('u1-meter');
  await js(`document.querySelector('#usage').click()`);
  await sleep(300);
  log('folded:', await js(`document.querySelector('#usage').innerText.replace(/\\n+/g,' | ')`));
  await shot('u2-folded');
  await js(`document.querySelector('#usage').click()`);
};
