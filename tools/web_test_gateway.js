// Temporary same-origin Web + WebSocket gateway for a single private test room.
// No dependencies: node tools/web_test_gateway.js
const http = require('node:http');
const net = require('node:net');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');
const { loadMusic } = require('./room_music');
const { serveMusicFile } = require('./music_file_http');

const webRoot = process.env.ARENA_WEB_ROOT
  ? path.resolve(process.env.ARENA_WEB_ROOT)
  : path.resolve(__dirname, '..', 'web_export');
let music = null;
try { music = loadMusic(process.env); }
catch (error) { console.warn(`ROOM_MUSIC_DISABLED ${error.message}`); }
const invite = process.env.ARENA_INVITE_TOKEN || '';
// Explicit opt-in for isolated A/B seams (?solo= / ?seed=). Off by default:
// a normal gateway neither forwards these params nor injects the flag.
const allowTestSeams = process.env.ARENA_ALLOW_TEST_SEAMS === '1';
const sessionCookieName = process.env.ARENA_LOCAL_MUSIC_TEST === '1' ? 'arena_music_test_session' : 'arena_session';
const port = Number(process.env.ARENA_HTTP_PORT || 8787);
// 房间池：一个网关对应多个宿主实例，每个实例一桌。逗号分隔，默认 4 桌。
const gamePorts = String(process.env.ARENA_GAME_PORTS || process.env.ARENA_GAME_PORT || '9082,9083,9084,9085')
  .split(',').map(v => Number(v.trim())).filter(v => Number.isInteger(v) && v > 0);
const gamePort = gamePorts[0] || 9082; // 兼容未带 room 参数的旧连接
const bindHost = process.env.ARENA_BIND_HOST || '127.0.0.1';
if (invite.length < 24 || !Number.isInteger(port) || gamePorts.length === 0) {
  throw new Error('A random ARENA_INVITE_TOKEN (24+ characters) and valid ports are required.');
}
// 房间号：6 位，剔除 0/O/1/I/L 这些口述和手抄容易混的字符
const CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
function makeRoomCode(taken) {
  let code = '';
  do {
    code = Array.from({ length: 6 }, () => CODE_ALPHABET[crypto.randomInt(CODE_ALPHABET.length)]).join('');
  } while (taken.has(code));
  return code;
}
const rooms = [];
// 对局内聊天的图片/动图：只存在网关内存里，跟着房间一起回收。
// 单张上限 2MB、每房最多 24 张、30 分钟过期——私人试玩够用，不占任何云存储。
const ATTACH_MAX_BYTES = 2 * 1024 * 1024;
const ATTACH_MAX_PER_ROOM = 24;
const ATTACH_TTL_MS = 30 * 60 * 1000;

