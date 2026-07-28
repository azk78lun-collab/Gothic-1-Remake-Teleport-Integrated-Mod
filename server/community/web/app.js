"use strict";

const messages = document.querySelector("#messages");
const statusText = document.querySelector("#status");
const nickname = document.querySelector("#nickname");
const message = document.querySelector("#message");
const postButton = document.querySelector("#post");
const refreshButton = document.querySelector("#refresh");
const boardState = document.querySelector("#board-state");
const replyContext = document.querySelector("#reply-context");
const replyTarget = document.querySelector("#reply-target");
const cancelReplyButton = document.querySelector("#cancel-reply");
let replyTo = null;
let boardOpen = true;

function clientId() {
  const key = "g1r-community-client-id";
  let value = localStorage.getItem(key);
  if (!value) {
    value = crypto.randomUUID();
    localStorage.setItem(key, value);
  }
  return value;
}

function setStatus(text, error = false) {
  statusText.textContent = text;
  statusText.classList.toggle("error", error);
}

function clearReply() {
  replyTo = null;
  replyContext.hidden = true;
  replyTarget.textContent = "";
}

function selectReply(item) {
  if (!boardOpen) return;
  replyTo = { id: item.id, display_name: item.display_name };
  replyTarget.textContent = `Replying to ${item.display_name} #${item.id} / 回复 ${item.display_name} #${item.id}`;
  replyContext.hidden = false;
  message.focus();
}

function messageCard(item) {
  const card = document.createElement("article");
  card.className = `message-card ${item.role === "admin" ? "admin" : ""}`;

  const meta = document.createElement("div");
  meta.className = "message-meta";
  const name = document.createElement("span");
  name.className = "message-name";
  name.textContent = item.display_name;
  const time = document.createElement("time");
  time.dateTime = item.created_at;
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
  reply.disabled = !boardOpen;
  reply.addEventListener("click", () => selectReply(item));
  tools.append(reply);
  card.append(tools);
  return card;
}

async function refresh() {
  refreshButton.disabled = true;
  try {
    const response = await fetch("/api/v1/messages?limit=100", { cache: "no-store" });
    const data = await response.json();
    if (!response.ok || !data.ok) throw new Error(data.message || "Request failed");
    boardOpen = data.board_open !== false;
    messages.replaceChildren(...data.messages.map(messageCard));
    if (!data.messages.length) messages.textContent = "No messages yet / 暂无留言";
    document.querySelector("#install-count").textContent = data.stats.unique_installs;
    document.querySelector("#message-count").textContent = data.stats.messages;
    boardState.textContent = boardOpen
      ? "Board is open / 留言板已开放"
      : "Posting is temporarily closed / 留言板已临时关闭";
    boardState.classList.toggle("closed", !boardOpen);
    nickname.disabled = !boardOpen;
    message.disabled = !boardOpen;
    postButton.disabled = !boardOpen;
    if (!boardOpen) clearReply();
  } catch (error) {
    setStatus(`Unable to refresh / 刷新失败：${error.message}`, true);
  } finally {
    refreshButton.disabled = false;
  }
}

async function post() {
  const nick = nickname.value.trim();
  const body = message.value.trim();
  if (!nick || !body) {
    setStatus("Nickname and message are required / 请填写昵称和留言", true);
    return;
  }
  postButton.disabled = true;
  setStatus("Posting / 正在发布…");
  try {
    const payload = { client_id: clientId(), nickname: nick, message: body };
    if (replyTo) payload.reply_to_id = replyTo.id;
    const response = await fetch("/api/v1/messages", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    const data = await response.json();
    if (!response.ok || !data.ok) throw new Error(data.message || "Request failed");
    localStorage.setItem("g1r-community-nickname", nick);
    message.value = "";
    clearReply();
    setStatus("Posted. Select Refresh to load it. / 已发布，请点击刷新查看。");
  } catch (error) {
    setStatus(`Unable to post / 发布失败：${error.message}`, true);
  } finally {
    postButton.disabled = !boardOpen;
  }
}

nickname.value = localStorage.getItem("g1r-community-nickname") || "";
postButton.addEventListener("click", post);
refreshButton.addEventListener("click", refresh);
cancelReplyButton.addEventListener("click", clearReply);
refresh();
