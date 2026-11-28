import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import assert from 'node:assert/strict';

const binary = process.argv[2];
if (!binary) throw new Error('Expected the portable runner path');
const directory = await mkdtemp(join(tmpdir(), 'vektkove-state-'));
const executable = resolve(binary);
const sourcePath = join(directory, 'game.vk');

function run() {
  return spawnSync(executable, ['run', sourcePath], { cwd: directory, encoding: 'utf8' });
}

try {
  await writeFile(sourcePath, [
    'track score 10',
    'track_add score 5',
    'track_count events',
    'track_max best 8',
    'track_max best 12',
    'track_min low 90',
    'track_min low 70',
    'text player "Ari"',
    'save "slot.json"',
    'track score 0',
    'track_reset events',
    'load "slot.json"',
    'out $score',
    'out $events',
    'out $best',
    'out $low',
    'out $player',
  ].join('\n'));
  const restored = run();
  assert.equal(restored.status, 0, restored.stderr);
  assert.equal(restored.stdout, '15\n1\n12\n70\nAri\n');

  await writeFile(join(directory, 'invalid.json'), '{"format":"VKGS","version":2,"variables":{}}');
  await writeFile(sourcePath, 'track score 4\nload "invalid.json"\nout $score');
  const invalid = run();
  assert.notEqual(invalid.status, 0);
  assert.match(invalid.stderr, /Invalid Vektkove game save/);
  await writeFile(join(directory, 'invalid.json'), '{"format":"VKGS","version":1,"variables":{}} trailing');
  const trailing = run();
  assert.notEqual(trailing.status, 0);
  assert.match(trailing.stderr, /Invalid Vektkove game save/);

  await writeFile(sourcePath, 'track score 4\nsave "slot.json"\nset transient 1\nload "slot.json"\nout $transient');
  const replaced = run();
  assert.notEqual(replaced.status, 0);
  assert.match(replaced.stderr, /Unknown variable \$transient/);

  const save = await readFile(join(directory, 'slot.json'), 'utf8');
  assert.match(save, /"score":4/);
  console.log('Game state and tracker tests passed');
} finally {
  await rm(directory, { recursive: true, force: true });
}
