/**
 * BloomBet Bot Bridge
 *
 * Runs locally on the same machine as LDPlayer / Delta executor.
 * - Connects to the backend via Socket.IO /bot namespace (authenticated)
 * - Exposes a local HTTP server so the Lua script can POST events to it
 * - Bridges: Lua HTTP → this bridge → Backend Socket.IO
 *
 * Usage: node bridge.js
 */

require('dotenv').config();
const express = require('express');
const { io: socketClient } = require('socket.io-client');

const BACKEND_URL = (process.env.BACKEND_URL || 'http://localhost:3001').replace(/\/+$/, '');
const BOT_API_KEY = process.env.BOT_API_KEY;
const BOT_ID = process.env.BOT_ID;
const BRIDGE_PORT = parseInt(process.env.BRIDGE_PORT || '4000', 10);

if (!BOT_API_KEY) {
  console.error('❌ BOT_API_KEY not set in .env');
  process.exit(1);
}
if (!BOT_ID) {
  console.error('❌ BOT_ID not set in .env — add your bot via POST /api/admin/bots first, then paste the returned ID here');
  process.exit(1);
}

// ─── Socket.IO connection to backend ────────────────────────────────────────

const socket = socketClient(`${BACKEND_URL}/bot`, {
  auth: {
    apiKey: BOT_API_KEY,
    botId: BOT_ID,
  },
  extraHeaders: {
    'bypass-tunnel-reminder': 'true',
  },
  reconnection: true,
  reconnectionDelay: 3000,
});

socket.on('connect', () => {
  console.log('✅ Connected to backend /bot namespace');
  socket.emit('bot:heartbeat');
});

socket.on('connect_error', (err) => {
  console.error('❌ Backend connection error:', err.message);
});

socket.on('disconnect', (reason) => {
  console.warn('⚠️  Disconnected from backend:', reason);
});

// Backend may send withdrawal:request — store it for the Lua script to poll
const pendingWithdrawals = [];

socket.on('withdrawal:request', (data) => {
  console.log('📤 Socket.IO: Withdrawal request received from backend:', data);
  pendingWithdrawals.push(data);
});

// Send heartbeat every 30s
setInterval(() => {
  if (socket.connected) {
    socket.emit('bot:heartbeat');
    console.log('💓 Heartbeat sent');
  }
}, 30_000);

// ─── HTTP server for Lua script ──────────────────────────────────────────────

const app = express();
app.use(express.json());

/**
 * POST /trade-completed
 * Called by Lua after a deposit trade is accepted and confirmed.
 */
app.post('/trade-completed', (req, res) => {
  const { robloxUserId, userId, tradeId, items } = req.body;
  const finalUserId = robloxUserId || userId;

  if (!finalUserId || !Array.isArray(items)) {
    console.warn('⚠️  /trade-completed: missing player userId or items array');
    return res.status(400).json({ error: 'Missing robloxUserId or items' });
  }

  console.log(`✅ Trade completed — userId: ${finalUserId}, items: ${items.map(i => i.name).join(', ')}`);

  socket.emit('trade:completed', {
    botId: BOT_ID,
    robloxUserId: Number(finalUserId),
    tradeId: tradeId || `manual-${Date.now()}`,
    items: items.map(item => ({
      name: item.name,
      assetId: item.assetId || item.templateId || 0
    })),
  });

  res.json({ ok: true });
});

/**
 * POST /withdrawal-completed
 * Body: { withdrawalId: string, robloxTradeId: string }
 */
app.post('/withdrawal-completed', (req, res) => {
  const { withdrawalId, robloxTradeId } = req.body;
  if (!withdrawalId) return res.status(400).json({ error: 'Missing withdrawalId' });

  console.log(`✅ Withdrawal completed reported by Lua — id: ${withdrawalId}`);
  socket.emit('withdrawal:completed', { withdrawalId, robloxTradeId: robloxTradeId || '' });

  const idx = pendingWithdrawals.findIndex(w => String(w.withdrawalId) === String(withdrawalId));
  if (idx !== -1) {
    pendingWithdrawals.splice(idx, 1);
    console.log(`🗑️ Removed withdrawalId ${withdrawalId} from local queue.`);
  }

  res.json({ ok: true });
});

/**
 * POST /withdrawal-failed
 * Body: { withdrawalId: string }
 */
app.post('/withdrawal-failed', (req, res) => {
  const { withdrawalId } = req.body;
  if (!withdrawalId) return res.status(400).json({ error: 'Missing withdrawalId' });

  console.log(`❌ Withdrawal failed reported by Lua — id: ${withdrawalId}`);
  socket.emit('withdrawal:failed', { withdrawalId });

  const idx = pendingWithdrawals.findIndex(w => String(w.withdrawalId) === String(withdrawalId));
  if (idx !== -1) {
    pendingWithdrawals.splice(idx, 1);
    console.log(`🗑️ Removed failed withdrawalId ${withdrawalId} from local queue.`);
  }

  res.json({ ok: true });
});

/**
 * GET /pending-withdrawal
 * Lua script polls this to know if it should initiate a withdrawal trade.
 */
app.get('/pending-withdrawal', (req, res) => {
  if (pendingWithdrawals.length > 0) {
    const next = pendingWithdrawals[0];
    
    console.log(`📥 Lua Polled: Handing over withdrawal request for player [${next.robloxUsername}]`);
    
    return res.json({
      withdrawal: {
        withdrawalId: next.withdrawalId,
        robloxUsername: next.robloxUsername,
        items: next.items
      }
    });
  }

  res.json({ withdrawal: null });
});

/**
 * GET /health
 * Lua can call this to verify the bridge is running.
 */
app.get('/health', (req, res) => {
  res.json({ ok: true, connected: socket.connected, botId: BOT_ID });
});

// Start processing connections
app.listen(BRIDGE_PORT, '0.0.0.0', () => {
  console.log(`\n========================================================`);
  console.log(`🌉  BLOOMBET BOT BRIDGE IS ONLINE (0.0.0.0)`);
  console.log(`📌  Set your Lua script variable to: http://10.0.2.2:${BRIDGE_PORT}`);
  console.log(`========================================================\n`);
  console.log(`   BOT_ID:      ${BOT_ID}`);
  console.log(`   Backend:     ${BACKEND_URL}\n`);
});
