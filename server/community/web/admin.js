"use strict";

const loginPanel = document.querySelector("#login-panel");
const adminPanel = document.querySelector("#admin-panel");
const tokenInput = document.querySelector("#token");
const loginStatus = document.querySelector("#login-status");
const adminStatus = document.querySelector("#admin-status");
const adminMessages = document.querySelector("#admin-messages");
const boardState = document.querySelector("#admin-board-state");
const toggleBoardButton = document.querySelector("#toggle-board");
const clearAllButton = document.querySelector("#clear-all");
const replyContext = document.querySelector("#admin-reply-context");
const replyTarget = document.querySelector("#admin-reply-target");
let token = sessionStorage.getItem("g1r-community-admin-token") || "";
let boardOpen = true;
let replyTo = null;

function authHeaders(json = false) {
  const headers = { Authorization: `Bearer ${token}` };
  if (json) headers["Content-Type"] = "application/json";
  return headers;
}

function setLoginStatus(text, error = false) {
  loginStatus.textContent = text;
  loginStatus.classList.toggle("error", error);
}

function setAdminStatus(text, error = false) {
  adminStatus.textContent = text;
  adminStatus.classList.toggle("error", error);
}

function clearReply() {
  replyTo = null;
  replyContext.hidden = true;
  replyTarget.textContent = "";
}

function selectReply(item) {
  replyTo = { id: item.id, display_name: item.display_name };
  replyTarget.textContent = `Replying to ${item.display_name} #${item.id} / 回复 ${item.display_name} #${item.id}`;
  replyContext.hidden = false;
  document.querySelector("#admin-message").focus();
}

function renderMessage(item) {
  const card = document.createElement("article");
  card.className = `message-card ${item.role === "admin" ? "admin" : ""}`;

  const meta = document.createElement("div");
  meta.className = "message-meta";
  const name = document.createElement("span");
  name.className = "message-name";
  name.textContent = `${item.display_name} · #${item.id}`;
  const time = document.createElement("time");
  time.textContent = new Date(item.created_at).toLocaleString();
  meta.append(name, time);

  const body = document.createElement("div");
  body.className = "message-body";
  body.textContent = item.message;

  if (item.reply_to_id) {
    const reference = document.createElement("div");
    reference.className = "reply-reference";
    const targetName = item.reply_to_display_name || `#${item.reply_to_id}`;
    reference.textContent = `↳ ${targetName}: ${item.reply_to_message || ""}`;
    card.append(meta, reference, body);
  } else {
    card.append(meta, body);
  }

  const tools = document.createElement("div");
  tools.className = "message-tools";
  const reply = document.createElement("button");
  reply.type = "button";
  reply.className = "secondary compact";
  reply.textContent = "Reply / 回复";
  reply.addEventListener("click", () => selectReply(item));
  const remove = document.createElement("button");
  remove.type = "button";
  remove.className = "danger";
  remove.textContent = "Delete / 删除";
  remove.addEventListener("click", () => deleteMessage(item.id));
  tools.append(reply, remove);
  card.append(tools);
  return card;
}

async function refreshAdmin() {
  const response = await fetch("/api/v1/admin/overview", { headers: authHeaders(), cache: "no-store" });
  const data = await response.json();
  if (!response.ok || !data.ok) throw new Error(data.message || "Authentication failed");
  document.querySelector("#unique-installs").textContent = data.stats.unique_installs;
  document.querySelector("#install-events").textContent = data.stats.install_events;
  document.querySelector("#message-count").textContent = data.stats.messages;
  boardOpen = data.board_open !== false;
  boardState.textContent = boardOpen
    ? "Board is open / 留言板已开放"
    : "Player posting is closed / 已暂停玩家留言";
  boardState.classList.toggle("closed", !boardOpen);
  toggleBoardButton.textContent = boardOpen
    ? "Close board / 暂停留言"
    : "Open board / 恢复留言";
  adminMessages.replaceChildren(...data.messages.map(renderMessage));
  if (!data.messages.length) adminMessages.textContent = "No messages / 暂无留言";
}

async function login() {
  token = tokenInput.value.trim();
  try {
    await refreshAdmin();
    sessionStorage.setItem("g1r-community-admin-token", token);
    loginPanel.hidden = true;
    adminPanel.hidden = false;
  } catch (error) {
    token = "";
    sessionStorage.removeItem("g1r-community-admin-token");
    setLoginStatus(`Sign-in failed / 登录失败：${error.message}`, true);
  }
}

async function postAdmin() {
  const field = document.querySelector("#admin-message");
  const body = field.value.trim();
  if (!body) return;
  try {
    const payload = { message: body };
    if (replyTo) payload.reply_to_id = replyTo.id;
    const response = await fetch("/api/v1/admin/messages", {
      method: "POST",
      headers: authHeaders(true),
      body: JSON.stringify(payload),
    });
    const data = await response.json();
    if (!response.ok || !data.ok) throw new Error(data.message || "Request failed");
    field.value = "";
    clearReply();
    setAdminStatus("Posted as 管理员");
    await refreshAdmin();
  } catch (error) {
    setAdminStatus(error.message, true);
  }
}

async function deleteMessage(id) {
  if (!confirm(`Delete message #${id}? / 删除这条留言？`)) return;
  try {
    const response = await fetch(`/api/v1/admin/messages/${id}`, {
      method: "DELETE",
      headers: authHeaders(),
    });
    const data = await response.json();
    if (!response.ok || !data.ok) throw new Error(data.message || "Request failed");
    if (replyTo && replyTo.id === id) clearReply();
    await refreshAdmin();
  } catch (error) {
    setAdminStatus(error.message, true);
  }
}

async function toggleBoard() {
  try {
    const response = await fetch("/api/v1/admin/settings", {
      method: "POST",
      headers: authHeaders(true),
      body: JSON.stringify({ board_open: !boardOpen }),
    });
    const data = await response.json();
    if (!response.ok || !data.ok) throw new Error(data.message || "Request failed");
    await refreshAdmin();
  } catch (error) {
    setAdminStatus(error.message, true);
  }
}

async function clearAllMessages() {
  if (!confirm("Clear every message? Installation counts are kept. / 清空全部留言？安装统计会保留。")) return;
  try {
    const response = await fetch("/api/v1/admin/messages", {
      method: "DELETE",
      headers: authHeaders(),
    });
    const data = await response.json();
    if (!response.ok || !data.ok) throw new Error(data.message || "Request failed");
    clearReply();
    setAdminStatus(`Deleted ${data.deleted} messages / 已清除 ${data.deleted} 条留言`);
    await refreshAdmin();
  } catch (error) {
    setAdminStatus(error.message, true);
  }
}

document.querySelector("#login").addEventListener("click", login);
document.querySelector("#admin-post").addEventListener("click", postAdmin);
document.querySelector("#admin-refresh").addEventListener("click", () => refreshAdmin().catch(error => setAdminStatus(error.message, true)));
document.querySelector("#admin-cancel-reply").addEventListener("click", clearReply);
toggleBoardButton.addEventListener("click", toggleBoard);
clearAllButton.addEventListener("click", clearAllMessages);
tokenInput.addEventListener("keydown", event => { if (event.key === "Enter") login(); });

if (token) {
  tokenInput.value = token;
  login();
}
