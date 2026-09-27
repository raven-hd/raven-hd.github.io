// Браузерный сценарий «Фруктового боя»: проходит сайт так, как это сделали бы люди,
// и записывает, что они видят. Каждая строка журнала — одно наблюдение.
// Сам по себе не запускается: базу и сайт готовит run.cjs, он же сравнивает журнал с expected.log.
//
// Жребий (кто ходит первым, кто получает свободный проход) каждый раз разный, поэтому
// в журнал пишутся не имена, а роли: «ПЕРВЫЙ», «БЕЗ ИГРЫ» и т.п.

const PLAYERS = [
  { name: 'Игрок Альфа', email: 'p1@fruit.local' },
  { name: 'Игрок Бета', email: 'p2@fruit.local' },
  { name: 'Игрок Гамма', email: 'p3@fruit.local' },
];
const ADMIN_EMAIL = 'admin@fruit.local';
const FLEET_STARTS = ['A1', 'F1', 'A3', 'E3', 'H3', 'A5', 'D5', 'F5', 'H5', 'J5'];

module.exports = async function scenario({ chromium, base, password }) {
  const lines = [];
  const errors = [];
  const rpc = new Map();
  const matchRoles = new Map();      // имя → роль в обычном матче
  const cupRoles = new Map();        // имя → роль в турнире

  const norm = (t, roles) => {
    let s = String(t ?? '').replace(/\s+/g, ' ').trim();
    if (roles) for (const [name, role] of roles) s = s.split(name).join(role);
    return s.replace(/\d{2}\.\d{2}\.\d{4}(, \d{2}:\d{2})?/g, '<дата>').replace(/\b\d{1,2}:\d{2}\b/g, '<время>')
            .replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/g, '<id>');
  };
  const write = (step, value, roles) => { const l = `${step}: ${norm(value, roles)}`; lines.push(l); console.log(l); };
  const log = (step, value) => write(step, value, matchRoles);
  const logCup = (step, value) => write(step, value, cupRoles);
  const logRaw = (step, value) => write(step, value, null);

  function watch(page, who) {
    page.on('pageerror', e => errors.push(`[${who}] ${e.message}`));
    page.on('console', m => {
      if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push(`[${who}] console: ${m.text().slice(0, 160)}`);
    });
    page.on('dialog', d => d.accept());
    page.on('request', r => { if (/\/rest\/v1\/rpc\//.test(r.url())) rpc.set(who, (rpc.get(who) || 0) + 1); });
  }
  const goView = (page, v) => page.click(v === 'home' ? '.brand-link' : `.main-nav [data-view="${v}"]`);
  const visibleView = page => page.evaluate(() => document.body.dataset.view);
  const text = (page, sel) => page.$eval(sel, n => n.innerText).catch(() => '<нет>');
  // действие, после которого страница загружает данные: ждём ответ нужной серверной функции,
  // а не фиксированную паузу — иначе на медленной машине можно прочитать старые данные
  async function afterRpc(page, rpcName, action) {
    const response = page.waitForResponse(r => r.url().includes(`/rest/v1/rpc/${rpcName}`), { timeout: 20000 });
    await action();
    await response;
    await page.waitForTimeout(150);   // ответ пришёл — даём странице его отрисовать
  }
  const turnIs = (page, re) => page.waitForFunction(
    r => new RegExp(r).test(document.getElementById('turnTitle')?.textContent || ''), re.source, { timeout: 30000 });

  const browser = await chromium.launch();
  async function newPage(who) {
    const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 } });
    const page = await ctx.newPage(); watch(page, who); return page;
  }
  async function login(page, email) {
    await page.goto(base + '?view=play', { waitUntil: 'networkidle' });
    await page.waitForSelector('#needAuthBtn', { state: 'visible', timeout: 20000 });
    await page.click('#needAuthBtn'); await page.click('#loginTab');
    await page.fill('#loginEmail', email); await page.fill('#loginPassword', password);
    await page.click('#loginBtn');
    await page.waitForFunction(() => !document.getElementById('authDialog').open, null, { timeout: 20000 });
    await page.waitForSelector('.account-name', { timeout: 20000 });
    await page.waitForLoadState('networkidle');
  }
  async function placeFleetAndReady(page) {
    await page.waitForSelector('#placementBoard .board-cell', { state: 'visible', timeout: 30000 });
    for (const cell of FLEET_STARTS) await page.click(`#placementBoard [data-cell="${cell}"]`);
    const counter = await text(page, '#placementCounter');
    await page.click('#readyBtn');
    return counter;
  }
  // турнирный матч: оба входят по кнопке «войти в матч» и расставляют флот — начинается бой
  async function startCupMatch(...pages) {
    for (const page of pages) {
      await page.goto(base + '?view=tournament', { waitUntil: 'networkidle' });
      const enter = page.locator('.tournament-match-action', { hasText: 'войти в матч' }).first();
      await enter.waitFor({ timeout: 20000 });
      await enter.click();
      await page.waitForFunction(() => document.body.dataset.view === 'game', null, { timeout: 20000 });
      await placeFleetAndReady(page);
    }
    await Promise.all(pages.map(page => turnIs(page, /ваш ход|ходит/)));
  }
  // loser сдаётся; возвращает, что видят оба
  async function surrenderCupMatch(winner, loser) {
    await loser.click('#surrenderGameBtn');
    await turnIs(loser, /победил/); await turnIs(winner, /вы победили/);
    return [`${await loser.textContent('#turnTitle')} · ${await loser.textContent('#battleBadge')}`,
            `${await winner.textContent('#turnTitle')} · ${await winner.textContent('#battleBadge')}`];
  }

  try {
    // 1. аноним: разделы, подсказки, рейтинг
    const anon = await newPage('аноним');
    await anon.goto(base, { waitUntil: 'networkidle' });
    for (const v of ['play', 'rating', 'tournament', 'home']) {
      await goView(anon, v); await anon.waitForLoadState('networkidle');
      logRaw(`аноним → ${v}`, await visibleView(anon));
    }
    logRaw('аноним, подсказки', await anon.$$eval('[data-setting-text]', ns => ns.map(n => n.textContent).join(' | ')));
    await afterRpc(anon, 'get_leaderboard', () => goView(anon, 'rating'));
    logRaw('аноним, строк рейтинга', await anon.$$eval('#ratingRows > *', ns => ns.length));

    // 2. демо-турнир: шесть состояний страницы без записи в базу
    const demo = await newPage('демо');
    await demo.goto(base + '?tournament-demo=1', { waitUntil: 'networkidle' });
    logRaw('демо, раздел', await visibleView(demo));
    for (const st of await demo.$$eval('[data-tournament-demo]', ns => ns.map(n => n.dataset.tournamentDemo))) {
      await demo.click(`[data-tournament-demo="${st}"]`); await demo.waitForTimeout(250);
      const facts = await demo.evaluate(() => {
        const visible = el => el && !el.closest('.hidden');
        const winner = document.getElementById('tournamentWinnerName');
        return [
          `матчей в сетке ${document.querySelectorAll('#tournamentView .tournament-match').length}`,
          `строк в таблице ${document.querySelectorAll('#tournamentPlayers > *').length}`,
          `статус «${visible(document.getElementById('tournamentStatusBadge')) ? document.getElementById('tournamentStatusBadge').textContent : '—'}»`,
          `победитель «${visible(winner) ? winner.textContent : '—'}»`,
        ].join(', ');
      });
      logRaw(`демо «${st}»`, facts);
    }

    // 3. гость
    const guest = await newPage('гость');
    await guest.goto(base + '?view=play', { waitUntil: 'networkidle' });
    await guest.waitForSelector('#needAuthBtn', { state: 'visible' });
    await guest.click('#needAuthBtn'); await guest.click('#guestTab'); await guest.click('#guestBtn');
    await guest.waitForSelector('.account-name', { timeout: 20000 }); await guest.waitForLoadState('networkidle');
    const guestName = norm(await text(guest, '.account-name'));
    logRaw('гость, имя из двух слов', /^\S+ \S+$/.test(guestName) ? 'да' : guestName);
    logRaw('гость, рейтинговый режим недоступен', await guest.$eval('#ratedGameMode', n => n.disabled));

    // 4. обычный рейтинговый матч двух игроков
    const A = await newPage('игрок А'); const B = await newPage('игрок Б');
    await login(A, PLAYERS[0].email); await login(B, PLAYERS[1].email);
    logRaw('А, рейтинговый режим выбран', await A.$eval('#ratedGameMode', n => n.checked && !n.disabled));
    await A.click('#createGameBtn');
    await A.waitForFunction(() => document.body.dataset.view === 'game', null, { timeout: 20000 });
    logRaw('А создал игру → раздел', await visibleView(A));
    await goView(B, 'play'); await B.waitForLoadState('networkidle');
    await B.click('#refreshGamesBtn'); await B.waitForTimeout(800);
    const row = B.locator('#activeGames .open-game', { hasText: PLAYERS[0].name });
    await row.getByRole('button', { name: 'присоединиться' }).click();
    await B.waitForFunction(() => document.body.dataset.view === 'game', null, { timeout: 20000 });
    for (const [page, who] of [[A, 'А'], [B, 'Б']]) logRaw(`${who}, расстановка`, await placeFleetAndReady(page));
    await Promise.all([turnIs(A, /ваш ход|ходит/), turnIs(B, /ваш ход|ходит/)]);
    const aFirst = (await A.textContent('#turnTitle')) === 'ваш ход';
    const [P1, P2] = aFirst ? [A, B] : [B, A];
    matchRoles.set(aFirst ? PLAYERS[0].name : PLAYERS[1].name, 'ПЕРВЫЙ');
    matchRoles.set(aFirst ? PLAYERS[1].name : PLAYERS[0].name, 'ВТОРОЙ');
    log('бой начался: ход первого / второго', `${await P1.textContent('#turnTitle')} / ${await P2.textContent('#turnTitle')}`);
    await P1.click('#enemyBoard [data-cell="A1"]');
    await P1.waitForFunction(() => document.querySelectorAll('#shotLog > *').length >= 1, null, { timeout: 20000 });
    log('первый: попадание, ход', await P1.textContent('#turnTitle'));
    await P1.click('#enemyBoard [data-cell="J10"]');
    await turnIs(P1, /^ходит/);
    log('первый: промах, ход', await P1.textContent('#turnTitle'));
    await turnIs(P2, /^ваш ход$/);
    log('второй получил ход (realtime)', await P2.textContent('#turnTitle'));
    await P2.click('#surrenderGameBtn');
    await turnIs(P2, /победил/); await turnIs(P1, /вы победили/);
    log('второй после сдачи', `${await P2.textContent('#turnTitle')} · ${await P2.textContent('#battleBadge')}`);
    log('первый после сдачи', `${await P1.textContent('#turnTitle')} · ${await P1.textContent('#battleBadge')}`);
    log('журнал выстрелов у первого / второго', `${await P1.$$eval('#shotLog > *', n => n.length)} / ${await P2.$$eval('#shotLog > *', n => n.length)}`);

    // 5. история, рейтинг, профиль, выход
    await afterRpc(P1, 'list_match_history', () => P1.click('#backLobbyBtn'));
    log('первый вернулся → раздел', await visibleView(P1));
    const hist = await P1.$$eval('#matchHistory > *', ns => ns[0] ? [ns[0].querySelector('strong')?.textContent, ns[0].querySelector('span')?.textContent] : ['<пусто>', '']);
    logRaw('история матчей, пара (создатель — соперник)', hist[0]);
    log('история матчей, итог', hist[1]);
    await afterRpc(P1, 'get_leaderboard', () => goView(P1, 'rating'));
    log('рейтинг, первые строки', await P1.$$eval('#ratingRows > *', ns => ns.slice(0, 3).map(n => n.innerText.replace(/\s+/g, ' ')).join(' || ')));
    await P1.click('.account-name');
    log('профиль открыт', await P1.$eval('#profileDialog', d => d.open));
    log('имя в профиле', await text(P1, '#profileName'));
    await afterRpc(P1, 'get_public_player_profile', () => P1.click('#openPlayerProfileBtn'));
    log('публичный профиль, статистика', await text(P1, '#publicProfileStats'));
    await P1.keyboard.press('Escape'); await P1.waitForTimeout(300);
    await P1.click('.account-name'); await P1.click('#logoutBtn');
    await P1.waitForFunction(() => !document.querySelector('.account-name'), null, { timeout: 20000 });
    log('после выхода в шапке', await text(P1, '#accountSlot'));

    // 6. админка
    const AD = await newPage('админ');
    await login(AD, ADMIN_EMAIL);
    await AD.click('#adminNavBtn'); await AD.waitForSelector('#adminGameSettings .admin-setting', { timeout: 20000 });
    await AD.waitForLoadState('networkidle');
    logRaw('админ, игроков в списке', await text(AD, '#adminPlayersCount'));
    await AD.click('[data-admin-game-filter="finished"]'); await AD.waitForLoadState('networkidle'); await AD.waitForTimeout(600);
    logRaw('админ, завершённых матчей', await text(AD, '#adminGamesCount'));
    await AD.click('#adminGames button >> nth=0');
    await AD.waitForFunction(() => document.getElementById('adminGameDialog').open, null, { timeout: 20000 }).catch(() => {});
    logRaw('админ, карточка матча открыта', await AD.$eval('#adminGameDialog', d => d.open));
    await AD.click('#adminCloseDialogBtn');
    await AD.click('#adminSecurityAuditBtn');
    await AD.waitForFunction(() => /пройдены|исправить/.test(document.getElementById('adminSecurityAuditMessage').textContent), null, { timeout: 20000 });
    logRaw('админ, проверка защиты', await text(AD, '#adminSecurityAuditMessage'));
    logRaw('админ, настроек баланса', await AD.$$eval('#adminGameSettings .admin-setting', n => n.length));
    await AD.click('#adminNotificationBtn'); await AD.waitForTimeout(300);
    logRaw('админ, колокольчик открыт', await AD.$eval('#adminNotificationShell', n => !n.classList.contains('hidden')));
    await AD.click('#adminNotificationBtn'); await AD.waitForTimeout(200);

    // 7. турнир «плей-офф» на троих: сетка на 4, один участник проходит первый раунд без игры
    await AD.fill('#adminTournamentName', 'Кубок Проверки');
    await AD.fill('#adminTournamentMaxPlayers', '4');
    await AD.click('label:has(#knockoutTournamentFormat)');
    logRaw('турнир: выбран формат плей-офф', await AD.$eval('#knockoutTournamentFormat', n => n.checked));
    await AD.click('#adminCreateTournamentBtn');
    await AD.waitForFunction(() => document.getElementById('adminTournamentDialog').open
      && document.getElementById('adminTournamentTitle').textContent === 'Кубок Проверки'
      && /создан/.test(document.getElementById('adminMessage').textContent), null, { timeout: 20000 });
    logRaw('турнир: сообщение админу', await text(AD, '#adminMessage'));
    logRaw('турнир: статус · сведения', `${await text(AD, '#adminTournamentStatus')} · ${await text(AD, '#adminTournamentMeta')}`);
    await AD.click('#adminTournamentDialog .dialog-close button');

    const cup = {};
    for (const { name, email } of PLAYERS) {
      const page = await newPage(`турнир: ${name}`); cup[name] = page;
      await login(page, email);
      await goView(page, 'tournament'); await page.waitForLoadState('networkidle');
      await page.waitForFunction(() => document.getElementById('tournamentApplicationBtn')?.dataset.action === 'apply', null, { timeout: 20000 });
      await page.click('#tournamentApplicationBtn');
      await page.waitForFunction(() => /отправлена|ошибк|не удалось/.test(document.getElementById('tournamentApplicationMessage').textContent), null, { timeout: 20000 });
      const shown = await page.waitForFunction(() => document.getElementById('tournamentApplicationBtn').dataset.action === 'withdraw', null, { timeout: 3000 }).then(() => true, () => false);
      logRaw(`турнир, ${name}: заявка`, `${await text(page, '#tournamentApplicationMessage')} · ${await text(page, '#tournamentApplicationText')} · страница показала заявку: ${shown}`);
    }

    await AD.locator('#adminTournaments button', { hasText: 'управлять' }).first().click();
    await AD.waitForFunction(() => document.querySelectorAll('#adminTournamentApplications button.primary').length === 3, null, { timeout: 20000 });
    for (let left = 2; left >= 0; left--) {
      await AD.locator('#adminTournamentApplications button', { hasText: 'одобрить' }).first().click();
      await AD.waitForFunction(n => document.querySelectorAll('#adminTournamentApplications button.primary').length === n
        && /одобрена/.test(document.getElementById('adminTournamentMessage').textContent), left, { timeout: 20000 });
    }
    logRaw('турнир: состав', `${await text(AD, '#adminTournamentMembersCount')} · ${(await AD.$$eval('#adminTournamentPlayers strong', n => n.map(x => x.textContent).sort())).join(', ')}`);
    logRaw('турнир: подсказка админу', await text(AD, '#adminTournamentHint'));
    await AD.click('#adminGenerateTournamentBtn');
    await AD.waitForFunction(() => /жеребьевка проведена|ошибк/.test(document.getElementById('adminTournamentMessage').textContent), null, { timeout: 20000 });
    logRaw('турнир: жеребьёвка', `${await text(AD, '#adminTournamentMessage')} · статус ${await text(AD, '#adminTournamentStatus')}`);
    await AD.click('#adminTournamentDialog .dialog-close button');

    // кто получил свободный проход, решил жребий: у него нет кнопки «войти в матч»
    const buttons = {};
    for (const { name } of PLAYERS) {
      const page = cup[name];
      await page.goto(base + '?view=tournament', { waitUntil: 'networkidle' });
      await page.waitForFunction(() => /идет/.test(document.getElementById('tournamentStatusBadge')?.textContent || ''), null, { timeout: 20000 });
      buttons[name] = await page.locator('.tournament-match-action', { hasText: 'войти в матч' }).count();
    }
    const byeName = PLAYERS.map(p => p.name).find(n => buttons[n] === 0);
    const semi = PLAYERS.map(p => p.name).filter(n => n !== byeName).sort();
    if (!byeName || semi.length !== 2) throw new Error(`не удалось определить свободный проход: ${JSON.stringify(buttons)}`);
    cupRoles.set(byeName, 'БЕЗ ИГРЫ').set(semi[0], 'ПОЛУФИНАЛИСТ 1').set(semi[1], 'ПОЛУФИНАЛИСТ 2');
    logCup('турнир: кнопок «войти в матч» у без игры / П1 / П2', `${buttons[byeName]} / ${buttons[semi[0]]} / ${buttons[semi[1]]}`);
    const byePage = cup[byeName];
    logCup('турнир: сетка', `матчей ${await byePage.locator('#tournamentBracket .tournament-match').count()} · свободных проходов ${await byePage.locator('#tournamentBracket .tournament-match-player.bye').count()}`);
    logCup('турнир: пара со свободным проходом', await byePage.$$eval('#tournamentBracket .tournament-match', ns => {
      const card = ns.find(n => n.querySelector('.bye')); return card ? card.innerText : '<нет>';
    }));
    logCup('турнир: финал до полуфинала', await byePage.$$eval('#tournamentBracket .tournament-round.is-final .tournament-match', ns => ns.map(n => n.innerText).join(' | ')));

    // порядок игроков внутри пары решает жребий посева — сравниваем без учёта порядка (по ролям)
    const roleSorted = items => items.map(x => norm(x, cupRoles)).sort().join(' / ');
    // что админ видит в разделе «незавершенные матчи»
    const adminMatches = async () => {
      const rows = await AD.$$eval('#adminTournamentMatches .admin-tournament-match', ns => ns.map(n => ({
        pair: n.querySelector('strong').textContent.split(' — '),
        note: n.querySelector('small').textContent,
        buttons: [...n.querySelectorAll('button')].map(b => b.textContent),
      })));
      return rows.map(r => `${roleSorted(r.pair)} (${norm(r.note, cupRoles)}) [${roleSorted(r.buttons)}]`).join(' || ') || '<пусто>';
    };
    const adminMessage = re => AD.waitForFunction(r => new RegExp(r).test(document.getElementById('adminTournamentMessage').textContent),
      re.source, { timeout: 20000 });

    // полуфинал сорвался: бой уже идёт, админ засчитывает техпобеду ПОЛУФИНАЛИСТУ 2
    await startCupMatch(cup[semi[0]], cup[semi[1]]);
    await AD.locator('#adminTournaments button', { hasText: 'управлять' }).first().click();
    await AD.waitForFunction(() => document.getElementById('adminTournamentDialog').open && !/загружаем/.test(document.getElementById('adminTournamentMessage').textContent), null, { timeout: 20000 });
    logCup('турнир: админ, незавершенные матчи', await adminMatches());
    await AD.locator('#adminTournamentMatches button', { hasText: `победа: ${semi[1]}` }).click();
    await adminMessage(/засчитана|ошибк|не удалось|нельзя/);
    logCup('турнир: техпобеда', await text(AD, '#adminTournamentMessage'));
    logCup('турнир: админ, после техпобеды', await adminMatches());
    for (const name of semi) {
      await cup[name].waitForFunction(() => /техническую победу/.test(document.getElementById('roomMessage')?.textContent || ''), null, { timeout: 20000 });
    }
    logCup('турнир: у игроков полуфинала', await text(cup[semi[0]], '#roomMessage'));

    // финал: бой начался, админ назначает переигровку — игроки получают новую комнату
    await startCupMatch(byePage, cup[semi[1]]);
    await AD.locator('#adminTournamentMatches button', { hasText: 'переигровка' }).click();
    await adminMessage(/переигровка назначена|ошибк|не удалось|нельзя/);
    logCup('турнир: переигровка', await text(AD, '#adminTournamentMessage'));
    logCup('турнир: админ, после переигровки', await adminMatches());
    await AD.click('#adminTournamentDialog .dialog-close button');
    await byePage.waitForFunction(() => /переигровку/.test(document.getElementById('roomMessage')?.textContent || ''), null, { timeout: 20000 });
    logCup('турнир: у финалистов', await text(byePage, '#roomMessage'));
    await byePage.goto(base + '?view=tournament', { waitUntil: 'networkidle' });
    logCup('турнир: активные матчи', await byePage.$$eval('#tournamentQualifiers .tournament-match-row', ns => ns.map(n => n.innerText.replace(/\s+/g, ' ')).join(' || ')));
    const cards = await byePage.$$eval('#tournamentBracket .tournament-match', ns => ns.map(n => [...n.querySelectorAll('.tournament-match-player')].map(l => l.textContent)));
    logCup('турнир: сетка после техпобеды', cards.map(lines => roleSorted(lines)).join(' | '));

    // переигранный финал: ПОЛУФИНАЛИСТ 2 сдаётся
    await startCupMatch(byePage, cup[semi[1]]);
    const [finalLoser, finalWinner] = await surrenderCupMatch(byePage, cup[semi[1]]);
    logCup('турнир: финал, у сдавшегося', finalLoser);
    logCup('турнир: финал, у победителя', finalWinner);

    await byePage.goto(base + '?view=tournament', { waitUntil: 'networkidle' });
    await byePage.waitForFunction(() => /завершен/.test(document.getElementById('tournamentStatusBadge')?.textContent || ''), null, { timeout: 20000 });
    logCup('турнир: итог', `статус ${await text(byePage, '#tournamentStatusBadge')} · победитель ${await text(byePage, '#tournamentWinnerName')}`);
    logCup('турнир: таблица результатов', await byePage.$$eval('#tournamentPlayers .tournament-result-row:not(.tournament-participant-head)', ns => ns.map(n => n.innerText.replace(/\s+/g, ' ')).join(' || ')));
    await afterRpc(byePage, 'list_match_history', () => goView(byePage, 'play'));
    logCup('турнир: история у победителя', await byePage.$$eval('#matchHistory > *', ns => ns[0]?.querySelector('span')?.textContent || '<пусто>'));
    await AD.locator('#adminTournaments button', { hasText: 'управлять' }).first().click();
    await AD.waitForFunction(() => document.getElementById('adminTournamentDialog').open && !/загружаем/.test(document.getElementById('adminTournamentMessage').textContent), null, { timeout: 20000 });
    logCup('турнир: у админа после финала', `статус ${await text(AD, '#adminTournamentStatus')} · кнопка «${await text(AD, '#adminCloseTournamentBtn')}» · раздел матчей скрыт ${await AD.$eval('#adminTournamentMatchesSection', n => n.classList.contains('hidden'))}`);
  } catch (e) {
    logRaw('СЦЕНАРИЙ ОСТАНОВИЛСЯ', e.message.split('\n')[0]);
  } finally {
    logRaw('ошибок на страницах', errors.length);
    await browser.close();
  }
  return { lines, errors, rpc };
};
