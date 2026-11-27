import { createServer } from 'node:http';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';

const binary = process.argv[2];
const engines = process.argv.slice(3);
if (!binary) throw new Error('Usage: node portable/ai_integration_test.mjs /path/to/ai_test [native-vk portable-vk]');

const seen = new Set();
const server = createServer((request, response) => {
  const url = new URL(request.url, 'http://localhost');
  if (url.pathname === '/page') {
    seen.add('page');
    response.end('Online reference content.');
  } else if (url.pathname === '/wiki') {
    if (url.searchParams.get('gsrsearch') !== 'solar power') { response.writeHead(400).end(); return; }
    seen.add('topic');
    response.setHeader('content-type', 'application/json');
    response.end(JSON.stringify({ query: { pages: { 1: { title: 'Solar power', extract: 'Solar energy comes from sunlight.' } } } }));
  } else if (url.pathname === '/invalid-json') {
    response.setHeader('content-type', 'application/json');
    response.end('{broken');
  } else if (url.pathname === '/failure') {
    response.writeHead(500).end('Provider error');
  } else if (url.pathname === '/ollama' || url.pathname === '/openai') {
    let body = '';
    request.setEncoding('utf8');
    request.on('data', chunk => body += chunk);
    request.on('end', () => {
      try {
        const payload = JSON.parse(body);
        const prompt = payload.messages.find(message => message.role === 'user').content;
        if (payload.model !== 'example' || payload.stream !== false || !prompt.includes('Online reference content.') ||
            !prompt.includes('Solar energy comes from sunlight.') || !prompt.includes('File reference content.') ||
            !prompt.includes('Quoted "reference".')) throw new Error('Unexpected request body');
        if (prompt.includes('[code]\n')) {
          const records = prompt.split('\n').filter(line => line.startsWith('{"instructions"')).map(line => JSON.parse(line));
          if (records.length !== 5 || records.some(record => record.format !== 'vektkove-instruction-tree-v1' || record.syntax_reward !== 1) ||
              !records.some(record => record.source.includes('out $value'))) throw new Error('Invalid code training records');
          seen.add('code-training');
        }
        if (url.pathname === '/openai' && request.headers.authorization !== 'Bearer test-key') throw new Error('Missing authorization');
        if (url.pathname === '/ollama' && request.headers.authorization) throw new Error('Unexpected authorization');
        seen.add(url.pathname.slice(1));
        response.setHeader('content-type', 'application/json');
        response.end(JSON.stringify(url.pathname === '/ollama'
          ? { message: { content: 'Ollama answer' } }
          : { choices: [{ message: { content: 'OpenAI answer' } }] }));
      } catch {
        response.writeHead(400).end();
      }
    });
  } else response.writeHead(404).end();
});

