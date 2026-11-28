import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { strict as assert } from 'node:assert';

const binary = process.argv[2];
if (!binary) throw new Error('Expected the portable runner path');
const directory = await mkdtemp(join(tmpdir(), 'vektkove-archive-'));
const passphrase = 'test-only archive passphrase';
const run = (action, input, output, secret = passphrase) => spawnSync(binary, [action, input, output], {
  env: { ...process.env, VEKTKOVE_GAME_PASSPHRASE: secret }, encoding: 'utf8',
});
try {
  const source = join(directory, 'game.zip');
  const encrypted = join(directory, 'game.vke');
  const restored = join(directory, 'restored.zip');
  const payload = Buffer.alloc(100000, 42);
  await writeFile(source, payload);
  assert.equal(run('encrypt-game', source, encrypted).status, 0);
  const ciphertext = await readFile(encrypted);
  assert.notDeepEqual(ciphertext, payload);
  assert.equal(run('decrypt-game', encrypted, restored).status, 0);
  assert.deepEqual(await readFile(restored), payload);
  assert.notEqual(run('decrypt-game', encrypted, restored).status, 0);
  assert.deepEqual(await readFile(restored), payload);
  const wrong = join(directory, 'wrong.zip');
  assert.notEqual(run('decrypt-game', encrypted, wrong, 'incorrect passphrase').status, 0);
  await assert.rejects(readFile(wrong));
  ciphertext[ciphertext.length - 1] ^= 1;
  const altered = join(directory, 'altered.vke');
  await writeFile(altered, ciphertext);
  assert.notEqual(run('decrypt-game', altered, wrong).status, 0);
  await assert.rejects(readFile(wrong));
  await writeFile(altered, ciphertext.subarray(0, ciphertext.length - 3));
  assert.notEqual(run('decrypt-game', altered, wrong).status, 0);
  await assert.rejects(readFile(wrong));
  const empty = join(directory, 'empty.zip');
  await writeFile(empty, Buffer.alloc(0));
  assert.equal(run('encrypt-game', empty, join(directory, 'empty.vke')).status, 0);
  assert.equal(run('decrypt-game', join(directory, 'empty.vke'), wrong).status, 0);
  assert.equal((await readFile(wrong)).length, 0);
  console.log('Authenticated game archive tests passed');
} finally {
  await rm(directory, { recursive: true, force: true });
}