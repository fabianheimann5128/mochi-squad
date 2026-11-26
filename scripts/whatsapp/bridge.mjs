// WhatsApp link for Mochi Squad. Runs as a linked device of the user's own WhatsApp account, like WhatsApp Web,
// through the unofficial Baileys library. It reads and writes one chat only: "Message yourself". Every other
// chat, group and status is ignored and never leaves this process.
//
//   node bridge.mjs <auth-folder>
//
// Protocol with the app (one JSON object per line):
//   stdout: {"qr": "<text for the QR code>"}                 scan in WhatsApp › Linked Devices
//   stdout: {"state": "connecting" | "open" | "logged_out", "number": "<own number>"}
//   stdout: {"message": {"id": "...", "text": "..."}}        the user wrote in "Message yourself"
//   stdout: {"unsupported": true}                            the user sent something that is not text
//   stdout: {"error": "..."}                                 short reason without personal data
//   stdin:  {"send": "<text>"}  {"logout": true}
// When stdin closes (the app quit), the process ends.
import { createInterface } from 'node:readline';
import makeWASocket, { DisconnectReason, jidNormalizedUser, normalizeMessageContent, useMultiFileAuthState } from '@whiskeysockets/baileys';

const authFolder = process.argv[2];
if (!authFolder) {
  console.error('usage: node bridge.mjs <auth-folder>');
  process.exit(64);
}

const CHUNK = 4000;
const emit = (event) => process.stdout.write(JSON.stringify(event) + '\n');
const silent = { level: 'silent', child: () => silent, trace() {}, debug() {}, info() {}, warn() {}, error() {}, fatal() {} };
const startedAt = Math.floor(Date.now() / 1000);
/** Ids of messages this process sent, so that an echo is never read as a message from the user. */
const sent = new Set();

const { state, saveCreds } = await useMultiFileAuthState(authFolder);
let socket;
let retries = 0;
let stopping = false;

const ownJids = () => [state.creds.me?.id, state.creds.me?.lid].filter(Boolean).map((jid) => jidNormalizedUser(jid));
const ownNumber = () => (state.creds.me?.id ?? '').split(':')[0].split('@')[0];

function connect() {
  const current = makeWASocket({
    auth: state,
    logger: silent,
    browser: ['Mochi Squad', 'Chrome', '1.0'],
    syncFullHistory: false,
    shouldSyncHistoryMessage: () => false,
    markOnlineOnConnect: false,
    emitOwnEvents: false,
    getMessage: async () => undefined,
    connectTimeoutMs: 30_000,
    qrTimeout: 60_000,
    // Everything but the own chat is dropped before it is even decrypted.
    shouldIgnoreJid: (jid) => !ownJids().includes(jidNormalizedUser(jid)),
  });
  socket = current;
  current.ev.on('creds.update', saveCreds);
  current.ev.on('connection.update', (update) => {
    if (socket !== current) return;
    if (update.qr) emit({ qr: update.qr });
    if (update.connection === 'open') {
      retries = 0;
      emit({ state: 'open', number: ownNumber() });
    }
    if (update.connection === 'close') {
      const code = update.lastDisconnect?.error?.output?.statusCode;
      if (code === DisconnectReason.loggedOut) {
        emit({ state: 'logged_out' });
        process.exit(0);
      }
      if (stopping) return;
      // Right after scanning the code WhatsApp asks for one restart; other drops are retried with a growing pause.
      emit({ state: 'connecting' });
      setTimeout(connect, code === DisconnectReason.restartRequired ? 0 : Math.min(30_000, 1000 * 2 ** retries++));
    }
  });
  current.ev.on('messages.upsert', (event) => {
    if (socket !== current || event.requestId) return;
    for (const message of event.messages) {
      const { key } = message;
      if (!key?.fromMe || key.participant || !key.id || sent.has(key.id)) continue;
      if (!ownJids().includes(jidNormalizedUser(key.remoteJid ?? ''))) continue;
      // Nothing from before this start: old messages would otherwise be answered again.
      if (Number(message.messageTimestamp ?? 0) < startedAt - 30) continue;
      const content = normalizeMessageContent(message.message);
      if (!content || content.protocolMessage || content.reactionMessage) continue;
      const text = content.conversation ?? content.extendedTextMessage?.text;
      if (typeof text === 'string' && text.trim()) emit({ message: { id: key.id, text } });
      else emit({ unsupported: true });
    }
  });
}

async function send(text) {
  const [jid] = ownJids();
  if (!socket || !jid) return emit({ error: 'not_connected' });
  for (let start = 0; start < text.length; start += CHUNK) {
    const result = await socket.sendMessage(jid, { text: text.slice(start, start + CHUNK) });
    if (result?.key?.id) sent.add(result.key.id);
    if (sent.size > 2000) sent.delete(sent.values().next().value);
  }
}

const lines = createInterface({ input: process.stdin });
lines.on('line', (line) => {
  let command;
  try { command = JSON.parse(line); } catch { return; }
  if (typeof command?.send === 'string' && command.send) send(command.send).catch(() => emit({ error: 'send_failed' }));
  else if (command?.logout) {
    stopping = true;
    Promise.resolve(socket?.logout()).catch(() => {}).finally(() => { emit({ state: 'logged_out' }); process.exit(0); });
  }
});
lines.on('close', () => { stopping = true; socket?.end(undefined); process.exit(0); });

connect();