// 按文件头判真实类型，绝不信任客户端给的 Content-Type
function sniffImage(buf) {
  if (!buf || buf.length < 4) return '';
  if (buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return 'image/jpeg';
  if (buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47) return 'image/png';
  if (buf[0] === 0x47 && buf[1] === 0x49 && buf[2] === 0x46 && buf[3] === 0x38) return 'image/gif';
  return '';
}

// 附件只对"当前有连接在这间房"的人开放：光知道房间号不够
function roomByAttach(id) {
  for (const room of rooms) {
    if (room.attachments && room.attachments.has(id)) return room;
  }
  return null;
}
// 端口池与实例管理：房间按需创建，进程按需 spawn，空房间 60 秒后回收。
// 常驻只保留 1 个"备胎"实例，让第一次建房也是 0 延迟。
const PORT_POOL = gamePorts;
const hostProcesses = new Map(); // port -> ChildProcess
const godotBin = process.env.ARENA_GODOT_BIN
  || path.resolve(__dirname, 'godot', 'Godot_v4.7.2-stable_win64_console.exe');
const projectDir = path.resolve(__dirname, '..', 'prototype');

function sendMusicChat(child, notices) {
  const feed = child.musicChatFeed;
  if (feed?.readyState === 1) feed.send(JSON.stringify(notices));
}

function createRoomMusic(child) {
  return music?.createRoom(child.musicKey, notices => sendMusicChat(child, notices));
}

// --- Solo room music ---
// Solo mode never claims a game room, so there is no host to sign a music_ticket.
// The gateway opens a music room that belongs to this browser only: the code is
// prefixed with SOLO-, the ticket is signed with a one-off key, and ownerToken is
// handed out directly (a solo player is always the host, so skip/clear work).
// The `rooms` array and /api/rooms* stay untouched, so the lobby never lists it.
const soloMusic = new Map();
const SOLO_MUSIC_TTL_MS = 30 * 60 * 1000;
// The TTL alone would let a client that POSTs in a loop grow the table unbounded.
const SOLO_MUSIC_LIMIT = 12;

function sweepSoloMusic() {
  const nowMs = Date.now();
  for (const [code, entry] of soloMusic) {
    if (nowMs - entry.usedAt < SOLO_MUSIC_TTL_MS) continue;
    entry.room.dispose();
    soloMusic.delete(code);
    console.log(`SOLO_MUSIC_EXPIRE room=${code}`);
  }
}

function createSoloMusic(name) {
  if (!music) return null;
  sweepSoloMusic();
  // Evict the least recently used solo room once the table is full.
  while (soloMusic.size >= SOLO_MUSIC_LIMIT) {
    let oldest = null;
    for (const entry of soloMusic) {
      if (!oldest || entry[1].usedAt < oldest[1].usedAt) oldest = entry;
    }
    if (!oldest) break;
    oldest[1].room.dispose();
    soloMusic.delete(oldest[0]);
    console.log(`SOLO_MUSIC_EVICT room=${oldest[0]}`);
  }
  const code = `SOLO-${crypto.randomBytes(6).toString('hex').toUpperCase()}`;
  const key = crypto.randomBytes(32);
  const room = music.createRoom(key, () => {});
  const connection = room.attachGame();
  // The ticket body must match room_music.js verifyTicket: <hex body>.<hex hmac>
  const body = Buffer.from(JSON.stringify({ connection, player: `solo:${code}`, name }));
  const ticket = `${body.toString('hex')}.${crypto.createHmac('sha256', key).update(body).digest('hex')}`;
  soloMusic.set(code, { room, usedAt: Date.now() });
  console.log(`SOLO_MUSIC_CREATE room=${code}`);
  return { code, ticket, owner: room.ownerToken };
}

function freePort() {
  return PORT_POOL.find(p => !hostProcesses.has(p));
}

function spawnHost(hostPort) {
  if (hostProcesses.has(hostPort)) return hostProcesses.get(hostPort);
  let child;
  const musicKey = music ? crypto.randomBytes(32) : null;
  // 权威房间服把模式/阶段/座位/介绍推回大厅时用的一次性凭据。
  // 只存在网关内存里，客户端拿不到，也就无法伪造房间状态。
  const metaKey = crypto.randomBytes(16).toString('hex');
  try {
    child = spawn(godotBin, [
      '--headless', '--path', projectDir,
      '--script', 'res://scripts/network/LanMatchHost.gd', '--',
      `--port=${hostPort}`, '--bind=127.0.0.1', `--session=r${hostPort}`,
    ], { windowsHide: true, stdio: 'ignore', env: {
      ...process.env, ARENA_INTERNAL_MUSIC_KEY: musicKey?.toString('hex') || '',
      ARENA_INTERNAL_MUSIC_URL: musicKey ? `ws://127.0.0.1:${port}/internal/music-chat?host_port=${hostPort}` : '',
      ARENA_ROOM_META_URL: `http://127.0.0.1:${port}/internal/room-meta?host_port=${hostPort}`,
      ARENA_ROOM_META_KEY: metaKey,
    } });
  } catch (error) {
    console.warn(`HOST_SPAWN_FAIL port=${hostPort} ${error.message}`);
    return null;
  }
  hostProcesses.set(hostPort, child);
  child.musicKey = musicKey;
  child.metaKey = metaKey;
  // Godot 从进程启动到绑定端口约需 1.2~1.5 秒；这之后被 claim 就不必再等
  setTimeout(() => { child.godotReady = true; }, 1500);
  const releaseHost = () => {
    if (hostProcesses.get(hostPort) !== child) return;
    hostProcesses.delete(hostPort);
    child.musicChatFeed?.terminate();
    // 实例意外退出时把对应房间一起摘掉，避免列表里挂着进不去的房间
    const idx = rooms.findIndex(r => r.port === hostPort);
    if (idx >= 0) {
      rooms[idx].music?.dispose();
      rooms.splice(idx, 1);
    } else {
      // A reaped room is already removed. Reuse its port only after the old host exits.
      ensureSpare();
    }
  };
  child.once('exit', releaseHost);
  child.once('error', error => {
    console.warn(`HOST_SPAWN_FAIL port=${hostPort} ${error.message}`);
    releaseHost();
  });
  console.log(`HOST_SPAWN port=${hostPort}`);
  return child;
}

function makeCode() {
  return makeRoomCode(new Set(rooms.map(r => r.code)));
}

// 保证至少有 1 个没人且没被占用的空桌（备胎）
function ensureSpare() {
  const idle = rooms.filter(r => r.players === 0 && !r.claimedAt);
  if (idle.length > 0) return true;
  const port = freePort();
  if (port === undefined) return false;
  const child = spawnHost(port);
  if (!child) return false;
  rooms.push({ code: makeCode(), port, host: '', players: 0, createdAt: 0, claimedAt: 0, lastActiveAt: 0, live: 0,
    attachments: new Map(), music: createRoomMusic(child) });
  return true;
}

// 进程退出时把拉起的实例一起收掉，别留孤儿进程
process.on('exit', () => {
  for (const child of hostProcesses.values()) {
    try { child.kill(); } catch { /* ignore */ }
  }
});

// 全员离线的房间保留多久。必须 >= host 端的 ROOM_RECONNECT_GRACE(90s)，
// 否则网关先把 host 进程杀了，那边留着的座位就白留了，掉线的人回来只会 404。
const ROOM_EMPTY_GRACE_MS = 90000;
// 刚 claim 的保护期：房主从建房成功到 WS 连上有 200~1500ms 的 players=0，
// 这段时间不能按空房算，否则房主还没进来桌子就被杀了。
const ROOM_CLAIM_PROTECT_MS = 8000;

setInterval(() => {
  const nowMs = Date.now();
  // Solo music rooms are not in `rooms`, so they need their own sweep. Piggyback on
  // this reaper: otherwise a room only expires when someone opens another solo match.
  sweepSoloMusic();
  for (let i = rooms.length - 1; i >= 0; i -= 1) {
    const room = rooms[i];
    if (!room.claimedAt) continue; // 备胎：任何情况下都不回收
    // 只要还有一个人在，房间就绝不关：局中有人掉线、其他人继续打，掉线者要能重连回来。
    if (room.players > 0) {
      // 有人退出后其他人还在玩，这次"全员离开"的标记已经过期；
      // 不清掉的话，剩下的人之后再掉线会被立即回收，等不到重连。
      if (room.pendingAbandonAt) room.pendingAbandonAt = 0;
      continue;
    }
    const claimedFor = nowMs - Number(room.claimedAt || 0);
    if (claimedFor <= ROOM_CLAIM_PROTECT_MS) continue;

    let shouldReap = false;
    if (room.pendingAbandonAt) {
      // 有人点了「离开房间」：客户端是先发 HTTP 再断 WS，所以等 1.5 秒确认
      // 真的没人了才回收。如果中间又有人连上来，取消这次放弃。
      if (nowMs - Number(room.pendingAbandonAt) < 1500) continue;
      shouldReap = true;
    } else {
      // 没人发过「离开」= 都是掉线（断网/切后台/被系统杀），按宽限保留，
      // 让 host 端那份座位保留有意义。
      const idleSince = Number(room.lastActiveAt || room.claimedAt || 0);
      shouldReap = nowMs - idleSince > ROOM_EMPTY_GRACE_MS;
    }
    if (!shouldReap) continue;

    console.log(`ROOM_REAP code=${room.code} port=${room.port} `
      + `reason=${room.pendingAbandonAt ? 'left' : 'idle'}`);
    room.music?.dispose();
    rooms.splice(i, 1);
    const child = hostProcesses.get(room.port);
    if (child) child.kill();
  }
  ensureSpare();
}, 1000);
const sessionCookie = crypto.createHmac('sha256', invite).update('arena-session-v1').digest('hex');
const mime = {'.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.wasm': 'application/wasm', '.pck': 'application/octet-stream', '.png': 'image/png', '.ico': 'image/x-icon'};

function secureEqual(a, b) {
  const first = Buffer.from(String(a));
  const second = Buffer.from(String(b));
  return first.length === second.length && crypto.timingSafeEqual(first, second);
}
function hasSession(req) {
  const prefix = `${sessionCookieName}=`;
  const found = (req.headers.cookie || '').split(';').map(v => v.trim()).find(v => v.startsWith(prefix));
  return found && secureEqual(found.slice(prefix.length), sessionCookie);
}
function deny(res) {
  res.writeHead(403, {'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store'});
  res.end('This private test room requires its invitation link.');
}
const server = http.createServer((req, res) => {
  // Godot 4 Web export requires cross-origin isolation for SharedArrayBuffer.
  // Without these headers, window.crossOriginIsolated stays false and the game
  // fails to start (black screen / missing feature error).
  res.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
  res.setHeader('Cross-Origin-Embedder-Policy', 'require-corp');
  res.setHeader('Referrer-Policy', 'no-referrer');
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Cache-Control', 'no-store');
  let url;
  try { url = new URL(req.url, 'http://localhost'); } catch { return deny(res); }
  if (url.pathname === '/' && url.searchParams.has('invite')) {
    if (!secureEqual(url.searchParams.get('invite'), invite)) return deny(res);
    const secure = req.headers['x-forwarded-proto'] === 'https';
    // 邀请链接形如 /?invite=TOKEN&room=CODE（等待房里"邀请好友"复制的就是它）。
    // 302 必须把 room 带上：浏览器跳到 "/" 之后 room 就没了，朋友点链接只会落在大厅，
    // 而不会进入那一桌。房间号只允许字母数字，避免把任意串塞进 Location。
    const roomParam = String(url.searchParams.get('room') || '').toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 8);
    // 页面自己的开关也要跟着跳转活下来：diag=1（诊断角标）、solo_net=1（单机本地回环）、
    // lowres / hires（分辨率档位）。原来只保留 room，导致 ?invite=...&diag=1 这条链接
    // 第一次点开时 diag 被 302 抹掉，必须手动再敲一遍才生效。
    const keep = new URLSearchParams();
    if (roomParam) keep.set('room', roomParam);
    for (const key of ['diag', 'solo_net', 'lowres', 'hires']) {
      const value = url.searchParams.get(key);
      if (value !== null) keep.set(key, value);
    }
    // Test-only seams: only forwarded when the gateway was started with the
    // explicit isolated-test switch. Normal invite links drop them.
    if (allowTestSeams) {
      for (const key of ['solo', 'seed']) {
        const value = url.searchParams.get(key);
        if (value !== null) keep.set(key, value);
      }
    }
    const keepQuery = keep.toString();
    const location = keepQuery ? `/?${keepQuery}` : '/';
    // 30 天：隧道每次重启都换域名，8 小时的有效期会让"昨天还能进"的标签页突然 403。
    // cookie 值只跟 invite 有关，不随域名变化，拉长有效期没有安全代价。
    res.writeHead(302, {'Set-Cookie': `${sessionCookieName}=${sessionCookie}; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000${secure ? '; Secure' : ''}`, 'Location': location});
    return res.end();
  }
  // --- 权威房间服 -> 大厅状态：内网端口 + 一次性 key，不走客户端 ---
  // 房间模式、阶段、已入座人数、观战人数与介绍只有宿主进程知道。
  // 客户端连人数都只能数 socket，用它来画「双人 · 可入座」必然说谎。
  if (url.pathname === '/internal/room-meta' && req.method === 'POST') {
    const hostPort = Number(url.searchParams.get('host_port'));
    const child = hostProcesses.get(hostPort);
    const room = rooms.find(r => r.port === hostPort);
    if (!child || !room || !child.metaKey
        || !secureEqual(req.headers['x-arena-meta-key'] || '', child.metaKey)) {
      res.writeHead(403, {'Content-Type': 'text/plain; charset=utf-8'});
      return res.end('forbidden');
    }
    let body = '';
    let tooBig = false;
    req.on('data', chunk => {
      if (tooBig) return;
      body += chunk;
      if (body.length > 4096) { tooBig = true; body = ''; req.destroy(); }
    });
    req.on('end', () => {
      if (tooBig) return;
      let meta = null;
      try { meta = JSON.parse(body || '{}'); } catch { meta = null; }
      if (!meta || typeof meta !== 'object') {
        res.writeHead(400, {'Cache-Control': 'no-store'});
        return res.end('bad_meta');
      }
      room.meta = {
        mode: Number(meta.mode) === 1 ? 1 : 0,
        phase: meta.phase === 'playing' ? 'playing' : 'waiting',
        seats: Math.max(0, Math.min(4, Number(meta.seats) || 0)),
        spectators: Math.max(0, Math.min(32, Number(meta.spectators) || 0)),
        capacity: Number(meta.capacity) === 4 ? 4 : 2,
        intro: String(meta.intro || '').slice(0, 40),
        updatedAt: Date.now(),
      };
      res.writeHead(204, {'Cache-Control': 'no-store'});
      res.end();
    });
    return;
  }
  if (!hasSession(req)) return deny(res);
  if (url.pathname.startsWith('/room-music/')) {
    const entry = music?.files.get(url.pathname);
    if (!entry) { res.writeHead(404).end(); return; }
    if (req.method !== 'GET' && req.method !== 'HEAD') { res.writeHead(405).end(); return; }
    res.setHeader('Vary', 'Cookie');
    return serveMusicFile(req, res, entry.file, entry.type, 'private, max-age=86400, immutable');
  }
  if (music && url.pathname === '/room_music_web.js' && req.method === 'GET') {
    fs.readFile(path.join(__dirname, 'room_music_web.js'), (error, contents) => {
      if (error) { res.writeHead(404); return res.end(); }
      res.writeHead(200, {'Content-Type': 'text/javascript; charset=utf-8'});
      res.end(contents);
    });
    return;
  }
  // --- 房间 API：客户端大厅靠它拿列表、建房 ---
  if (url.pathname === '/api/rooms' && (req.method === 'GET' || req.method === 'HEAD')) {
    const nowMs = Date.now();
    const payload = JSON.stringify({
      // open = 真的有人连上，或 10 秒内刚有过活动（建房/断开）。
      // 以前用「claimedAt > 0」当判据：房主建过房就永远 open，所有人退出后
      // 大厅里还挂着这张空桌，要等 60 秒回收才消失。
      // 预热备胎的 lastActiveAt=0、claimedAt=0，open=false，永远不会出现在大厅。
      rooms: rooms.map(r => ({
        code: r.code, host: r.host, players: r.players, createdAt: r.createdAt,
        open: r.players > 0 || (nowMs - Number(r.lastActiveAt || 0) < 3000),
        // 权威元数据由房间宿主推送（见 /internal/room-meta）。没有 meta 时
        // 退回"按连接数猜"，但绝不把观众算成参赛席。
        mode: r.meta ? r.meta.mode : 0,
        phase: r.meta ? r.meta.phase : 'waiting',
        seats: r.meta ? r.meta.seats : Math.min(4, r.players),
        spectators: r.meta ? r.meta.spectators : 0,
        capacity: r.meta ? r.meta.capacity : 2,
        intro: r.meta ? r.meta.intro : '',
      })),
    });
    res.writeHead(200, {'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(payload), 'Cache-Control': 'no-store'});
    return res.end(req.method === 'HEAD' ? undefined : payload);
  }
  if (url.pathname === '/api/rooms/claim' && req.method === 'POST') {
    let body = '';
    let tooBig = false;
    req.on('data', chunk => { body += chunk; if (body.length > 4096) { tooBig = true; req.destroy(); } });
    req.on('end', () => {
      if (tooBig) return;
      let host = '';
      try { host = String(JSON.parse(body || '{}').host || '').slice(0, 24); } catch { host = ''; }
      const nowMs = Date.now();
      ensureSpare();
      // 只分配"从未被认领过"的空桌。认领过的桌子即使 players=0 也还在 90 秒重连
      // 保留期里：宿主可能留着上一局和原玩家的座位，把它分给新建房的人，既会让
      // 建房者被"对局正在进行"挡在门外，也会顶掉原玩家的回座机会。
      // 端口池满时直接回 503 no_room（客户端提示"创建房间失败"），绝不动保护期内的旧房；
      // 那张桌子到期回收后，它的端口会重新长出一张干净的空桌。
      const empty = rooms.filter(r => r.players === 0 && !r.claimedAt);
      if (empty.length === 0) {
        const busy = JSON.stringify({ error: 'no_room' });
        res.writeHead(503, {'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(busy), 'Cache-Control': 'no-store'});
        return res.end(busy);
      }
      const target = empty[0];
      target.host = host;
      target.createdAt = nowMs;
      target.claimedAt = nowMs;
      // 建房也算一次活动：大厅靠 lastActiveAt 判断这张桌子是否还"活着"。
      target.lastActiveAt = nowMs;
      // 新桌从干净状态开始；宿主进程会在 1 秒内推第一份权威 meta。
      target.meta = null;
      // 刚 spawn 的实例约需 1.2 秒才监听端口，等它起来再回；用备胎则立即返回
      const child = hostProcesses.get(target.port);
      if (target.music) {
        target.music.dispose();
        target.music = createRoomMusic(child);
        sendMusicChat(child, []);
      }
      let waitMs = 0;
      if (child && !child.godotReady) { child.godotReady = true; waitMs = 1200; }
      const payload = JSON.stringify({ code: target.code, players: 0, music_owner: target.music?.ownerToken });
      setTimeout(() => {
        res.writeHead(200, {'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(payload), 'Cache-Control': 'no-store'});
        res.end(payload);
        // 备胎被用掉了，异步补一个，下一次建房仍是 0 延迟
        ensureSpare();
      }, waitMs);
    });
    return;
  }
  // Solo room music: open a music room that belongs to this browser only.
  // It does not take a table out of `rooms`.
  if (url.pathname === '/api/music/solo' && req.method === 'POST') {
    let body = '';
    let tooBig = false;
    req.on('data', chunk => { body += chunk; if (body.length > 1024) { tooBig = true; req.destroy(); } });
    req.on('end', () => {
      if (tooBig) return;
      let name = '';
      try { name = String(JSON.parse(body || '{}').name || '').slice(0, 16).trim(); } catch { name = ''; }
      const session = createSoloMusic(name || '你');
      if (!session) {
        const payload = JSON.stringify({ error: 'no_music' });
        res.writeHead(503, {'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(payload), 'Cache-Control': 'no-store'});
        return res.end(payload);
      }
      const payload = JSON.stringify({ room: session.code, ticket: session.ticket, music_owner: session.owner });
      res.writeHead(200, {'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(payload), 'Cache-Control': 'no-store'});
      res.end(payload);
    });
    return;
  }
  // Reclaim the solo room when the player leaves solo mode, instead of waiting for the TTL.
  if (url.pathname === '/api/music/solo/release' && req.method === 'POST') {
    let body = '';
    let tooBig = false;
    req.on('data', chunk => { body += chunk; if (body.length > 512) { tooBig = true; req.destroy(); } });
    req.on('end', () => {
      if (tooBig) return;
      let code = '';
      try { code = String(JSON.parse(body || '{}').room || '').toUpperCase(); } catch { code = ''; }
      const entry = code ? soloMusic.get(code) : null;
      if (entry) {
        entry.room.dispose();
        soloMusic.delete(code);
        console.log(`SOLO_MUSIC_RELEASE room=${code}`);
      }
      res.writeHead(204, {'Cache-Control': 'no-store'});
      res.end();
    });
    return;
  }
  // 主动退出：客户端点「离开房间」时发这条，网关据此立即回收空房。
  // 掉线（断网/切后台）不会发，房间继续按 90 秒宽限保留，人回来还能接上。
  if (url.pathname === '/api/rooms/leave' && req.method === 'POST') {
    let body = '';
    let tooBig = false;
    req.on('data', chunk => {
      if (tooBig) return;
      body += chunk;
      if (body.length > 1024) { tooBig = true; body = ''; }
    });
    req.on('end', () => {
      if (tooBig) {
        res.writeHead(413, {'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store'});
        return res.end('too_big');
      }
      let code = '';
      try { code = String(JSON.parse(body || '{}').code || '').toUpperCase(); } catch { code = ''; }
      const room = code ? rooms.find(r => r.code === code) : null;
      // 只打标记，不在这里删。客户端是先发 HTTP 再断 WS，
      // 此刻 players 可能还是 1；交给 1 秒一次的回收循环确认"真的没人了"。
      if (room && room.claimedAt) room.pendingAbandonAt = Date.now();
      const payload = JSON.stringify({ ok: true });
      res.writeHead(200, {'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(payload), 'Cache-Control': 'no-store'});
      res.end(payload);
    });
    return;
  }
  if (url.pathname === '/api/chat/upload' && req.method === 'POST') {
    if (!hasSession(req)) return deny(res);
    const code = (url.searchParams.get('room') || '').toUpperCase();
    const room = rooms.find(r => r.code === code);
    const live = room ? (room.live || 0) : 0;
    if (!room || live <= 0) {
      res.writeHead(403, {'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store'});
      return res.end('not_in_room');
    }
    if (!room.attachments) room.attachments = new Map();
    if (room.attachments.size >= ATTACH_MAX_PER_ROOM) {
      res.writeHead(429, {'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store'});
      return res.end('too_many_attachments');
    }
    const chunks = [];
    let total = 0;
    let aborted = false;
    req.on('data', chunk => {
      total += chunk.length;
      if (total > ATTACH_MAX_BYTES) {
        aborted = true;
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (aborted) return;
      const body = Buffer.concat(chunks);
      const type = sniffImage(body);
      if (!type) {
        res.writeHead(415, {'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store'});
        return res.end('unsupported_type');
      }
      const id = crypto.randomBytes(16).toString('hex');
      room.attachments.set(id, { type, body, at: Date.now() });
      const payload = JSON.stringify({ id, type, bytes: body.length });
      res.writeHead(200, {'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(payload), 'Cache-Control': 'no-store'});
      console.log(`ATTACH_PUT room=${room.code} id=${id.slice(0, 8)} bytes=${body.length} type=${type}`);
      res.end(payload);
    });
    req.on('error', () => { /* 客户端中断上传：不写任何东西 */ });
    return;
  }
  if (url.pathname.startsWith('/api/chat/att/') && (req.method === 'GET' || req.method === 'HEAD')) {
    if (!hasSession(req)) return deny(res);
    const id = url.pathname.slice('/api/chat/att/'.length);
    const room = roomByAttach(id);
    if (!room) { res.writeHead(404, {'Cache-Control': 'no-store'}); return res.end(); }
    const entry = room.attachments.get(id);
    if (!entry || Date.now() - entry.at > ATTACH_TTL_MS) {
      room.attachments.delete(id);
      res.writeHead(404, {'Cache-Control': 'no-store'});
      return res.end();
    }
    // 只有"当前有人在这间房里"才放行：房间空了以后旧链接自动失效
    if ((room.live || 0) <= 0) { res.writeHead(410, {'Cache-Control': 'no-store'}); return res.end(); }
    res.writeHead(200, {
      'Content-Type': entry.type,
      'Content-Length': entry.body.length,
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
    });
    return res.end(entry.body);
  }
  if (req.method !== 'GET' && req.method !== 'HEAD') { res.writeHead(405); return res.end(); }
  let pathname;
  try { pathname = decodeURIComponent(url.pathname); } catch { return deny(res); }
  // Publish metadata, version snapshots, the lock and atomic-entry temp files all
  // live under dot-prefixed names in the serve root. They are management data,
  // not web assets: never serve them over HTTP.
  if (pathname.split('/').some(segment => segment.startsWith('.'))) {
    res.writeHead(404, {'Cache-Control': 'no-store'});
    return res.end('Not found');
  }
  let target = path.resolve(webRoot, '.' + (pathname === '/' ? '/index.html' : pathname));
  if (!target.startsWith(webRoot + path.sep)) return deny(res);
  if (target.endsWith('.gz')) return deny(res);

  // Godot 的 AudioWorklet 路径跟着 executable 走：executable = index.<hash> 时，
  // 引擎要 index.<hash>.audio.worklet.js / .audio.position.worklet.js。
  // 这两个文件必须由 version_web_export.js 复制出来；漏了就是 404 →
  // addModule() 失败 → **整个游戏静音**，而且控制台只有一行 load 失败，很难查。
  // 这里做事后兜底：哈希副本不存在时回退到不带哈希的原名，宁可丢长缓存也别静音。
  if (!fs.existsSync(target) && /^index\.[0-9a-f]{8,}\.audio(\.position)?\.worklet\.js$/.test(path.basename(target))) {
    const fallback = path.join(webRoot, path.basename(target).replace(/^index\.[0-9a-f]{8,}\./, 'index.'));
    if (fs.existsSync(fallback)) target = fallback;
  }

  // Inject the real invite URL into the page so the in-game "copy invite link"
  // button can show / copy it. After the ?invite= redirect the token only lives
  // in a cookie, so the page cannot recover it by itself.
  if (path.extname(target).toLowerCase() === '.html') {
    fs.readFile(target, 'utf8', (error, html) => {
      if (error) { res.writeHead(404); return res.end('Not found'); }
      const scheme = req.headers['x-forwarded-proto'] === 'https' ? 'https' : 'http';
      const inviteUrl = `${scheme}://${req.headers.host}/?invite=${invite}`;
      // Godot 4 Web 的软键盘走 DisplayServer.virtual_keyboard_show()，它在 _process 的
      // 事件分发阶段执行，此时浏览器的 user activation 已过期，移动端会静默拒绝 focus()。
      // 这里在登录页的两个输入框位置铺一层真实 <input>（透明），点击由浏览器原生弹键盘，
      // 输入值经 window.arenaVKInput 回传给 GDScript。仅在触摸设备启用，不影响桌面键盘。
      const vkBridge = `<script>(function(){`
        + `var DESIGN={w:540,h:960};`
        // 验证码是独立一屏，必须在同一个位置放自己的 input：
        // 复用邮箱框的话，点验证码那行弹出来的是邮箱键盘，还会把验证码写进邮箱。
        + `var FIELDS=[`
        + `{key:'email',x:58,y:338,w:424,h:44,type:'email'},`
        + `{key:'password',x:58,y:440,w:424,h:44,type:'password'},`
        + `{key:'otp',x:58,y:330,w:424,h:56,type:'text',inputmode:'numeric',autocomplete:'one-time-code'}`
        + `];`
        + `var layer=null;var touch=!!(window.matchMedia&&window.matchMedia('(pointer:coarse)').matches);`
        + `function layout(){var c=document.getElementById('canvas');if(!c)return;var r=c.getBoundingClientRect();`
        + `if(!r.width||!r.height)return;`
        + `var s=Math.min(r.width/DESIGN.w,r.height/DESIGN.h);`
        + `var ox=r.left+(r.width-DESIGN.w*s)/2,oy=r.top+(r.height-DESIGN.h*s)/2;`
        + `FIELDS.forEach(function(f){var e=f.el;if(!e)return;e.style.left=(ox+f.x*s)+'px';e.style.top=(oy+f.y*s)+'px';`
        + `e.style.width=(f.w*s)+'px';e.style.height=(f.h*s)+'px';e.style.fontSize=(20*s)+'px';});}`
        + `function build(){if(layer||!touch)return;layer=document.createElement('div');`
        + `layer.style.cssText='position:fixed;left:0;top:0;z-index:2147483000;pointer-events:none;';`
        + `document.body.appendChild(layer);`
        + `FIELDS.forEach(function(f){var e=document.createElement('input');e.type=f.type;`
        + `if(f.inputmode)e.setAttribute('inputmode',f.inputmode);`
        + `e.setAttribute('enterkeyhint','done');`
        + `e.autocomplete=f.autocomplete||'off';e.autocapitalize='off';e.spellcheck=false;`
        + `e.style.cssText='position:fixed;display:none;opacity:0.01;border:0;background:transparent;'`
        + `+'color:transparent;caret-color:transparent;padding:0;margin:0;outline:none;pointer-events:auto;';`
        + `e.addEventListener('input',function(){if(window.arenaVKInput)window.arenaVKInput(f.key,e.value);});`
        + `e.addEventListener('keydown',function(ev){if(ev.key==='Enter')e.blur();});`
        + `layer.appendChild(e);f.el=e;});`
        + `window.addEventListener('resize',layout);`
        + `window.addEventListener('orientationchange',function(){setTimeout(layout,300);});`
        + `layout();}`
        + `window.arenaVKSetPage=function(p){build();if(!touch)return;`
        + `FIELDS.forEach(function(f){if(!f.el)return;`
        + `var on=(p==='auth'&&f.key!=='otp')||(p==='auth_otp'&&f.key==='otp');`
        + `f.el.style.display=on?'block':'none';if(!on)f.el.blur();});`
        + `if(p==='auth'||p==='auth_otp')layout();};`
        + `window.arenaVKBlur=function(){if(!touch)return;FIELDS.forEach(function(f){if(f.el)f.el.blur();});};`
        + `window.arenaVKClear=function(key){if(!touch)return;FIELDS.forEach(function(f){if(f.el&&f.key===key)f.el.value='';});};`
        + `window.arenaVKReset=function(){if(!touch)return;FIELDS.forEach(function(f){if(f.el)f.el.value='';});};`
        + `if(document.readyState!=='loading')build();else document.addEventListener('DOMContentLoaded',build);`
        + `})();</script>`;
      const musicBridge = music ? '<script src="/room_music_web.js"></script>\n' : '';
      const testSeamFlag = allowTestSeams
        ? '<script>window.ARENA_TEST_SEAMS=true;</script>\n'
        : '';
      const inject = `<script>window.ARENA_INVITE_URL=${JSON.stringify(inviteUrl)};</script>\n${testSeamFlag}${musicBridge}${vkBridge}\n`
        // ---- boot fetch probe ----
        // 背景：国内直连公网入口时，页面会长时间停在首屏 Load 画面，只有一个聚合
        // 进度条，远程用户说不清"卡在哪个文件、哪条线路"。这里在 Godot loader 执行
        // 之前包一层 fetch：逐文件记录开始时间、HTTP 状态、cf-ray（Cloudflare 边缘
        // 节点代号，如 LAX/HKG）、已收字节与最后进展时间，供下面的 bootLoadingHint
        // 渲染到加载页；用户截一张图即可定位问题文件与线路。
        // 必须在 loader <script> 之前执行，Godot 下载 wasm/pck 走的就是 window.fetch。
        + `<script>(function(){`
        + `try{`
        + `if(!window.fetch||window.__arenaFetchProbe)return;window.__arenaFetchProbe=true;`
        + `var real=window.fetch.bind(window);`
        + `var D=window.arenaLoadDiag={log:[],active:null,err:'',colo:'',t0:performance.now()};`
        + `window.fetch=function(input,init){`
        + `  var url='';try{url=typeof input==='string'?input:(input&&input.url)||String(input);}catch(e){}`
        + `  var n=0;for(var i=0;i<D.log.length;i++){if(D.log[i].url===url)n++;}`
        + `  var rec={url:url,start:performance.now(),last:performance.now(),bytes:0,total:0,status:0,state:'connect',try:n+1};`
        + `  D.log.push(rec);D.active=rec;D.err='';`
        + `  return real(input,init).then(function(resp){`
        + `    rec.status=resp.status;rec.state='download';`
        + `    try{var ray=resp.headers.get('cf-ray')||'';var c=ray.split('-').pop();if(c){rec.colo=c;D.colo=c;window.arenaEdgeColo=c;}}catch(e){}`
        + `    if(resp.status>=400){rec.state='error';D.err='HTTP '+resp.status+' '+url;return resp;}`
        + `    if(!resp.body||typeof TransformStream==='undefined'||typeof resp.body.pipeThrough!=='function'){rec.state='done';if(D.active===rec)D.active=null;return resp;}`
        + `    try{`
        + `      var stream=resp.body.pipeThrough(new TransformStream({`
        + `        transform:function(chunk,ctrl){rec.bytes+=chunk.byteLength||chunk.length||0;rec.last=performance.now();ctrl.enqueue(chunk);},`
        + `        flush:function(){rec.state='done';rec.ms=Math.round(performance.now()-rec.start);if(D.active===rec)D.active=null;}`
        + `      }));`
        + `      return new Response(stream,{status:resp.status,statusText:resp.statusText,headers:resp.headers});`
        + `    }catch(e){rec.state='done';if(D.active===rec)D.active=null;return resp;}`
        + `  },function(err){`
        + `    rec.state='error';rec.ms=Math.round(performance.now()-rec.start);`
        + `    D.err=((err&&err.message)?err.message:String(err))+' · '+url;`
        + `    if(D.active===rec)D.active=null;`
        + `    throw err;`
        + `  });`
        + `};`
        + `}catch(e){}`
        + `})();</script>\n`
        + `<script>(function bootLoadingHint(){`
        // The anchor can miss (unexpected template, injected fragment). In that
        // case the injection lands in <head>, where document.body is null; wait
        // for the body instead of throwing on appendChild.
        + `if(!document.body){document.addEventListener('DOMContentLoaded',bootLoadingHint,{once:true});return;}`
        // 首次要下载 wasm(br ~8MB) + pck(br ~3.4MB) 并编译引擎。
        // 必须监听 Godot 的 #status 消失来移除提示，只靠定时器会一直挂在底栏上。
        // 每 400ms 用 arenaLoadDiag 重绘：当前文件 / 速率 / 卡住秒数 / 最近错误 /
        // CDN 边缘节点。用户能看到"在动"就不会反复刷新，截图即可远程定位。
        + `var hint=document.createElement('div');`
        + `hint.id='arena-loading-hint';`
        + `hint.style.cssText='position:fixed;left:16px;right:16px;bottom:150px;text-align:center;`
        + `font:13px/1.6 system-ui,-apple-system,sans-serif;color:#b9bcc4;z-index:9;pointer-events:none;`
        + `text-shadow:0 1px 2px rgba(0,0,0,.8);white-space:pre-line;';`
        + `var BASE='首次加载约 13MB，之后走本地缓存会快很多';`
        + `hint.textContent=BASE;`
        + `document.body.appendChild(hint);`
        + `var slow=false,stall=false;`
        + `function label(u){if(/\\.wasm($|\\?)/.test(u))return '引擎 wasm';if(/\\.pck($|\\?)/.test(u))return '游戏数据包';if(/\\.js($|\\?)/.test(u))return '引导脚本';return '资源文件';}`
        + `function fmt(b){return b>=1048576?(b/1048576).toFixed(1)+'MB':Math.max(1,Math.round(b/1024))+'KB';}`
        + `var tick=setInterval(function(){`
        + `  var s=document.getElementById('status');`
        // Godot 加载完成会把 #status 隐藏或移除；两种情况都视为引擎已起来
        + `  if(!s||s.style.display==='none'||s.offsetParent===null){kill();return;}`
        + `  var lines=[BASE];`
        + `  var D=window.arenaLoadDiag;`
        + `  var a=D&&D.active;`
        + `  if(a){`
        + `    var sec=Math.max(1,Math.round((performance.now()-a.start)/1000));`
        + `    var spd=a.bytes>0&&sec>1?Math.round(a.bytes/sec/1024)+'KB/s':'';`
        + `    var idle=a.last?(performance.now()-a.last)/1000:0;`
        + `    var line=label(a.url)+' · 已收 '+fmt(a.bytes)+(spd?' · '+spd:'');`
        + `    if(a.try>1)line+=' · 第'+a.try+'次尝试';`
        + `    if(idle>15)line+='\\n⚠ 该文件 '+Math.round(idle)+' 秒无进展（可能丢包或被断开，引擎会自动重试）';`
        + `    line+='\\n用时 '+sec+' 秒';`
        + `    lines.push(line);`
        + `  }else{`
        + `    var p=document.getElementById('status-progress');`
        + `    if(p&&p.max>0){`
        + `      var pct=Math.max(0,Math.min(100,Math.round(p.value/p.max*100)));`
        + `      lines.push('总进度 '+pct+'%');`
        + `    }else{lines.push('正在编译 / 启动引擎…');}`
        + `  }`
        + `  if(D&&D.err)lines.push('最近错误：'+D.err);`
        + `  if(D&&D.colo)lines.push('线路节点 '+D.colo);else lines.push('入口 '+location.host);`
        + `  if(slow)lines.push('网络较慢：请保持前台，不要锁屏或切后台');`
        + `  if(stall)lines.push('已超过 2 分钟：建议刷新重试，或换 Wi-Fi / 流量再进');`
        + `  hint.textContent=lines.join('\\n');`
        + `},400);`
        + `function kill(){if(hint.parentNode)hint.remove();clearInterval(tick);`
        + `if(fallback)clearTimeout(fallback);if(slowT)clearTimeout(slowT);if(stallT)clearTimeout(stallT);}`
        // 45 秒还没起来：明确告诉他是网络慢，不是坏了
        + `var slowT=setTimeout(function(){slow=true;},45000);`
        // 2 分钟：给出可操作的两条路，避免用户干等
        + `var stallT=setTimeout(function(){stall=true;},120000);`
        // 兜底：万一 #status 结构变了，最多遮挡 3 分钟
        + `var fallback=setTimeout(kill,180000);`
        + `})();</script>\n`
        // 手机端限制设备像素比 + 可选性能角标。
        // 背景：Godot Web 的 canvasResizePolicy=2 会把 canvas 按 DPR 放大，
        // 540×960 的设计在 iPhone(DPR3) 上是 ~1170×2532 = 296 万像素，
        // 低端 GPU 填充率扛不住，表现就是"有的人掉帧、有的人不卡"。
        // 钳到 1.5x（平板 2x）后像素降到约 1/4，文字仍清晰。
        // 这段在 <script src="index.js"> 之前执行，早于 new Engine()，所以改 DPR 有效。
        + `<script>(function(){`
        + `var Q=new URLSearchParams(location.search);`
        + `var mobile=/Android|iPhone|iPad|iPod|Mobile/i.test(navigator.userAgent);`
        + `var wantHi=Q.get('hires')==='1';`
        + `var wantLow=Q.get('lowres')==='1';`
        + `if(mobile&&!wantHi){`
        + `  var tablet=Math.min(innerWidth,innerHeight)>=700;`
        + `  var cap=wantLow?1:(tablet?2:1.5);`
        + `  var real=window.devicePixelRatio||1;`
        + `  if(real>cap){try{Object.defineProperty(window,'devicePixelRatio',{configurable:true,get:function(){return cap;}});}catch(e){}}`
        + `}`
        // ?diag=1：左上角显示实时 FPS / 帧分布 / canvas 分辨率 / DPR，用于远程判断掉帧类型
        + `if(Q.get('diag')==='1'){`
        + `  var box=document.createElement('div');`
        + `  box.style.cssText='position:fixed;left:8px;top:8px;z-index:2147483000;font:12px/1.45 ui-monospace,Menlo,monospace;color:#9fe8ff;background:rgba(0,0,0,.62);padding:5px 7px;border-radius:6px;pointer-events:none;white-space:pre';`
        + `  if(document.body)document.body.appendChild(box);else document.addEventListener('DOMContentLoaded',function(){document.body.appendChild(box);},{once:true});`
        + `  var f=0,t0=performance.now(),fps=0,plast=0,pworst=0,ft=new Float64Array(600),fi=0,fn=0;`
        + `  function pct(a,p){if(!a.length)return 0;var b=a.slice().sort(function(x,y){return x-y;});return b[Math.min(b.length-1,Math.max(0,Math.floor((b.length-1)*p)))];}`
        // 环形缓冲 600 帧（约 10 秒）：原来 push+shift 每帧都要搬 4000 个元素，
        // 而且每 500ms 排序 4000 个数——测量工具自己就会造出长帧，污染判读。
        + `  window.arenaFrameReset=function(){fi=0;fn=0;f=0;t0=performance.now();plast=0;pworst=0;};`
        + `  function loop(now){f++;`
        // frame max：最近半秒里最长的一次帧间隔。FPS 是平均值，看不出瞬时卡顿；
        // 这个值稳定在 16~18ms = 浏览器一直在顺畅出帧（问题在网络）；
        // 时不时跳到 30ms+ = CPU/GPU 峰值（问题在渲染或逻辑）。
        + `    if(plast>0){var g=now-plast;if(g>pworst)pworst=g;ft[fi]=g;fi=(fi+1)%600;if(fn<600)fn++;}plast=now;`
        + `    if(now-t0>=500){fps=Math.round(f*1000/(now-t0));f=0;t0=now;`
        + `    var w=Math.round(pworst);pworst=0;`
        + `    var a=[];for(var i=0;i<fn;i++)a.push(ft[i]);a.sort(function(x,y){return x-y;});`
        + `    var l33=0,l50=0,l100=0;for(var i=0;i<a.length;i++){var v=a[i];if(v>33)l33++;if(v>50)l50++;if(v>100)l100++;}`
        + `    var p50=Math.round(pct(a,0.5)),p95=Math.round(pct(a,0.95)),p99=Math.round(pct(a,0.99));`
        + `    var mx=a.length?a[a.length-1]:0;`
        + `    window.arenaFrameStats={n:a.length,p50:p50,p95:p95,p99:p99,max:Math.round(mx),long33:l33,long50:l50,long100:l100,fps:fps};`
        + `    var c=document.getElementById('canvas');`
        + `    var d=window.arenaNetDiag;`
        + `    box.textContent='FPS '+fps+'  p95 '+p95+'ms  >50 '+l50+'\\nframe max '+w+'ms\\ncanvas '+(c?c.width+'x'+c.height:'-')+'\\nDPR '+(window.devicePixelRatio||1).toFixed(2)+'\\nwin '+innerWidth+'x'+innerHeight`
        // 启动时 fetch 探针记下的 Cloudflare 边缘节点（如 LAX/HKG），对局中也能看线路
        + `      +(window.arenaLoadDiag&&window.arenaLoadDiag.colo?'\\nedge '+window.arenaLoadDiag.colo:'')`
        + `      +(d?('\\nnet n='+d.samples+' lag='+d.lag+' buf='+d.buffer+' jit='+d.jitter+'\\ndc '+d.dc+' proc '+d.proc+' phys '+d.phys+' draw '+d.draw+' hud '+d.hud+'\\naudio buses='+d.buses+' voices='+d.voices+'\\nsfx '+d.sfx):'\\nnet -');`
        + `  }requestAnimationFrame(loop);}`
        + `  requestAnimationFrame(loop);`
        + `}`
        + `})();</script>\n`;
      // The loader is content addressed in the new publisher (index.<8hex>.js),
      // but legacy entries still use index.js. Match either anchor and inject
      // before the loader; only fall back to </head> when neither exists, and the
      // loading hint above defers itself until <body> exists in that case.
      const anchor = /<script\s+src="(?:index\.js|index\.[0-9a-f]{8,}\.js)"><\/script>/;
      const out = anchor.test(html)
        ? html.replace(anchor, (tag) => inject + tag)
        : html.replace('</head>', inject + '</head>');
      res.writeHead(200, {'Content-Type': 'text/html; charset=utf-8', 'Content-Length': Buffer.byteLength(out), 'Cache-Control': 'no-store'});
      if (req.method === 'HEAD') return res.end();
      res.end(out);
    });
    return;
  }

  fs.stat(target, (error, stat) => {
    if (error || !stat.isFile()) { res.writeHead(404); return res.end('Not found'); }
    const baseName = path.basename(target);
    // 带内容哈希的文件名（index.<hash>.wasm / .pck / .js）内容永不改变：浏览器和 CDN
    // 都可以缓存一年。没带哈希的旧文件名继续回源校验，保证换版本能立刻拿到新包。
    const hashed = /^index\.[0-9a-f]{8,}\.(wasm|pck|js|audio(\.position)?\.worklet\.js)$/.test(baseName);
    // Revalidate with ETag instead of forcing a full re-download. wasm/pck are
    // ~30 MB total; with `no-store` every refresh pulled all of it again.
    const etag = `"${stat.size.toString(16)}-${Math.floor(stat.mtimeMs).toString(16)}"`;
    const cacheControl = hashed
      ? 'public, max-age=31536000, immutable'
      : path.extname(target) === '.pck' ? 'no-cache' : 'public, max-age=600';
    if (req.headers['if-none-match'] === etag) {
      res.writeHead(304, {'ETag': etag, 'Cache-Control': cacheControl});
      return res.end();
    }
    // brotli 优先：回源段（家里上行）是真正的瓶颈，wasm 从 9.8MB 降到 ~8.2MB。
    const accept = String(req.headers['accept-encoding'] || '');
    const wantsBr = /(?:^|,|\s)br(?:$|,|;|\s)/.test(accept) && !/br\s*;\s*q=0/.test(accept);
    const wantsGzip = /(?:^|,|\s)gzip(?:$|,|;|\s)/.test(accept) && !/gzip\s*;\s*q=0/.test(accept);
    let encoding = '';
    if (wantsBr && fs.existsSync(target + '.br')) encoding = 'br';
    else if (wantsGzip && fs.existsSync(target + '.gz')) encoding = 'gzip';
    const served = encoding ? `${target}.${encoding === 'br' ? 'br' : 'gz'}` : target;
    const length = encoding ? fs.statSync(served).size : stat.size;
    const headers = {
      'Content-Type': mime[path.extname(target)] || 'application/octet-stream',
      'Content-Length': length,
      'Vary': 'Accept-Encoding',
      'ETag': etag,
      // 带哈希的名字能长缓存；旧名字按文件区分：wasm 允许边缘缓存 10 分钟，
      // pck 用 no-cache 回源校验（见上）。
      'Cache-Control': cacheControl,
    };
    if (encoding) headers['Content-Encoding'] = encoding;
    res.writeHead(200, headers);
    if (req.method === 'HEAD') return res.end();
    fs.createReadStream(served).pipe(res);
  });
});
server.on('upgrade', (req, socket, head) => {
  const wsUrl = new URL(req.url, 'http://localhost');
  if (wsUrl.pathname === '/internal/music-chat') {
    const hostPort = Number(wsUrl.searchParams.get('host_port'));
    const child = hostProcesses.get(hostPort);
    const room = rooms.find(entry => entry.port === hostPort);
    const key = child?.musicKey;
    if (!music || !room?.music || !key || socket.remoteAddress !== '127.0.0.1' ||
        !secureEqual(req.headers.authorization, `Bearer ${key.toString('hex')}`)) {
      socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n');
      return;
    }
    return music.sockets.handleUpgrade(req, socket, head, feed => {
      child.musicChatFeed?.terminate();
      child.musicChatFeed = feed;
      feed.on('error', () => feed.terminate());
      feed.on('close', () => { if (child.musicChatFeed === feed) child.musicChatFeed = null; });
      console.log(`MUSIC_CHAT_FEED port=${hostPort}`);
      sendMusicChat(child, room.music.notices);
    });
  }
  const connectionId = crypto.randomBytes(4).toString('hex');
  let origin;
  try { origin = new URL(req.headers.origin || ''); } catch {
    console.warn(`WS_REJECT id=${connectionId} reason=missing_origin`);
    socket.destroy(); return;
  }
  if (!req.url.startsWith('/ws') || !hasSession(req) || origin.host !== req.headers.host || req.headers.upgrade?.toLowerCase() !== 'websocket') {
    // 细分原因：域名换了之后最常见的是 no_session_cookie（新域名下没有旧 cookie）
    const upgradeOk = req.headers.upgrade?.toLowerCase() === 'websocket';
    const cookieOk = hasSession(req);
    const reason = !upgradeOk ? 'not_websocket'
      : !req.url.startsWith('/ws') ? 'bad_path'
      : !cookieOk ? 'no_session_cookie'
      : 'origin_mismatch';
    console.warn(`WS_REJECT id=${connectionId} reason=${reason} cookie=${cookieOk ? 'yes' : 'no'} origin=${origin.host} host=${req.headers.host}`);
    socket.write('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n');
    socket.destroy();
    return;
  }
  // 按 ?room=CODE 分流到对应实例。带 room 但查不到时明确 404，
  // 绝不回落到第一桌——否则输错房间号会莫名进到别人的桌里。
  const roomCode = (wsUrl.searchParams.get('room') || '').toUpperCase();
  const matched = roomCode ? rooms.find(r => r.code === roomCode) : null;
  if (wsUrl.pathname === '/ws/music') {
    // Solo music rooms live outside `rooms` (the lobby must not see them), so fall
    // back to the separate solo table. This branch must stay ABOVE the generic
    // `roomCode && !matched` 404 below, or a SOLO- room would be rejected first.
    const musicTarget = matched?.music || soloMusic.get(roomCode)?.room;
    if (!musicTarget) {
      socket.end('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n');
      return;
    }
    return music.sockets.handleUpgrade(req, socket, head, client => musicTarget.accept(client));
  }
  if (roomCode && !matched) {
    console.warn(`WS_REJECT id=${connectionId} reason=unknown_room room=${roomCode}`);
    socket.write('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n');
    socket.destroy();
    return;
  }
  const room = matched || rooms[0];
  if (!room) {
    console.warn(`WS_REJECT id=${connectionId} reason=no_room_available`);
    socket.write('HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n');
    socket.destroy();
    return;
  }
  const backend = net.createConnection({host: '127.0.0.1', port: room.port});
  let counted = false;
  let closed = false;
  const roomMusic = room.music;
  const musicConnection = roomMusic?.attachGame();
  // 附件权限与房间活跃人数绑定：最后一个人离开就把图片全清掉，旧链接立刻失效
  room.live = (room.live || 0) + 1;
  let liveHeld = true;
  const releaseLive = () => {
    if (!liveHeld) return;
    liveHeld = false;
    room.live = Math.max(0, (room.live || 0) - 1);
    if (room.live === 0 && room.attachments) {
      const dropped = room.attachments.size;
      room.attachments.clear();
      if (dropped > 0) console.log(`ATTACH_PURGE room=${room.code} dropped=${dropped}`);
    }
  };
  const releaseSlot = () => {
    if (!counted) return;
    counted = false;
    room.players = Math.max(0, room.players - 1);
    room.lastActiveAt = Date.now();
    if (room.players === 0) { room.host = ''; room.createdAt = 0; }
  };
  // 两条 socket 必须一起收：只关后端不关浏览器，客户端会一直"看起来已连接"
  // （收不到任何包也不报错），既不触发重连，大厅还挂着这个人的计数。
  // 反过来只关浏览器不关后端，headless 实例会留一条僵尸连接占着座位。
  const teardown = reason => {
    if (closed) return;
    closed = true;
    if (musicConnection) roomMusic.detachGame(musicConnection);
    releaseLive();
    releaseSlot();
    console.log(`WS_CLOSE id=${connectionId} room=${room.code} reason=${reason} players=${room.players}`);
    socket.destroy();
    backend.destroy();
  };
  socket.on('close', () => teardown('browser_closed'));
  socket.on('error', error => { console.warn(`WS_BROWSER_ERROR id=${connectionId} code=${error.code}`); teardown('browser_error'); });
  backend.on('connect', () => {
    // 浏览器在回源前就断开时不要再计数，否则这一桌会永久少一个座位。
    if (closed) { backend.destroy(); return; }
    counted = true;
    room.players += 1;
    room.lastActiveAt = Date.now();
    // 有人重新连回来：取消刚才那次「全员离开」的待回收标记。
    room.pendingAbandonAt = 0;
    console.log(`WS_OPEN id=${connectionId} room=${room.code} players=${room.players}`);
    const headers = [];
    for (let i = 0; i < req.rawHeaders.length; i += 2) headers.push(`${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}`);
    const backendPath = musicConnection ? `/arena-music/${musicConnection}` : '/';
    backend.write(`GET ${backendPath} HTTP/1.1\r\n${headers.join('\r\n')}\r\n\r\n`);
    if (head.length) backend.write(head);
    socket.pipe(backend).pipe(socket);
  });
  backend.on('error', error => { console.warn(`WS_BACKEND_ERROR id=${connectionId} code=${error.code}`); teardown('backend_error'); });
  backend.on('close', () => teardown('backend_closed'));
});
server.listen(port, bindHost, () => {
  console.log(`ARENA_GATEWAY listening on ${bindHost}:${port}`);
  // 预热 1 个备胎实例：让第一次建房也是 0 延迟
  if (ensureSpare()) console.log('SPARE_READY');
});