await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const directory = await mkdtemp(join(tmpdir(), 'vektkove-ai-'));
try {
  const file = join(directory, 'reference.txt');
  await writeFile(file, 'File reference content.');
  const codeFile = join(directory, 'training.vk');
  await writeFile(codeFile, 'set value 4\nout $value\nhalt\n');
  const base = `http://127.0.0.1:${server.address().port}`;
  const env = { ...process.env, VEKTKOVE_AI_TEST_PAGE: `${base}/page`, VEKTKOVE_AI_TEST_FILE: file,
    VEKTKOVE_WIKIPEDIA_URL: `${base}/wiki`, VEKTKOVE_OLLAMA_URL: `${base}/ollama`,
    VEKTKOVE_OPENAI_URL: `${base}/openai`, OPENAI_API_KEY: 'test-key' };
  const execute = (command, args, overrides = {}) => new Promise((resolve, reject) => {
    const child = spawn(command, args, { env: { ...env, ...overrides } });
    let stdout = '', stderr = '';
    child.stdout.on('data', chunk => stdout += chunk);
    child.stderr.on('data', chunk => stderr += chunk);
    child.on('error', reject);
    child.on('close', code => resolve({ code, stdout, stderr }));
  });
  if (binary !== '-') {
    const unit = await execute(binary, [], { OPENAI_API_KEY: '' });
    if (unit.code !== 0) throw new Error(`AI integration failed: exit ${unit.code}: ${unit.stderr}`);
  }
  if (engines.length) {
    const source = join(directory, 'program.vk');
    await writeFile(source, [
      'ai_config "ollama" "example"',
      'train "topic" "solar power"',
      `train "url" ${JSON.stringify(`${base}/page`)}`,
      `train "file" ${JSON.stringify(file)}`,
      'train "text" "Quoted \\"reference\\".\\nAnother line."',
      'ai_learn "code" "set value 2\\nout $value\\nhalt"',
      `train "file" ${JSON.stringify(codeFile)}`,
      'ai_remember "synthetic" "sample seed"',
      'ai_ask answer "What is solar power?"',
      'out $answer',
      'ai_config "openai" "example"',
      'ai_ask answer "What is solar power?"',
      'out $answer',
      'ai_clear',
    ].join('\n'));
    let bytecode;
    for (const [index, engine] of engines.entries()) {
      const compiled = join(directory, `program-${index}.vkb`);
      const check = await execute(engine, ['check', source]);
      const score = await execute(engine, ['score', source]);
      const ast = await execute(engine, ['ast', source]);
      if (check.code !== 0 || check.stdout.trim() !== 'Syntax OK' || score.code !== 0 || score.stdout.trim() !== '1' || ast.code !== 0) throw new Error('Code analysis failed');
      const tree = JSON.parse(ast.stdout);
      if (tree.format !== 'vektkove-instruction-tree-v1' || tree.syntax_reward !== 1 || !tree.instructions.length || !tree.source.includes('ai_remember')) throw new Error('Invalid AST export');
      const invalid = await execute(engine, ['score', file]);
      const invalidCheck = await execute(engine, ['check', file]);
      if (invalid.code !== 0 || invalid.stdout.trim() !== '0' || invalidCheck.code === 0) throw new Error('Invalid source score failed');
      const compile = await execute(engine, ['compile', source, compiled]);
      if (compile.code !== 0) throw new Error(`AI program compile failed: ${compile.stderr}`);
      const current = await readFile(compiled);
      if (bytecode && !bytecode.equals(current)) throw new Error('AI bytecode differs between engines');
      bytecode = current;
      const run = await execute(engine, ['run', compiled]);
      if (run.code !== 0 || run.stdout.replace(/\r\n/g, '\n') !== 'Ollama answer\nOpenAI answer\n') {
        throw new Error(`AI program failed: ${run.stderr} ${run.stdout}`);
      }
      const failures = [
        { source: 'ai_config "openai" "example"\nai_ask answer "Question"', env: { OPENAI_API_KEY: '' }, expected: 'OPENAI_API_KEY' },
        { source: 'ai_config "ollama" "example"\nai_ask answer "Question"', env: { VEKTKOVE_OLLAMA_URL: `${base}/failure` }, expected: 'network request failed' },
        { source: 'train "topic" "solar power"', env: { VEKTKOVE_WIKIPEDIA_URL: `${base}/invalid-json` }, expected: 'No usable Wikipedia results' },
        { source: 'train "url" "http://localhost.example.com/page"', env: {}, expected: 'AI URLs must use HTTPS' },
      ];
      for (const [failureIndex, failure] of failures.entries()) {
        const path = join(directory, `failure-${index}-${failureIndex}.vk`);
        await writeFile(path, failure.source);
        const result = await execute(engine, ['run', path], failure.env);
        if (result.code === 0 || !result.stderr.includes(failure.expected) || result.stderr.includes('test-key')) {
          throw new Error(`AI error handling failed: ${result.stderr}`);
        }
      }
    }
  }
  if (['page', 'topic', 'ollama', 'openai', ...(engines.length ? ['code-training'] : [])].some(name => !seen.has(name))) {
    throw new Error(`AI integration did not exercise every endpoint: ${[...seen].join(', ')}`);
  }
  console.log('AI local mock integration passed');
} finally {
  server.close();
  await rm(directory, { recursive: true, force: true });
}