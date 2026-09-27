#!/usr/bin/env node
// Браузерный сценарий на локальной копии Supabase: готовит чистую базу и тестовых игроков,
// поднимает копию сайта, проходит её в браузере (scenario.cjs) и сравнивает журнал с эталоном.
// Боевую базу не трогает.
//
//   node tests/e2e/run.cjs            прогнать и сравнить с tests/e2e/expected.log
//   node tests/e2e/run.cjs --update   прогнать и записать новый эталон — после осознанных изменений
//
// Нужно: Docker, Node.js 20+, запущенный локальный Supabase (npx supabase start) и Playwright:
//   npm install --no-save playwright@1.56.0 && npx playwright install chromium
// Внимание: сценарий начинает с `supabase db reset --local` — локальная (не боевая!) база очищается.

const { execSync, execFileSync } = require('child_process');
const fs = require('fs');
const http = require('http');
const os = require('os');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const EXPECTED = path.join(__dirname, 'expected.log');
const OUT = process.env.E2E_OUT || path.join(__dirname, 'out');
const UPDATE = process.argv.includes('--update');
const PASSWORD = 'Test-pass-12345';
const USERS = [
  ['admin@fruit.local', 'Админ Тест'],
  ['p1@fruit.local', 'Игрок Альфа'],   // ники не совпадают с тестами базы, чтобы после сценария
  ['p2@fruit.local', 'Игрок Бета'],    // `supabase test db` не спотыкался о занятый ник
  ['p3@fruit.local', 'Игрок Гамма'],
];

const say = m => console.log(`\n▶ ${m}`);
const fail = m => { console.error(`\n✗ ${m}`); process.exit(1); };

function hasSupabaseCli() {
  try { execSync('supabase --version', { stdio: 'ignore' }); return true; } catch { return false; }
}
const SUPABASE = hasSupabaseCli() ? 'supabase' : 'npx --yes supabase@2.118.0';
const supabase = args => execSync(`${SUPABASE} ${args}`, { cwd: ROOT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });

function localEnv() {
  let out;
  try { out = supabase('status -o env'); } catch { fail('локальный Supabase не запущен. запустите: npx supabase start'); }
  const env = {};
  for (const m of out.matchAll(/^([A-Z_]+)="?([^"\n]*)"?$/gm)) env[m[1]] = m[2];
  if (!env.API_URL || !env.PUBLISHABLE_KEY || !env.SERVICE_ROLE_KEY) fail('не удалось прочитать адрес и ключи локального Supabase');
  if (!/^http:\/\/(127\.0\.0\.1|localhost)[:/]/.test(env.API_URL)) fail(`API_URL не локальный (${env.API_URL}) — сценарий работает только с локальной копией`);
  return env;
}

function sql(projectId, query) {
  execFileSync('docker', ['exec', `supabase_db_${projectId}`, 'psql', '-U', 'postgres', '-d', 'postgres',
    '-v', 'ON_ERROR_STOP=1', '-q', '-c', query], { stdio: ['ignore', 'pipe', 'pipe'] });
}

async function createUser(env, email, nick) {
  for (let attempt = 0; attempt < 30; attempt++) {
    const res = await fetch(`${env.API_URL}/auth/v1/admin/users`, {
      method: 'POST',
      headers: { apikey: env.SERVICE_ROLE_KEY, Authorization: `Bearer ${env.SERVICE_ROLE_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ email, password: PASSWORD, email_confirm: true, user_metadata: { school_nick: nick } }),
    }).catch(() => null);
    if (res && res.ok) return;
    await new Promise(r => setTimeout(r, 1000));   // вход ещё поднимается после сброса базы
  }
  fail(`не удалось создать тестового игрока ${email}`);
}

// копия сайта с адресом локального Supabase; в CSP добавляется только этот адрес
function buildSite(env) {
  const site = fs.mkdtempSync(path.join(os.tmpdir(), 'fruitkog-e2e-'));
  for (const item of ['index.html', 'boot.js', 'styles.css', 'src', 'assets', 'vendor']) {
    fs.cpSync(path.join(ROOT, item), path.join(site, item), { recursive: true });
  }
  fs.writeFileSync(path.join(site, 'config.js'),
    `export const SUPABASE_URL = ${JSON.stringify(env.API_URL)};\nexport const SUPABASE_PUBLISHABLE_KEY = ${JSON.stringify(env.PUBLISHABLE_KEY)};\n`);
  const origin = new URL(env.API_URL).origin;
  const indexPath = path.join(site, 'index.html');
  const html = fs.readFileSync(indexPath, 'utf8');
  const patched = html.replace("connect-src 'self' https: wss:", `connect-src 'self' https: wss: ${origin} ${origin.replace(/^http/, 'ws')}`);
  if (patched === html) fail("в index.html не найдено connect-src 'self' https: wss: — поправьте run.cjs под новую CSP");
  fs.writeFileSync(indexPath, patched);
  return site;
}

const TYPES = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.webp': 'image/webp', '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon', '.json': 'application/json', '.woff2': 'font/woff2', '.woff': 'font/woff', '.ttf': 'font/ttf',
};
function serve(site) {
  const server = http.createServer((req, res) => {
    let file = path.join(site, decodeURIComponent(new URL(req.url, 'http://local').pathname));
    if (file !== site && !file.startsWith(site + path.sep)) { res.writeHead(403); res.end(); return; }
    if (fs.existsSync(file) && fs.statSync(file).isDirectory()) file = path.join(file, 'index.html');
    fs.readFile(file, (err, data) => {
      if (err) { res.writeHead(404); res.end(); return; }
      res.writeHead(200, { 'Content-Type': TYPES[path.extname(file).toLowerCase()] || 'application/octet-stream' });
      res.end(data);
    });
  });
  return new Promise(resolve => server.listen(0, '127.0.0.1', () => resolve(server)));
}

const plural = (n, one, few, many) =>
  n % 10 === 1 && n % 100 !== 11 ? one : n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 12 || n % 100 > 14) ? few : many;

// построчное сравнение (наибольшая общая подпоследовательность) — показывает только отличия
function diff(expected, actual) {
  const a = expected, b = actual, n = a.length, m = b.length;
  const dp = Array.from({ length: n + 1 }, () => new Array(m + 1).fill(0));
  for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--) {
    dp[i][j] = a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
  }
  const out = [];
  let i = 0, j = 0;
  while (i < n || j < m) {
    if (i < n && j < m && a[i] === b[j]) { i++; j++; }
    else if (i < n && (j === m || dp[i + 1][j] >= dp[i][j + 1])) out.push(`- ${a[i++]}`);
    else out.push(`+ ${b[j++]}`);
  }
  return out;
}

if (process.argv.includes('--self-test')) {
  const d = diff(['a', 'b', 'c', 'd'], ['a', 'x', 'c', 'd', 'e']);
  console.log(d.join('\n'));
  process.exit(JSON.stringify(d) === JSON.stringify(['- b', '+ x', '+ e']) ? 0 : 1);
}

(async () => {
  let chromium;
  try { ({ chromium } = require('playwright')); } catch {
    fail('нет Playwright. установите: npm install --no-save playwright@1.56.0 && npx playwright install chromium');
  }
  const projectId = (fs.readFileSync(path.join(ROOT, 'supabase', 'config.toml'), 'utf8').match(/^project_id\s*=\s*"([^"]+)"/m) || [])[1];
  if (!projectId) fail('в supabase/config.toml нет project_id');

  say('чистая локальная база (supabase db reset --local)');
  localEnv();
  try { supabase('db reset --local'); } catch (e) { fail(`db reset не удался:\n${e.stderr || e.message}`); }
  const env = localEnv();

  say('тестовые игроки');
  for (const [email, nick] of USERS) await createUser(env, email, nick);
  sql(projectId, "update public.profiles set is_admin=(display_name='Админ Тест'), school_verified=true;");

  say('копия сайта');
  const site = buildSite(env);
  const server = await serve(site);
  const base = `http://127.0.0.1:${server.address().port}/index.html`;

  say(`сценарий в браузере: ${base}`);
  const scenario = require('./scenario.cjs');
  const { lines, errors, rpc } = await scenario({ chromium, base, password: PASSWORD });
  server.close();
  fs.rmSync(site, { recursive: true, force: true });

  fs.mkdirSync(OUT, { recursive: true });
  const actual = lines.join('\n') + '\n';
  fs.writeFileSync(path.join(OUT, 'actual.log'), actual);
  fs.writeFileSync(path.join(OUT, 'rpc-calls.txt'), [...rpc].map(([who, n]) => `${who}: ${n}`).join('\n') + '\n');
  if (errors.length) console.log('\nошибки на страницах:\n' + errors.map(e => '  ' + e).join('\n'));

  const stopped = lines.some(l => l.startsWith('СЦЕНАРИЙ ОСТАНОВИЛСЯ'));
  if (stopped || errors.length) fail('сценарий не прошёл до конца или на страницах были ошибки (см. выше и out/actual.log)');

  if (UPDATE) {
    fs.writeFileSync(EXPECTED, actual);
    console.log(`\n✓ эталон обновлён: ${path.relative(ROOT, EXPECTED)} — проверьте изменения в git diff перед коммитом`);
    return;
  }
  const expected = fs.existsSync(EXPECTED) ? fs.readFileSync(EXPECTED, 'utf8') : '';
  if (expected === actual) { console.log(`\n✓ всё как в эталоне (${lines.length} ${plural(lines.length, 'наблюдение', 'наблюдения', 'наблюдений')})`); return; }
  console.log('\nотличия от эталона (- ожидалось, + получилось):');
  for (const l of diff(expected.split('\n'), actual.split('\n'))) console.log('  ' + l);
  fail('сайт ведёт себя не так, как в эталоне. если изменение задумано — запустите с --update и закоммитьте expected.log');
})().catch(e => fail(e.stack || e.message));
